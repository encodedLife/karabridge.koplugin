--[[--
Running the queue.

The store holds entries; this decides what an entry *means*. Handlers are
registered per action, so adding a queueable operation is one registration and
does not touch the store, the menu or the sync flow.

A handler is `function(payload, context) -> Result`. Success removes the entry;
failure records the attempt and leaves it. An action with no registered handler
is quarantined rather than retried, because it will never succeed — that state
happens when a plugin downgrade leaves entries from a newer version behind.

@module karabridge.features.queue.manager
]]

local Bookmarks = require("karabridge.api.bookmarks")
local Logging = require("karabridge.shared.logging")
local Result = require("karabridge.shared.result")
local Store = require("karabridge.features.queue.store")
local Text = require("karabridge.shared.text")

local log = Logging.forModule("queue")

local Manager = {}
Manager.__index = Manager

--- @tparam table opts `{ store = <Store>, client_factory = function }`
function Manager.new(opts)
    assert(type(opts) == "table" and opts.store, "Manager.new requires a store")

    local instance = setmetatable({
        store = opts.store,
        client_factory = opts.client_factory,
        handlers = {},
    }, Manager)

    instance:registerDefaults()
    return instance
end

--- Register a handler for an action.
-- @tparam string action
-- @tparam function handler `function(payload, context) -> Result`
function Manager:register(action, handler)
    self.handlers[action] = handler
end

--- The handlers KaraBridge ships with.
function Manager:registerDefaults()
    --- Bookmark a link that was captured while offline.
    self:register("create_link", function(payload, context)
        if type(payload.url) ~= "string" or payload.url == "" then
            return Result.err("invalid_payload", "The queued link has no URL.")
        end
        if not context.client then
            return Result.err("not_configured", "Karakeep is not configured.")
        end

        return Bookmarks.new(context.client):createLink({
            url = payload.url,
            title = payload.title,
            note = payload.note,
        })
    end)
end

--- Queue a link for bookmarking.
--
-- Keyed by URL, so tapping the same link twice while offline leaves one entry.
--
-- @tparam string url
-- @tparam[opt] table extra title, note
-- @treturn boolean
function Manager:queueLink(url, extra)
    extra = extra or {}
    return self.store:add(url, "create_link", {
        url = url,
        title = extra.title,
        note = extra.note,
    })
end

function Manager:hasPending()
    return self.store:count() > 0
end

--- Process every queued entry.
--
-- @tparam[opt] function progress `function(message) -> boolean`
-- @treturn table Summary.
function Manager:processAll(progress)
    progress = progress or function()
        return true
    end

    local pending = self.store:pending()

    local summary = {
        total = #pending,
        succeeded = 0,
        failed = 0,
        parked = 0,
        cancelled = false,
        first_error = nil,
    }

    if #pending == 0 then
        return summary
    end

    -- Built once for the whole run, not once per entry.
    local context = {
        client = self.client_factory and self.client_factory() or nil,
    }

    for index, item in ipairs(pending) do
        local go_on = progress(string.format("Sending queued item %d of %d" .. Text.ELLIPSIS, index, #pending))
        if go_on == false then
            summary.cancelled = true
            break
        end

        local handler = self.handlers[item.entry.action]

        if not handler then
            -- Will never succeed; retrying it every sync would be noise.
            log.warn("no handler for queued action", item.entry.action, "- parking", item.key)
            self.store:quarantine(item.key, "no handler for action '" .. tostring(item.entry.action) .. "'")
            summary.parked = summary.parked + 1
        else
            local ok, result = pcall(handler, item.entry.payload, context)

            if not ok then
                -- A handler that throws must not take the whole run down with
                -- it; the other entries still deserve their attempt.
                result = Result.err("handler_error", tostring(result))
            end

            if result and result:isOk() then
                self.store:remove(item.key)
                summary.succeeded = summary.succeeded + 1
            else
                local message = (result and (result.message or result:describe())) or "unknown error"
                summary.failed = summary.failed + 1
                summary.first_error = summary.first_error or message

                if not self.store:recordFailure(item.key, message) then
                    summary.parked = summary.parked + 1
                end
            end
        end
    end

    self.store:flush()

    log.info(
        string.format(
            "queue done - %d of %d sent, %d failed, %d parked",
            summary.succeeded,
            summary.total,
            summary.failed,
            summary.parked
        )
    )

    return summary
end

--- The lines shown after a queue run.
-- @tparam table summary
-- @treturn table
function Manager.summarise(summary)
    local lines = {}

    if summary.total == 0 then
        return { "Nothing is waiting to be sent." }
    end

    if summary.succeeded == 1 then
        table.insert(lines, "Sent 1 queued item.")
    elseif summary.succeeded > 1 then
        table.insert(lines, string.format("Sent %d queued items.", summary.succeeded))
    end

    if summary.failed > 0 then
        table.insert(lines, string.format("%d could not be sent, and will be retried.", summary.failed))
        if summary.first_error then
            table.insert(lines, "First reason: " .. tostring(summary.first_error))
        end
    end

    if summary.parked > 0 then
        table.insert(
            lines,
            string.format(
                "%d gave up after %d attempts and were set aside. See Diagnostics.",
                summary.parked,
                Store.MAX_ATTEMPTS
            )
        )
    end

    if summary.cancelled then
        table.insert(lines, "Cancelled; the rest are still queued.")
    end

    if #lines == 0 then
        table.insert(lines, "Nothing was sent.")
    end

    return lines
end

return Manager
