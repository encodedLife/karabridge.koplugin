--[[--
Managing the queue, including the entries that gave up.

The store could already quarantine an entry; there was no way to do anything
about one. An item set aside where the user can see it but not touch it is only
marginally better than one silently dropped — they know something was lost and
still cannot get it back.

So: inspect the reason, retry a single item, put one back in the queue, delete
one, or clear them all. "Retry after fixing the server settings" is the common
case and is exactly "release, then sync".

Every destructive action asks first. Deleting a queued item throws away the
only record that the user wanted something saved.

@module karabridge.features.queue.menu
]]

local Notification = require("karabridge.shared.notification")
local Text = require("karabridge.shared.text")

local QueueMenu = {}

--- A short, readable label for an entry.
--
-- Truncated: a queued URL can be hundreds of characters and a menu row is not.
--
-- @tparam table item `{ key, reason }`
-- @treturn string
function QueueMenu.label(item)
    local key = tostring(item.key or "?")
    if #key > 48 then
        key = key:sub(1, 45) .. Text.ELLIPSIS
    end
    return key
end

--- Confirm, then run.
local function confirm(text, ok_text, action)
    local ok, ConfirmBox = pcall(require, "ui/widget/confirmbox")
    if not ok then
        return action()
    end

    require("ui/uimanager"):show(ConfirmBox:new({
        text = text,
        ok_text = ok_text,
        ok_callback = action,
    }))
end

--- The submenu for one set-aside entry.
-- @tparam table plugin
-- @tparam table item `{ key, reason, at }`
-- @treturn table
function QueueMenu.buildEntryMenu(plugin, item)
    local store = plugin.queue.store

    return {
        {
            text = "Why it was set aside",
            keep_menu_open = true,
            callback = function()
                Notification.alert(table.concat({
                    tostring(item.key),
                    "",
                    tostring(item.reason or "no reason recorded"),
                    item.at and ("\nSet aside " .. os.date("%Y-%m-%d %H:%M", item.at)) or "",
                }, "\n"))
            end,
        },
        {
            text = "Try it again now",
            help_text = "Puts it back in the queue and sends it straight away. "
                .. "Use this after correcting the server settings.",
            callback = function()
                if not store:release(item.key) then
                    Notification.alert("This item could not be put back; it may be damaged beyond repair.")
                    return
                end
                store:flush()
                require("karabridge.features.article_download.menu").flushQueue(plugin)
            end,
        },
        {
            text = "Put it back in the queue",
            help_text = "Sends it at the next sync rather than now.",
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                if store:release(item.key) then
                    store:flush()
                    Notification.info("Back in the queue.")
                else
                    Notification.alert("This item could not be put back.")
                end
                if touchmenu_instance then
                    touchmenu_instance:updateItems()
                end
            end,
        },
        {
            text = "Delete it",
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                confirm(
                    "Delete this set-aside item?\n\n"
                        .. tostring(item.key)
                        .. "\n\nThis is the only record that you wanted it saved.",
                    "Delete",
                    function()
                        store.data.quarantine[item.key] = nil
                        store.dirty = true
                        store:flush()
                        Notification.info("Deleted.")
                        if touchmenu_instance then
                            touchmenu_instance:updateItems()
                        end
                    end
                )
            end,
        },
    }
end

--- The set-aside submenu: one row per entry, plus the bulk actions.
-- @tparam table plugin
-- @treturn table
function QueueMenu.buildParkedMenu(plugin)
    if not plugin.queue then
        return { { text = "The queue is not available.", enabled_func = function()
            return false
        end } }
    end

    local store = plugin.queue.store
    local parked = store:parked()

    if #parked == 0 then
        return {
            {
                text = "Nothing has been set aside.",
                enabled_func = function()
                    return false
                end,
            },
        }
    end

    local items = {}

    for _, item in ipairs(parked) do
        table.insert(items, {
            text = QueueMenu.label(item),
            keep_menu_open = true,
            sub_item_table_func = function()
                return QueueMenu.buildEntryMenu(plugin, item)
            end,
        })
    end

    table.insert(items, {
        text = "Put them all back in the queue",
        separator = true,
        keep_menu_open = true,
        callback = function(touchmenu_instance)
            local released = 0
            for _, item in ipairs(store:parked()) do
                if store:release(item.key) then
                    released = released + 1
                end
            end
            store:flush()
            Notification.info(string.format("%d item(s) back in the queue.", released))
            if touchmenu_instance then
                touchmenu_instance:updateItems()
            end
        end,
    })

    table.insert(items, {
        text = "Delete them all",
        keep_menu_open = true,
        callback = function(touchmenu_instance)
            confirm(
                string.format(
                    "Delete all %d set-aside item(s)?\n\nThis cannot be undone.",
                    store:parkedCount()
                ),
                "Delete all",
                function()
                    store:clearParked()
                    store:flush()
                    Notification.info("Deleted.")
                    if touchmenu_instance then
                        touchmenu_instance:updateItems()
                    end
                end
            )
        end,
    })

    return items
end

--- What the Diagnostics row shows before it is opened.
-- @tparam table plugin
-- @treturn string
function QueueMenu.describeParked(plugin)
    local parked = plugin.queue and plugin.queue.store:parkedCount() or 0
    return string.format("Set-aside items: %d", parked)
end

return QueueMenu
