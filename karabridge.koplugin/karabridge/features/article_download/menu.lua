--[[--
The download action, and the settings that shape it.

Separate from `features/menu/main_menu.lua` so the download feature owns its own
UI. The main menu asks this module for a submenu and knows nothing about
scopes, image limits or `Trapper`.

`Trapper` is what makes a long download interruptible: it wraps the work in a
coroutine, `Trapper:info()` shows progress and returns false when the user taps
Cancel, and `Trapper:reset()` clears the widget. Outside a wrapped coroutine
`Trapper:info()` is a harmless no-op, which is what lets the same downloader run
from a menu tap and from an automatic sync.

@module karabridge.features.article_download.menu
]]

local Downloader = require("karabridge.features.article_download.downloader")
local ListPicker = require("karabridge.features.menu.list_picker")
local Notification = require("karabridge.shared.notification")
local Progress = require("karabridge.features.progress")
local Connectivity = require("karabridge.features.connectivity")
local QueueManager = require("karabridge.features.queue.manager")
local Result = require("karabridge.shared.result")
local Sync = require("karabridge.features.sync")
local Text = require("karabridge.shared.text")
local Uploader = require("karabridge.features.article_sync.uploader")
local Validation = require("karabridge.config.validation")

local DownloadMenu = {}

--- Run something long behind a progress dialog, then report.
--
-- The dialog and the cancellation both come from `features/progress.lua`, so
-- every long operation in the plugin behaves the same way and only one place
-- has to get Trapper right.
--
-- @tparam table plugin
-- @tparam function build `function(progress) -> runnable` returning a Result
-- @tparam function describe `function(value) -> table of lines`
-- @tparam[opt] boolean needs_folder Require a usable download folder.
-- @tparam[opt] string message Shown before the work starts.
local function runWithProgress(plugin, build, describe, needs_folder, message)
    local readiness = plugin.settings:readiness()
    local ready = needs_folder and readiness.download or readiness.connect

    if not ready then
        Notification.alert(Validation.describeMissing(readiness.missing))
        return
    end

    Connectivity.whenConnected(function()
        Progress.run({
            message = message or ("Talking to Karakeep" .. Text.ELLIPSIS),
            work = build,
            done = function(result)
                if result:isErr() then
                    Notification.alert(result.message or result:describe())
                    return
                end

                Notification.alert(table.concat(describe(result.value), "\n"))

                local FileManager = require("apps/filemanager/filemanager")
                if FileManager.instance then
                    FileManager.instance:onRefresh()
                end
                require("ui/uimanager"):setDirty(nil, "ui")
            end,
        })
    end)
end

--- Describe the configured scope, for the menu label.
-- @tparam table settings
-- @treturn string
function DownloadMenu.describeScope(settings)
    local list = Text.trim(settings:get("filter_list") or "")
    local tags = Text.splitList(settings:get("filter_tags"))

    if list ~= "" and #tags > 0 then
        return string.format("list '%s', tagged %s", list, table.concat(tags, ", "))
    elseif list ~= "" then
        return string.format("list '%s'", list)
    elseif #tags > 0 then
        return "tagged " .. table.concat(tags, ", ")
    end

    return "all unarchived"
end

--- The full synchronisation: send back, fetch, tidy up.
-- @tparam table plugin
function DownloadMenu.synchronise(plugin)
    runWithProgress(plugin, function(progress)
        return Sync.new({
            client = plugin:getClient(),
            settings = plugin.settings,
            queue = plugin.queue,
            progress = progress,
        }):run()
    end, Sync.summarise, true, "Synchronising with Karakeep" .. Text.ELLIPSIS)

    -- Quietly, and afterwards: the sync is what the user asked for, and a
    -- version check must not delay it or fail it. It only ever says something
    -- when a newer version exists, and it never installs anything.
    if plugin.settings:get("update_check_on_sync") == true then
        local UpdateMenu = require("karabridge.features.update.menu")
        UpdateMenu.check(plugin, true)
    end
end

--- Download only, without sending anything back.
-- @tparam table plugin
function DownloadMenu.download(plugin)
    runWithProgress(plugin, function(progress)
        return Downloader.new({
            client = plugin:getClient(),
            settings = plugin.settings,
            progress = progress,
        }):run()
    end, Downloader.summarise, true, "Downloading articles" .. Text.ELLIPSIS)
end

--- Send reading status and highlights, without downloading.
--
-- Useful mid-read: it needs no download folder check and cannot interrupt
-- reading with a long fetch.
--
-- @tparam table plugin
function DownloadMenu.upload(plugin)
    runWithProgress(plugin, function(progress)
        return Uploader.new({
            client = plugin:getClient(),
            settings = plugin.settings,
            progress = progress,
        }):run()
    end, Uploader.summarise, false, "Sending status and highlights" .. Text.ELLIPSIS)
end

--- Send whatever is waiting in the queue.
--
-- Separate from a full sync, so a user with a queued link and no wish to
-- download anything can just send it.
--
-- @tparam table plugin
function DownloadMenu.flushQueue(plugin)
    runWithProgress(plugin, function(progress)
        return Result.ok(plugin.queue:processAll(progress))
    end, QueueManager.summarise, false, "Sending queued items" .. Text.ELLIPSIS)
end

--- Open the download folder in the file manager.
-- @tparam table plugin
function DownloadMenu.openFolder(plugin)
    local folder = plugin.settings:get("download_folder")
    if not folder or folder == "" then
        Notification.alert("No download folder is set.")
        return
    end

    local FileManager = require("apps/filemanager/filemanager")

    -- Closing the document first: reinit() on the file manager while a book is
    -- open leaves KOReader showing the reader with the file manager behind it.
    if plugin.ui and plugin.ui.document then
        plugin.ui:onClose()
    end

    if FileManager.instance then
        FileManager.instance:reinit(folder)
    else
        FileManager:showFiles(folder)
    end
end

--- The download submenu.
-- @tparam table plugin
-- @treturn table
-- Which settings the list picker writes here. `filter_list` decides what is
-- synced at all, so unlike the book list a missing one is an error, not a
-- shrug -- see features/menu/list_picker.lua.
DownloadMenu.LIST_KEYS = { name = "filter_list", id = "filter_list_id" }

function DownloadMenu.build(plugin)
    local settings = plugin.settings

    return {
        {
            text_func = function()
                return "What to download: " .. DownloadMenu.describeScope(settings)
            end,
            help_text = table.concat({
                "Set 'filter_list' and 'filter_tags' in karabridge.conf.",
                "",
                "A list and several tags can be combined: the list narrows the set on the "
                    .. "server and the tags are applied on the device.",
            }, "\n"),
            keep_menu_open = true,
            callback = function()
                Notification.alert(DownloadMenu.describeScopeDetail(plugin))
            end,
        },
        {
            text_func = function()
                return ListPicker.describe(plugin, DownloadMenu.LIST_KEYS, "Only from list")
            end,
            help_text = table.concat({
                "Sync only the bookmarks in one Karakeep list.",
                "",
                "Unlike the list for book cards, this one decides what is synced at all. "
                    .. "If it is missing from Karakeep the sync stops and says so, rather "
                    .. "than quietly falling back to everything and filling the device.",
            }, "\n"),
            sub_item_table_func = function()
                return ListPicker.build(plugin, DownloadMenu.LIST_KEYS, "Sync from every list.")
            end,
        },
        {
            text_func = function()
                return string.format("Articles per sync: %d", settings:get("articles_per_sync") or 30)
            end,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                local SpinWidget = require("ui/widget/spinwidget")
                local UIManager = require("ui/uimanager")

                UIManager:show(SpinWidget:new({
                    title_text = "Articles per sync",
                    info_text = "The newest articles are fetched, up to this many.",
                    value = settings:get("articles_per_sync") or 30,
                    value_min = 1,
                    value_max = 200,
                    value_step = 1,
                    value_hold_step = 10,
                    callback = function(spin)
                        settings:set("articles_per_sync", spin.value)
                        settings:flush()
                        if touchmenu_instance then
                            touchmenu_instance:updateItems()
                        end
                    end,
                }))
            end,
        },
        {
            text = "Embed images",
            checked_func = function()
                return settings:get("download_images") ~= false
            end,
            callback = function()
                settings:set("download_images", settings:get("download_images") == false)
                settings:flush()
            end,
        },
        {
            text = "Prefer the saved page archive",
            help_text = table.concat({
                "Off (recommended): use Karakeep's extracted article, which is just the prose.",
                "",
                "On: use the full page archive instead -- the whole page, including navigation "
                    .. "and banners. Karakeep already extracts its article text from an archive, "
                    .. "so this is only worth turning on for pages where that extraction went wrong.",
            }, "\n"),
            checked_func = function()
                return settings:get("prefer_archive") == true
            end,
            callback = function()
                settings:set("prefer_archive", settings:get("prefer_archive") ~= true)
                settings:flush()
            end,
        },
    }
end

--- The detail shown when the scope row is tapped.
-- @tparam table plugin
-- @treturn string
function DownloadMenu.describeScopeDetail(plugin)
    local downloader = Downloader.new({ client = plugin:getClient(), settings = plugin.settings })
    local scope = downloader:resolveScope()

    if scope:isErr() then
        return "This filter cannot be used:\n\n" .. (scope.message or scope:describe())
    end

    return table.concat({
        "Downloading: " .. scope.value.label,
        "",
        "Change this with 'filter_list' and 'filter_tags' in karabridge.conf,",
        "then use Settings file -> Reload it now.",
    }, "\n")
end

return DownloadMenu
