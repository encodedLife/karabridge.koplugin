require("spec.support.helper")

local Offsets = require("karabridge.features.article_sync.offsets")

describe("Offsets", function()
    describe("utf16Length", function()
        -- Karakeep's offsets come from summing textContent.length over DOM text
        -- nodes, and JavaScript's String.length counts UTF-16 code units. Lua
        -- strings are bytes; the two agree only for ASCII.
        it("counts ASCII one per character", function()
            assert.equals(5, Offsets.utf16Length("hello"))
        end)

        it("counts a two-byte character as one unit", function()
            -- "ä" is C3 A4: two bytes, one UTF-16 unit.
            assert.equals(1, Offsets.utf16Length("\195\164"))
            assert.equals(3, Offsets.utf16Length("\195\164\195\182\195\188"))
        end)

        it("counts a three-byte character as one unit", function()
            -- "€" is E2 82 AC.
            assert.equals(1, Offsets.utf16Length("\226\130\172"))
        end)

        it("counts an emoji as two units, because it is a surrogate pair", function()
            -- "😀" is F0 9F 98 80: four bytes, two UTF-16 units.
            assert.equals(2, Offsets.utf16Length("\240\159\152\128"))
        end)

        it("counts a mixed string correctly", function()
            -- "aä😀" = 1 + 1 + 2
            assert.equals(4, Offsets.utf16Length("a\195\164\240\159\152\128"))
        end)

        it("returns zero for a non-string", function()
            assert.equals(0, Offsets.utf16Length(nil))
        end)
    end)

    describe("domText", function()
        it("inserts no separator between elements", function()
            -- The DOM walk concatenates text nodes and nothing else. Turning
            -- tags into spaces -- which is right for matching -- shifts every
            -- offset after the first block boundary.
            assert.equals("onetwo", Offsets.domText("<p>one</p><p>two</p>"))
        end)

        it("keeps whitespace that is really in the text", function()
            assert.equals("one two", Offsets.domText("<p>one two</p>"))
        end)

        it("decodes entities, as textContent would", function()
            assert.equals("a & b", Offsets.domText("<p>a &amp; b</p>"))
        end)

        it("drops script content, which is not rendered text", function()
            assert.equals("visible", Offsets.domText("<script>hidden()</script><p>visible</p>"))
        end)
    end)

    describe("locate", function()
        it("finds a passage and reports zero-based UTF-16 offsets", function()
            local html = "<p>The quick brown fox.</p>"
            local start_offset, end_offset = Offsets.locate(html, "quick brown")

            assert.equals(4, start_offset)
            assert.equals(15, end_offset)
        end)

        it("accounts for umlauts before the passage", function()
            -- "Über " is 5 characters but 6 bytes. A byte offset would put the
            -- highlight one character too far to the right.
            local html = "<p>\195\156ber die Br\195\188cke</p>"
            local start_offset = Offsets.locate(html, "Br\195\188cke")

            assert.equals(9, start_offset)
        end)

        it("accounts for an emoji before the passage", function()
            -- One emoji is two UTF-16 units and four bytes.
            local html = "<p>\240\159\152\128 done</p>"
            local start_offset = Offsets.locate(html, "done")

            assert.equals(3, start_offset)
        end)

        it("measures the passage itself in UTF-16 units", function()
            local html = "<p>x \195\164\195\182\195\188 y</p>"
            local start_offset, end_offset = Offsets.locate(html, "\195\164\195\182\195\188")

            assert.equals(2, start_offset)
            assert.equals(5, end_offset)
        end)

        it("does not count a separator the DOM does not have", function()
            -- Second paragraph starts at 3, not 4: there is no space between
            -- the two <p> elements in textContent.
            local html = "<p>one</p><p>two</p>"
            assert.equals(3, Offsets.locate(html, "two"))
        end)

        it("tolerates whitespace differences in the captured text", function()
            local html = "<p>The quick brown fox.</p>"
            assert.equals(4, Offsets.locate(html, "  quick   brown  "))
        end)

        it("spans a block boundary the device captured with a space", function()
            -- KOReader gives "one two" for text the DOM stores as "onetwo".
            local html = "<p>one</p><p>two</p>"
            local start_offset, end_offset = Offsets.locate(html, "one two")

            assert.equals(0, start_offset)
            assert.equals(6, end_offset)
        end)

        it("resolves a repeated passage to its first occurrence", function()
            assert.equals(0, Offsets.locate("<p>alpha beta alpha</p>", "alpha"))
        end)

        it("retries on a middle slice when the ends were captured badly", function()
            local html = "<p>Consider the following rather lengthy and quite distinctive passage.</p>"
            local sloppy = "XConsider the following rather lengthy and quite distinctive passageX"

            assert.is_not_nil(Offsets.locate(html, sloppy))
        end)

        it("gives up rather than guessing", function()
            assert.is_nil(Offsets.locate("<p>some text</p>", "nowhere in this article at all"))
        end)

        it("accepts plain text with no markup", function()
            assert.equals(6, Offsets.locate("hello world", "world"))
        end)

        it("copes with empty input", function()
            assert.is_nil(Offsets.locate("", "x"))
            assert.is_nil(Offsets.locate("<p>x</p>", ""))
            assert.is_nil(Offsets.locate(nil, "x"))
        end)
    end)

    describe("normaliseWithMap", function()
        it("maps every normalised position back to the original", function()
            local text = "  a   b  "
            local normalised, map = Offsets.normaliseWithMap(text)

            assert.equals("a b", normalised)
            assert.equals("a", text:sub(map[1], map[1]))
            assert.equals("b", text:sub(map[3], map[3]))
        end)

        it("leaves text with no runs of whitespace unchanged", function()
            local normalised, map = Offsets.normaliseWithMap("abc")

            assert.equals("abc", normalised)
            assert.same({ 1, 2, 3 }, map)
        end)
    end)
end)
