--[[--
A note of remote objects whose local mapping could not be written.

The failure this exists for:

    Karakeep card created           -> succeeded, and it has an ID
    sidecar write fails             -> the ID is lost
    next export finds no ID         -> creates a *second* card

The remote side did what was asked; only the record of it was lost. Left
unhandled, every subsequent export duplicates the book, and the user ends up
deleting cards by hand with no idea why they keep appearing.

Sidecar writes fail for ordinary reasons: an SD card pulled out, a read-only
mount, a full disk, a `.sdr` directory the user deleted between operations. So
this is not a theoretical case.

The journal lives **outside** the book's sidecar, in KaraBridge's own settings,
precisely because the sidecar is the thing that just failed. Before creating a
remote object, callers ask here first; after a successful sidecar write, they
clear the entry. An entry that survives is visible in Diagnostics.

@module karabridge.shared.recovery
]]

local Logging = require("karabridge.shared.logging")

local log = Logging.forModule("recovery")

local Recovery = {}
Recovery.__index = Recovery

Recovery.KEY = "karabridge_recovery"
Recovery.SCHEMA_VERSION = 1

--- @tparam table opts `{ store = <LuaSettings-compatible> }`
function Recovery.new(opts)
    assert(type(opts) == "table" and type(opts.store) == "table", "Recovery.new requires a store")

    local instance = setmetatable({ store = opts.store, dirty = false }, Recovery)

    local raw = opts.store:readSetting(Recovery.KEY)
    if type(raw) ~= "table" or type(raw.entries) ~= "table" then
        instance.data = { version = Recovery.SCHEMA_VERSION, entries = {} }
    else
        instance.data = { version = Recovery.SCHEMA_VERSION, entries = raw.entries }
    end

    return instance
end

local function compose(kind, key)
    return tostring(kind) .. "\0" .. tostring(key)
end

--- Record that a remote object exists but its local mapping was not written.
-- @tparam string kind "book_card" or "article"
-- @tparam string key The local file path.
-- @tparam string bookmark_id
function Recovery:record(kind, key, bookmark_id)
    if type(bookmark_id) ~= "string" or bookmark_id == "" then
        return
    end

    self.data.entries[compose(kind, key)] = {
        kind = kind,
        key = key,
        bookmark_id = bookmark_id,
        at = os.time(),
    }
    self.dirty = true

    log.warn("remote object", bookmark_id, "created but its local mapping could not be written for", tostring(key))
end

--- The remote ID recorded for this file, if the mapping was never written.
-- @tparam string kind
-- @tparam string key
-- @treturn string|nil
function Recovery:lookup(kind, key)
    local entry = self.data.entries[compose(kind, key)]
    return entry and entry.bookmark_id or nil
end

--- Forget an entry, once its mapping has been written successfully.
-- @tparam string kind
-- @tparam string key
function Recovery:clear(kind, key)
    local composed = compose(kind, key)
    if self.data.entries[composed] then
        self.data.entries[composed] = nil
        self.dirty = true
    end
end

--- Every outstanding entry, sorted, for Diagnostics.
-- @treturn table Array of `{ kind, key, bookmark_id, at }`.
function Recovery:all()
    local list = {}
    for _, entry in pairs(self.data.entries) do
        table.insert(list, entry)
    end
    table.sort(list, function(a, b)
        return tostring(a.key) < tostring(b.key)
    end)
    return list
end

function Recovery:count()
    local total = 0
    for _ in pairs(self.data.entries) do
        total = total + 1
    end
    return total
end

function Recovery:clearAll()
    self.data.entries = {}
    self.dirty = true
end

--- Write to disk, if anything changed.
-- @treturn boolean Whether a write happened.
function Recovery:flush()
    if not self.dirty then
        return false
    end

    self.store:saveSetting(Recovery.KEY, self.data)
    self.store:flush()
    self.dirty = false

    return true
end

--- A no-op journal, for callers that have not been given one.
--
-- Returned rather than nil so every call site can use it unconditionally; a
-- missing journal degrades to the old behaviour rather than to a crash.
-- @treturn table
function Recovery.none()
    return setmetatable({
        store = { readSetting = function() end, saveSetting = function() end, flush = function() end },
        data = { version = Recovery.SCHEMA_VERSION, entries = {} },
        dirty = false,
    }, Recovery)
end

return Recovery
