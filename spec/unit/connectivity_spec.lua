--[[--
Asking KOReader whether there is a network.

The bug this exists for: a device on Wi-Fi being asked to connect to Wi-Fi, over
and over, and the action being silently dropped when the user agreed.
]]

local Connectivity = require("karabridge.features.connectivity")

--- A stand-in for KOReader's NetworkMgr.
local function manager(state)
    local calls = { run_when_connected = 0, run_when_online = 0, before_wifi_action = 0 }

    local mgr = {
        calls = calls,
        isConnected = function()
            return state.connected == true
        end,
        isOnline = function()
            return state.online == true
        end,
    }

    if state.has_run_when_connected ~= false then
        mgr.runWhenConnected = function(_, callback)
            calls.run_when_connected = calls.run_when_connected + 1
            if state.connected then
                callback()
            else
                -- KOReader's own contract: it prompts, and the callback still runs.
                calls.before_wifi_action = calls.before_wifi_action + 1
                callback()
            end
        end
    end

    if state.has_run_when_online ~= false then
        mgr.runWhenOnline = function(_, callback)
            calls.run_when_online = calls.run_when_online + 1
            if state.online then
                callback()
            elseif not state.connected then
                calls.before_wifi_action = calls.before_wifi_action + 1
                callback()
            else
                -- The branch that caused the report: prompt, drop the work.
                calls.before_wifi_action = calls.before_wifi_action + 1
            end
        end
    end

    return mgr
end

describe("Connectivity", function()
    after_each(function()
        Connectivity.setBackend(nil)
    end)

    describe("isConnected", function()
        it("asks isConnected, not the hostname probe", function()
            -- isOnline resolves dns.msftncsi.com. A Pi-hole with that domain
            -- blocklisted makes a working connection look offline.
            Connectivity.setBackend(manager({ connected = true, online = false }))
            assert.is_true(Connectivity.isConnected())
        end)

        it("is false when there is really no connection", function()
            Connectivity.setBackend(manager({ connected = false, online = false }))
            assert.is_false(Connectivity.isConnected())
        end)

        it("falls back to isOnline on a KOReader without isConnected", function()
            local mgr = manager({ connected = true, online = true })
            mgr.isConnected = nil
            Connectivity.setBackend(mgr)

            assert.is_true(Connectivity.isConnected())
        end)

        it("is false when there is no network manager at all", function()
            Connectivity.setBackend({})
            assert.is_false(Connectivity.isConnected())
        end)
    end)

    describe("whenConnected", function()
        it("runs straight away on a connected device, with no prompt", function()
            -- The whole report: connected, but the DNS probe failed. There must
            -- be no prompt.
            local mgr = manager({ connected = true, online = false })
            Connectivity.setBackend(mgr)

            local ran = false
            Connectivity.whenConnected(function()
                ran = true
            end)

            assert.is_true(ran)
            assert.equals(0, mgr.calls.before_wifi_action)
            assert.equals(1, mgr.calls.run_when_connected)
        end)

        it("never uses runWhenOnline when runWhenConnected exists", function()
            -- runWhenOnline drops the callback in exactly the connected-but-not-
            -- resolving case, which is the one that was happening.
            local mgr = manager({ connected = true, online = false })
            Connectivity.setBackend(mgr)

            Connectivity.whenConnected(function() end)

            assert.equals(0, mgr.calls.run_when_online)
        end)

        it("still runs the work after the user is asked to connect", function()
            local mgr = manager({ connected = false, online = false })
            Connectivity.setBackend(mgr)

            local ran = false
            Connectivity.whenConnected(function()
                ran = true
            end)

            assert.is_true(ran)
            assert.equals(1, mgr.calls.before_wifi_action)
        end)

        it("falls back to runWhenOnline on an older KOReader", function()
            local mgr = manager({ connected = true, online = true, has_run_when_connected = false })
            Connectivity.setBackend(mgr)

            local ran = false
            Connectivity.whenConnected(function()
                ran = true
            end)

            assert.is_true(ran)
            assert.equals(1, mgr.calls.run_when_online)
        end)

        it("runs the work rather than swallowing it when there is no manager", function()
            -- Letting the request fail with a reason beats doing nothing at all.
            Connectivity.setBackend({})

            local ran = false
            Connectivity.whenConnected(function()
                ran = true
            end)

            assert.is_true(ran)
        end)
    end)
end)
