--[[--
Turning book export on, from KaraBridge's own menu.

KOReader's highlight exporter runs a target only when that target's
`settings.enabled` is set (`exporter.koplugin/base.lua:128`), and every target
starts switched off. So a user who has configured KaraBridge, opened a book
with highlights and tapped **Export highlights** gets nothing at all, with no
message — because KaraBridge was never ticked in a different menu they had no
reason to visit.

That is a fair thing for KOReader to do; it is not a fair thing for KaraBridge
to leave unexplained. This module puts the same switch in KaraBridge's own
menu, next to everything else about Karakeep, and says what state it is in.

Both switches are kept in step:

  * `export_local_books` — KaraBridge's own setting, so it can be turned on
    from `karabridge.conf` before the device is ever touched;
  * `G_reader_settings.exporter.karabridge.enabled` — KOReader's, which is
    what its exporter actually reads.

Toggling here sets both. Ticking KaraBridge in KOReader's own exporter menu
still works, and `isReadyToExport` consults `export_local_books`, so the two
cannot disagree in a way that leaves the user stuck.

@module karabridge.features.book_export.menu
]]

local ListPicker = require("karabridge.features.menu.list_picker")
local Logging = require("karabridge.shared.logging")
local Notification = require("karabridge.shared.notification")

local log = Logging.forModule("book_export.menu")

local BookExportMenu = {}

--- The exporter's stored settings for a target, from G_reader_settings.
--
-- Read directly rather than through the target object, because the target may
-- not have hydrated yet and this has to work whenever the menu is drawn.
--
-- @treturn table
local function exporterSettings()
    -- selene: allow(undefined_variable)
    if type(G_reader_settings) ~= "table" and type(G_reader_settings) ~= "userdata" then
        return {}
    end
    -- selene: allow(undefined_variable)
    local all = G_reader_settings:readSetting("exporter") or {}
    return all
end

--- Is KaraBridge ticked as an export target in KOReader?
-- @treturn boolean
function BookExportMenu.isTargetEnabled()
    local all = exporterSettings()
    return type(all.karabridge) == "table" and all.karabridge.enabled == true
end

--- Tick or untick KaraBridge in KOReader's exporter settings.
-- @tparam boolean enabled
function BookExportMenu.setTargetEnabled(enabled)
    -- selene: allow(undefined_variable)
    if type(G_reader_settings) ~= "table" and type(G_reader_settings) ~= "userdata" then
        return
    end

    local all = exporterSettings()
    all.karabridge = all.karabridge or {}
    all.karabridge.enabled = enabled and true or nil

    -- selene: allow(undefined_variable)
    G_reader_settings:saveSetting("exporter", all)
    log.info("book export target", enabled and "enabled" or "disabled")
end

--- Whether book export will actually do anything, and why not.
-- @tparam table plugin
-- @treturn boolean ready
-- @treturn string reason
function BookExportMenu.state(plugin)
    if plugin.settings:get("export_local_books") == false then
        return false, "switched off in KaraBridge"
    end
    if not plugin.settings:readiness().connect then
        return false, "the server is not configured"
    end
    if not BookExportMenu.isTargetEnabled() then
        return false, "not ticked as an export target"
    end
    return true, "on"
end

--- The menu label.
-- @tparam table plugin
-- @treturn string
function BookExportMenu.describe(plugin)
    local ready, reason = BookExportMenu.state(plugin)
    if ready then
        return "Export book highlights: on"
    end
    return "Export book highlights: off (" .. reason .. ")"
end

--- Turn book export on or off, setting both switches.
-- @tparam table plugin
function BookExportMenu.toggle(plugin)
    local ready = BookExportMenu.state(plugin)

    if ready then
        plugin.settings:set("export_local_books", false)
        plugin.settings:flush()
        BookExportMenu.setTargetEnabled(false)
        Notification.info("Book highlights will no longer be exported.")
        return
    end

    if not plugin.settings:readiness().connect then
        Notification.alert("Set the Karakeep server address and API key first.")
        return
    end

    plugin.settings:set("export_local_books", true)
    plugin.settings:flush()
    BookExportMenu.setTargetEnabled(true)

    Notification.alert(table.concat({
        "Book highlights will now be exported to Karakeep.",
        "",
        "Export them with:",
        "Tools \226\134\146 Export highlights \226\134\146 Export all notes in current book",
        "",
        "Each book becomes one Karakeep card whose text you can edit freely,",
        "with every marked passage attached to it as a Karakeep highlight.",
    }, "\n"))
end

-- Which settings this picker writes. Kept together so the two never drift.
BookExportMenu.LIST_KEYS = { name = "book_list", id = "book_list_id" }

--- The submenu.
-- @tparam table plugin
-- @treturn table
function BookExportMenu.build(plugin)
    local settings = plugin.settings

    return {
        {
            text_func = function()
                return BookExportMenu.describe(plugin)
            end,
            help_text = table.concat({
                "Offers KaraBridge as a target in KOReader's highlight exporter.",
                "",
                "KOReader keeps that switch in Tools > Export highlights > Formats, "
                    .. "and every target starts switched off -- which is why an export "
                    .. "can silently do nothing. This sets it for you.",
            }, "\n"),
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                BookExportMenu.toggle(plugin)
                if touchmenu_instance then
                    touchmenu_instance:updateItems()
                end
            end,
        },
        {
            text = "How to export",
            keep_menu_open = true,
            callback = function()
                Notification.alert(table.concat({
                    "Open a book, then:",
                    "",
                    "Tools \226\134\146 Export highlights",
                    "  \226\134\146 Export all notes in current book",
                    "",
                    "Each book becomes one Karakeep card. Exporting again reuses that",
                    "same card rather than creating a second one.",
                    "",
                    "The card body is written only when the card is created, and is",
                    "yours to edit afterwards. Later exports never overwrite it.",
                    "",
                    "Every marked passage is a real Karakeep highlight attached to the",
                    "card, not a copy inside its text, so the book appears in the",
                    "Highlights view just as a saved article does.",
                    "",
                    "The cover is uploaded too. Karakeep shows it in the list layout",
                    "and on the preview page, but not as a grid thumbnail.",
                }, "\n"))
            end,
        },
        {
            text_func = function()
                return "Upload covers: " .. (settings:get("upload_book_cover") ~= false and "yes" or "no")
            end,
            help_text = "Set 'upload_book_cover' in karabridge.conf.",
            enabled_func = function()
                return false
            end,
            keep_menu_open = true,
        },
        {
            text_func = function()
                local tag = settings:get("book_tag") or ""
                return "Tag for book cards: " .. (tag ~= "" and tag or "none")
            end,
            help_text = "Set 'book_tag' in karabridge.conf.",
            enabled_func = function()
                return false
            end,
            keep_menu_open = true,
        },
        {
            text_func = function()
                return ListPicker.describe(plugin, BookExportMenu.LIST_KEYS, "List for new book cards")
            end,
            help_text = table.concat({
                "Which Karakeep list a book card is put into when it is created.",
                "",
                "Only when it is created. If you later move a card to another list in "
                    .. "Karakeep, it stays there -- KaraBridge never files an existing card "
                    .. "again, and changing this setting does not move the cards you already "
                    .. "have. Where you put a card is your decision.",
                "",
                "Finding the card again does not depend on this at all: it is looked up by "
                    .. "its bookmark ID, which no amount of moving changes.",
            }, "\n"),
            sub_item_table_func = function()
                return ListPicker.build(
                    plugin,
                    BookExportMenu.LIST_KEYS,
                    "New book cards are not added to any list."
                )
            end,
        },
        {
            text = "Card body: editable in Karakeep",
            help_text = table.concat({
                "A book becomes one Karakeep card plus its highlights, and the two are separate.",
                "",
                "The card body is yours. KaraBridge writes it once, when it creates the card, "
                    .. "and never touches it again -- not the text, not the title. Notes, summaries "
                    .. "and questions you write there survive every later export.",
                "",
                "The highlights are not in that text. Each is a real Karakeep highlight attached "
                    .. "to the card, so later exports synchronise highlights and the cover, and "
                    .. "leave the body alone.",
            }, "\n"),
            keep_menu_open = true,
        },
    }
end

return BookExportMenu
