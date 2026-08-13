local Helper = require("spec.support.helper")

local EpubBuilder = require("karabridge.formats.epub_builder")

-- A sentinel for "remove this field". A plain nil in an override table cannot
-- express it: `{ title = nil }` is simply an empty table, so the merge below
-- would leave the base value in place and the spec would silently test nothing.
local NONE = setmetatable({}, { __tostring = function() return "NONE" end })

-- Both bookmarks on the author's own Karakeep have title = null, so this shape
-- is the normal case rather than an edge case.
local function bookmark(overrides)
    local base = {
        id = "abc123",
        title = "An Article",
        note = nil,
        tags = {},
        content = {
            type = "link",
            url = "https://example.org/article",
            title = "Page Title",
            author = "A. Writer",
            publisher = "Example Press",
            datePublished = "2026-01-15T10:00:00Z",
            htmlContent = "<p>Body text.</p>",
        },
    }

    for key, value in pairs(overrides or {}) do
        if key == "content" then
            for ckey, cvalue in pairs(value) do
                base.content[ckey] = (cvalue ~= NONE) and cvalue or nil
            end
        else
            base[key] = (value ~= NONE) and value or nil
        end
    end

    return base
end

describe("EpubBuilder", function()
    before_each(function()
        Helper.install()
    end)

    after_each(function()
        Helper.uninstall()
        EpubBuilder.setFetcher(nil)
    end)

    describe("titleOf", function()
        it("prefers the bookmark title", function()
            assert.equals("An Article", EpubBuilder.titleOf(bookmark()))
        end)

        it("falls back to the content title", function()
            assert.equals("Page Title", EpubBuilder.titleOf(bookmark({ title = NONE })))
        end)

        it("falls back to the URL", function()
            local b = bookmark({ title = NONE, content = { title = NONE } })
            assert.equals("https://example.org/article", EpubBuilder.titleOf(b))
        end)

        it("falls back to Untitled when there is nothing at all", function()
            local b = bookmark({ title = NONE, content = { title = NONE, url = NONE } })
            assert.equals("Untitled", EpubBuilder.titleOf(b))
        end)

        it("treats an empty string as absent", function()
            assert.equals("Page Title", EpubBuilder.titleOf(bookmark({ title = "" })))
        end)
    end)

    describe("buildDocument", function()
        it("opens with the title as an h1", function()
            assert.matches("<h1>An Article</h1>", EpubBuilder.buildDocument(bookmark(), "<p>x</p>"))
        end)

        it("includes author, publisher and the date, separated", function()
            local doc = EpubBuilder.buildDocument(bookmark(), "<p>x</p>")
            assert.matches("A. Writer", doc)
            assert.matches("Example Press", doc)
            assert.matches("2026%-01%-15", doc)
        end)

        it("truncates the date to its day", function()
            local doc = EpubBuilder.buildDocument(bookmark(), "<p>x</p>")
            assert.is_nil(doc:find("10:00:00", 1, true))
        end)

        it("omits the metadata line entirely when there is no metadata", function()
            local b = bookmark({ content = { author = NONE, publisher = NONE, datePublished = NONE } })
            local doc = EpubBuilder.buildDocument(b, "<p>x</p>")
            local _, count = doc:gsub('class="kb%-meta"', "")
            assert.equals(1, count) -- only the source URL line
        end)

        it("links to the source", function()
            assert.matches("https://example.org/article", EpubBuilder.buildDocument(bookmark(), "<p>x</p>"))
        end)

        it("carries the user's Karakeep note", function()
            local doc = EpubBuilder.buildDocument(bookmark({ note = "Read for the third section." }), "<p>x</p>")
            assert.matches("Read for the third section.", doc)
            assert.matches("kb%-note", doc)
        end)

        it("escapes a title containing markup", function()
            local doc = EpubBuilder.buildDocument(bookmark({ title = "A <b>bold</b> & brash title" }), "<p>x</p>")
            assert.matches("&lt;b&gt;", doc)
            assert.matches("&amp;", doc)
            assert.is_nil(doc:find("<b>", 1, true))
        end)

        it("says so plainly when there is no body", function()
            assert.matches("No readable content", EpubBuilder.buildDocument(bookmark(), nil))
        end)
    end)

    describe("buildOpf", function()
        it("uses the Karakeep ID as the book identifier", function()
            -- So two articles sharing a title are still distinct books to
            -- KOReader's library.
            local opf = EpubBuilder.buildOpf(bookmark(), "An Article", {})
            assert.matches("urn:karakeep:abc123", opf)
        end)

        it("carries the Dublin Core metadata", function()
            local opf = EpubBuilder.buildOpf(bookmark(), "An Article", {})
            assert.matches("<dc:creator>A. Writer</dc:creator>", opf)
            assert.matches("<dc:publisher>Example Press</dc:publisher>", opf)
            assert.matches("<dc:source>https://example.org/article</dc:source>", opf)
        end)

        it("omits fields that are absent, rather than emitting empty elements", function()
            local b = bookmark({ content = { author = NONE, publisher = NONE } })
            local opf = EpubBuilder.buildOpf(b, "T", {})
            assert.is_nil(opf:find("dc:creator", 1, true))
            assert.is_nil(opf:find("dc:publisher", 1, true))
        end)

        it("renders tags as subjects", function()
            local b = bookmark({ tags = { { name = "philosophy" }, { name = "ai" } } })
            local opf = EpubBuilder.buildOpf(b, "T", {})
            assert.matches("<dc:subject>philosophy</dc:subject>", opf)
            assert.matches("<dc:subject>ai</dc:subject>", opf)
        end)

        it("survives a malformed tag entry", function()
            local b = bookmark({ tags = { "not a table", { noName = true } } })
            assert.is_string(EpubBuilder.buildOpf(b, "T", {}))
        end)

        it("manifests every image with its media type", function()
            local opf = EpubBuilder.buildOpf(bookmark(), "T", {
                { path = "images/img1.png", media_type = "image/png" },
            })
            assert.matches('href="images/img1.png"', opf)
            assert.matches('media%-type="image/png"', opf)
        end)

        it("always manifests the three core documents", function()
            local opf = EpubBuilder.buildOpf(bookmark(), "T", {})
            assert.matches("toc.ncx", opf)
            assert.matches("content.xhtml", opf)
            assert.matches("stylesheet.css", opf)
        end)
    end)

    describe("buildNcx", function()
        it("matches the OPF identifier", function()
            local ncx = EpubBuilder.buildNcx(bookmark(), "An Article")
            assert.matches("urn:karakeep:abc123", ncx)
            assert.matches("<text>An Article</text>", ncx)
        end)

        it("escapes the title", function()
            assert.matches("&amp;", EpubBuilder.buildNcx(bookmark(), "A & B"))
        end)
    end)

    describe("buildXhtml", function()
        it("produces a complete document with an XML declaration", function()
            -- getBalancedHTML parses a whole document and returns nothing for a
            -- fragment, so the document must be complete before balancing.
            local xhtml, balanced = EpubBuilder.buildXhtml("T", "<p>body</p>")

            assert.matches("^<%?xml version", xhtml)
            assert.matches("<html", xhtml)
            assert.matches("<body>", xhtml)
            assert.matches("<p>body</p>", xhtml)
            -- crengine is absent under a plain interpreter, which must degrade
            -- rather than throw.
            assert.is_false(balanced)
        end)

        it("links the stylesheet", function()
            assert.matches("stylesheet.css", EpubBuilder.buildXhtml("T", ""))
        end)
    end)

    describe("fetchImages", function()
        it("keeps an image whose bytes identify it", function()
            EpubBuilder.setFetcher(function()
                return "\137PNG\r\n\26\n" .. string.rep("\0", 40)
            end)

            local images, data = EpubBuilder.fetchImages({ { src = "https://x/a.png", path = "images/img1.png" } })

            assert.equals(1, #images)
            assert.equals("image/png", images[1].media_type)
            assert.is_string(data["images/img1.png"])
        end)

        it("trusts the bytes over the URL extension", function()
            -- A .jpg URL serving a PNG is common, and crengine refuses an image
            -- whose declared type disagrees with its content.
            EpubBuilder.setFetcher(function()
                return "\137PNG\r\n\26\n" .. string.rep("\0", 40)
            end)

            local images = EpubBuilder.fetchImages({ { src = "https://x/a.jpg", path = "images/img1.jpg" } })
            assert.equals("image/png", images[1].media_type)
        end)

        it("drops an image that could not be fetched", function()
            EpubBuilder.setFetcher(function()
                return nil
            end)

            local images = EpubBuilder.fetchImages({ { src = "https://x/a.png", path = "images/img1.png" } })
            assert.equals(0, #images)
        end)

        it("drops an HTML error page served where an image should be", function()
            EpubBuilder.setFetcher(function()
                return "<!DOCTYPE html><html><body>404"
            end)

            local images = EpubBuilder.fetchImages({ { src = "https://x/a.png", path = "images/img1.png" } })
            assert.equals(0, #images)
        end)

        it("drops WebP, which crengine cannot decode", function()
            EpubBuilder.setFetcher(function()
                return "RIFF____WEBP" .. string.rep("\0", 40)
            end)

            local images = EpubBuilder.fetchImages({ { src = "https://x/a.webp", path = "images/img1.webp" } })
            assert.equals(0, #images)
        end)

        it("reports progress per image", function()
            EpubBuilder.setFetcher(function()
                return "\137PNG\r\n\26\n" .. string.rep("\0", 40)
            end)

            local messages = {}
            EpubBuilder.fetchImages({
                { src = "https://x/a.png", path = "images/img1.png" },
                { src = "https://x/b.png", path = "images/img2.png" },
            }, {
                progress = function(message)
                    table.insert(messages, message)
                end,
            })

            assert.equals(2, #messages)
            assert.matches("1 of 2", messages[1])
        end)
    end)

    describe("build", function()
        it("refuses a bookmark with no content, without touching the disk", function()
            local result = EpubBuilder.build(bookmark({ content = { htmlContent = NONE } }), "/tmp/x.epub", {})

            assert.is_true(result:isErr())
            assert.equals("no_content", result:errorCode())
        end)

        it("refuses an empty body", function()
            local result = EpubBuilder.build(bookmark({ content = { htmlContent = "" } }), "/tmp/x.epub", {})
            assert.equals("no_content", result:errorCode())
        end)
    end)
end)

describe("EpubBuilder image limits", function()
    -- An article can point at an arbitrarily large image, and the fetcher
    -- accumulates it in memory on a device that has very little.
    it("caps a single image", function()
        assert.is_number(EpubBuilder.MAX_IMAGE_BYTES)
        assert.is_true(EpubBuilder.MAX_IMAGE_BYTES > 0)
        -- Large enough for a real cover, small enough to matter on a Kobo.
        assert.is_true(EpubBuilder.MAX_IMAGE_BYTES <= 16 * 1024 * 1024)
    end)
end)
