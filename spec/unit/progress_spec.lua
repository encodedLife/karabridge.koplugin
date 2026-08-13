--[[--
The progress dialog.

Two defects are pinned here. The dialog used to appear only after the first
step, so the freeze people reported had already happened by then. And every
"did the user cancel?" check in the plugin was dead, because the third argument
to Trapper:info is skip_dismiss_check and it was being passed as true.
]]

local Progress = require("karabridge.features.progress")

--- A stand-in for KOReader's Trapper.
local function trapper(opts)
    opts = opts or {}
    local record = { messages = {}, info_args = {}, resets = 0, wrapped = 0 }

    return record,
        {
            wrap = function(_, fn)
                record.wrapped = record.wrapped + 1
                fn()
            end,
            info = function(_, text, fast_refresh, skip_dismiss_check)
                table.insert(record.messages, text)
                table.insert(record.info_args, {
                    fast_refresh = fast_refresh,
                    skip_dismiss_check = skip_dismiss_check,
                })
                if opts.cancel_after and #record.messages > opts.cancel_after then
                    return false
                end
                return true
            end,
            reset = function()
                record.resets = record.resets + 1
            end,
        }
end

describe("Progress.run", function()
    after_each(function()
        Progress.setBackend(nil)
    end)

    it("shows its message before any work happens", function()
        -- The point of the whole module: a blocking request on a single-threaded
        -- reader is a frozen screen, and a message shown after the first step
        -- arrives too late to say anything.
        local record, backend = trapper()
        Progress.setBackend(backend)

        local message_when_work_began
        Progress.run({
            message = "Testing the connection",
            work = function()
                message_when_work_began = record.messages[1]
                return true
            end,
        })

        assert.equals("Testing the connection", message_when_work_began)
    end)

    it("lets the dialog notice a cancel", function()
        -- Trapper:info's third argument is skip_dismiss_check. Passing it true
        -- makes info return before the yield that sees the tap, so it always
        -- answers true and no cancellation is ever detected.
        local record, backend = trapper()
        Progress.setBackend(backend)

        Progress.run({
            message = "Working",
            work = function(step)
                step("one")
                return true
            end,
        })

        local during_work = record.info_args[2]
        assert.is_true(during_work.fast_refresh)
        assert.is_falsy(during_work.skip_dismiss_check)
    end)

    it("passes a refusal back to the work", function()
        local _, backend = trapper({ cancel_after = 2 })
        Progress.setBackend(backend)

        local answers = {}
        Progress.run({
            message = "Working",
            work = function(step)
                table.insert(answers, step("one"))
                table.insert(answers, step("two"))
                return true
            end,
        })

        assert.is_true(answers[1])
        assert.is_false(answers[2])
    end)

    it("hands the result to done", function()
        local _, backend = trapper()
        Progress.setBackend(backend)

        local got
        Progress.run({
            message = "Working",
            work = function()
                return { sent = 3 }
            end,
            done = function(value)
                got = value
            end,
        })

        assert.equals(3, got.sent)
    end)

    it("clears the dialog even when the work raises", function()
        -- Trapper belongs to all of KOReader. A stranded widget sits on top of
        -- whatever the user does next.
        local record, backend = trapper()
        Progress.setBackend(backend)

        Progress.run({
            message = "Working",
            work = function()
                error("something went wrong")
            end,
            done = function()
                error("done must not run after a raise")
            end,
        })

        assert.equals(1, record.resets)
    end)

    it("clears it on the ordinary path too", function()
        local record, backend = trapper()
        Progress.setBackend(backend)

        Progress.run({ message = "Working", work = function() end })

        assert.equals(1, record.resets)
    end)

    it("still does the work when there is no Trapper", function()
        -- A headless run, and every spec that does not install one.
        Progress.setBackend({})

        local ran, stepped = false, nil
        Progress.run({
            message = "Working",
            work = function(step)
                ran = true
                stepped = step("anything")
                return true
            end,
        })

        assert.is_true(ran)
        assert.is_true(stepped)
    end)
end)
