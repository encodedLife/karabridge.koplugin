--[[--
Showing that something is happening, and letting it be stopped.

Every operation that touches the network goes through here, for three reasons
that were each a real complaint or a real defect.

## A blocking request looks like a crash

KOReader is single-threaded. A request that takes four seconds is four seconds
of a frozen screen, and on an e-ink display -- where nothing animates and the
refresh is slow anyway -- there is no way to tell that from a hang. So the
message is shown **before** the work starts, not after the first step: by the
time the first step reports, the freeze has already happened.

## The dialog was never dismissable

The old calls were `Trapper:info(message, true, true)`, with a comment claiming
the two flags kept one widget in place. The second does that. The third is
`skip_dismiss_check` (`trapper.lua:125`), and with it set, `info` returns before
the yield that notices a tap -- so it **always returns true**. Every "did the
user cancel?" check in this plugin was therefore dead code, and tapping the
dialog did nothing.

Passing it as false costs a 0.1 second yield per step. On a thirty-article sync
that is three seconds, and it buys an abort that works.

## Trapper is shared, and a raise used to strand it

`Trapper:reset()` closes the widget. When it was called after the work rather
than in every path out, an error left a dialog sitting on top of whatever the
user did next -- and Trapper belongs to all of KOReader, not to us.

@module karabridge.features.progress
]]

local Logging = require("karabridge.shared.logging")

local log = Logging.forModule("progress")

local Progress = {}

-- Replaced by the specs, which have no KOReader.
local trapper_backend

--- Replace the Trapper. Used by the specs.
-- @tparam table|nil backend
function Progress.setBackend(backend)
    trapper_backend = backend
end

--- KOReader's Trapper, or nil when there is none.
-- @treturn table|nil
function Progress.trapper()
    if trapper_backend then
        return trapper_backend
    end

    local ok, Trapper = pcall(require, "ui/trapper")
    if not ok or type(Trapper) ~= "table" then
        return nil
    end
    return Trapper
end

--- Run work behind a progress dialog.
--
-- `work` is given a `step(message)` function. It returns **false** when the
-- user has asked to stop, and work that can stop should check it; work that
-- cannot may ignore it.
--
-- @tparam table opts
--   message  shown immediately, before any work happens
--   work     `function(step)`; its return value is passed to `done`
--   done     optional; `function(value)`, run after the dialog is cleared
function Progress.run(opts)
    local message = opts.message or "Working" .. "\226\128\166"
    local work = opts.work
    local done = opts.done

    local Trapper = Progress.trapper()

    -- No KOReader, or a Trapper that cannot wrap: do the work rather than
    -- refusing to. `wrap` is checked rather than the table's mere existence,
    -- because the latter is true of anything.
    if not Trapper or type(Trapper.wrap) ~= "function" then
        local ok, value = pcall(work, function()
            return true
        end)
        if not ok then
            log.err("the operation raised:", tostring(value))
            return
        end
        if done then
            done(value)
        end
        return
    end

    Trapper:wrap(function()
        -- Before the first request, so the screen never sits blank while a
        -- socket is being opened.
        Trapper:info(message)

        local ok, value = pcall(work, function(text)
            -- The third argument is deliberately absent. It is
            -- skip_dismiss_check, and passing it true is what made every
            -- cancel check in this plugin do nothing.
            return Trapper:info(text, true)
        end)

        -- In every path out, including the one where the work raised: the
        -- widget belongs to KOReader, not to this operation.
        Trapper:reset()

        if not ok then
            log.err("the operation raised:", tostring(value))
            return
        end

        if done then
            done(value)
        end
    end)
end

return Progress
