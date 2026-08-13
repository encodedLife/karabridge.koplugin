local Helper = require("spec.support.helper")

local BookExportMenu = require("karabridge.features.book_export.menu")

-- A stand-in for KOReader's G_reader_settings, which the exporter's own
-- enabled flag lives in.
local function installGlobalSettings(initial)
    local data = initial or {}
    _G.G_reader_settings = {
        readSetting = function(_, key)
            return data[key]
        end,
        saveSetting = function(_, key, value)
            data[key] = value
        end,
    }
    return data
end

describe("book_export.Menu", function()
    -- The defect this exists for: KOReader runs an export target only when its
    -- own `enabled` flag is set, and every target starts off. A user who had
    -- configured KaraBridge, opened a book with highlights and tapped "Export
    -- highlights" got nothing at all, with no message -- because the switch
    -- lives in a menu they had no reason to visit.
    before_each(function()
        Helper.install()
        installGlobalSettings()
    end)

    after_each(function()
        Helper.uninstall()
        _G.G_reader_settings = nil
    end)

    local function plugin(values)
        local base = { server_url = "https://k.example.org", api_token = "ak1_x" }
        for key, value in pairs(values or {}) do
            base[key] = value
        end
        return { settings = Helper.settings(base) }
    end

    describe("state", function()
        it("is off when the target has never been ticked", function()
            local ready, reason = BookExportMenu.state(plugin())

            assert.is_false(ready)
            assert.matches("not ticked", reason)
        end)

        it("is off when the server is not configured", function()
            local ready, reason = BookExportMenu.state({ settings = Helper.settings() })

            assert.is_false(ready)
            assert.matches("server is not configured", reason)
        end)

        it("is off when KaraBridge's own switch is off", function()
            local ready, reason = BookExportMenu.state(plugin({ export_local_books = false }))

            assert.is_false(ready)
            assert.matches("switched off in KaraBridge", reason)
        end)

        it("is on once the target is ticked and the server is configured", function()
            BookExportMenu.setTargetEnabled(true)
            assert.is_true(BookExportMenu.state(plugin()))
        end)
    end)

    describe("describe", function()
        it("says why it is off, not merely that it is", function()
            -- "off" alone is what left the user with nothing to act on.
            assert.matches("not ticked", BookExportMenu.describe(plugin()))
        end)

        it("says on when it is on", function()
            BookExportMenu.setTargetEnabled(true)
            assert.equals("Export book highlights: on", BookExportMenu.describe(plugin()))
        end)
    end)

    describe("toggle", function()
        it("sets both switches, so one tap is enough", function()
            local p = plugin()
            BookExportMenu.toggle(p)

            assert.is_true(BookExportMenu.isTargetEnabled())
            assert.is_true(p.settings:get("export_local_books"))
            assert.is_true(BookExportMenu.state(p))
        end)

        it("clears both switches when turned off again", function()
            local p = plugin()
            BookExportMenu.toggle(p)
            BookExportMenu.toggle(p)

            assert.is_false(BookExportMenu.isTargetEnabled())
            assert.is_false(p.settings:get("export_local_books"))
        end)

        it("refuses, with an explanation, when the server is not configured", function()
            local messages = {}
            require("karabridge.shared.notification").setBackend({
                info = function(text)
                    table.insert(messages, text)
                end,
                alert = function(text)
                    table.insert(messages, text)
                end,
            })

            BookExportMenu.toggle({ settings = Helper.settings() })
            require("karabridge.shared.notification").setBackend(nil)

            assert.is_false(BookExportMenu.isTargetEnabled())
            assert.matches("server address and API key", table.concat(messages, "\n"))
        end)

        it("tells the user where to export from", function()
            -- Knowing the switch is on is not enough; the action lives in a
            -- different menu again.
            local messages = {}
            require("karabridge.shared.notification").setBackend({
                info = function() end,
                alert = function(text)
                    table.insert(messages, text)
                end,
            })

            BookExportMenu.toggle(plugin())
            require("karabridge.shared.notification").setBackend(nil)

            assert.matches("Export highlights", table.concat(messages, "\n"))
        end)
    end)

    describe("build", function()
        it("gives every row a label", function()
            for _, item in ipairs(BookExportMenu.build(plugin())) do
                assert.is_true(item.text ~= nil or item.text_func ~= nil)
            end
        end)

        it("evaluates every label without error", function()
            for _, item in ipairs(BookExportMenu.build(plugin())) do
                if item.text_func then
                    assert.is_string(item.text_func())
                end
            end
        end)

        it("survives having no G_reader_settings at all", function()
            _G.G_reader_settings = nil
            assert.is_false(BookExportMenu.isTargetEnabled())
        end)
    end)
end)
