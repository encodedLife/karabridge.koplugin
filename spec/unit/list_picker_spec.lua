--[[--
Choosing a Karakeep list from the menu.

The case worth most of this file: the list is deleted in Karakeep. The setting
still names it, so the menu must say so rather than quietly reading "none" --
and the two settings that name a list must go on behaving differently, because
one is decoration and the other decides what gets synced at all.
]]

local Helper = require("spec.support.helper")

local ListPicker = require("karabridge.features.menu.list_picker")

local BOOK_KEYS = { name = "book_list", id = "book_list_id" }
local FILTER_KEYS = { name = "filter_list", id = "filter_list_id" }

local CATALOGUE = { { id = "l1", name = "KOReader Books" }, { id = "l2", name = "Fiction" } }

local function plugin(values, catalogue)
    local settings = Helper.settings(values)
    if catalogue then
        settings:setInternal(ListPicker.CACHE_KEY, catalogue)
    end
    return { settings = settings }
end

local function labels(items)
    local out = {}
    for _, item in ipairs(items) do
        table.insert(out, item.text)
    end
    return out
end

--- Find a row by its label, so inserting a row does not break every index.
local function row(items, text)
    for _, item in ipairs(items) do
        if item.text == text then
            return item
        end
    end
    return nil
end

describe("ListPicker", function()
    before_each(function()
        Helper.install()
    end)

    after_each(function()
        Helper.uninstall()
    end)

    describe("build", function()
        it("offers the actions, None, and every cached list", function()
            local items = ListPicker.build(plugin({}, CATALOGUE), BOOK_KEYS)
            assert.same({
                "Fetch the lists from Karakeep",
                "Create a new list" .. require("karabridge.shared.text").ELLIPSIS,
                "None",
                "Fiction",
                "KOReader Books",
            }, labels(items))
        end)

        it("ticks None when nothing is chosen", function()
            local items = ListPicker.build(plugin({}, CATALOGUE), BOOK_KEYS)
            assert.is_true(row(items, "None").checked_func())
            assert.is_false(row(items, "Fiction").checked_func())
        end)

        it("ticks the chosen list", function()
            local items = ListPicker.build(plugin({ book_list = "Fiction" }, CATALOGUE), BOOK_KEYS)
            assert.is_false(row(items, "None").checked_func())
            assert.is_true(row(items, "Fiction").checked_func())
        end)

        it("says so plainly when nothing has been fetched yet", function()
            local items = ListPicker.build(plugin({}), BOOK_KEYS)
            local empty = row(items, "No lists known yet -- fetch them first")
            assert.is_not_nil(empty)
            assert.is_false(empty.enabled_func())
        end)

        it("serves both settings from one catalogue", function()
            -- They are the same lists. Fetching twice would be a second request
            -- for the same answer.
            local p = plugin({}, CATALOGUE)
            assert.is_not_nil(row(ListPicker.build(p, BOOK_KEYS), "Fiction"))
            assert.is_not_nil(row(ListPicker.build(p, FILTER_KEYS), "Fiction"))
        end)
    end)

    describe("a list deleted in Karakeep", function()
        it("keeps naming it, marked as gone", function()
            -- Dropping it would leave a menu that reads "none" while the
            -- setting still names a list and the sync still behaves
            -- differently because of it.
            local p = plugin({ book_list = "Deleted", book_list_id = "gone" }, CATALOGUE)

            local name, known = ListPicker.chosen(p, BOOK_KEYS)
            assert.equals("Deleted", name)
            assert.is_false(known)
        end)

        it("says it in the row label", function()
            local p = plugin({ book_list = "Deleted", book_list_id = "gone" }, CATALOGUE)
            assert.equals(
                "List for new book cards: Deleted (not on the server)",
                ListPicker.describe(p, BOOK_KEYS, "List for new book cards")
            )
        end)

        it("shows it in the picker so it can be replaced deliberately", function()
            local p = plugin({ book_list = "Deleted", book_list_id = "gone" }, CATALOGUE)
            local missing = row(ListPicker.build(p, BOOK_KEYS), "Deleted (not on the server)")

            assert.is_not_nil(missing)
            assert.is_true(missing.checked_func())
            assert.is_false(missing.enabled_func())
        end)

        it("does not tick any live list while one is missing", function()
            local p = plugin({ book_list = "Deleted", book_list_id = "gone" }, CATALOGUE)
            local items = ListPicker.build(p, BOOK_KEYS)

            assert.is_false(row(items, "Fiction").checked_func())
            assert.is_false(row(items, "KOReader Books").checked_func())
        end)

        it("does not cry wolf before anything has been fetched", function()
            -- An empty catalogue means "never asked", not "no lists exist".
            local p = plugin({ book_list = "Fiction" })

            local name, known = ListPicker.chosen(p, BOOK_KEYS)
            assert.equals("Fiction", name)
            assert.is_true(known)
        end)
    end)

    describe("choose", function()
        it("stores both the name and the ID", function()
            -- The name breaks when the list is renamed; the ID breaks when it
            -- is deleted and made again. Each covers the other.
            local p = plugin({}, CATALOGUE)

            ListPicker.choose(p, BOOK_KEYS, CATALOGUE[2])

            assert.equals("Fiction", p.settings:get("book_list"))
            assert.equals("l2", p.settings:get("book_list_id"))
        end)

        it("clears both for None", function()
            local p = plugin({ book_list = "Fiction", book_list_id = "l2" }, CATALOGUE)

            ListPicker.choose(p, BOOK_KEYS, nil)

            assert.equals("", p.settings:get("book_list"))
            assert.equals("", p.settings:get("book_list_id"))
        end)

        it("writes the filter keys when given them", function()
            local p = plugin({}, CATALOGUE)

            ListPicker.choose(p, FILTER_KEYS, CATALOGUE[1])

            assert.equals("KOReader Books", p.settings:get("filter_list"))
            assert.equals("l1", p.settings:get("filter_list_id"))
            assert.equals("", p.settings:get("book_list"))
        end)
    end)

    describe("repopulate", function()
        -- sub_item_table_func runs once, when the submenu is opened; updateItems
        -- only redraws what item_table already holds. So a fetch that found new
        -- lists could not show them until the menu was left and re-entered.
        it("swaps the rows into the table the menu is holding", function()
            local p = plugin({})
            local live = ListPicker.build(p, BOOK_KEYS)
            local redrawn = 0

            local menu = {
                item_table = live,
                updateItems = function()
                    redrawn = redrawn + 1
                end,
            }

            assert.is_nil(row(live, "Fiction"))

            -- What a fetch does.
            p.settings:setInternal(ListPicker.CACHE_KEY, CATALOGUE)
            ListPicker.repopulate(p, BOOK_KEYS, nil, menu)

            -- The same table, now with the lists in it.
            assert.is_true(menu.item_table == live)
            assert.is_not_nil(row(live, "Fiction"))
            assert.equals(1, redrawn)
        end)

        it("does nothing without a menu to update", function()
            local p = plugin({}, CATALOGUE)
            assert.has_no_error(function()
                ListPicker.repopulate(p, BOOK_KEYS, nil, nil)
                ListPicker.repopulate(p, BOOK_KEYS, nil, {})
            end)
        end)
    end)

    describe("afterCreate", function()
        local Result = require("karabridge.shared.result")

        it("adds the new list, chooses it, and shows it", function()
            local p = plugin({}, { { id = "l1", name = "KOReader Books" } })
            local live = ListPicker.build(p, BOOK_KEYS)
            local menu = { item_table = live, updateItems = function() end }

            ListPicker.afterCreate(
                p,
                BOOK_KEYS,
                nil,
                Result.ok({ id = "l9", name = "Fresh" }),
                menu
            )

            assert.equals("Fresh", p.settings:get("book_list"))
            assert.equals("l9", p.settings:get("book_list_id"))
            assert.is_not_nil(row(live, "Fresh"))
        end)

        it("changes nothing when the creation failed", function()
            local p = plugin({ book_list = "Fiction", book_list_id = "l2" }, CATALOGUE)

            ListPicker.afterCreate(p, BOOK_KEYS, nil, Result.err("bad_request", "nope"))

            assert.equals("Fiction", p.settings:get("book_list"))
        end)

        it("changes nothing when Karakeep returns no id", function()
            local p = plugin({}, CATALOGUE)

            ListPicker.afterCreate(p, BOOK_KEYS, nil, Result.ok({ name = "Fresh" }))

            assert.equals("", p.settings:get("book_list"))
        end)
    end)

    describe("catalogue", function()
        it("survives a cache that is not a table", function()
            local p = plugin({})
            p.settings.store:saveSetting(ListPicker.CACHE_KEY, "nonsense")

            assert.same({}, ListPicker.catalogue(p))
        end)
    end)
end)
