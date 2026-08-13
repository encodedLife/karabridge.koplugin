local Helper = require("spec.support.helper")

local Automation = require("karabridge.features.automation")

describe("Automation", function()
    before_each(function()
        Helper.install()
    end)

    after_each(function()
        Helper.uninstall()
    end)

    describe("isDue", function()
        it("allows the first automatic sync", function()
            assert.is_true(Automation.isDue(nil, 30, 1000))
        end)

        it("refuses one that is too soon", function()
            -- 10 minutes after the last, with a 30 minute floor.
            assert.is_false(Automation.isDue(1000, 30, 1000 + 10 * 60))
        end)

        it("allows one once the interval has passed", function()
            assert.is_true(Automation.isDue(1000, 30, 1000 + 30 * 60))
        end)

        it("allows one exactly on the boundary", function()
            assert.is_true(Automation.isDue(0, 1, 60))
            assert.is_false(Automation.isDue(0, 1, 59))
        end)

        it("falls back to 30 minutes when no interval is given", function()
            assert.is_false(Automation.isDue(0, nil, 29 * 60))
            assert.is_true(Automation.isDue(0, nil, 30 * 60))
        end)
    end)

    describe("setup", function()
        -- The handler is attached as a *field* only while the setting is on, so
        -- with it off nothing is dispatched at all rather than dispatched and
        -- ignored, which is the established pattern.
        it("attaches the handler when automatic syncing is on", function()
            local plugin = { settings = Helper.settings({ auto_sync_on_wifi = true }) }
            Automation.setup(plugin)

            assert.is_function(plugin.onNetworkConnected)
        end)

        it("attaches nothing when it is off", function()
            local plugin = { settings = Helper.settings({ auto_sync_on_wifi = false }) }
            Automation.setup(plugin)

            assert.is_nil(plugin.onNetworkConnected)
        end)

        it("detaches when the setting is turned off again", function()
            local settings = Helper.settings({ auto_sync_on_wifi = true })
            local plugin = { settings = settings }

            Automation.setup(plugin)
            assert.is_function(plugin.onNetworkConnected)

            settings:set("auto_sync_on_wifi", false)
            Automation.setup(plugin)
            assert.is_nil(plugin.onNetworkConnected)
        end)

        it("is off by default, so nothing happens unasked", function()
            local plugin = { settings = Helper.settings() }
            Automation.setup(plugin)

            assert.is_nil(plugin.onNetworkConnected)
        end)
    end)

    describe("buildMenu", function()
        local function plugin()
            return { settings = Helper.settings({ auto_sync_on_wifi = true, auto_sync_interval = 45 }) }
        end

        it("gives every item a label", function()
            for _, item in ipairs(Automation.buildMenu(plugin())) do
                assert.is_true(item.text ~= nil or item.text_func ~= nil)
            end
        end)

        it("shows the configured interval", function()
            local items = Automation.buildMenu(plugin())
            assert.matches("45 min", items[2].text_func())
        end)

        it("greys the interval out when automatic syncing is off", function()
            local p = { settings = Helper.settings({ auto_sync_on_wifi = false }) }
            assert.is_false(Automation.buildMenu(p)[2].enabled_func())
        end)

        it("says 'never' before the first automatic sync", function()
            assert.matches("never", Automation.buildMenu(plugin())[3].text_func())
        end)

        it("shows when the last automatic sync ran", function()
            local p = plugin()
            p.settings:setInternal("last_auto_sync", 1700000000)

            assert.matches("%d%d%d%d%-%d%d%-%d%d", Automation.buildMenu(p)[3].text_func())
        end)

        it("toggles the setting and reattaches the handler", function()
            local p = plugin()
            local items = Automation.buildMenu(p)

            assert.is_true(items[1].checked_func())
            items[1].callback()

            assert.is_false(items[1].checked_func())
            assert.is_nil(p.onNetworkConnected)
        end)
    end)
end)
