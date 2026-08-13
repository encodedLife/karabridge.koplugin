--[[--
The server address and API key dialog, and the connection test behind it.

`text_type = "password"` on the token field is not decoration: an e-reader is
frequently read in public and the key is long enough that shoulder-surfing it
is realistic. The value is never echoed anywhere else either — the menu shows
`Logging.mask()` of it, not the key.

@module karabridge.features.menu.server_settings
]]

local ConnectionTest = require("karabridge.features.connection_test")
local Logging = require("karabridge.shared.logging")
local Notification = require("karabridge.shared.notification")
local Progress = require("karabridge.features.progress")
local Connectivity = require("karabridge.features.connectivity")
local Text = require("karabridge.shared.text")

local ServerSettings = {}

--- Menu text: the address, and whether a key is present. Never the key itself.
-- @tparam table settings
-- @treturn string
function ServerSettings.describe(settings)
    local url = settings:get("server_url")
    if not url or url == "" then
        return "Server: not set"
    end
    return string.format("Server: %s (key %s)", Logging.maskUrl(url), Logging.mask(settings:get("api_token")))
end

--- Run the connection test and show the outcome.
-- @tparam table plugin Anything with `getClient()` and `settings`.
function ServerSettings.test(plugin)
    Connectivity.whenConnected(function()
        Progress.run({
            message = "Testing the connection" .. Text.ELLIPSIS,
            work = function()
                return ConnectionTest.run(plugin:getClient())
            end,
            done = function(result)
                Notification.alert(ConnectionTest.describe(result, plugin.settings:get("server_url")))
            end,
        })
    end)
end

--- Show the address/key dialog.
-- @tparam table plugin
-- @tparam[opt] table touchmenu_instance Refreshed so the new value shows at once.
function ServerSettings.edit(plugin, touchmenu_instance)
    local MultiInputDialog = require("ui/widget/multiinputdialog")
    local UIManager = require("ui/uimanager")

    local settings = plugin.settings

    local dialog
    dialog = MultiInputDialog:new({
        title = "Karakeep server",
        fields = {
            {
                text = settings:get("server_url") or "",
                input_type = "string",
                hint = "Server address, e.g. https://karakeep.example.org",
            },
            {
                text = settings:get("api_token") or "",
                input_type = "string",
                text_type = "password",
                hint = "API key (Karakeep: Settings > API Keys)",
            },
        },
        buttons = {
            {
                {
                    text = "Cancel",
                    id = "close",
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = "Save and test",
                    callback = function()
                        local fields = dialog:getFields()

                        -- set() normalises the URL and rejects a malformed one;
                        -- report that here rather than saving something the
                        -- API client would then fail on obscurely.
                        local url_ok, url_problem = settings:set("server_url", fields[1] or "")
                        settings:set("api_token", Text.trim(fields[2] or ""))
                        settings:flush()

                        UIManager:close(dialog)
                        if touchmenu_instance then
                            touchmenu_instance:updateItems()
                        end

                        if not url_ok then
                            Notification.alert("That server address cannot be used: " .. tostring(url_problem))
                            return
                        end

                        ServerSettings.test(plugin)
                    end,
                },
            },
        },
    })

    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

return ServerSettings
