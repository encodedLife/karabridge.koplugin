--[[--
Replacing the running plugin with a newer one.

This is the only place in KaraBridge that overwrites itself, so it is written
to fail safely rather than quickly. The order matters and each step exists
because of a way this goes wrong:

1. **Download** the zip next to the plugins directory. Next to, not into a
   cache: the swap is done with `os.rename`, which does not cross filesystems,
   and on a Kobo the cache and the plugins need not be on the same one.
2. **Verify before touching anything.** The archive must open, and must contain
   `_meta.lua` and `main.lua`. A truncated download or a mis-built release is
   caught here, while the working copy is still untouched.
3. **Extract** to a sibling directory. Neither `.new` nor `.old` ends in
   `.koplugin`, so KOReader's plugin loader ignores both.
4. **Carry the configuration over.** `karabridge.conf` may live *inside* the
   plugin directory -- `config/paths.lua` lists it as a location -- so a
   replacement that skipped this would delete the user's server address and API
   key on the first update.
5. **Swap** with two renames, and undo the first if the second fails.
6. **Restart**, because Lua has already loaded the old code into memory.

What this deliberately does not do: verify a signature. The trust boundary is
TLS plus the GitHub account, and pretending otherwise would be worse than
saying so.

@module karabridge.features.update.install
]]

local Filesystem = require("karabridge.shared.filesystem")
local Github = require("karabridge.api.github")
local Logging = require("karabridge.shared.logging")
local Paths = require("karabridge.shared.paths")
local Result = require("karabridge.shared.result")
local Text = require("karabridge.shared.text")

local log = Logging.forModule("update.install")

local Install = {}

-- Files a KaraBridge archive must contain to be one.
Install.REQUIRED = { "_meta.lua", "main.lua" }

--- Is this archive entry safe to write?
--
-- An archive says where its contents should go, and that is a decision made by
-- whoever built it. `destination .. "/" .. entry.path` will happily walk out of
-- the destination given `../../`, and an absolute path ignores the destination
-- altogether -- the classic zip-slip.
--
-- The realistic threat here is small: the archive comes from a GitHub release in
-- a repository the user configured, and anyone who controls that repository
-- controls the plugin's code anyway. But "you would have to be compromised
-- already" is a poor reason to write a file wherever a stranger asks, and the
-- check costs four comparisons.
--
-- @tparam any path
-- @treturn boolean
-- @treturn string|nil why not
function Install.isSafeEntry(path)
    if type(path) ~= "string" or path == "" then
        return false, "an entry with no name"
    end
    if path:find("\\", 1, true) then
        -- A backslash is a separator on one platform and an ordinary character
        -- on another, so a path containing one means different things depending
        -- on who expands it. Refused rather than guessed at.
        return false, path
    end
    if path:sub(1, 1) == "/" or path:match("^%a:") then
        return false, path
    end
    for component in path:gmatch("[^/]+") do
        if component == ".." then
            return false, path
        end
    end
    return true
end

-- Replaced by the specs, which have neither libarchive nor a device.
local archiver

--- Replace the archive backend. Used by the specs.
-- @tparam table|nil backend `{ entries(zip), unpack(zip, dest, strip) }`
function Install.setArchiver(backend)
    archiver = backend
end

--- The archive backend, defaulting to KOReader's.
local function archive()
    if archiver then
        return archiver
    end

    return {
        --- Every path inside the archive.
        entries = function(zip)
            local ok, Archiver = pcall(require, "ffi/archiver")
            if not ok then
                return nil, "this KOReader has no archive support"
            end

            local reader = Archiver.Reader:new()
            if not reader:open(zip) then
                return nil, "the archive could not be opened"
            end

            local paths = {}
            for entry in reader:iterate() do
                table.insert(paths, entry.path)
            end
            reader:close()

            return paths
        end,

        --- Extract, stripping the archive's single root directory.
        --
        -- Done with `ffi/archiver` rather than `Device:unpackArchive`, which is
        -- the obvious call and was the first implementation. It was wrong:
        -- `unpackArchive` is recent, and a KOReader without it -- which is most
        -- of them still in use -- could not install an update at all. It failed
        -- with "this KOReader cannot unpack archives", which reads like a
        -- limitation of the device rather than a mistake of ours.
        --
        -- The logic below is `Device:unpackArchive`'s, because there is no
        -- reason to differ from it: iterate, strip one leading path component,
        -- skip the root directory entry itself.
        unpack = function(zip, destination)
            local ok, Archiver = pcall(require, "ffi/archiver")
            if not ok or type(Archiver.Reader) ~= "table" then
                return false, "this KOReader has no archive support"
            end

            local reader = Archiver.Reader:new()
            if not reader:open(zip) then
                return false, "the archive could not be opened"
            end

            Filesystem.ensureDirectory(destination)

            for entry in reader:iterate() do
                -- Checked again here, not only in looksRight: this is the line
                -- that actually writes, and a guard belongs where the damage
                -- would be done.
                if not Install.isSafeEntry(entry.path) then
                    reader:close()
                    return false, "the archive contains an unsafe path: " .. tostring(entry.path)
                end

                local target = entry.path
                local _, tail = target:match("([^/]*)/*(.*)")

                if tail and tail ~= "" then
                    target = tail
                elseif entry.mode == "directory" then
                    -- The archive's own root directory; there is nothing to
                    -- create for it, the destination already exists.
                    target = nil
                end

                if target then
                    if not reader:extractToPath(entry.path, destination .. "/" .. target) then
                        break
                    end
                end
            end

            local failed = reader.err
            reader:close()

            if failed then
                return false, tostring(failed)
            end
            return true
        end,
    }
end

--- Does this archive look like a KaraBridge plugin?
--
-- Checked before anything is replaced. The paths may or may not sit under a
-- single root directory, depending on how the zip was built, so the tail of
-- each entry is what is compared.
--
-- @tparam table paths
-- @treturn boolean ok
-- @treturn string|nil what is missing
function Install.looksRight(paths)
    local seen = {}
    local roots = {}

    for _, path in ipairs(paths or {}) do
        local safe, offender = Install.isSafeEntry(path)
        if not safe then
            return false, "an entry that would be written outside the plugin folder: " .. tostring(offender)
        end

        local tail = path:match("([^/]+)$")
        if tail then
            seen[tail] = true
        end

        -- One root directory, because that is what is stripped on the way out.
        -- Two roots would mean half the archive landing a level too high.
        local head = path:match("^([^/]+)/")
        if head then
            roots[head] = true
        end
    end

    local root_count = 0
    for _ in pairs(roots) do
        root_count = root_count + 1
    end
    if root_count > 1 then
        return false, "more than one top-level directory"
    end

    for _, required in ipairs(Install.REQUIRED) do
        if not seen[required] then
            return false, required
        end
    end

    return true
end

--- Where the working, staging and previous copies live.
-- @tparam string plugin_dir The directory the running plugin was loaded from.
-- @treturn table
function Install.paths(plugin_dir)
    local trimmed = plugin_dir:gsub("/+$", "")
    return {
        live = trimmed,
        staging = trimmed .. ".new",
        previous = trimmed .. ".old",
        -- Beside the plugins directory rather than in a cache, so every rename
        -- below stays on one filesystem.
        download = trimmed .. ".download.zip",
    }
end

--- Move the user's configuration into the replacement, if it lives here.
--
-- Without this the first update deletes the server address and the API key of
-- anyone who kept `karabridge.conf` in the plugin directory, which
-- `config/paths.lua` explicitly allows.
--
-- @tparam table paths
-- @treturn boolean Whether a config file was carried over.
function Install.carryConfiguration(paths)
    local existing = Paths.join(paths.live, "karabridge.conf")
    if not Filesystem.fileExists(existing) then
        return false
    end

    -- Both of these return a Result, not a value. Treating them as plain
    -- returns crashed the install with "string expected, got table" -- and did
    -- it in the one step whose whole purpose is not to lose the user's API key.
    local content = Filesystem.readFile(existing)
    if content:isErr() then
        log.warn("could not read the configuration to carry it over -", content:describe())
        return false
    end

    local carried = Filesystem.writeFile(Paths.join(paths.staging, "karabridge.conf"), content.value)
    if carried:isErr() then
        log.warn("could not write the configuration into the new copy -", carried:describe())
        return false
    end

    return true
end

--- Remove a directory tree.
local function removeTree(path)
    if not Filesystem.directoryExists(path) then
        return
    end
    -- Only ever called on directories this module made or renamed, and only
    -- with a path derived from the plugin's own location.
    os.execute(string.format("rm -rf %q", path))
end

--- Download, verify and install the newest release.
--
-- @tparam table opts settings, plugin_dir, release (from `check`), progress,
--   request
-- @treturn Result Value is `{ version, restart_required }`.
function Install.run(opts)
    local settings = opts.settings
    local release = opts.release
    local plugin_dir = opts.plugin_dir

    -- Each phase says what it is doing. Unpacking seventy files on a Kobo's
    -- flash is slow enough that a screen frozen on "Downloading" reads as a
    -- hang, and this is the one operation where a hang would be alarming --
    -- the plugin is replacing itself.
    local step = opts.progress or function()
        return true
    end

    if type(plugin_dir) ~= "string" or plugin_dir == "" then
        return Result.err("no_plugin_dir", "KaraBridge does not know where it is installed.")
    end
    if type(release) ~= "table" or type(release.asset) ~= "table" then
        return Result.err("no_asset", "That release has no zip to install.")
    end

    local api = Github.new({
        repo = Text.trim(settings:get("update_repo") or ""),
        token = settings:get("update_token"),
        request = opts.request,
        sleep = opts.sleep,
    })
    if not api then
        return Result.err("bad_repo", "'update_repo' should look like owner/name.")
    end

    local paths = Install.paths(plugin_dir)

    removeTree(paths.staging)
    removeTree(paths.previous)
    os.remove(paths.download)

    step("Downloading " .. tostring(release.tag) .. Text.ELLIPSIS)
    local downloaded = api:downloadAsset(release.asset, paths.download)
    if downloaded:isErr() then
        os.remove(paths.download)
        return downloaded
    end

    local installed = Install.fromArchive({
        zip = paths.download,
        plugin_dir = plugin_dir,
        progress = step,
    })

    os.remove(paths.download)

    if installed:isErr() then
        return installed
    end

    log.info("installed", tostring(release.tag))
    return Result.ok({ version = release.tag, restart_required = true })
end

--- Verify an archive and put it in place, without downloading anything.
--
-- Split out from `run` so the part that can destroy a working installation can
-- be exercised directly -- by a spec, and by `scripts/release.sh` against the
-- zip it has just built, before that zip is ever published. 0.0.2 shipped a
-- crash in here precisely because this could only be reached through a
-- download, so nothing checked it until someone tried to update.
--
-- @tparam table opts zip, plugin_dir, progress
-- @treturn Result Value is `{ version }` read from the installed `_meta.lua`.
function Install.fromArchive(opts)
    local zip = opts.zip
    local plugin_dir = opts.plugin_dir
    local step = opts.progress or function()
        return true
    end

    if type(plugin_dir) ~= "string" or plugin_dir == "" then
        return Result.err("no_plugin_dir", "KaraBridge does not know where it is installed.")
    end

    local paths = Install.paths(plugin_dir)
    local fs = archive()

    removeTree(paths.staging)
    removeTree(paths.previous)

    -- Verify, while the working copy is still untouched.
    step("Checking the download" .. Text.ELLIPSIS)
    local paths_in_zip, entries_error = fs.entries(zip)
    if not paths_in_zip then
        return Result.err("bad_archive", "The download could not be read: " .. tostring(entries_error))
    end

    local right, missing = Install.looksRight(paths_in_zip)
    if not right then
        return Result.err("bad_archive", "That zip is not a KaraBridge plugin; " .. missing .. " is missing.")
    end

    -- Extract.
    step("Unpacking" .. Text.ELLIPSIS)
    local unpacked, unpack_error = fs.unpack(zip, paths.staging)
    if not unpacked then
        removeTree(paths.staging)
        return Result.err("unpack_failed", "The update could not be unpacked: " .. tostring(unpack_error))
    end

    -- Keep the configuration.
    Install.carryConfiguration(paths)

    -- Swap, and undo the first rename if the second fails.
    step("Installing" .. Text.ELLIPSIS)
    local moved_away = os.rename(paths.live, paths.previous)
    if not moved_away then
        removeTree(paths.staging)
        return Result.err("swap_failed", "The old version could not be moved aside; nothing was changed.")
    end

    local moved_in = os.rename(paths.staging, paths.live)
    if not moved_in then
        os.rename(paths.previous, paths.live)
        removeTree(paths.staging)
        return Result.err("swap_failed", "The new version could not be put in place; the old one was restored.")
    end

    removeTree(paths.previous)

    return Result.ok({ version = Install.installedVersion(plugin_dir) })
end

--- The version recorded in an installed copy's `_meta.lua`.
-- @tparam string plugin_dir
-- @treturn string|nil
function Install.installedVersion(plugin_dir)
    local meta = Filesystem.readFile(Paths.join(plugin_dir, "_meta.lua"))
    if meta:isErr() then
        return nil
    end
    return meta.value:match('version%s*=%s*"([^"]+)"')
end

return Install
