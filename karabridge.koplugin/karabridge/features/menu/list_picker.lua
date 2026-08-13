--[[--
Choosing a Karakeep list from the menu, for any setting that names one.

Two settings name a list, and they are not interchangeable:

  * `book_list` — where a **new** book card is filed. Decoration: if the list
    is gone, the card is still created and the export still succeeds.
  * `filter_list` — which bookmarks are synced at all. Load-bearing: if that
    list is gone, the sync **stops**, because "only list X" quietly becoming
    "everything" would flood the device with articles nobody asked for.

The picker is the same in both cases; only the keys and the wording differ.

## Why the list is remembered by ID as well as by name

Each survives a failure the other does not. A name breaks the moment the list
is renamed in Karakeep; an ID breaks if the list is deleted and made again.
Both are stored, the ID is preferred, and whichever matched is written back so
the other catches up. It costs nothing: `GET /lists` returns the whole set, so
matching on both is one request either way.

## Why a deleted list is shown rather than hidden

If a chosen list disappears from Karakeep, the obvious thing is to drop it from
the menu. That is wrong: the setting still names it, the sync still behaves
differently because of it, and a row that has silently reverted to "none" tells
the user nothing. So the name stays, marked as missing, until they replace it.

## Why the rows are replaced rather than redrawn

`sub_item_table_func` runs **once**, when the submenu is opened
(`touchmenu.lua:858`); `updateItems()` afterwards only redraws whatever
`item_table` already holds. So a fetch that adds lists could not show them: the
table it would have to change was built before the fetch happened.

`repopulate` therefore rebuilds the rows and swaps them into the live
`item_table` in place, then redraws. Replacing the table wholesale would not
work either -- the menu holds a reference to the one it was given.

## Why the catalogue is cached

A menu builder must never make a network call. The menu would then be as slow
and as failable as the connection, and drawing it offline would hang. Fetching
is a row of its own, and one fetch serves both pickers — they are the same
lists.

@module karabridge.features.menu.list_picker
]]

local Connectivity = require("karabridge.features.connectivity")
local Lists = require("karabridge.api.lists")
local Logging = require("karabridge.shared.logging")
local Notification = require("karabridge.shared.notification")
local Progress = require("karabridge.features.progress")
local Text = require("karabridge.shared.text")

local log = Logging.forModule("menu.list_picker")

local ListPicker = {}

-- Where the last fetch is kept. One catalogue, because both settings choose
-- from the same set of lists.
ListPicker.CACHE_KEY = "list_catalogue"

--- The lists last seen on the server.
-- @tparam table plugin
-- @treturn table Array of `{ id, name }`.
function ListPicker.catalogue(plugin)
    local cached = plugin.settings:getInternal(ListPicker.CACHE_KEY)
    return type(cached) == "table" and cached or {}
end

--- Store what a fetch returned.
-- @tparam table plugin
-- @tparam table fetched The Result from `Lists:all`.
-- @tparam[opt] function done
function ListPicker.remember(plugin, fetched, done)
    if fetched:isErr() then
        Notification.alert("Could not read the lists from Karakeep.\n\n" .. fetched:describe())
        return
    end

    local catalogue = {}
    for _, list in ipairs(fetched.value or {}) do
        if type(list.id) == "string" and type(list.name) == "string" then
            table.insert(catalogue, { id = list.id, name = list.name })
        end
    end
    table.sort(catalogue, function(a, b)
        return a.name:lower() < b.name:lower()
    end)

    plugin.settings:setInternal(ListPicker.CACHE_KEY, catalogue)
    plugin.settings:flush()

    if #catalogue == 0 then
        Notification.info("Karakeep has no lists yet.")
    end

    if done then
        done(true)
    end
end

--- Fetch the lists from Karakeep and remember them.
-- @tparam table plugin
-- @tparam[opt] function done
function ListPicker.refresh(plugin, done)
    Connectivity.whenConnected(function()
        Progress.run({
            message = "Reading the lists from Karakeep" .. Text.ELLIPSIS,
            work = function()
                return Lists.new(plugin:getClient()):all()
            end,
            done = function(fetched)
                ListPicker.remember(plugin, fetched, done)
            end,
        })
    end)
end

--- The list a setting names, and whether the server still has it.
--
-- @tparam table plugin
-- @tparam table keys `{ name = "book_list", id = "book_list_id" }`
-- @treturn string name, empty when none is chosen
-- @treturn boolean known Whether it is in the last fetched catalogue.
function ListPicker.chosen(plugin, keys)
    local name = Text.trim(plugin.settings:get(keys.name) or "")
    if name == "" then
        return "", true
    end

    local id = Text.trim(plugin.settings:get(keys.id) or "")
    local catalogue = ListPicker.catalogue(plugin)

    -- An empty catalogue means "never fetched", not "no lists exist". Claiming
    -- the chosen list is missing on that basis would be a guess, and a
    -- frightening one.
    if #catalogue == 0 then
        return name, true
    end

    for _, list in ipairs(catalogue) do
        if list.id == id or list.name:lower() == name:lower() then
            return name, true
        end
    end

    return name, false
end

--- The label for the row that opens the picker.
-- @tparam table plugin
-- @tparam table keys
-- @tparam string prefix e.g. "List for new book cards"
-- @treturn string
function ListPicker.describe(plugin, keys, prefix)
    local name, known = ListPicker.chosen(plugin, keys)

    if name == "" then
        return prefix .. ": none"
    end
    if not known then
        return prefix .. ": " .. name .. " (not on the server)"
    end
    return prefix .. ": " .. name
end

--- Choose a list, or none.
-- @tparam table plugin
-- @tparam table keys
-- @tparam table|nil list `{ id, name }`
function ListPicker.choose(plugin, keys, list)
    plugin.settings:set(keys.name, list and list.name or "")
    plugin.settings:set(keys.id, list and list.id or "")
    plugin.settings:flush()
    log.info(keys.name, "set to", list and list.name or "none")
end

--- Rebuild the picker's rows in the menu that is already open.
--
-- The menu holds the table `sub_item_table_func` returned, and only re-reads it
-- on redraw -- so the rows are swapped into that same table rather than a new
-- one being handed over.
--
-- @tparam table plugin
-- @tparam table keys
-- @tparam string|nil none_help
-- @tparam table|nil touchmenu_instance
function ListPicker.repopulate(plugin, keys, none_help, touchmenu_instance)
    if type(touchmenu_instance) ~= "table" or type(touchmenu_instance.item_table) ~= "table" then
        return
    end

    local rebuilt = ListPicker.build(plugin, keys, none_help)
    local live = touchmenu_instance.item_table

    for index = #live, 1, -1 do
        live[index] = nil
    end
    for _, item in ipairs(rebuilt) do
        table.insert(live, item)
    end

    touchmenu_instance:updateItems()
end

--- Ask for a name and create the list in Karakeep.
--
-- @tparam table plugin
-- @tparam table keys
-- @tparam string|nil none_help
-- @tparam table|nil touchmenu_instance
function ListPicker.createList(plugin, keys, none_help, touchmenu_instance)
    local ok, InputDialog = pcall(require, "ui/widget/inputdialog")
    if not ok then
        return
    end
    local UIManager = require("ui/uimanager")

    local dialog
    dialog = InputDialog:new({
        title = "New Karakeep list",
        description = "The list is created in Karakeep and chosen here.",
        input = "",
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
                    text = "Create",
                    callback = function()
                        local name = Text.trim(dialog:getInputText() or "")
                        UIManager:close(dialog)

                        if name == "" then
                            return
                        end

                        Connectivity.whenConnected(function()
                            Progress.run({
                                message = "Creating '" .. name .. "'" .. Text.ELLIPSIS,
                                work = function()
                                    return Lists.new(plugin:getClient()):create(name)
                                end,
                                done = function(created)
                                    ListPicker.afterCreate(
                                        plugin,
                                        keys,
                                        none_help,
                                        created,
                                        touchmenu_instance
                                    )
                                end,
                            })
                        end)
                    end,
                },
            },
        },
    })

    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

--- Record a newly created list, choose it, and show it.
-- @tparam table plugin
-- @tparam table keys
-- @tparam string|nil none_help
-- @tparam table created The Result from `Lists:create`.
-- @tparam table|nil touchmenu_instance
function ListPicker.afterCreate(plugin, keys, none_help, created, touchmenu_instance)
    if created:isErr() then
        Notification.alert("Could not create the list.\n\n" .. created:describe())
        return
    end

    local list = created.value or {}
    if type(list.id) ~= "string" or type(list.name) ~= "string" then
        Notification.alert("Karakeep created the list but did not say which one it is.")
        return
    end

    -- Added to the catalogue rather than triggering another fetch: we know
    -- exactly what changed, and a second request would say the same thing.
    local catalogue = ListPicker.catalogue(plugin)
    table.insert(catalogue, { id = list.id, name = list.name })
    plugin.settings:setInternal(ListPicker.CACHE_KEY, catalogue)

    -- Choosing it is the point of having made it.
    ListPicker.choose(plugin, keys, { id = list.id, name = list.name })

    Notification.info("Created '" .. list.name .. "' and selected it.")
    ListPicker.repopulate(plugin, keys, none_help, touchmenu_instance)
end

--- The picker's items.
--
-- @tparam table plugin
-- @tparam table keys
-- @tparam[opt] string none_help What choosing "None" means for this setting.
-- @treturn table
function ListPicker.build(plugin, keys, none_help)
    local items = {
        {
            text = "Fetch the lists from Karakeep",
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                ListPicker.refresh(plugin, function()
                    ListPicker.repopulate(plugin, keys, none_help, touchmenu_instance)
                end)
            end,
        },
        {
            text = "Create a new list" .. Text.ELLIPSIS,
            help_text = "Creates it in Karakeep and selects it here.",
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                ListPicker.createList(plugin, keys, none_help, touchmenu_instance)
            end,
        },
        {
            text = "None",
            help_text = none_help,
            checked_func = function()
                return ListPicker.chosen(plugin, keys) == ""
            end,
            radio = true,
            callback = function()
                ListPicker.choose(plugin, keys, nil)
            end,
        },
    }

    local catalogue = {}
    for _, list in ipairs(ListPicker.catalogue(plugin)) do
        table.insert(catalogue, list)
    end
    -- Sorted here as well as on the way in, so a cache written by an older
    -- version still displays in a sensible order.
    table.sort(catalogue, function(a, b)
        return tostring(a.name):lower() < tostring(b.name):lower()
    end)

    local chosen, known = ListPicker.chosen(plugin, keys)

    -- A chosen list the server no longer has. Kept visible, because the
    -- setting still names it and a row that quietly said "none" would hide
    -- that.
    if chosen ~= "" and not known then
        table.insert(items, {
            text = chosen .. " (not on the server)",
            help_text = "This list is gone from Karakeep. Pick another, or None.",
            checked_func = function()
                return true
            end,
            radio = true,
            enabled_func = function()
                return false
            end,
            keep_menu_open = true,
        })
    end

    if #catalogue == 0 then
        table.insert(items, {
            text = "No lists known yet -- fetch them first",
            enabled_func = function()
                return false
            end,
            keep_menu_open = true,
        })
        return items
    end

    for _, list in ipairs(catalogue) do
        table.insert(items, {
            text = list.name,
            checked_func = function()
                local name, present = ListPicker.chosen(plugin, keys)
                return present and name:lower() == list.name:lower()
            end,
            radio = true,
            callback = function()
                ListPicker.choose(plugin, keys, list)
            end,
        })
    end

    return items
end

return ListPicker
