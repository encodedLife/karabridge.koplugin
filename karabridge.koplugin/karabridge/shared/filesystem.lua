--[[--
The disk-touching half of path handling.

Everything here goes through an injectable backend so that the specs can drive
it with an in-memory filesystem, and so a future port to a device without
`libkoreader-lfs` has one place to change. `karabridge.shared.paths` holds the
pure string manipulation.

@module karabridge.shared.filesystem
]]

local Paths = require("karabridge.shared.paths")
local Result = require("karabridge.shared.result")

local Filesystem = {}

local backend

--- Resolve the filesystem backend, preferring KOReader's bundled lfs.
local function lfs()
    if backend then
        return backend
    end

    local ok, module = pcall(require, "libs/libkoreader-lfs")
    if not ok then
        ok, module = pcall(require, "lfs")
    end

    if ok and type(module) == "table" then
        backend = module
    else
        -- No lfs at all: every query answers "not there", which is the safe
        -- answer, and every mutation fails loudly rather than silently.
        backend = {
            attributes = function()
                return nil
            end,
            mkdir = function()
                return nil, "no filesystem backend"
            end,
            dir = function()
                return function()
                    return nil
                end
            end,
        }
    end

    return backend
end

--- Replace the filesystem backend. Used by the specs.
-- @tparam table|nil module lfs-compatible table, or nil to reset.
function Filesystem.setBackend(module)
    backend = module
end

--- Does a regular file exist at this path?
-- @tparam any path
-- @treturn boolean
function Filesystem.fileExists(path)
    if type(path) ~= "string" or path == "" then
        return false
    end
    return lfs().attributes(path, "mode") == "file"
end

--- Does a directory exist at this path?
-- @tparam any path
-- @treturn boolean
function Filesystem.directoryExists(path)
    if type(path) ~= "string" or path == "" then
        return false
    end
    return lfs().attributes(path, "mode") == "directory"
end

--- Size of a file in bytes, or nil.
-- @tparam any path
-- @treturn number|nil
function Filesystem.fileSize(path)
    if type(path) ~= "string" or path == "" then
        return nil
    end
    return lfs().attributes(path, "size")
end

--- Create a directory and any missing parents.
-- @tparam any path
-- @treturn Result
function Filesystem.ensureDirectory(path)
    if type(path) ~= "string" or path == "" then
        return Result.err("invalid_path", "No folder was given.")
    end
    if Filesystem.directoryExists(path) then
        return Result.ok(path)
    end

    local normalised = Paths.normalise(path)
    local accumulated = normalised:sub(1, 1) == "/" and "" or "."

    for segment in normalised:gmatch("[^/]+") do
        accumulated = accumulated .. "/" .. segment
        if not Filesystem.directoryExists(accumulated) then
            lfs().mkdir(accumulated)
        end
    end

    if not Filesystem.directoryExists(path) then
        return Result.err("mkdir_failed", "The folder does not exist and could not be created.", { path = path })
    end

    return Result.ok(path)
end

-- Name of the probe file written to test whether a folder is usable. Dotted so
-- it stays out of the way in the file manager if a crash ever leaves one behind.
Filesystem.PROBE_NAME = ".karabridge-write-test"

--- Confirm a folder exists, can be created, and can actually be written to.
--
-- Without this check an unwritable download folder surfaces only as every
-- single article failing to build, one confusing line at a time, from deep
-- inside the zip writer. Under Flatpak an unreachable folder is the likely
-- default rather than an edge case, so the error names that possibility.
--
-- @tparam any path
-- @treturn Result Error codes: "invalid_path", "mkdir_failed", "not_writable".
function Filesystem.checkWritableDirectory(path)
    if type(path) ~= "string" or path == "" then
        return Result.err("invalid_path", "No download folder is set.")
    end

    local created = Filesystem.ensureDirectory(path)
    if created:isErr() then
        return created
    end

    local probe = Paths.join(path, Filesystem.PROBE_NAME)
    local handle = io.open(probe, "w")
    if not handle then
        return Result.err("not_writable", "The download folder cannot be written to.", { path = path })
    end

    handle:write("ok")
    handle:close()
    os.remove(probe)

    return Result.ok(path)
end

--- Read a whole file into memory.
-- @tparam any path
-- @treturn Result Error codes: "invalid_path", "not_found".
function Filesystem.readFile(path)
    if type(path) ~= "string" or path == "" then
        return Result.err("invalid_path", "No file path was given.")
    end

    local handle = io.open(path, "r")
    if not handle then
        return Result.err("not_found", "The file could not be opened.", { path = path })
    end

    local content = handle:read("*a")
    handle:close()

    return Result.ok(content or "")
end

--- Move `source` onto `target`, keeping the old target if anything fails.
--
-- The obvious version of this is wrong:
--
--     os.remove(target)
--     os.rename(source, target)   -- if this fails, target is gone for good
--
-- On POSIX `rename()` over an existing file is already atomic, so the remove
-- is not only unnecessary, it opens a window in which a failure destroys the
-- only good copy. The remove exists because a rename over an existing file
-- fails on some filesystems, which is a real concern on a Kobo's FAT32
-- partition.
--
-- So: try the atomic rename first. Only if that fails move the old file aside,
-- retry, and put it back when the retry also fails. The user's previous EPUB
-- survives every branch.
--
-- @tparam string source
-- @tparam string target
-- @treturn Result Error code: "rename_failed".
function Filesystem.replaceFile(source, target)
    -- The atomic path, and the one taken on every normal Linux filesystem.
    if os.rename(source, target) then
        return Result.ok(target)
    end

    if not Filesystem.fileExists(target) then
        -- Nothing was in the way, so the rename failed for a real reason --
        -- a full disk, a bad path, a different device.
        local _, reason = os.rename(source, target)
        os.remove(source)
        return Result.err("rename_failed", "The file could not be saved.", { path = target, reason = reason })
    end

    local backup = target .. ".karabridge-old"
    os.remove(backup)

    if not os.rename(target, backup) then
        os.remove(source)
        return Result.err("rename_failed", "The existing file could not be moved aside.", { path = target })
    end

    local renamed, reason = os.rename(source, target)
    if not renamed then
        -- Put the old file back. Losing a half-read article to a failed
        -- refresh would be far worse than not refreshing it.
        os.rename(backup, target)
        os.remove(source)
        return Result.err("rename_failed", "The file could not be replaced.", { path = target, reason = reason })
    end

    os.remove(backup)
    return Result.ok(target)
end

--- Write a file, replacing any existing one.
--
-- Written to a temporary name and moved into place by `replaceFile`, so a
-- failure part way through leaves the previous file intact rather than a
-- truncated one or none at all. This matters most for the queue, which is
-- rewritten on every flush and holds intent that exists nowhere else.
--
-- @tparam any path
-- @tparam string content
-- @treturn Result Error codes: "invalid_path", "open_failed", "write_failed",
--   "rename_failed".
function Filesystem.writeFile(path, content)
    if type(path) ~= "string" or path == "" then
        return Result.err("invalid_path", "No file path was given.")
    end

    local tmp_path = path .. ".karabridge-tmp"
    local handle, open_error = io.open(tmp_path, "w")
    if not handle then
        return Result.err("open_failed", "The file could not be opened for writing.", {
            path = path,
            reason = open_error,
        })
    end

    -- Both are checked. A full disk shows up at one or the other, and
    -- reporting success for a truncated file is how a queue quietly loses
    -- entries.
    local written, write_error = handle:write(content or "")
    local closed, close_error = handle:close()

    if not written or not closed then
        os.remove(tmp_path)
        return Result.err("write_failed", "The file could not be written; the disk may be full.", {
            path = path,
            reason = write_error or close_error,
        })
    end

    local replaced = Filesystem.replaceFile(tmp_path, path)
    if replaced:isErr() then
        return replaced
    end

    return Result.ok(path)
end

--- Iterate the entries of a directory, excluding "." and "..".
-- @tparam any path
-- @treturn table Array of entry names; empty when the directory is unreadable.
function Filesystem.listDirectory(path)
    local entries = {}
    if not Filesystem.directoryExists(path) then
        return entries
    end

    -- lfs.dir returns *two* values: the iterator and a directory object that
    -- the iterator needs as its state. Keeping only the first gives
    -- "directory metatable expected, got nil" on the first call, and a mock
    -- that returns a bare closure hides it -- which is how this shipped once.
    local ok, iterator, state = pcall(lfs().dir, path)
    if not ok or type(iterator) ~= "function" then
        return entries
    end

    for entry in iterator, state do
        if entry ~= "." and entry ~= ".." then
            table.insert(entries, entry)
        end
    end

    return entries
end

return Filesystem
