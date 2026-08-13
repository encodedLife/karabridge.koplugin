--[[--
The version row, and updating from it.

Doubles as the place the running version is shown, because "which version am I
on" and "is there a newer one" are the same question asked half a second apart.

Checking can be automatic. **Installing never is** -- replacing the running
plugin is always a deliberate tap, and it always says what it is about to do.

@module karabridge.features.update.menu
]]

local Check = require("karabridge.features.update.check")
local Connectivity = require("karabridge.features.connectivity")
local Install = require("karabridge.features.update.install")
local Logging = require("karabridge.shared.logging")
local Notification = require("karabridge.shared.notification")
local Progress = require("karabridge.features.progress")
local Text = require("karabridge.shared.text")

local log = Logging.forModule("update.menu")

local UpdateMenu = {}

-- The result of the last check, so the menu can show it without asking again.
-- Deliberately not persisted: a check is cheap, and a stale "update available"
-- surviving a restart would be worse than no answer at all.
local last_check

--- Forget the last check. Used by the specs.
function UpdateMenu.reset()
    last_check = nil
end

--- What the last check found, if anything.
-- @treturn table|nil
function UpdateMenu.lastCheck()
    return last_check
end

--- The row's label: the running version, and what is known about newer ones.
-- @tparam table plugin
-- @treturn string
function UpdateMenu.describe(plugin)
    local current = plugin.version or "unknown"

    if last_check and last_check.available then
        return string.format("Version %s " .. Text.EM_DASH .. " %s available", current, last_check.latest)
    end
    return "Version " .. current
end

--- Ask GitHub, and remember the answer.
-- @tparam table plugin
-- @tparam[opt] boolean quiet Say nothing when already up to date.
-- @tparam[opt] function done
function UpdateMenu.check(plugin, quiet, done)
    if not Check.isConfigured(plugin.settings) then
        Notification.alert(table.concat({
            "No update source is set.",
            "",
            "Put this in karabridge.conf:",
            "  update_repo = owner/name",
            "",
            "For a private repository, add an access token:",
            "  update_token = ...",
        }, "\n"))
        return
    end

    Connectivity.whenConnected(function()
        Progress.run({
            message = "Checking for updates" .. Text.ELLIPSIS,
            work = function()
                return Check.run({ settings = plugin.settings, current = plugin.version })
            end,
            done = function(checked)
                UpdateMenu.reportCheck(plugin, checked, quiet, done)
            end,
        })
    end)
end

--- What to say once a check has come back.
-- @tparam table plugin
-- @tparam table checked The Result from `Check.run`.
-- @tparam boolean quiet
-- @tparam function|nil done
function UpdateMenu.reportCheck(plugin, checked, quiet, done)
    if checked:isErr() then
        log.warn("update check failed:", checked:describe())
        if not quiet then
            Notification.alert("Could not check for updates.\n\n" .. checked:describe())
        end
        return
    end

    last_check = checked.value

    if not checked.value.available then
        if not quiet then
            Notification.info("KaraBridge " .. tostring(plugin.version) .. " is the newest version.")
        end
    elseif quiet then
        Notification.info("KaraBridge " .. tostring(checked.value.latest) .. " is available.")
    end

    if done then
        done(checked.value)
    end
end

--- Install the release the last check found, after asking.
-- @tparam table plugin
function UpdateMenu.install(plugin)
    if not (last_check and last_check.available) then
        Notification.alert("Check for an update first.")
        return
    end

    local release = last_check.release
    if type(release.asset) ~= "table" then
        Notification.alert(table.concat({
            "Release " .. tostring(last_check.latest) .. " has no zip attached,",
            "so it cannot be installed from here.",
            "",
            release.url or "",
        }, "\n"))
        return
    end

    local ConfirmBox = require("ui/widget/confirmbox")
    local UIManager = require("ui/uimanager")

    UIManager:show(ConfirmBox:new({
        text = table.concat({
            string.format("Install KaraBridge %s?", tostring(last_check.latest)),
            "",
            string.format("The running version is %s.", tostring(plugin.version)),
            "Your settings and karabridge.conf are kept.",
            "",
            "KOReader has to restart afterwards.",
        }, "\n"),
        ok_text = "Install",
        ok_callback = function()
            UpdateMenu.perform(plugin)
        end,
    }))
end

--- Do the installation and offer the restart.
-- @tparam table plugin
function UpdateMenu.perform(plugin)
    Connectivity.whenConnected(function()
        Progress.run({
            message = "Downloading " .. tostring(last_check.latest) .. Text.ELLIPSIS,
            work = function(step)
                local installed = Install.run({
                    settings = plugin.settings,
                    plugin_dir = plugin.path,
                    release = last_check.release,
                    progress = step,
                })
                return installed
            end,
            done = function(installed)
                if installed:isErr() then
                    log.err("update failed:", installed:describe())
                    Notification.alert("The update failed.\n\n" .. installed:describe())
                    return
                end

                last_check = nil

                local ConfirmBox = require("ui/widget/confirmbox")
                local UIManager = require("ui/uimanager")

                UIManager:show(ConfirmBox:new({
                    text = table.concat({
                        "KaraBridge " .. tostring(installed.value.version) .. " is installed.",
                        "",
                        "KOReader must restart to use it. Restart now?",
                    }, "\n"),
                    ok_text = "Restart",
                    ok_callback = function()
                        UIManager:restartKOReader()
                    end,
                }))
            end,
        })
    end)
end

--- The version and updates submenu.
-- @tparam table plugin
-- @treturn table
function UpdateMenu.build(plugin)
    return {
        text_func = function()
            return UpdateMenu.describe(plugin)
        end,
        help_text = table.concat({
            "The version of KaraBridge running now, and where updates come from.",
            "",
            "Set 'update_repo' in karabridge.conf to owner/name. A private repository "
                .. "also needs 'update_token'; a public one needs nothing else.",
            "",
            "Checking is safe at any time. Installing replaces the plugin and asks first.",
        }, "\n"),
        sub_item_table = {
            {
                text = "Check for updates",
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    UpdateMenu.check(plugin, false, function()
                        if touchmenu_instance then
                            touchmenu_instance:updateItems()
                        end
                    end)
                end,
            },
            {
                text_func = function()
                    if last_check and last_check.available then
                        return "Install " .. tostring(last_check.latest)
                    end
                    return "Install (nothing to install yet)"
                end,
                enabled_func = function()
                    return last_check ~= nil and last_check.available == true
                end,
                keep_menu_open = true,
                callback = function()
                    UpdateMenu.install(plugin)
                end,
            },
            {
                text = "Check automatically when syncing",
                help_text = "Only checks, and only says something when a newer version exists. "
                    .. "It never installs by itself.",
                checked_func = function()
                    return plugin.settings:get("update_check_on_sync") == true
                end,
                callback = function()
                    local settings = plugin.settings
                    settings:set("update_check_on_sync", settings:get("update_check_on_sync") ~= true)
                    settings:flush()
                end,
            },
            {
                text_func = function()
                    local repo = Text.trim(plugin.settings:get("update_repo") or "")
                    return "Source: " .. (repo ~= "" and repo or "not set")
                end,
                help_text = "Set 'update_repo' in karabridge.conf.",
                enabled_func = function()
                    return false
                end,
                keep_menu_open = true,
            },
            {
                text_func = function()
                    local token = Text.trim(plugin.settings:get("update_token") or "")
                    return "Access: " .. (token ~= "" and "token set (private)" or "anonymous (public)")
                end,
                help_text = "A private repository needs 'update_token' in karabridge.conf. "
                    .. "The token itself is never shown or logged.",
                enabled_func = function()
                    return false
                end,
                keep_menu_open = true,
            },
        },
    }
end

return UpdateMenu
