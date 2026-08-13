--[[--
Turning crawled HTML into something safe to put in an EPUB.

Everything here treats its input as hostile. The HTML comes from an arbitrary
web page by way of Karakeep's crawler, so it may contain scripts, event
handlers, `javascript:` URLs, tracking pixels and malformed markup. None of
that belongs on an e-reader, and crengine will happily try to render most of
it.

This module removes what is actively unhelpful. It does **not** try to produce
well-formed XHTML — `formats/epub_builder.lua` hands the assembled document to
crengine's `getBalancedHTML()` for that, which is a real parser and much better
at it than a pile of patterns would be.

Pure Lua, no KOReader dependencies, so every branch is covered by specs.

@module karabridge.formats.html_cleaner
]]

local Text = require("karabridge.shared.text")

local HtmlCleaner = {}

-- Elements with no place in an offline article. `svg` and `canvas` are here
-- not because they are dangerous but because crengine cannot render them and
-- leaves a gap where they were.
local STRIPPED_ELEMENTS = {
    "script",
    "style",
    "iframe",
    "object",
    "embed",
    "noscript",
    "form",
    "input",
    "button",
    "select",
    "textarea",
    "svg",
    "canvas",
    "video",
    "audio",
}

--- Case-insensitive pattern for a tag name: "img" -> "[iI][mM][gG]".
--
-- HTML tag names are case-insensitive and crawled pages are inconsistent about
-- it. Lua patterns have no case-insensitive flag, so the classes are built.
local function anyCase(word)
    return (word:gsub("%a", function(c)
        return "[" .. c:lower() .. c:upper() .. "]"
    end))
end

local function stripElement(html, tag)
    local name = anyCase(tag)
    -- Paired form first, then any leftover self-closing or orphaned tag.
    html = html:gsub("<%s*" .. name .. "[^>]*>.-<%s*/%s*" .. name .. "%s*>", "")
    html = html:gsub("<%s*/?%s*" .. name .. "[^>]*>", "")
    return html
end

local NAMED_ENTITIES = {
    amp = "&",
    lt = "<",
    gt = ">",
    quot = '"',
    apos = "'",
    nbsp = " ",
    ensp = " ",
    emsp = " ",
    thinsp = " ",
    shy = "",
    ndash = "\226\128\147",
    mdash = "\226\128\148",
    lsquo = "\226\128\152",
    rsquo = "\226\128\153",
    ldquo = "\226\128\156",
    rdquo = "\226\128\157",
    sbquo = "\226\128\154",
    bdquo = "\226\128\158",
    hellip = "\226\128\166",
    middot = "\194\183",
    bull = "\226\128\162",
    dagger = "\226\128\160",
    copy = "\194\169",
    reg = "\194\174",
    trade = "\226\132\162",
    laquo = "\194\171",
    raquo = "\194\187",
    deg = "\194\176",
    euro = "\226\130\172",
    pound = "\194\163",
    times = "\195\151",
    minus = "\226\136\146",
    frac12 = "\194\189",
    auml = "\195\164",
    ouml = "\195\182",
    uuml = "\195\188",
    Auml = "\195\132",
    Ouml = "\195\150",
    Uuml = "\195\156",
    szlig = "\195\159",
}

--- Encode a Unicode code point as UTF-8. Lua 5.1 has no utf8 library.
-- @tparam number cp
-- @treturn string
function HtmlCleaner.utf8Char(cp)
    if type(cp) ~= "number" or cp < 0 or cp > 0x10FFFF then
        return ""
    end

    if cp < 0x80 then
        return string.char(cp)
    elseif cp < 0x800 then
        return string.char(0xC0 + math.floor(cp / 0x40), 0x80 + (cp % 0x40))
    elseif cp < 0x10000 then
        return string.char(
            0xE0 + math.floor(cp / 0x1000),
            0x80 + (math.floor(cp / 0x40) % 0x40),
            0x80 + (cp % 0x40)
        )
    end

    return string.char(
        0xF0 + math.floor(cp / 0x40000),
        0x80 + (math.floor(cp / 0x1000) % 0x40),
        0x80 + (math.floor(cp / 0x40) % 0x40),
        0x80 + (cp % 0x40)
    )
end

--- Decode the HTML entities likely to appear in crawled article text.
--
-- Unknown named entities are left as they are: returning nil from a gsub
-- callback leaves the match in place, which is better than turning `&foo;`
-- into nothing and losing text.
--
-- @tparam any s
-- @treturn string
function HtmlCleaner.decodeEntities(s)
    if type(s) ~= "string" then
        return ""
    end

    s = s:gsub("&#[xX](%x+);", function(hex)
        return HtmlCleaner.utf8Char(tonumber(hex, 16))
    end)
    s = s:gsub("&#(%d+);", function(dec)
        return HtmlCleaner.utf8Char(tonumber(dec))
    end)
    s = s:gsub("&(%a+);", function(name)
        return NAMED_ENTITIES[name]
    end)

    return s
end

--- Remove elements and attributes that have no business in an offline EPUB.
-- @tparam any html
-- @treturn string
function HtmlCleaner.sanitise(html)
    if type(html) ~= "string" then
        return ""
    end

    html = html:gsub("<!%-%-.-%-%->", "")
    html = html:gsub("<[%?!][^>]*>", "") -- doctypes and processing instructions

    for _, tag in ipairs(STRIPPED_ELEMENTS) do
        html = stripElement(html, tag)
    end

    -- Inline event handlers: onclick="…", onload='…', and onerror=alert(1).
    -- The unquoted form is valid HTML and was passing straight through: the
    -- quoted patterns cannot match it, because there is no closing quote to
    -- anchor on. It ends at whitespace or at the closing angle bracket instead.
    html = html:gsub('%s[oO][nN]%a+%s*=%s*"[^"]*"', "")
    html = html:gsub("%s[oO][nN]%a+%s*=%s*'[^']*'", "")
    html = html:gsub("%s[oO][nN]%a+%s*=%s*[^%s>\"']+", "")

    -- javascript: URLs, neutralised rather than removed, so the link text
    -- survives even though the destination is gone.
    local js = anyCase("javascript")
    html = html:gsub("(" .. anyCase("href") .. '%s*=%s*)"%s*' .. js .. ':[^"]*"', '%1"#"')
    html = html:gsub("(" .. anyCase("href") .. "%s*=%s*)'%s*" .. js .. ":[^']*'", "%1'#'")
    -- Unquoted, for the same reason as the handlers above.
    html = html:gsub("(" .. anyCase("href") .. "%s*=%s*)" .. js .. ":[^%s>]*", '%1"#"')

    return html
end

--- Flatten HTML to plain text, for highlight offset matching.
--
-- Tags become spaces rather than being deleted, so words either side of a
-- block boundary do not run together into one nonexistent word.
--
-- @tparam any html
-- @treturn string
function HtmlCleaner.toText(html)
    if type(html) ~= "string" then
        return ""
    end

    local s = HtmlCleaner.sanitise(html)
    s = s:gsub("<[^>]*>", " ")
    s = HtmlCleaner.decodeEntities(s)

    return Text.normaliseWhitespace(s)
end

local KNOWN_IMAGE_EXTS = {
    jpg = ".jpg",
    jpeg = ".jpg",
    png = ".png",
    gif = ".gif",
    webp = ".webp",
    svg = ".svg",
    bmp = ".bmp",
}

--- Guess a file extension for an image URL, defaulting to .jpg.
--
-- Only a guess. The media type actually written into the EPUB comes from
-- `sniffType` on the downloaded bytes, because the extension in a URL is
-- frequently a lie and crengine refuses an image whose declared type does not
-- match its content.
--
-- @tparam any src
-- @treturn string
function HtmlCleaner.imageExtension(src)
    if type(src) ~= "string" then
        return ".jpg"
    end

    local path = src:match("^[^%?#]*") or src
    local ext = path:match("%.([%a%d]+)$")
    if ext then
        local known = KNOWN_IMAGE_EXTS[ext:lower()]
        if known then
            return known
        end
    end

    return ".jpg"
end

local MEDIA_TYPES = {
    [".jpg"] = "image/jpeg",
    [".png"] = "image/png",
    [".gif"] = "image/gif",
    [".webp"] = "image/webp",
    [".svg"] = "image/svg+xml",
    [".bmp"] = "image/bmp",
}

--- Map a local image path to its EPUB media type.
-- @tparam any path
-- @treturn string
function HtmlCleaner.mediaType(path)
    if type(path) ~= "string" then
        return "image/jpeg"
    end
    local ext = path:match("(%.[%a%d]+)$")
    return (ext and MEDIA_TYPES[ext:lower()]) or "image/jpeg"
end

--- Identify an image from its magic bytes.
--
-- The authoritative answer, unlike the URL's extension. crengine will not
-- render an image whose declared media type disagrees with its content, and a
-- `.jpg` URL serving a PNG is common enough to matter.
--
-- @tparam any data
-- @treturn string|nil Media type, or nil when unrecognised.
function HtmlCleaner.sniffType(data)
    if type(data) ~= "string" or #data < 12 then
        return nil
    end

    if data:sub(1, 3) == "\255\216\255" then
        return "image/jpeg"
    end
    if data:sub(1, 8) == "\137PNG\r\n\26\n" then
        return "image/png"
    end
    if data:sub(1, 6) == "GIF87a" or data:sub(1, 6) == "GIF89a" then
        return "image/gif"
    end
    if data:sub(1, 4) == "RIFF" and data:sub(9, 12) == "WEBP" then
        return "image/webp"
    end
    if data:sub(1, 2) == "BM" then
        return "image/bmp"
    end
    if data:match("^%s*<%?xml") or data:match("^%s*<svg") then
        return "image/svg+xml"
    end

    return nil
end

--- Rewrite `<img>` sources to local EPUB paths, collecting what to download.
--
-- Images that cannot be used are dropped rather than left pointing at the
-- network, so the EPUB never renders a broken-image box on a device that is
-- offline by the time you read it. Dropped: relative sources (Karakeep gives
-- us the article out of context, so there is nothing to resolve against),
-- `data:` URIs (already inline, and frequently enormous), and everything past
-- `max_images`.
--
-- The same source appearing twice reuses the first local path, so a repeated
-- logo is downloaded and stored once.
--
-- @tparam any html
-- @tparam[opt=30] number max_images
-- @treturn string Rewritten HTML.
-- @treturn table Array of `{ src = <remote url>, path = "images/img1.jpg" }`.
function HtmlCleaner.collectImages(html, max_images)
    if type(html) ~= "string" then
        return "", {}
    end
    max_images = max_images or 30

    local images = {}
    local by_src = {}

    local rewritten = html:gsub("<%s*[iI][mM][gG]([^>]*)>", function(attrs)
        local src = attrs:match('[sS][rR][cC]%s*=%s*"([^"]*)"') or attrs:match("[sS][rR][cC]%s*=%s*'([^']*)'")

        if not src or src == "" then
            return ""
        end

        src = Text.trim(HtmlCleaner.decodeEntities(src))

        if not src:match("^[hH][tT][tT][pP][sS]?://") then
            return ""
        end

        local existing = by_src[src]
        if existing then
            return string.format('<img src="%s"/>', Text.escapeXml(existing))
        end

        if #images >= max_images then
            return ""
        end

        local path = string.format("images/img%d%s", #images + 1, HtmlCleaner.imageExtension(src))

        table.insert(images, { src = src, path = path })
        by_src[src] = path

        -- Deliberately no alt="": crengine's getBalancedHTML() rewrites an
        -- empty attribute to a bare one ("alt"), which is not well-formed XML
        -- and breaks the whole document.
        return string.format('<img src="%s"/>', Text.escapeXml(path))
    end)

    return rewritten, images
end

--- Remove every `<img>` element. Used when image embedding is switched off.
-- @tparam any html
-- @treturn string
function HtmlCleaner.stripImages(html)
    if type(html) ~= "string" then
        return ""
    end
    return (html:gsub("<%s*[iI][mM][gG][^>]*>", ""))
end

--- Remove `<img>` elements whose local path is not in `kept`.
--
-- Called after downloading, for the images that failed. Without it the EPUB
-- references a file that was never written, which crengine renders as a broken
-- image box.
--
-- @tparam string html
-- @tparam table kept Set keyed by local path.
-- @treturn string
function HtmlCleaner.dropMissingImages(html, kept)
    if type(html) ~= "string" then
        return ""
    end

    return (html:gsub('<img src="([^"]*)"[^>]*/?>', function(path)
        if kept[path] then
            return nil -- leave the match alone
        end
        return ""
    end))
end

return HtmlCleaner
