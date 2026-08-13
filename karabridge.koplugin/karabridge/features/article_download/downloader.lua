--[[--
Downloading Karakeep articles onto the device.

The orchestration: work out the scope, fetch the bookmarks, resolve each one's
content, build an EPUB, record what happened. Everything it needs is injected —
the API client, the settings, and the progress reporter — so the whole flow can
be driven by a spec with no network and no UI.

Three safety rules, each of which exists because getting it wrong loses a
user's reading:

  * **The download folder is checked up front.** Otherwise an unwritable folder
    surfaces as every single article failing, one confusing line at a time,
    from deep inside the zip writer.
  * **Nothing already on the device is re-downloaded.** Matched by Karakeep ID
    from the filename, so it survives a rename of the title portion.
  * **A capped or cancelled run reports `complete = false`.** The caller must
    not treat a partial list as everything the server has; deleting local files
    on that basis is how you lose an article you had not finished.

Deleting local files that are gone remotely is deliberately *not* here. It
belongs with the sync flow that knows about reading status, and doing it from
the downloader would mean deleting on the basis of a list this module already
knows may be incomplete.

@module karabridge.features.article_download.downloader
]]

local Bookmarks = require("karabridge.api.bookmarks")
local EpubBuilder = require("karabridge.formats.epub_builder")
local Filesystem = require("karabridge.shared.filesystem")
local Hashing = require("karabridge.shared.hashing")
local Library = require("karabridge.features.article_download.library")
local Lists = require("karabridge.api.lists")
local Logging = require("karabridge.shared.logging")
local MarkdownHtml = require("karabridge.formats.markdown_html")
local Metadata = require("karabridge.shared.metadata")
local Paths = require("karabridge.shared.paths")
local Result = require("karabridge.shared.result")
local Sources = require("karabridge.features.article_download.sources")
local Tags = require("karabridge.api.tags")
local Text = require("karabridge.shared.text")

local log = Logging.forModule("article_download")

local Downloader = {}
Downloader.__index = Downloader

--- Create a downloader.
-- @tparam table opts
--   client    required; a `karabridge.api.client`
--   settings  required; a `karabridge.config.settings`
--   progress  optional; `function(message) -> boolean` — return false to cancel
-- @treturn Downloader
function Downloader.new(opts)
    assert(type(opts) == "table" and opts.client and opts.settings, "Downloader.new requires a client and settings")

    return setmetatable({
        client = opts.client,
        settings = opts.settings,
        bookmarks = Bookmarks.new(opts.client),
        lists = Lists.new(opts.client),
        tags = Tags.new(opts.client),
        -- A no-op reporter that never cancels, so callers with no UI (a spec,
        -- an automatic sync) need not supply one.
        progress = opts.progress or function()
            return true
        end,
    }, Downloader)
end

--- Turn the configured filters into a scope the bookmark endpoint understands.
--
-- A list is resolved by name, because a user editing `karabridge.conf` on a
-- computer has a name in front of them and not an opaque ID.
--
-- Tags are awkward: Karakeep's tag endpoint takes one tag, so with several
-- configured the first is used server-side to narrow the set and the rest are
-- applied client-side. That is a correct filter, just not necessarily the most
-- selective one it could have been.
--
-- @treturn Result Value is `{ scope, scope_id, label, extra_tags }`.
function Downloader:resolveScope()
    local list_name = Text.trim(self.settings:get("filter_list") or "")
    local tag_names = Text.splitList(self.settings:get("filter_tags"))

    local list_id = Text.trim(self.settings:get("filter_list_id") or "")

    if list_name ~= "" or list_id ~= "" then
        -- The ID first, so a list renamed in Karakeep does not stop the sync;
        -- the name as a fallback, so a list deleted and made again does not
        -- either. One request answers both: GET /lists returns the whole set.
        local all = self.lists:all()
        if all:isErr() then
            return all
        end

        local by_id, by_name
        local wanted = list_name:lower()
        for _, list in ipairs(all.value or {}) do
            if list_id ~= "" and list.id == list_id then
                by_id = list
            end
            if wanted ~= "" and type(list.name) == "string" and list.name:lower() == wanted then
                by_name = list
            end
        end

        local found = by_id or by_name
        if not found then
            -- Refused rather than widened. "Only this list" quietly becoming
            -- "everything" would fill the device with articles nobody asked
            -- for, which is far worse than a sync that says what is wrong.
            return Result.err(
                "list_not_found",
                string.format(
                    "Karakeep has no list called '%s' any more. Pick another under "
                        .. "Download settings, or choose None.",
                    list_name ~= "" and list_name or list_id
                ),
                { list = list_name }
            )
        end

        return Result.ok({
            scope = "list",
            scope_id = found.id,
            label = string.format("list '%s'", found.name or list_name),
            extra_tags = tag_names,
        })
    end

    if #tag_names > 0 then
        local found = self.tags:findByName(tag_names[1])
        if found:isErr() then
            return found
        end
        if not found.value then
            return Result.err(
                "tag_not_found",
                string.format("No Karakeep tag is called '%s'.", tag_names[1]),
                { tag = tag_names[1] }
            )
        end

        local extra = {}
        for index = 2, #tag_names do
            table.insert(extra, tag_names[index])
        end

        return Result.ok({
            scope = "tag",
            scope_id = found.value.id,
            label = string.format("tag '%s'", found.value.name or tag_names[1]),
            extra_tags = extra,
        })
    end

    return Result.ok({ scope = "all", label = "all unarchived bookmarks", extra_tags = {} })
end

--- Does this bookmark carry every one of `names` as a tag?
-- @tparam table bookmark
-- @tparam table names Array of tag names.
-- @treturn boolean
function Downloader.hasAllTags(bookmark, names)
    if #(names or {}) == 0 then
        return true
    end

    local present = {}
    for _, tag in ipairs(bookmark.tags or {}) do
        if type(tag) == "table" and type(tag.name) == "string" then
            present[tag.name:lower()] = true
        end
    end

    for _, wanted in ipairs(names) do
        if not present[wanted:lower()] then
            return false
        end
    end

    return true
end

--- Fetch the bookmarks in scope, following pagination.
--
-- @tparam table scope From `resolveScope`.
-- @treturn Result Value is `{ items, complete }`. `complete` is false when the
--   walk stopped at the per-sync cap rather than at the end of the collection.
function Downloader:fetchBookmarks(scope)
    local limit = self.settings:get("articles_per_sync") or 30
    local include_archived = self.settings:get("include_archived") == true

    local collected = {}
    local cursor = nil
    local complete = false

    -- A hard cap on pages as well as on articles: a scope where almost
    -- everything is filtered out client-side could otherwise walk a very large
    -- collection one page at a time.
    for _ = 1, 50 do
        local page = self.bookmarks:page({
            scope = scope.scope,
            scope_id = scope.scope_id,
            limit = math.min(limit, 100),
            cursor = cursor,
            archived = include_archived,
        })

        if page:isErr() then
            return page
        end

        local payload = page.value or {}

        for _, bookmark in ipairs(payload.bookmarks or {}) do
            -- The list and tag endpoints accept no `archived` filter, so
            -- archived bookmarks are dropped here for those scopes.
            local archived_ok = include_archived or not bookmark.archived

            if archived_ok and Sources.isReadable(bookmark) and Downloader.hasAllTags(bookmark, scope.extra_tags) then
                table.insert(collected, bookmark)
                if #collected >= limit then
                    return Result.ok({ items = collected, complete = false })
                end
            end
        end

        cursor = payload.nextCursor
        if not cursor then
            complete = true
            break
        end
    end

    return Result.ok({ items = collected, complete = complete })
end

--- Fetch an asset into memory, refusing anything implausibly large.
--
-- Page archives are whole pages with their resources inlined and can run to
-- many megabytes. A Kobo has little RAM to spare, so there is a ceiling, and
-- the asset goes to a file first so its size can be checked before it is read
-- in.
--
-- @tparam string asset_id
-- @treturn string|nil
function Downloader:fetchAsset(asset_id)
    local folder = self.settings:get("download_folder")
    if not folder then
        return nil
    end

    local tmp_path = Paths.join(folder, ".karabridge-asset.tmp")
    local max_bytes = (self.settings:get("max_archive_mb") or 4) * 1024 * 1024

    local downloaded = self.bookmarks:downloadAsset(asset_id, tmp_path)
    if downloaded:isErr() then
        log.warn("could not download asset", asset_id, "-", downloaded:describe())
        return nil
    end

    local size = Filesystem.fileSize(tmp_path) or 0
    if size > max_bytes then
        log.warn(string.format("asset %s is %d bytes, over the %d limit - skipping", asset_id, size, max_bytes))
        os.remove(tmp_path)
        return nil
    end

    local read = Filesystem.readFile(tmp_path)
    os.remove(tmp_path)

    if read:isErr() then
        return nil
    end
    return read.value
end

--- Work down the possible content sources until one yields something.
-- @tparam table bookmark
-- @treturn string|nil Article HTML.
-- @treturn string|nil The label of the source that produced it.
function Downloader:resolveContent(bookmark)
    local prefer_archive = self.settings:get("prefer_archive") == true
    local content = bookmark.content or {}

    for _, source in ipairs(Sources.forBookmark(bookmark, prefer_archive)) do
        local body

        if source.kind == "text" then
            body = MarkdownHtml.render(content.text or "")
        elseif source.kind == "inline" then
            body = content.htmlContent
        elseif source.kind == "asset" then
            body = self:fetchAsset(source.asset_id)
        elseif source.kind == "endpoint" then
            local fetched = self.bookmarks:readableContent(bookmark.id, "markdown")
            if fetched:isOk() and fetched.value and fetched.value ~= "" then
                body = MarkdownHtml.render(fetched.value)
            end
        end

        if type(body) == "string" and body ~= "" then
            log.dbg(tostring(bookmark.id), "content from", source.label, #body, "bytes")

            if source.full_page then
                -- A whole-page snapshot rather than an extracted article, so it
                -- arrives with navigation and other page furniture attached.
                log.info(tostring(bookmark.id), "using", source.label, "- expect page furniture around the article")
            end

            return body, source.label
        end
    end

    return nil
end

--- Download one bookmark and write its EPUB.
-- @tparam table bookmark
-- @treturn Result Value is `{ path, title, images, dropped }`.
function Downloader:downloadOne(bookmark)
    local folder = self.settings:get("download_folder")
    local title = EpubBuilder.titleOf(bookmark)

    local body_html, source_label = self:resolveContent(bookmark)
    if not body_html then
        log.info("no readable content for", tostring(bookmark.id), tostring((bookmark.content or {}).url))
        return Result.err("no_content", "No readable content was available.", { id = bookmark.id })
    end

    local filename = Paths.buildArticleFilename(bookmark.id, title)
    local filepath = Paths.resolveInside(folder, filename)

    -- The title comes from a web page, so the filename derived from it is
    -- remote-controlled. sanitiseFilename should already have made it safe;
    -- this is the check that says so rather than assuming it.
    if not filepath then
        log.err("refusing to write outside the download folder:", filename)
        return Result.err("unsafe_path", "The article's title produced an unusable filename.", { id = bookmark.id })
    end

    local built = EpubBuilder.build(bookmark, filepath, {
        body_html = body_html,
        include_images = self.settings:get("download_images") ~= false,
        max_images = self.settings:get("max_images") or 20,
        progress = function(message)
            self.progress(message)
        end,
    })

    if built:isErr() then
        log.err("could not build EPUB for", tostring(bookmark.id), "-", built:describe())
        return built
    end

    -- Record the provenance now, while it is known. The ID is also in the
    -- filename, but the sidecar survives a rename and the filename does not.
    -- remote_modified_at is what makes a later refresh possible: it is the
    -- server's own answer to "has this changed", so comparing it costs no
    -- extra request.
    local recorded = Metadata.update(filepath, "article", {
        bookmark_id = bookmark.id,
        source_url = (bookmark.content or {}).url,
        content_hash = Hashing.hash(body_html),
        remote_modified_at = bookmark.modifiedAt,
        downloaded_at = os.time(),
        source = source_label,
    })

    if not recorded then
        -- The EPUB is on disk but nothing records where it came from. Not a
        -- failure -- the article is readable -- but the next sync will see it
        -- as unchanged for ever, so say so.
        log.warn("wrote", filepath, "but could not record its provenance in the sidecar")
    end

    return Result.ok({
        path = filepath,
        title = title,
        images = built.value.images,
        dropped = built.value.dropped,
    })
end

--- Download everything in scope.
--
-- @treturn Result Value is a summary table:
--   downloaded, skipped, failed, total, complete, cancelled, scope, first_error
function Downloader:run()
    local folder = self.settings:get("download_folder")

    local writable = Filesystem.checkWritableDirectory(folder)
    if writable:isErr() then
        log.err("download folder unusable:", tostring(folder), "-", writable:describe())
        return writable
    end

    local scope = self:resolveScope()
    if scope:isErr() then
        return scope
    end

    local limit = self.settings:get("articles_per_sync") or 30
    log.info(string.format("syncing scope=%s limit=%d", scope.value.label, limit))

    self.progress("Fetching your Karakeep articles" .. Text.ELLIPSIS)

    local fetched = self:fetchBookmarks(scope.value)
    if fetched:isErr() then
        log.err("fetch failed:", fetched:describe())
        return fetched
    end

    local index = Library.index(folder)

    -- Not just "is the ID already here": Karakeep re-crawls, so an article
    -- that arrived as a stub can become the full text later. See
    -- Library.classify for the rule and why an opened article is never
    -- replaced.
    local plan = Library.classify(fetched.value.items, index, Metadata.read, Metadata.wasOpened)

    local pending = {}
    for _, bookmark in ipairs(plan.download) do
        table.insert(pending, { bookmark = bookmark, refresh = false })
    end
    for _, item in ipairs(plan.refresh) do
        table.insert(pending, { bookmark = item.bookmark, refresh = true })
    end

    -- Recorded before downloading anything, so cancelling half way through
    -- does not make the rest look as though it vanished from the server.
    local remote_ids = {}
    for _, bookmark in ipairs(fetched.value.items) do
        remote_ids[bookmark.id] = true
    end

    local summary = {
        total = #fetched.value.items,
        downloaded = 0,
        refreshed = 0,
        skipped = plan.unchanged,
        -- Changed on Karakeep, but opened here, so deliberately left alone.
        stale = #plan.stale,
        failed = 0,
        complete = fetched.value.complete,
        cancelled = false,
        scope = scope.value.label,
        remote_ids = remote_ids,
        first_error = nil,
    }

    for position, item in ipairs(pending) do
        local go_on = self.progress(
            string.format(
                "%s %d of %d:\n\n%s",
                item.refresh and "Refreshing" or "Downloading",
                position,
                #pending,
                EpubBuilder.titleOf(item.bookmark)
            )
        )

        if go_on == false then
            summary.cancelled = true
            summary.complete = false
            break
        end

        local downloaded = self:downloadOne(item.bookmark)
        if downloaded:isOk() then
            if item.refresh then
                summary.refreshed = summary.refreshed + 1
            else
                summary.downloaded = summary.downloaded + 1
            end
        else
            summary.failed = summary.failed + 1
            summary.first_error = summary.first_error or downloaded.message or downloaded:errorCode()
        end
    end

    log.info(
        string.format(
            "done - %d fetched, %d downloaded, %d skipped, %d failed (complete=%s cancelled=%s)",
            summary.total,
            summary.downloaded,
            summary.skipped,
            summary.failed,
            tostring(summary.complete),
            tostring(summary.cancelled)
        )
    )

    return Result.ok(summary)
end

--- Turn a summary into the lines shown to the user.
--
-- Separate from `run()` so the wording can change without touching the flow,
-- and so a spec can assert on the flow without matching on prose.
--
-- @tparam table summary
-- @treturn table Array of lines.
function Downloader.summarise(summary)
    local lines = {}

    if summary.downloaded == 1 then
        table.insert(lines, "Downloaded 1 article.")
    else
        table.insert(lines, string.format("Downloaded %d articles.", summary.downloaded))
    end

    if (summary.refreshed or 0) == 1 then
        table.insert(lines, "Refreshed 1 article that changed in Karakeep.")
    elseif (summary.refreshed or 0) > 1 then
        table.insert(lines, string.format("Refreshed %d articles that changed in Karakeep.", summary.refreshed))
    end
    if summary.skipped > 0 then
        table.insert(lines, string.format("%d already on the device.", summary.skipped))
    end
    if (summary.stale or 0) > 0 then
        table.insert(
            lines,
            string.format(
                "%d changed in Karakeep but were left alone because you have opened them.",
                summary.stale
            )
        )
    end
    if summary.cancelled then
        table.insert(lines, "Cancelled; the rest were left alone.")
    end
    if summary.failed > 0 then
        table.insert(lines, string.format("%d could not be downloaded.", summary.failed))
        if summary.first_error then
            table.insert(lines, "First reason: " .. tostring(summary.first_error))
        end
    end
    if summary.downloaded == 0 and summary.failed == 0 and summary.skipped == 0 and summary.total == 0 then
        table.insert(lines, string.format("Nothing to download in %s.", summary.scope or "this scope"))
    end

    return lines
end

return Downloader
