--[[--
The KaraBridge menu.

Kept out of `main.lua` deliberately: the menu is the part that changes with
every new feature, and if it lives in the plugin entry point then the entry
point grows without limit. A plugin entry point can easily reach a thousand
lines, roughly half
of it menu construction.

Menu items for features that are not built yet are absent rather than greyed
out. A disabled item that never becomes enabled is a promise the plugin is not
keeping.

@module karabridge.features.menu.main_menu
]]

local Automation = require("karabridge.features.automation")
local BookExportMenu = require("karabridge.features.book_export.menu")
local ConfigFileMenu = require("karabridge.features.menu.config_file_menu")
local DownloadFolder = require("karabridge.features.menu.download_folder")
local DownloadMenu = require("karabridge.features.article_download.menu")
local Notification = require("karabridge.shared.notification")
local QueueMenu = require("karabridge.features.queue.menu")
local ServerSettings = require("karabridge.features.menu.server_settings")
local Text = require("karabridge.shared.text")
local UpdateMenu = require("karabridge.features.update.menu")

local MainMenu = {}

--- Build the whole menu.
-- @tparam table plugin The plugin instance; needs `settings`, `getClient`, `version`, `path`.
-- @treturn table A KOReader menu item table.
function MainMenu.build(plugin)
    local settings = plugin.settings

    return {
        -- "tools" rather than "more_tools". It used to sit one level deeper,
        -- on the reasoning that a background integration does not belong on
        -- the first page. That was wrong in practice: syncing and exporting
        -- are things one reaches for often, and Tools is exactly where they
        -- are looked for, next to the other tools that do the same kind of
        -- job. One tap saved, every time.
        text = "KaraBridge",
        sorting_hint = "tools",
        sub_item_table = {
            {
                text = "Synchronise now",
                help_text = table.concat({
                    "Sends reading status and highlights back, then downloads new articles.",
                    "",
                    "Sending happens first, so an article you have just finished is archived "
                        .. "rather than downloaded again a moment later.",
                }, "\n"),
                callback = function()
                    DownloadMenu.synchronise(plugin)
                end,
            },
            {
                text = "Send read status and highlights",
                help_text = "Sends only. Safe to use while reading -- it downloads nothing.",
                keep_menu_open = true,
                callback = function()
                    DownloadMenu.upload(plugin)
                end,
            },
            {
                text = "Download articles only",
                keep_menu_open = true,
                callback = function()
                    DownloadMenu.download(plugin)
                end,
            },
            {
                -- Hidden entirely when the queue is empty, which is almost
                -- always. A permanently greyed-out row is clutter.
                text_func = function()
                    return string.format("Send %d queued item(s)", plugin.queue and plugin.queue.store:count() or 0)
                end,
                enabled_func = function()
                    return plugin.queue ~= nil and plugin.queue:hasPending()
                end,
                keep_menu_open = true,
                callback = function()
                    DownloadMenu.flushQueue(plugin)
                end,
            },
            {
                text = "Go to the download folder",
                callback = function()
                    DownloadMenu.openFolder(plugin)
                end,
                separator = true,
            },
            {
                text_func = function()
                    return ServerSettings.describe(settings)
                end,
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    ServerSettings.edit(plugin, touchmenu_instance)
                end,
            },
            {
                text = "Test the connection",
                keep_menu_open = true,
                callback = function()
                    ServerSettings.test(plugin)
                end,
                separator = true,
            },
            {
                text_func = function()
                    return DownloadFolder.describe(settings)
                end,
                keep_menu_open = true,
                sub_item_table_func = function()
                    return MainMenu.buildDownloadFolderMenu(plugin)
                end,
            },
            {
                text_func = function()
                    return BookExportMenu.describe(plugin)
                end,
                help_text = "Highlights from your own EPUB and PDF books, as one Karakeep card per book.",
                keep_menu_open = true,
                sub_item_table_func = function()
                    return BookExportMenu.build(plugin)
                end,
            },
            {
                text = "Automatic syncing",
                keep_menu_open = true,
                sub_item_table_func = function()
                    return Automation.buildMenu(plugin)
                end,
            },
            {
                text = "Download settings",
                keep_menu_open = true,
                sub_item_table_func = function()
                    return DownloadMenu.build(plugin)
                end,
            },
            {
                text_func = function()
                    return ConfigFileMenu.describe(settings)
                end,
                help_text = table.concat({
                    "Set KaraBridge up from a text file instead of typing an API key on the device.",
                    "",
                    "The file seeds these settings the first time KaraBridge runs. They then appear in "
                        .. "these menus like any other setting, and whatever you change here wins from that point on.",
                    "",
                    'Editing the file later does nothing by itself -- choose "Reload it now" to pull the changes in.',
                }, "\n"),
                keep_menu_open = true,
                separator = true,
                sub_item_table_func = function()
                    return ConfigFileMenu.build(plugin)
                end,
            },
            -- Last, and showing the running version, because "which version
            -- am I on" and "is there a newer one" are the same question asked
            -- half a second apart.
            UpdateMenu.build(plugin),
            {
                text = "Diagnostics",
                keep_menu_open = true,
                sub_item_table_func = function()
                    return MainMenu.buildDiagnosticsMenu(plugin)
                end,
            },
        },
    }
end

--- Submenu for choosing the download folder.
-- @tparam table plugin
-- @treturn table
function MainMenu.buildDownloadFolderMenu(plugin)
    local settings = plugin.settings

    local function report(outcome, touchmenu_instance)
        if touchmenu_instance then
            touchmenu_instance:updateItems()
        end
        if outcome.ok then
            Notification.info("Download folder: " .. outcome.path)
        elseif outcome.message then
            Notification.alert(outcome.message)
        end
    end

    return {
        {
            text = "Choose a folder" .. Text.ELLIPSIS,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                DownloadFolder.choose(settings, function(outcome)
                    report(outcome, touchmenu_instance)
                end)
            end,
        },
        {
            text = "Type a path" .. Text.ELLIPSIS,
            help_text = "For a folder the picker cannot reach, such as one that is not mounted yet.",
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                DownloadFolder.enterManually(settings, function(outcome)
                    report(outcome, touchmenu_instance)
                end)
            end,
        },
        {
            text = "Check the current folder",
            keep_menu_open = true,
            callback = function()
                local folder = settings:get("download_folder")
                if not folder or folder == "" then
                    Notification.alert("No download folder is set.")
                    return
                end

                local Filesystem = require("karabridge.shared.filesystem")
                local check = Filesystem.checkWritableDirectory(folder)
                if check:isOk() then
                    Notification.alert("This folder exists and can be written to:\n\n" .. folder)
                else
                    Notification.alert(check.message .. "\n\n" .. folder)
                end
            end,
        },
    }
end

--- Submenu with the information a bug report needs.
--
-- Every value here is masked by `Settings:describe()`, so the whole screen can
-- be photographed and sent to someone without leaking the API key.
--
-- @tparam table plugin
-- @treturn table
function MainMenu.buildDiagnosticsMenu(plugin)
    return {
        {
            text = "Version and paths",
            keep_menu_open = true,
            callback = function()
                Notification.alert(table.concat({
                    "KaraBridge " .. tostring(plugin.version or "?"),
                    "",
                    "Loaded from:",
                    tostring(plugin.path or "?"),
                    "",
                    "Settings file:",
                    tostring(plugin.settings.config_path or "(none)"),
                }, "\n"))
            end,
        },
        {
            text = "Current settings",
            help_text = "The API key is masked, so this screen is safe to share.",
            keep_menu_open = true,
            callback = function()
                Notification.alert(table.concat(plugin.settings:describe(), "\n"))
            end,
        },
        {
            text_func = function()
                return QueueMenu.describeParked(plugin)
            end,
            help_text = "Queued items that failed too many times, or that this version cannot handle. "
                .. "Each can be inspected, retried, put back or deleted.",
            keep_menu_open = true,
            sub_item_table_func = function()
                return QueueMenu.buildParkedMenu(plugin)
            end,
        },
        {
            text_func = function()
                local outstanding = plugin.recovery and plugin.recovery:count() or 0
                return string.format("Unsaved Karakeep links: %d", outstanding)
            end,
            help_text = "Cards created in Karakeep whose link to the local book could not be written. "
                .. "KaraBridge remembers them so the next export updates rather than duplicates.",
            keep_menu_open = true,
            callback = function()
                Notification.alert(MainMenu.describeRecovery(plugin))
            end,
        },
    }
end

--- What "Unsaved Karakeep links" shows.
--
-- A remote object exists and the local record of it does not. Visible rather
-- than silent, because the symptom otherwise is duplicate cards appearing for
-- no discernible reason.
--
-- @tparam table plugin
-- @treturn string
function MainMenu.describeRecovery(plugin)
    if not plugin.recovery then
        return "Nothing outstanding."
    end

    local entries = plugin.recovery:all()
    if #entries == 0 then
        return "Nothing outstanding. Every Karakeep card is linked to its book."
    end

    local lines = {
        "These Karakeep cards exist, but the link to the book could not be saved.",
        "The next export will update them rather than create duplicates.",
        "",
    }
    for _, entry in ipairs(entries) do
        table.insert(lines, Text.MIDDLE_DOT .. " " .. tostring(entry.key))
        table.insert(lines, "   card " .. tostring(entry.bookmark_id))
    end

    return table.concat(lines, "\n")
end

return MainMenu
