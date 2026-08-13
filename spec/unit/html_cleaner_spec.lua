require("spec.support.helper")

local HtmlCleaner = require("karabridge.formats.html_cleaner")

describe("HtmlCleaner", function()
    describe("decodeEntities", function()
        it("decodes the five predefined entities", function()
            assert.equals("&<>\"'", HtmlCleaner.decodeEntities("&amp;&lt;&gt;&quot;&apos;"))
        end)

        it("decodes numeric and hex references", function()
            assert.equals("A", HtmlCleaner.decodeEntities("&#65;"))
            assert.equals("A", HtmlCleaner.decodeEntities("&#x41;"))
        end)

        it("decodes multi-byte code points as UTF-8", function()
            assert.equals("\226\128\148", HtmlCleaner.decodeEntities("&#x2014;")) -- em dash
        end)

        it("decodes the German umlauts that crawled pages are full of", function()
            assert.equals("\195\164\195\182\195\188\195\159", HtmlCleaner.decodeEntities("&auml;&ouml;&uuml;&szlig;"))
        end)

        it("turns a non-breaking space into a plain one", function()
            assert.equals("a b", HtmlCleaner.decodeEntities("a&nbsp;b"))
        end)

        it("leaves an unknown entity alone rather than deleting text", function()
            assert.equals("&frobnicate;", HtmlCleaner.decodeEntities("&frobnicate;"))
        end)

        it("returns an empty string for a non-string", function()
            assert.equals("", HtmlCleaner.decodeEntities(nil))
        end)
    end)

    describe("utf8Char", function()
        it("encodes each width correctly", function()
            assert.equals("A", HtmlCleaner.utf8Char(0x41))
            assert.equals("\195\164", HtmlCleaner.utf8Char(0xE4))
            assert.equals("\226\130\172", HtmlCleaner.utf8Char(0x20AC))
            assert.equals("\240\159\152\128", HtmlCleaner.utf8Char(0x1F600))
        end)

        it("refuses nonsense rather than producing invalid bytes", function()
            assert.equals("", HtmlCleaner.utf8Char(-1))
            assert.equals("", HtmlCleaner.utf8Char(0x110000))
            assert.equals("", HtmlCleaner.utf8Char("x"))
        end)
    end)

    describe("sanitise", function()
        it("removes a script element and its contents", function()
            local out = HtmlCleaner.sanitise("<p>a</p><script>alert(1)</script><p>b</p>")
            assert.is_nil(out:find("alert", 1, true))
            assert.matches("<p>a</p>", out)
            assert.matches("<p>b</p>", out)
        end)

        it("is case-insensitive about tag names", function()
            -- Crawled pages are wildly inconsistent about this.
            local out = HtmlCleaner.sanitise("<SCRIPT>bad()</SCRIPT>")
            assert.is_nil(out:find("bad", 1, true))
        end)

        it("removes an orphaned opening tag with no closer", function()
            local out = HtmlCleaner.sanitise("<p>a</p><iframe src='x'>")
            assert.is_nil(out:find("iframe", 1, true))
        end)

        it("removes style, form controls and media elements", function()
            local out = HtmlCleaner.sanitise(
                "<style>p{}</style><form><input name=x><button>go</button></form><video src='v'></video>"
            )
            for _, needle in ipairs({ "style", "form", "input", "button", "video" }) do
                assert.is_nil(out:find(needle, 1, true), needle .. " survived")
            end
        end)

        it("removes svg and canvas, which crengine cannot render", function()
            local out = HtmlCleaner.sanitise("<svg><circle/></svg><canvas></canvas>")
            assert.is_nil(out:find("svg", 1, true))
            assert.is_nil(out:find("canvas", 1, true))
        end)

        it("removes comments and doctypes", function()
            local out = HtmlCleaner.sanitise("<!DOCTYPE html><!-- tracking --><p>a</p>")
            assert.is_nil(out:find("DOCTYPE", 1, true))
            assert.is_nil(out:find("tracking", 1, true))
        end)

        it("removes inline event handlers", function()
            local out = HtmlCleaner.sanitise([[<p onclick="steal()" onmouseover='x'>text</p>]])
            assert.is_nil(out:find("onclick", 1, true))
            assert.is_nil(out:find("onmouseover", 1, true))
            assert.matches("text", out)
        end)

        it("neutralises a javascript: link but keeps its text", function()
            local out = HtmlCleaner.sanitise([[<a href="javascript:evil()">click</a>]])
            assert.is_nil(out:find("evil", 1, true))
            assert.matches('href="#"', out)
            assert.matches("click", out)
        end)

        it("leaves an ordinary link alone", function()
            local html = [[<a href="https://example.org/a">link</a>]]
            assert.matches("https://example.org/a", HtmlCleaner.sanitise(html))
        end)

        it("returns an empty string for a non-string", function()
            assert.equals("", HtmlCleaner.sanitise(nil))
        end)
    end)

    describe("toText", function()
        it("flattens tags to spaces so words do not run together", function()
            -- "<p>one</p><p>two</p>" must not become "onetwo".
            assert.equals("one two", HtmlCleaner.toText("<p>one</p><p>two</p>"))
        end)

        it("decodes entities and normalises whitespace", function()
            assert.equals("a & b", HtmlCleaner.toText("<p>a &amp;\n\n  b</p>"))
        end)

        it("drops script content, so it is not matched as article text", function()
            assert.equals("visible", HtmlCleaner.toText("<script>hidden()</script><p>visible</p>"))
        end)
    end)

    describe("imageExtension", function()
        it("recognises the common extensions", function()
            assert.equals(".png", HtmlCleaner.imageExtension("https://x/y.png"))
            assert.equals(".jpg", HtmlCleaner.imageExtension("https://x/y.JPEG"))
            assert.equals(".gif", HtmlCleaner.imageExtension("https://x/y.gif"))
        end)

        it("ignores a query string", function()
            assert.equals(".png", HtmlCleaner.imageExtension("https://x/y.png?w=800&h=600"))
        end)

        it("falls back to .jpg for an unknown or absent extension", function()
            assert.equals(".jpg", HtmlCleaner.imageExtension("https://x/image"))
            assert.equals(".jpg", HtmlCleaner.imageExtension("https://x/y.xyz"))
        end)
    end)

    describe("sniffType", function()
        -- The authoritative answer, because a .jpg URL serving a PNG is common
        -- and crengine refuses an image whose declared type is wrong.
        it("recognises JPEG, PNG, GIF, WebP and BMP", function()
            assert.equals("image/jpeg", HtmlCleaner.sniffType("\255\216\255" .. string.rep("\0", 20)))
            assert.equals("image/png", HtmlCleaner.sniffType("\137PNG\r\n\26\n" .. string.rep("\0", 20)))
            assert.equals("image/gif", HtmlCleaner.sniffType("GIF89a" .. string.rep("\0", 20)))
            assert.equals("image/webp", HtmlCleaner.sniffType("RIFF____WEBP" .. string.rep("\0", 20)))
            assert.equals("image/bmp", HtmlCleaner.sniffType("BM" .. string.rep("\0", 20)))
        end)

        it("recognises SVG", function()
            assert.equals("image/svg+xml", HtmlCleaner.sniffType("<svg xmlns='...'>            "))
        end)

        it("returns nothing for an HTML error page served where an image should be", function()
            -- The realistic failure: a CDN answering 200 with a login page.
            assert.is_nil(HtmlCleaner.sniffType("<!DOCTYPE html><html><body>Not found"))
        end)

        it("returns nothing for a truncated response", function()
            assert.is_nil(HtmlCleaner.sniffType("\255\216"))
        end)
    end)

    describe("collectImages", function()
        it("rewrites an absolute source to a local path", function()
            local html, images = HtmlCleaner.collectImages('<p><img src="https://x/a.png"></p>')

            assert.matches('<img src="images/img1.png"/>', html)
            assert.equals(1, #images)
            assert.equals("https://x/a.png", images[1].src)
            assert.equals("images/img1.png", images[1].path)
        end)

        it("numbers several images", function()
            local _, images = HtmlCleaner.collectImages('<img src="https://x/a.png"><img src="https://x/b.jpg">')

            assert.equals(2, #images)
            assert.equals("images/img1.png", images[1].path)
            assert.equals("images/img2.jpg", images[2].path)
        end)

        it("reuses the path for a repeated source", function()
            -- A logo appearing five times is downloaded and stored once.
            local html, images = HtmlCleaner.collectImages('<img src="https://x/a.png"><img src="https://x/a.png">')

            assert.equals(1, #images)
            local _, count = html:gsub('src="images/img1%.png"', "")
            assert.equals(2, count)
        end)

        it("drops a relative source, which has nothing to resolve against", function()
            local html, images = HtmlCleaner.collectImages('<img src="/local/a.png">')

            assert.equals(0, #images)
            assert.is_nil(html:find("img", 1, true))
        end)

        it("drops a data: URI", function()
            local _, images = HtmlCleaner.collectImages('<img src="data:image/png;base64,AAAA">')
            assert.equals(0, #images)
        end)

        it("drops an img with no src at all", function()
            local html, images = HtmlCleaner.collectImages("<img>")
            assert.equals(0, #images)
            assert.equals("", html)
        end)

        it("stops at max_images and removes the rest", function()
            local html, images = HtmlCleaner.collectImages(
                '<img src="https://x/1.png"><img src="https://x/2.png"><img src="https://x/3.png">',
                2
            )

            assert.equals(2, #images)
            local _, count = html:gsub("<img", "")
            assert.equals(2, count)
        end)

        it("emits no empty alt attribute", function()
            -- crengine's getBalancedHTML rewrites alt="" to a bare alt, which
            -- is not well-formed XML and breaks the whole document.
            local html = HtmlCleaner.collectImages('<img src="https://x/a.png" alt="">')
            assert.is_nil(html:find("alt", 1, true))
        end)

        it("decodes entities in the source before using it", function()
            local _, images = HtmlCleaner.collectImages('<img src="https://x/a.png?w=1&amp;h=2">')
            assert.equals("https://x/a.png?w=1&h=2", images[1].src)
        end)

        it("handles single-quoted attributes", function()
            local _, images = HtmlCleaner.collectImages("<img src='https://x/a.png'>")
            assert.equals(1, #images)
        end)
    end)

    describe("stripImages", function()
        it("removes every img element", function()
            local html = HtmlCleaner.stripImages('<p>a</p><img src="https://x/a.png"><p>b</p>')
            assert.is_nil(html:find("img", 1, true))
            assert.matches("<p>a</p>", html)
        end)
    end)

    describe("dropMissingImages", function()
        it("removes references to images that were not embedded", function()
            -- Otherwise the EPUB shows a broken-image box for a file that was
            -- never written.
            local html = '<img src="images/img1.png"/><img src="images/img2.png"/>'
            local out = HtmlCleaner.dropMissingImages(html, { ["images/img1.png"] = true })

            assert.matches("images/img1.png", out)
            assert.is_nil(out:find("img2", 1, true))
        end)

        it("keeps everything when all were embedded", function()
            local html = '<img src="images/img1.png"/>'
            assert.equals(html, HtmlCleaner.dropMissingImages(html, { ["images/img1.png"] = true }))
        end)
    end)
end)

describe("HtmlCleaner.sanitise unquoted attributes", function()
    -- The quoted patterns cannot match an unquoted value: there is no closing
    -- quote to anchor on. Unquoted attributes are valid HTML and were passing
    -- through untouched.
    it("removes an unquoted event handler", function()
        local out = HtmlCleaner.sanitise("<p onclick=alert(1)>text</p>")
        assert.is_nil(out:lower():find("onclick", 1, true))
        assert.is_truthy(out:find("text", 1, true))
    end)

    it("removes it before the closing bracket, not the bracket itself", function()
        local out = HtmlCleaner.sanitise("<div onmouseover=x()>keep</div>")
        assert.is_nil(out:lower():find("onmouseover", 1, true))
        assert.is_truthy(out:find("keep", 1, true))
    end)

    it("still removes the quoted forms", function()
        assert.is_nil(HtmlCleaner.sanitise('<p onclick="alert(1)">t</p>'):lower():find("onclick", 1, true))
        assert.is_nil(HtmlCleaner.sanitise("<p onclick='alert(1)'>t</p>"):lower():find("onclick", 1, true))
    end)

    it("neutralises an unquoted javascript: href", function()
        local out = HtmlCleaner.sanitise("<a href=javascript:alert(1)>link</a>")
        assert.is_nil(out:lower():find("javascript:", 1, true))
        assert.is_truthy(out:find("link", 1, true))
    end)

    it("leaves an ordinary attribute alone", function()
        -- The handler pattern must not eat every unquoted attribute it meets.
        local out = HtmlCleaner.sanitise("<img src=pic.png alt=one>")
        assert.is_truthy(out:find("pic.png", 1, true))
    end)
end)
