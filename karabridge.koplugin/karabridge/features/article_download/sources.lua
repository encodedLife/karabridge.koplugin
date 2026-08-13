--[[--
Deciding where an article's text comes from.

A Karakeep link bookmark can carry its content in up to four places, and they
are not equivalent. Getting the order wrong produces an EPUB full of navigation
menus and cookie banners instead of an article, which is the single most
visible way this plugin can disappoint.

The order, best first:

1. **`content.htmlContent`** — the extracted article. The normal source, and it
   covers articles of any length: Karakeep inlines it in the database only
   below a size threshold, but a request with `includeContent=true` hydrates
   the field from the asset before answering, so that split is invisible here.
2. **`content.contentAssetId`** — the same extracted article, out of line. A
   safety net for the case where Karakeep's own read of that asset fails: it
   swallows the error and returns null rather than failing the request, so this
   is reachable even though (1) should have covered it.
3. **`content.precrawledArchiveAssetId`** — what a SingleFile upload produced.
4. **`content.fullPageArchiveAssetId`** — Karakeep's own page snapshot.
5. **The readable-content endpoint** — always last, because it serves markdown,
   so formatting and images are lost in the conversion back to HTML.

(3) and (4) are *whole pages*: navigation, sidebars, cookie banners, inlined
assets. They are a **fallback for when extraction produced nothing**, not a
preference — Karakeep runs a precrawled archive through the same readability
extraction it uses for a live crawl, so its text has already reached (1) by the
time a client sees the bookmark. `prefer_archive` moves them to the front for
the pages where that extraction went wrong, which is what the setting is for.

The user's own capture comes before Karakeep's, because it is the one that can
hold content behind a paywall they are entitled to read.

Pure: this decides *what to try*, and the downloader does the trying.

@module karabridge.features.article_download.sources
]]

local Sources = {}

local function nonEmptyString(value)
    return type(value) == "string" and value ~= ""
end

--- Where an article's text might come from, best first.
--
-- @tparam table bookmark
-- @tparam[opt=false] boolean prefer_archive Put the whole-page archives first.
-- @treturn table Array of `{ kind, asset_id, full_page, label }` where `kind`
--   is "inline", "asset" or "endpoint".
function Sources.forBookmark(bookmark, prefer_archive)
    local content = (type(bookmark) == "table" and bookmark.content) or {}

    -- A text bookmark carries its body directly; there is nothing to resolve.
    if content.type == "text" then
        return { { kind = "text", label = "text bookmark body" } }
    end

    if content.type ~= "link" then
        return {}
    end

    local readable, archives = {}, {}

    if nonEmptyString(content.htmlContent) then
        table.insert(readable, { kind = "inline", label = "inline readable HTML" })
    end
    if nonEmptyString(content.contentAssetId) then
        table.insert(readable, {
            kind = "asset",
            asset_id = content.contentAssetId,
            label = "readable HTML asset",
        })
    end

    if nonEmptyString(content.precrawledArchiveAssetId) then
        table.insert(archives, {
            kind = "asset",
            asset_id = content.precrawledArchiveAssetId,
            full_page = true,
            label = "precrawled archive",
        })
    end
    if nonEmptyString(content.fullPageArchiveAssetId) then
        table.insert(archives, {
            kind = "asset",
            asset_id = content.fullPageArchiveAssetId,
            full_page = true,
            label = "full page archive",
        })
    end

    local sources = {}
    local first = prefer_archive and archives or readable
    local second = prefer_archive and readable or archives

    for _, source in ipairs(first) do
        table.insert(sources, source)
    end
    for _, source in ipairs(second) do
        table.insert(sources, source)
    end

    table.insert(sources, { kind = "endpoint", label = "readable content endpoint" })

    return sources
end

--- Is there anything worth putting on the device?
--
-- Asset bookmarks (uploaded PDFs and images) are skipped: they are already a
-- file, and turning one into an EPUB would be worse than leaving it alone.
-- `unknown` is Karakeep's placeholder for a bookmark it has not crawled yet.
--
-- @tparam table bookmark
-- @treturn boolean
function Sources.isReadable(bookmark)
    local content = (type(bookmark) == "table" and bookmark.content) or nil
    if not content then
        return false
    end
    return content.type == "link" or content.type == "text"
end

return Sources
