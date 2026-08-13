--[[--
Syncing without being asked, and the actions a gesture can be bound to.

Two rules govern everything here, and both are about not being annoying:

**Never turn the radio on.** This reacts to a connection the user made for
their own reasons; it does not create one. On a device that is asleep most of
the time, waking the Wi-Fi to check for articles is a poor trade for battery,
and a plugin that does it silently is worse. This is the line KOReader's own
network-using plugins take.

**Never interrupt reading.** With a document open, only the *upload* half runs:
reading status and highlights, which is the part that goes stale on the server,
and which needs no progress dialog. Downloads wait until no document is open.

The handler is attached as a *field* only while the setting is on, so with it
off nothing is dispatched at all rather than being dispatched and ignored. That
is the established pattern, and it is the reason `setup()` is called again
whenever the setting changes.

@module karabridge.features.automation
]]

local Logging = require("karabridge.shared.logging")
local Sync = require("karabridge.features.sync")
local Uploader = require("karabridge.features.article_sync.uploader")

local log = Logging.forModule("automation")

local Automation = {}

-- How long to let a fresh connection settle before using it. A request fired
-- the instant the interface comes up frequently fails DNS.
Automation.SETTLE_SECONDS = 2

--- Has enough time passed since the last automatic sync?
--
-- Pure, so the throttle is testable without waiting.
--
-- @tparam number|nil last_at Unix time of the last automatic sync.
-- @tparam number interval_minutes
-- @tparam number now
-- @treturn boolean
function Automation.isDue(last_at, interval_minutes, now)
    if not last_at then
        return true
    end
    return (now - last_at) >= (interval_minutes or 30) * 60
end

--- Attach or detach the network handler, to match the setting.
--
-- Called from `init()` and again whenever `auto_sync_on_wifi` changes.
--
-- @tparam table plugin
function Automation.setup(plugin)
    if plugin.settings:get("auto_sync_on_wifi") == true then
        plugin.onNetworkConnected = Automation.onNetworkConnected
    else
        plugin.onNetworkConnected = nil
    end
end

--- Run when Wi-Fi comes up.
--
-- Assigned to `plugin.onNetworkConnected`, so `self` is the plugin.
function Automation.onNetworkConnected(plugin)
    if not plugin.settings:readiness().connect then
        return
    end

    local now = os.time()
    local last = plugin.settings:getInternal("last_auto_sync")
    local interval = plugin.settings:get("auto_sync_interval") or 30

    if not Automation.isDue(last, interval, now) then
        log.dbg("auto-sync skipped,", now - last, "s since the last one")
        return
    end

    local UIManager = require("ui/uimanager")

    UIManager:scheduleIn(Automation.SETTLE_SECONDS, function()
        plugin.settings:setInternal("last_auto_sync", os.time())
        plugin.settings:flush()

        Automation.run(plugin)
    end)
end

--- Do the automatic work, quietly.
-- @tparam table plugin
function Automation.run(plugin)
    local Notification = require("karabridge.shared.notification")
    local Progress = require("karabridge.features.progress")
    local Text = require("karabridge.shared.text")

    local reading = plugin.ui and plugin.ui.document ~= nil

    Progress.run({
        message = "Syncing with Karakeep" .. Text.ELLIPSIS,
        work = function()
        local result, summarise

        if reading then
            -- Mid-read: send only. That is the half which goes stale on the
            -- server, and it cannot interrupt with a download dialog.
            log.info("auto-sync (upload only, a document is open)")
            result = Uploader.new({
                client = plugin:getClient(),
                settings = plugin.settings,
            }):run()
            summarise = Uploader.summarise
        else
            log.info("auto-sync (full)")
            result = Sync.new({
                client = plugin:getClient(),
                settings = plugin.settings,
                queue = plugin.queue,
            }):run()
            summarise = Sync.summarise
        end

        if result:isErr() then
            log.warn("auto-sync failed:", result:describe())
            return nil
        end

        return summarise(result.value)
        end,
        done = function(lines)
            if lines and #lines > 0 then
                -- A toast, never a modal: nobody asked for this, so it must
                -- not demand a tap to dismiss.
                Notification.info(table.concat(lines, " "))
            end
        end,
    })
end

--- Register the actions a gesture or a profile can be bound to.
-- @tparam table plugin
function Automation.registerDispatcherActions(plugin)
    local ok, Dispatcher = pcall(require, "dispatcher")
    if not ok then
        return
    end

    Dispatcher:registerAction("karabridge_sync", {
        category = "none",
        event = "SynchroniseKaraBridge",
        title = "Synchronise KaraBridge",
        general = true,
    })
    Dispatcher:registerAction("karabridge_upload", {
        category = "none",
        event = "SendKaraBridgeStatus",
        title = "Send KaraBridge read status and highlights",
        general = true,
    })
    Dispatcher:registerAction("karabridge_go_to_folder", {
        category = "none",
        event = "GoToKaraBridgeFolder",
        title = "Go to the KaraBridge folder",
        general = true,
    })

    log.dbg("dispatcher actions registered")
    return plugin
end

--- The menu items for the automation settings.
-- @tparam table plugin
-- @treturn table
function Automation.buildMenu(plugin)
    local settings = plugin.settings

    return {
        {
            text = "Sync when Wi-Fi connects",
            help_text = table.concat({
                "Syncs when you turn Wi-Fi on. It never turns the radio on by itself.",
                "",
                "While you are reading, only reading status and highlights are sent, so a "
                    .. "sync cannot interrupt you. A full sync, including downloads, runs when "
                    .. "no document is open.",
            }, "\n"),
            checked_func = function()
                return settings:get("auto_sync_on_wifi") == true
            end,
            callback = function()
                settings:set("auto_sync_on_wifi", settings:get("auto_sync_on_wifi") ~= true)
                settings:flush()
                Automation.setup(plugin)
            end,
        },
        {
            text_func = function()
                return string.format("Sync at most every: %d min", settings:get("auto_sync_interval") or 30)
            end,
            enabled_func = function()
                return settings:get("auto_sync_on_wifi") == true
            end,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                local SpinWidget = require("ui/widget/spinwidget")
                local UIManager = require("ui/uimanager")

                UIManager:show(SpinWidget:new({
                    title_text = "Shortest gap between automatic syncs",
                    value = settings:get("auto_sync_interval") or 30,
                    value_min = 5,
                    value_max = 720,
                    value_step = 5,
                    value_hold_step = 30,
                    callback = function(spin)
                        settings:set("auto_sync_interval", spin.value)
                        settings:flush()
                        if touchmenu_instance then
                            touchmenu_instance:updateItems()
                        end
                    end,
                }))
            end,
        },
        {
            text_func = function()
                local last = settings:getInternal("last_auto_sync")
                if not last then
                    return "Last automatic sync: never"
                end
                return "Last automatic sync: " .. os.date("%Y-%m-%d %H:%M", last)
            end,
            enabled_func = function()
                return false -- informational
            end,
            keep_menu_open = true,
        },
    }
end

return Automation
