--[[--
Assembling an EPUB on the device.

Karakeep has no EPUB export endpoint, so the file is built here. The approach
follows the one KOReader itself uses for generated books, which
solves the same problem: hand the ragged crawler HTML to crengine's
`getBalancedHTML()` to make it well-formed, then write the container with
`ffi/archiver`'s zip writer.

Three things in here are not obvious and each caused a bug somewhere before:

  * **The whole document is assembled before balancing.**
    `getBalancedHTML()` parses a *complete* HTML document and returns nothing
    at all for a bare fragment, so balancing just the body silently does
    nothing and the unbalanced markup ships.
  * **Images are fetched before the archive is opened.** A zip entry can only
    be written once, so which images survive has to be known before the XHTML
    that references them is emitted.
  * **`mimetype` must be the first entry and stored uncompressed.** That is the
    EPUB specification, and a reader that checks will reject the file
    otherwise.

The KOReader dependencies (`libs/libkoreader-cre`, `ffi/archiver`) are required
lazily inside `build()`, and the image fetch is injectable, so the document
assembly can be exercised by specs without a device.

@module karabridge.formats.epub_builder
]]

local Filesystem = require("karabridge.shared.filesystem")
local HtmlCleaner = require("karabridge.formats.html_cleaner")
local Logging = require("karabridge.shared.logging")
local Result = require("karabridge.shared.result")
local Text = require("karabridge.shared.text")

local log = Logging.forModule("formats.epub_builder")

local EpubBuilder = {}

-- Deliberately restrained. An e-reader applies the user's own font, size and
-- margins on top of this; a stylesheet that fights those is worse than none.
EpubBuilder.CSS = [[
body { margin: 0; padding: 0; text-align: justify; }
h1 { font-size: 1.4em; text-align: left; margin: 0 0 0.2em 0; }
h2, h3, h4, h5, h6 { text-align: left; margin: 1em 0 0.3em 0; }
p { margin: 0 0 0.6em 0; text-indent: 0; }
img { max-width: 100%; height: auto; }
figure { margin: 0.8em 0; text-align: center; }
figcaption { font-size: 0.8em; font-style: italic; text-align: center; }
blockquote { margin: 0.6em 1.2em; font-style: italic; }
pre { font-family: monospace; font-size: 0.85em; white-space: pre-wrap; margin: 0.6em 0; }
code { font-family: monospace; font-size: 0.9em; }
hr { border: 0; border-top: 1px solid #999; margin: 1em 0; }
table { border-collapse: collapse; }
td, th { border: 1px solid #999; padding: 0.2em 0.4em; }
.kb-meta { font-size: 0.8em; margin: 0 0 1em 0; }
.kb-note { font-size: 0.9em; font-style: italic; margin: 0 0 1em 0; }
]]

-- Largest image embedded in a generated EPUB. Beyond this the download is
-- abandoned and the article keeps its text: an e-reader has little memory, and
-- one enormous decorative image is a poor reason to fail a whole article.
EpubBuilder.MAX_IMAGE_BYTES = 8 * 1024 * 1024

local fetch_backend

--- Replace the image fetcher. Used by the specs.
-- @tparam function|nil fn `fn(url) -> string|nil`
function EpubBuilder.setFetcher(fn)
    fetch_backend = fn
end

--- Fetch a remote image.
--
-- Kept away from `api/client.lua` on purpose: these are third-party URLs and
-- must not carry the Karakeep API token. The networking modules are required
-- inside the function because `socketutil` pulls in KOReader's whole device
-- stack, which probes SDL and wants a display.
--
-- Two things this does that the obvious version does not, both for the same
-- reason as `api/client.lua`:
--
--   * the request is wrapped, and `reset_timeout()` runs beyond the wrapper.
--     `socketutil`'s timeouts are **process-global** -- `set_timeout` writes
--     `http.TIMEOUT` and the values that the monkey-patched `socket.tcp` gives
--     every socket KOReader opens afterwards. Leaving them set does not break
--     KaraBridge; it breaks every other part of KOReader that opens a
--     connection.
--   * the body is capped. An article can point at an arbitrarily large image,
--     and this accumulates it in memory on a device that has very little. The
--     cap is enforced in the sink, so an oversized image is abandoned partway
--     rather than downloaded in full and then rejected.
local function fetchUrl(url, block_timeout, total_timeout)
    if fetch_backend then
        return fetch_backend(url)
    end

    local socket = require("socket")
    local socketutil = require("socketutil")
    local http = require("socket.http")

    local sink = {}
    local received = 0
    local too_big = false

    -- A sink of our own rather than ltn12's, so the limit can stop the transfer
    -- instead of being checked after the fact.
    local function capped(chunk, err)
        if chunk == nil then
            return err == nil and 1 or nil, err
        end
        received = received + #chunk
        if received > EpubBuilder.MAX_IMAGE_BYTES then
            too_big = true
            return nil, "image too large"
        end
        table.insert(sink, chunk)
        return 1
    end

    socketutil:set_timeout(block_timeout or 10, total_timeout or 30)

    local ok, code, response_headers = pcall(function()
        return socket.skip(1, http.request({
            url = url,
            method = "GET",
            sink = capped,
            headers = { ["User-Agent"] = "KOReader KaraBridge" },
        }))
    end)

    socketutil:reset_timeout()

    if not ok or too_big then
        return nil
    end
    if response_headers == nil or code ~= 200 then
        return nil
    end

    return table.concat(sink)
end

--- Is this a string with something in it?
--
-- Written out rather than using `Text.displayText`, which always returns a
-- string: chaining it with `or` never falls through, so every title became "?".
local function usable(value)
    if type(value) == "string" and value ~= "" then
        return value
    end
    return nil
end

--- The title to use for a bookmark, falling back until something is usable.
--
-- Both bookmarks on the author's own Karakeep have `title = null`, so the
-- fallback chain is the normal path here rather than an edge case.
--
-- @tparam table bookmark
-- @treturn string
function EpubBuilder.titleOf(bookmark)
    if type(bookmark) ~= "table" then
        return "Untitled"
    end
    local content = bookmark.content or {}
    return usable(bookmark.title) or usable(content.title) or usable(content.url) or "Untitled"
end

--- Build the article body: heading, byline, source link, note, then content.
-- @tparam table bookmark
-- @tparam string|nil body_html
-- @treturn string
function EpubBuilder.buildDocument(bookmark, body_html)
    local content = bookmark.content or {}
    local title = EpubBuilder.titleOf(bookmark)

    local meta = {}
    if type(content.author) == "string" and content.author ~= "" then
        table.insert(meta, Text.escapeXml(content.author))
    end
    if type(content.publisher) == "string" and content.publisher ~= "" then
        table.insert(meta, Text.escapeXml(content.publisher))
    end
    if type(content.datePublished) == "string" and content.datePublished ~= "" then
        table.insert(meta, Text.escapeXml(content.datePublished:sub(1, 10)))
    end

    local parts = { "<h1>" .. Text.escapeXml(title) .. "</h1>" }

    if #meta > 0 then
        table.insert(parts, '<p class="kb-meta">' .. table.concat(meta, " &#183; ") .. "</p>")
    end

    if type(content.url) == "string" and content.url ~= "" then
        table.insert(
            parts,
            string.format(
                '<p class="kb-meta"><a href="%s">%s</a></p>',
                Text.escapeXml(content.url),
                Text.escapeXml(content.url)
            )
        )
    end

    -- The user's own note in Karakeep travels with the article; it is often
    -- the reason they saved it.
    if type(bookmark.note) == "string" and bookmark.note ~= "" then
        table.insert(parts, '<p class="kb-note">' .. Text.escapeXml(bookmark.note) .. "</p>")
    end

    table.insert(parts, "<hr/>")
    table.insert(parts, body_html or "<p><em>No readable content was available for this bookmark.</em></p>")

    return table.concat(parts, "\n")
end

--- The OPF package document.
-- @tparam table bookmark
-- @tparam string title
-- @tparam table images Array of `{ path, media_type }`.
-- @treturn string
function EpubBuilder.buildOpf(bookmark, title, images)
    local content = bookmark.content or {}
    local parts = {
        [[<?xml version="1.0" encoding="UTF-8"?>]],
        [[<package xmlns="http://www.idpf.org/2007/opf" unique-identifier="bookid" version="2.0">]],
        [[<metadata xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:opf="http://www.idpf.org/2007/opf">]],
        "<dc:title>" .. Text.escapeXml(title) .. "</dc:title>",
        -- The Karakeep ID as the book identifier, so two articles with the same
        -- title are still distinct books to KOReader's library.
        '<dc:identifier id="bookid">urn:karakeep:' .. Text.escapeXml(tostring(bookmark.id)) .. "</dc:identifier>",
        "<dc:language>en</dc:language>",
    }

    if type(content.author) == "string" and content.author ~= "" then
        table.insert(parts, "<dc:creator>" .. Text.escapeXml(content.author) .. "</dc:creator>")
    end
    if type(content.publisher) == "string" and content.publisher ~= "" then
        table.insert(parts, "<dc:publisher>" .. Text.escapeXml(content.publisher) .. "</dc:publisher>")
    end
    if type(content.url) == "string" and content.url ~= "" then
        table.insert(parts, "<dc:source>" .. Text.escapeXml(content.url) .. "</dc:source>")
    end
    if type(content.datePublished) == "string" and content.datePublished ~= "" then
        table.insert(parts, "<dc:date>" .. Text.escapeXml(content.datePublished) .. "</dc:date>")
    end
    for _, tag in ipairs(bookmark.tags or {}) do
        if type(tag) == "table" and type(tag.name) == "string" then
            table.insert(parts, "<dc:subject>" .. Text.escapeXml(tag.name) .. "</dc:subject>")
        end
    end

    table.insert(parts, "</metadata>")
    table.insert(parts, "<manifest>")
    table.insert(parts, [[<item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>]])
    table.insert(parts, [[<item id="content" href="content.xhtml" media-type="application/xhtml+xml"/>]])
    table.insert(parts, [[<item id="css" href="stylesheet.css" media-type="text/css"/>]])

    for index, image in ipairs(images) do
        table.insert(
            parts,
            string.format(
                '<item id="img%d" href="%s" media-type="%s"/>',
                index,
                Text.escapeXml(image.path),
                image.media_type
            )
        )
    end

    table.insert(parts, "</manifest>")
    table.insert(parts, [[<spine toc="ncx"><itemref idref="content"/></spine>]])
    table.insert(parts, "</package>")

    return table.concat(parts, "\n")
end

--- The NCX table of contents. One entry: an article is a single chapter.
-- @tparam table bookmark
-- @tparam string title
-- @treturn string
function EpubBuilder.buildNcx(bookmark, title)
    return table.concat({
        [[<?xml version="1.0" encoding="UTF-8"?>]],
        [[<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">]],
        [[<head><meta name="dtb:uid" content="urn:karakeep:]]
            .. Text.escapeXml(tostring(bookmark.id))
            .. [["/></head>]],
        "<docTitle><text>" .. Text.escapeXml(title) .. "</text></docTitle>",
        [[<navMap><navPoint id="navpoint-1" playOrder="1">]],
        "<navLabel><text>" .. Text.escapeXml(title) .. "</text></navLabel>",
        [[<content src="content.xhtml"/>]],
        [[</navPoint></navMap></ncx>]],
    }, "\n")
end

EpubBuilder.CONTAINER_XML = table.concat({
    [[<?xml version="1.0" encoding="UTF-8"?>]],
    [[<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">]],
    [[<rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>]],
    [[</container>]],
}, "\n")

--- Wrap the body in a complete XHTML document and let crengine balance it.
--
-- Assembled complete *before* balancing, because `getBalancedHTML()` parses a
-- whole document and returns nothing for a fragment.
--
-- @tparam string title
-- @tparam string document Body HTML.
-- @treturn string
-- @treturn boolean Whether crengine actually balanced it.
function EpubBuilder.buildXhtml(title, document)
    local xhtml = table.concat({
        [[<html xmlns="http://www.w3.org/1999/xhtml">]],
        "<head>",
        "<title>" .. Text.escapeXml(title) .. "</title>",
        [[<link rel="stylesheet" type="text/css" href="stylesheet.css"/>]],
        "</head>",
        "<body>",
        document,
        "</body></html>",
    }, "\n")

    local balanced_ok, balanced = pcall(function()
        local cre = require("libs/libkoreader-cre")
        return cre.getBalancedHTML(xhtml, 0x0)
    end)

    local balanced_used = false
    if balanced_ok and type(balanced) == "string" and balanced ~= "" then
        xhtml = balanced
        balanced_used = true
    end

    -- The XML declaration goes on afterwards: crengine does not emit one.
    return [[<?xml version="1.0" encoding="UTF-8"?>]] .. "\n" .. xhtml, balanced_used
end

--- Download the images an article references, dropping the ones that fail.
--
-- Held one at a time and handed straight to the caller, because a Kobo has
-- little RAM and an image-heavy article could otherwise hold a dozen
-- multi-megabyte buffers at once.
--
-- @tparam table candidates Array of `{ src, path }`.
-- @tparam[opt] table opts progress, block_timeout, total_timeout
-- @treturn table images Array of `{ path, media_type }`, in order.
-- @treturn table data Keyed by path.
function EpubBuilder.fetchImages(candidates, opts)
    opts = opts or {}
    local images, data = {}, {}

    for index, candidate in ipairs(candidates) do
        if opts.progress then
            opts.progress(string.format("Fetching image %d of %d" .. Text.ELLIPSIS, index, #candidates))
        end

        local bytes = fetchUrl(candidate.src, opts.block_timeout, opts.total_timeout)
        -- Trust the magic bytes, not the URL.
        local media_type = bytes and HtmlCleaner.sniffType(bytes)

        -- WebP is excluded deliberately: crengine cannot decode it, and an
        -- image it cannot decode renders as a broken box rather than nothing.
        if bytes and media_type and media_type ~= "image/webp" then
            table.insert(images, { path = candidate.path, media_type = media_type })
            data[candidate.path] = bytes
        else
            log.dbg("dropping image", candidate.src, media_type or "unfetchable")
        end
    end

    return images, data
end

--- Build an EPUB and write it to disk.
--
-- @tparam table bookmark A Karakeep bookmark.
-- @tparam string filepath Destination.
-- @tparam table opts
--   body_html      article HTML; defaults to `bookmark.content.htmlContent`
--   include_images download and embed images
--   max_images     cap on embedded images
--   progress       optional `function(message)` for UI feedback
-- @treturn Result Error codes: "no_content", "zip_open_failed", "rename_failed".
function EpubBuilder.build(bookmark, filepath, opts)
    opts = opts or {}

    local content = bookmark.content or {}
    local title = EpubBuilder.titleOf(bookmark)
    local body_html = opts.body_html or content.htmlContent

    if type(body_html) ~= "string" or body_html == "" then
        return Result.err("no_content", "There was no readable content for this bookmark.")
    end

    body_html = HtmlCleaner.sanitise(body_html)

    local candidates = {}
    if opts.include_images then
        body_html, candidates = HtmlCleaner.collectImages(body_html, opts.max_images or 30)
    else
        body_html = HtmlCleaner.stripImages(body_html)
    end

    -- Before opening the archive: an entry can be written only once, so which
    -- images survive must be known before the XHTML referencing them is built.
    local images, image_data = EpubBuilder.fetchImages(candidates, opts)

    if #images < #candidates then
        local kept = {}
        for _, image in ipairs(images) do
            kept[image.path] = true
        end
        body_html = HtmlCleaner.dropMissingImages(body_html, kept)
    end

    local xhtml, balanced = EpubBuilder.buildXhtml(title, EpubBuilder.buildDocument(bookmark, body_html))
    if not balanced then
        log.warn("getBalancedHTML unavailable or failed for", tostring(bookmark.id), "- writing unbalanced HTML")
    end

    local Archiver = require("ffi/archiver")
    local writer = Archiver.Writer:new({})
    local tmp_path = filepath .. ".karabridge-tmp"

    if not writer:open(tmp_path, "epub") then
        return Result.err("zip_open_failed", "The EPUB file could not be created.", { path = tmp_path })
    end

    local mtime = os.time()

    -- Every write is checked. A full disk shows up here as a false return, and
    -- an EPUB missing content.xhtml is a file KOReader cannot open -- reporting
    -- that as success would replace a working article with a broken one.
    local failed_entry

    local function add(name, data)
        if failed_entry then
            return
        end
        if not writer:addFileFromMemory(name, data, mtime) then
            failed_entry = name
        end
    end

    -- "mimetype" first and stored, per the EPUB specification.
    writer:setZipCompression("store")
    add("mimetype", "application/epub+zip")
    writer:setZipCompression("deflate")

    add("META-INF/container.xml", EpubBuilder.CONTAINER_XML)
    add("OEBPS/stylesheet.css", EpubBuilder.CSS)
    add("OEBPS/content.xhtml", xhtml)
    add("OEBPS/content.opf", EpubBuilder.buildOpf(bookmark, title, images))
    add("OEBPS/toc.ncx", EpubBuilder.buildNcx(bookmark, title))

    -- Already-compressed formats gain nothing from deflate, and a Kobo's CPU is
    -- slow enough that the attempt is worth skipping.
    writer:setZipCompression("store")
    for _, image in ipairs(images) do
        add("OEBPS/" .. image.path, image_data[image.path])
        image_data[image.path] = nil -- release as we go
    end

    local closed = writer:close()
    collectgarbage()

    if failed_entry then
        os.remove(tmp_path)
        return Result.err("write_failed", "The EPUB could not be written; the disk may be full.", {
            entry = failed_entry,
        })
    end

    -- close() flushes the central directory, so a failure here means the
    -- archive is incomplete even though every entry was accepted.
    if closed == false then
        os.remove(tmp_path)
        return Result.err("write_failed", "The EPUB could not be finished; the disk may be full.")
    end

    -- Moved into place rather than removed-then-renamed: a failed rename after
    -- the remove would take the previous article with it. See
    -- Filesystem.replaceFile.
    local replaced = Filesystem.replaceFile(tmp_path, filepath)
    if replaced:isErr() then
        return replaced
    end

    return Result.ok({ path = filepath, images = #images, dropped = #candidates - #images })
end

return EpubBuilder
