require("spec.support.helper")

local Text = require("karabridge.shared.text")

describe("Text", function()
    describe("trim", function()
        it("removes surrounding whitespace", function()
            assert.equals("hello", Text.trim("  \t hello \n "))
        end)

        it("returns an empty string for a non-string", function()
            assert.equals("", Text.trim(nil))
            assert.equals("", Text.trim(42))
        end)
    end)

    describe("normaliseWhitespace", function()
        it("collapses runs of whitespace", function()
            assert.equals("a b c", Text.normaliseWhitespace("a  \n\t b   c"))
        end)

        it("makes text captured on device comparable with text from the server", function()
            local from_device = "The quick\nbrown  fox"
            local from_server = "The quick brown fox"
            assert.equals(Text.normaliseWhitespace(from_server), Text.normaliseWhitespace(from_device))
        end)
    end)

    describe("trimPartialUtf8", function()
        it("leaves complete ASCII alone", function()
            assert.equals("hello", Text.trimPartialUtf8("hello"))
        end)

        it("leaves a complete multi-byte sequence alone", function()
            -- "ä" is C3 A4
            assert.equals("h\195\164", Text.trimPartialUtf8("h\195\164"))
        end)

        it("drops a dangling two-byte lead", function()
            assert.equals("h", Text.trimPartialUtf8("h\195"))
        end)

        it("drops a truncated four-byte sequence", function()
            -- U+1F600 is F0 9F 98 80; cut after three bytes.
            assert.equals("x", Text.trimPartialUtf8("x\240\159\152"))
        end)
    end)

    describe("truncate", function()
        it("leaves short text alone", function()
            assert.equals("short", Text.truncate("short", 100))
        end)

        it("never splits a character", function()
            -- Six bytes of three two-byte characters, cut at five.
            local truncated = Text.truncate("\195\164\195\182\195\188", 5)
            assert.equals("\195\164\195\182", truncated)
        end)
    end)

    describe("escapeXml", function()
        it("escapes the five predefined entities", function()
            assert.equals("&amp;&lt;&gt;&quot;&apos;", Text.escapeXml("&<>\"'"))
        end)

        it("escapes the ampersand first, so escapes are not double-escaped", function()
            assert.equals("&amp;lt;", Text.escapeXml("&lt;"))
        end)
    end)

    describe("displayText", function()
        it("passes through usable text", function()
            assert.equals("Title", Text.displayText("Title", "?"))
        end)

        it("falls back for empty, nil and table values", function()
            assert.equals("Untitled", Text.displayText("", "Untitled"))
            assert.equals("Untitled", Text.displayText(nil, "Untitled"))
            assert.equals("Untitled", Text.displayText({}, "Untitled"))
        end)

        it("renders a number, because an ID may legitimately be one", function()
            assert.equals("42", Text.displayText(42))
        end)
    end)

    describe("splitList", function()
        it("splits and trims", function()
            assert.same({ "read-later", "ebook" }, Text.splitList("read-later, ebook"))
        end)

        it("drops empty entries left by a trailing or doubled comma", function()
            assert.same({ "a", "b" }, Text.splitList("a,,b,"))
        end)

        it("returns an empty list for empty input", function()
            assert.same({}, Text.splitList(""))
            assert.same({}, Text.splitList(nil))
        end)

        it("keeps a single item with no comma", function()
            assert.same({ "solo" }, Text.splitList("  solo  "))
        end)
    end)
end)
