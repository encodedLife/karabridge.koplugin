--[[--
The `karabridge.conf` submenu.

Three actions, and they exist because a config file the user cannot see the
effect of is worse than no config file at all:

  * **Where KaraBridge looks** — the search order, with a tick against the one
    actually in use. Answers "why is my file being ignored" without a support
    round trip.
  * **Create an example file** — writes a commented template generated from the
    schema, so it can never drift out of date. Refuses to overwrite.
  * **Reload it now** — the *only* thing that lets the file override a setting
    already changed in the menu. Everything else about the file is seeding.

@module karabridge.features.menu.config_file_menu
]]

local ConfigPaths = require("karabridge.config.paths")
local Notification = require("karabridge.shared.notification")
local Text = require("karabridge.shared.text")

local ConfigFileMenu = {}

--- Menu text for the parent item.
-- @tparam table settings
-- @treturn string
function ConfigFileMenu.describe(settings)
    if settings.config_path then
        if #(settings.config_problems or {}) > 0 then
            return "Settings file: found, with problems"
        end
        return "Settings file: found"
    end
    return "Settings file: none"
end

--- The lines shown by "Where KaraBridge looks".
-- @tparam table settings
-- @treturn string
function ConfigFileMenu.describeSearchOrder(settings)
    local lines = { "Checked in order, first one found wins:", "" }

    for _, path in ipairs(ConfigPaths.candidates(settings.plugin_dir)) do
        local marker = (path == settings.config_path) and Text.CHECK .. " " or Text.MIDDLE_DOT .. " "
        table.insert(lines, marker .. path)
    end

    if settings.config_path and #(settings.config_problems or {}) > 0 then
        table.insert(lines, "")
        table.insert(lines, "Problems in the file:")
        for _, problem in ipairs(settings.config_problems) do
            table.insert(lines, "  " .. problem)
        end
    end

    return table.concat(lines, "\n")
end

--- Build the submenu.
-- @tparam table plugin
-- @treturn table Array of KOReader menu items.
function ConfigFileMenu.build(plugin)
    local settings = plugin.settings

    return {
        {
            text = "Where KaraBridge looks",
            keep_menu_open = true,
            callback = function()
                Notification.alert(ConfigFileMenu.describeSearchOrder(settings))
            end,
        },
        {
            text = "Create an example file",
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                local outcome = settings:writeConfigTemplate()

                local message
                if outcome.ok then
                    message = "Wrote an example settings file to:\n"
                        .. outcome.path
                        .. "\n\nEdit it on a computer, then use 'Reload it now'."
                elseif outcome.reason == "exists" then
                    message = "A settings file already exists at:\n" .. outcome.path .. "\n\nIt was left untouched."
                elseif outcome.reason == "no_data_dir" then
                    message = "KaraBridge could not work out where to write the file."
                else
                    message = "Could not write to:\n" .. tostring(outcome.path)
                end

                Notification.alert(message)
                if touchmenu_instance then
                    touchmenu_instance:updateItems()
                end
            end,
        },
        {
            text = "Reload it now",
            help_text = "Re-reads the file and overwrites the matching settings here. Use this after editing it.",
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                local outcome = settings:reloadConfigFile()

                local message
                if not outcome.path then
                    message = "No settings file was found."
                else
                    message = string.format("Applied %d setting(s) from:\n%s", outcome.applied, outcome.path)
                    if #outcome.problems > 0 then
                        message = message .. "\n\n" .. table.concat(outcome.problems, "\n")
                    end
                end

                Notification.alert(message)
                if touchmenu_instance then
                    touchmenu_instance:updateItems()
                end
            end,
        },
    }
end

return ConfigFileMenu
