--[[--
A stand-in for KOReader's DocSettings, backed by a table per document.

Enough to exercise `karabridge.shared.metadata`: sidecar presence, reading and
writing a key, and flushing. Real `.sdr` directories are not involved, so the
metadata specs stay fast and leave nothing behind.

    MockDocSettings.seed("/books/x.epub", { karakeep = { bookmark = { id = "a" } } })
    local data = Metadata.read("/books/x.epub")

@module spec.mocks.docsettings
]]

local MockDocSettings = {}

-- doc path -> settings table
local store = {}
-- doc path -> number of flushes, so "did this persist" is assertable
local flushes = {}
-- doc paths whose writes should fail, so the recovery path is testable.
local readonly = {}

local Handle = {}
Handle.__index = Handle

function Handle:readSetting(key, default)
    local values = store[self.path]
    if values[key] == nil and default ~= nil then
        values[key] = default
    end
    return values[key]
end

function Handle:saveSetting(key, value)
    if readonly[self.path] then
        -- What a read-only mount, a full disk or a pulled SD card looks like.
        error("cannot write sidecar for " .. self.path)
    end
    store[self.path][key] = value
    return self
end

function Handle:delSetting(key)
    store[self.path][key] = nil
    return self
end

function Handle:flush()
    flushes[self.path] = (flushes[self.path] or 0) + 1
    return self
end

--- Pretend a document already has a sidecar with these settings.
-- @tparam string path
-- @tparam table values
function MockDocSettings.seed(path, values)
    store[path] = values or {}
end

--- Make writes to a document fail, as an unwritable sidecar would.
-- @tparam string path
function MockDocSettings.makeUnwritable(path)
    readonly[path] = true
end

--- Forget every document. Call between specs.
function MockDocSettings.reset()
    store = {}
    flushes = {}
    readonly = {}
end

--- The raw settings table for a document, for assertions.
-- @tparam string path
-- @treturn table|nil
function MockDocSettings.peek(path)
    return store[path]
end

--- How many times a document's sidecar was flushed.
-- @tparam string path
-- @treturn number
function MockDocSettings.flushCount(path)
    return flushes[path] or 0
end

function MockDocSettings.hasSidecarFile(_, path)
    return store[path] ~= nil
end

function MockDocSettings.open(_, path)
    if store[path] == nil then
        store[path] = {}
    end
    -- `data` mirrors the real DocSettings, which exposes the raw table. It is
    -- what lets Metadata.wasOpened scan for copt_* keys, since DocSettings has
    -- no "list my keys" call.
    return setmetatable({ path = path, data = store[path] }, Handle)
end

return MockDocSettings
