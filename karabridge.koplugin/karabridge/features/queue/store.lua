--[[--
The persistent queue's storage, and nothing else.

For operations with no durable local state to reconstruct them from. Article
reading status does not belong here — that already lives in the `.sdr` sidecar
and is reconciled on every sync, so a queue for it would be a second source of
truth that could drift. What does belong here is capturing a link while
offline: nothing on disk records the intent, so if it is not queued it is lost.

## The envelope

    {
        version    = 1,
        entries    = { [key] = { action, payload, attempts, last_error,
                                 created_at, updated_at } },
        quarantine = { [key] = { entry, reason, at } },
    }

An envelope rather than a flat table. Storing a `_length`
*inside* the entries table, so every iteration has to skip it by name and a
queued item called `_length` would corrupt the count. Keeping payload and
bookkeeping in separate namespaces makes that impossible.

## Quarantine

An entry that does not validate is moved aside with the reason, and the rest of
the queue processes normally. The two obvious alternatives are both worse:
silently dropping it is data loss, and retrying it forever blocks everything
behind it. Parked where the diagnostics menu can show it is neither.

The backing store is injected, so this is exercised by fast specs with no disk.

@module karabridge.features.queue.store
]]

local Logging = require("karabridge.shared.logging")

local log = Logging.forModule("queue.store")

local Store = {}
Store.__index = Store

Store.SCHEMA_VERSION = 1
Store.KEY = "karabridge_queue"

--- How many times an entry is retried before it is parked.
--
-- A bounded number, because an entry that fails deterministically — a URL the
-- server will always reject — would otherwise be retried on every sync for
-- ever, and its error would drown out real failures.
Store.MAX_ATTEMPTS = 5

--- @tparam table opts `{ store = <LuaSettings-compatible> }`
function Store.new(opts)
    assert(type(opts) == "table" and type(opts.store) == "table", "Store.new requires a store")

    local instance = setmetatable({ store = opts.store, dirty = false }, Store)
    instance:load()
    return instance
end

--- Is this a usable queue entry?
--
-- Pure, and the gate everything passes through on the way in and on the way
-- out. Anything that fails is quarantined rather than trusted.
--
-- @param entry any
-- @treturn boolean ok
-- @treturn string|nil reason
function Store.validate(entry)
    if type(entry) ~= "table" then
        return false, "not a table"
    end
    if type(entry.action) ~= "string" or entry.action == "" then
        return false, "no action"
    end
    if type(entry.payload) ~= "table" then
        return false, "no payload"
    end
    return true
end

--- Read the envelope, migrating and quarantining as needed.
function Store:load()
    local raw = self.store:readSetting(Store.KEY)

    if type(raw) ~= "table" then
        self.data = { version = Store.SCHEMA_VERSION, entries = {}, quarantine = {} }
        return
    end

    local entries = type(raw.entries) == "table" and raw.entries or {}
    local quarantine = type(raw.quarantine) == "table" and raw.quarantine or {}

    -- Validate on the way in. A corrupt entry that reaches processing would
    -- fail on every run for ever; here it is set aside once.
    local clean = {}
    for key, entry in pairs(entries) do
        local ok, reason = Store.validate(entry)
        if ok then
            clean[key] = entry
        else
            log.warn("quarantining a corrupt queue entry:", tostring(key), "-", tostring(reason))
            quarantine[key] = { entry = entry, reason = reason, at = os.time() }
            self.dirty = true
        end
    end

    self.data = {
        version = Store.SCHEMA_VERSION,
        entries = clean,
        quarantine = quarantine,
    }

    if tonumber(raw.version) ~= Store.SCHEMA_VERSION then
        self.dirty = true
    end
end

--- Add or replace an entry.
--
-- Keyed, so queueing the same thing twice leaves one entry. The key is the
-- caller's choice of natural identity — a URL for a link, a file path for a
-- book card.
--
-- @tparam string key
-- @tparam string action
-- @tparam table payload
-- @treturn boolean Whether it was stored.
function Store:add(key, action, payload)
    local entry = {
        action = action,
        payload = payload,
        attempts = 0,
        last_error = nil,
        created_at = os.time(),
        updated_at = os.time(),
    }

    local ok, reason = Store.validate(entry)
    if not ok then
        log.err("refusing to queue an invalid entry:", tostring(reason))
        return false
    end

    local existing = self.data.entries[key]
    if existing then
        -- Keep the original creation time and the attempt count: re-queueing
        -- the same thing is not a fresh start, and resetting attempts would
        -- defeat MAX_ATTEMPTS for something that keeps being retried.
        entry.created_at = existing.created_at or entry.created_at
        entry.attempts = existing.attempts or 0
    end

    self.data.entries[key] = entry
    self.dirty = true

    log.dbg("queued", action, "as", key)
    return true
end

function Store:remove(key)
    if self.data.entries[key] then
        self.data.entries[key] = nil
        self.dirty = true
    end
end

function Store:has(key)
    return self.data.entries[key] ~= nil
end

--- Record a failed attempt, parking the entry once it has had too many.
-- @tparam string key
-- @tparam string message
-- @treturn boolean Whether the entry is still queued.
function Store:recordFailure(key, message)
    local entry = self.data.entries[key]
    if not entry then
        return false
    end

    entry.attempts = (entry.attempts or 0) + 1
    entry.last_error = message
    entry.updated_at = os.time()
    self.dirty = true

    if entry.attempts >= Store.MAX_ATTEMPTS then
        log.warn("parking", key, "after", entry.attempts, "attempts:", tostring(message))
        self:quarantine(key, string.format("failed %d times: %s", entry.attempts, tostring(message)))
        return false
    end

    return true
end

--- Move an entry aside, with the reason.
-- @tparam string key
-- @tparam string reason
function Store:quarantine(key, reason)
    local entry = self.data.entries[key]
    if not entry then
        return
    end

    self.data.quarantine[key] = { entry = entry, reason = reason, at = os.time() }
    self.data.entries[key] = nil
    self.dirty = true
end

--- Put a quarantined entry back in the queue, with its attempts reset.
-- @tparam string key
-- @treturn boolean
function Store:release(key)
    local parked = self.data.quarantine[key]
    if not parked then
        return false
    end

    local ok = Store.validate(parked.entry)
    if not ok then
        return false
    end

    parked.entry.attempts = 0
    parked.entry.last_error = nil
    self.data.entries[key] = parked.entry
    self.data.quarantine[key] = nil
    self.dirty = true

    return true
end

--- Every queued entry, oldest first.
--
-- Sorted, so processing order is reproducible and a spec can assert on it;
-- `pairs()` over a hash is not stable across Lua states.
--
-- @treturn table Array of `{ key, entry }`.
function Store:pending()
    local list = {}
    for key, entry in pairs(self.data.entries) do
        table.insert(list, { key = key, entry = entry })
    end

    table.sort(list, function(a, b)
        local a_at, b_at = a.entry.created_at or 0, b.entry.created_at or 0
        if a_at ~= b_at then
            return a_at < b_at
        end
        return a.key < b.key
    end)

    return list
end

--- Every quarantined entry.
-- @treturn table Array of `{ key, reason, at }`.
function Store:parked()
    local list = {}
    for key, parked in pairs(self.data.quarantine) do
        table.insert(list, { key = key, reason = parked.reason, at = parked.at })
    end
    table.sort(list, function(a, b)
        return a.key < b.key
    end)
    return list
end

function Store:count()
    local total = 0
    for _ in pairs(self.data.entries) do
        total = total + 1
    end
    return total
end

function Store:parkedCount()
    local total = 0
    for _ in pairs(self.data.quarantine) do
        total = total + 1
    end
    return total
end

--- Empty the queue. Does not touch quarantine.
function Store:clear()
    self.data.entries = {}
    self.dirty = true
end

--- Empty quarantine.
function Store:clearParked()
    self.data.quarantine = {}
    self.dirty = true
end

--- Write to disk, if anything changed.
--
-- Guarded on `dirty` because this runs on KOReader's flush event, which fires
-- often, and a Kobo's flash does not enjoy being rewritten for nothing.
function Store:flush()
    if not self.dirty then
        return false
    end

    self.store:saveSetting(Store.KEY, self.data)
    self.store:flush()
    self.dirty = false

    return true
end

return Store
