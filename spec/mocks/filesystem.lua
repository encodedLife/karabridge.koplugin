--[[--
An in-memory lfs, for `karabridge.shared.filesystem`.

Only `attributes`, `mkdir` and `dir` — the three functions the filesystem
module calls. Note that `Filesystem.readFile`/`writeFile` use `io.open`
directly and are therefore *not* covered by this mock: those are exercised
against a real temporary directory instead, because the interesting failures
there (a rename across devices, a full disk) are exactly the ones a mock would
paper over.

@module spec.mocks.filesystem
]]

local MockFilesystem = {}

local entries = {}

--- Declare a directory as existing.
-- @tparam string path
function MockFilesystem.addDirectory(path)
    entries[path] = { mode = "directory" }
end

--- Declare a file as existing.
-- @tparam string path
-- @tparam[opt=0] number size
function MockFilesystem.addFile(path, size)
    entries[path] = { mode = "file", size = size or 0 }
end

--- Forget everything. Call between specs.
function MockFilesystem.reset()
    entries = {}
end

function MockFilesystem.attributes(path, key)
    local entry = entries[path]
    if not entry then
        return nil
    end
    if key then
        return entry[key]
    end
    return entry
end

function MockFilesystem.mkdir(path)
    if entries[path] then
        return nil, "File exists"
    end
    entries[path] = { mode = "directory" }
    return true
end

function MockFilesystem.dir(path)
    local names = {}
    local prefix = path:gsub("/+$", "") .. "/"

    for candidate in pairs(entries) do
        if candidate:sub(1, #prefix) == prefix then
            local rest = candidate:sub(#prefix + 1)
            if rest ~= "" and not rest:find("/") then
                table.insert(names, rest)
            end
        end
    end
    table.sort(names)

    table.insert(names, 1, ".")
    table.insert(names, 2, "..")

    -- Two values, like the real lfs: an iterator plus a state object it is
    -- called with. A mock returning a bare closure lets `for e in iter do`
    -- pass here and fail on device with "directory metatable expected".
    local state = { index = 0 }
    return function(s)
        s.index = s.index + 1
        return names[s.index]
    end, state
end

return MockFilesystem
