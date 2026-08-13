local Helper = require("spec.support.helper")

local Downloader = require("karabridge.features.article_download.downloader")
local Library = require("karabridge.features.article_download.library")
local Sources = require("karabridge.features.article_download.sources")

describe("article_download.Sources", function()
    local function link(content)
        local base = { type = "link", url = "https://example.org/a" }
        for key, value in pairs(content or {}) do
            base[key] = value
        end
        return { id = "b1", content = base }
    end

    describe("forBookmark", function()
        it("prefers inline readable HTML", function()
            local sources = Sources.forBookmark(link({ htmlContent = "<p>x</p>" }))
            assert.equals("inline", sources[1].kind)
        end)

        it("falls back to the readable asset", function()
            -- Reachable even though htmlContent should have covered it:
            -- Karakeep swallows a failed asset read and returns null.
            local sources = Sources.forBookmark(link({ contentAssetId = "a1" }))
            assert.equals("asset", sources[1].kind)
            assert.equals("a1", sources[1].asset_id)
        end)

        it("puts archives after the extracted article, not before", function()
            -- An archive is a whole page including navigation and banners.
            -- Karakeep already extracted the prose from it, so preferring the
            -- archive would be a downgrade.
            local sources = Sources.forBookmark(link({
                htmlContent = "<p>x</p>",
                fullPageArchiveAssetId = "f1",
            }))

            assert.equals("inline", sources[1].kind)
            assert.equals("asset", sources[2].kind)
            assert.is_true(sources[2].full_page)
        end)

        it("prefers the user's own capture over Karakeep's snapshot", function()
            local sources = Sources.forBookmark(link({
                precrawledArchiveAssetId = "p1",
                fullPageArchiveAssetId = "f1",
            }))

            assert.equals("p1", sources[1].asset_id)
            assert.equals("f1", sources[2].asset_id)
        end)

        it("moves the archives to the front when asked", function()
            local sources = Sources.forBookmark(link({
                htmlContent = "<p>x</p>",
                fullPageArchiveAssetId = "f1",
            }), true)

            assert.is_true(sources[1].full_page)
            assert.equals("inline", sources[2].kind)
        end)

        it("always ends with the readable-content endpoint", function()
            -- Last, because it serves markdown and loses formatting and images.
            local sources = Sources.forBookmark(link({ htmlContent = "<p>x</p>" }))
            assert.equals("endpoint", sources[#sources].kind)
        end)

        it("offers the endpoint even when nothing else is available", function()
            local sources = Sources.forBookmark(link({}))
            assert.equals(1, #sources)
            assert.equals("endpoint", sources[1].kind)
        end)

        it("treats a text bookmark as carrying its own body", function()
            local sources = Sources.forBookmark({ content = { type = "text", text = "# Hi" } })
            assert.equals(1, #sources)
            assert.equals("text", sources[1].kind)
        end)

        it("offers nothing for an asset bookmark", function()
            assert.same({}, Sources.forBookmark({ content = { type = "asset", assetId = "x" } }))
        end)

        it("ignores an empty string as if the field were absent", function()
            local sources = Sources.forBookmark(link({ htmlContent = "", contentAssetId = "" }))
            assert.equals(1, #sources)
            assert.equals("endpoint", sources[1].kind)
        end)
    end)

    describe("isReadable", function()
        it("accepts links and text", function()
            assert.is_true(Sources.isReadable({ content = { type = "link" } }))
            assert.is_true(Sources.isReadable({ content = { type = "text" } }))
        end)

        it("rejects assets, which are already a file", function()
            assert.is_false(Sources.isReadable({ content = { type = "asset" } }))
        end)

        it("rejects a bookmark Karakeep has not crawled yet", function()
            assert.is_false(Sources.isReadable({ content = { type = "unknown" } }))
        end)

        it("rejects a bookmark with no content at all", function()
            assert.is_false(Sources.isReadable({}))
            assert.is_false(Sources.isReadable(nil))
        end)
    end)
end)

describe("article_download.Library", function()
    before_each(function()
        Helper.install()
        Helper.mocks.filesystem.addDirectory("/downloads")
    end)

    after_each(function()
        Helper.uninstall()
    end)

    it("indexes our files by their embedded bookmark ID", function()
        Helper.mocks.filesystem.addFile("/downloads/[kb-id_abc] An Article.epub")
        Helper.mocks.filesystem.addFile("/downloads/[kb-id_xyz] Another.epub")

        local index = Library.index("/downloads")

        assert.equals("/downloads/[kb-id_abc] An Article.epub", index.abc)
        assert.equals("/downloads/[kb-id_xyz] Another.epub", index.xyz)
        assert.equals(2, Library.count(index))
    end)

    it("ignores files that are not ours", function()
        -- Including another plugin's, which use a different prefix. Claiming
        -- one would mean
        -- deleting a file another plugin is managing.
        Helper.mocks.filesystem.addFile("/downloads/[xx-id_abc] Another Article.epub")
        Helper.mocks.filesystem.addFile("/downloads/An Ordinary Book.epub")

        assert.equals(0, Library.count(Library.index("/downloads")))
    end)

    it("descends into subfolders, so sorting by hand does not lose track", function()
        Helper.mocks.filesystem.addDirectory("/downloads/tech")
        Helper.mocks.filesystem.addFile("/downloads/tech/[kb-id_deep] Nested.epub")

        assert.equals("/downloads/tech/[kb-id_deep] Nested.epub", Library.index("/downloads").deep)
    end)

    it("skips .sdr directories", function()
        Helper.mocks.filesystem.addDirectory("/downloads/[kb-id_abc] An Article.sdr")
        Helper.mocks.filesystem.addFile("/downloads/[kb-id_abc] An Article.sdr/[kb-id_zzz] decoy.epub")

        assert.is_nil(Library.index("/downloads").zzz)
    end)

    it("returns an empty index for a folder that does not exist", function()
        assert.equals(0, Library.count(Library.index("/nope")))
    end)

    describe("missing", function()
        it("separates what is already here from what is not", function()
            local index = { b1 = "/downloads/one.epub" }
            local missing, skipped = Library.missing({ { id = "b1" }, { id = "b2" } }, index)

            assert.equals(1, #missing)
            assert.equals("b2", missing[1].id)
            assert.equals(1, skipped)
        end)

        it("keeps the given order", function()
            local missing = Library.missing({ { id = "a" }, { id = "b" }, { id = "c" } }, {})
            assert.equals("a", missing[1].id)
            assert.equals("c", missing[3].id)
        end)
    end)
end)

describe("article_download.Downloader", function()
    before_each(function()
        Helper.install()
    end)

    after_each(function()
        Helper.uninstall()
    end)

    local function downloader(responses, settings_values)
        local client = Helper.client(responses)
        local settings = Helper.settings(settings_values)
        return Downloader.new({ client = client, settings = settings }), settings
    end

    describe("resolveScope", function()
        it("defaults to everything unarchived", function()
            local d = downloader({})
            local scope = d:resolveScope()

            assert.is_true(scope:isOk())
            assert.equals("all", scope.value.scope)
        end)

        it("resolves a list by name", function()
            local d = downloader({
                { code = 200, body = '{"lists":[{"id":"l1","name":"Psychologie"}]}' },
            }, { filter_list = "psychologie" })

            local scope = d:resolveScope()

            assert.equals("list", scope.value.scope)
            assert.equals("l1", scope.value.scope_id)
        end)

        it("reports a list name that does not exist, by name", function()
            local d = downloader({ { code = 200, body = '{"lists":[]}' } }, { filter_list = "Nope" })
            local scope = d:resolveScope()

            assert.equals("list_not_found", scope:errorCode())
            assert.matches("Nope", scope.message)
        end)

        it("prefers the stored ID, so a renamed list still syncs", function()
            -- Renaming a list in Karakeep used to stop the sync outright.
            local d = downloader({
                { code = 200, body = '{"lists":[{"id":"l1","name":"The New Name"}]}' },
            }, { filter_list = "The Old Name", filter_list_id = "l1" })

            local scope = d:resolveScope()

            assert.equals("list", scope.value.scope)
            assert.equals("l1", scope.value.scope_id)
        end)

        it("falls back to the name when the stored ID is gone", function()
            -- A list deleted and made again keeps its name but not its ID.
            local d = downloader({
                { code = 200, body = '{"lists":[{"id":"l2","name":"Psychologie"}]}' },
            }, { filter_list = "Psychologie", filter_list_id = "deleted" })

            local scope = d:resolveScope()

            assert.equals("l2", scope.value.scope_id)
        end)

        it("refuses rather than widening when the list is gone entirely", function()
            -- The important half of this feature. "Only this list" quietly
            -- becoming "everything" would fill the device with articles nobody
            -- asked for -- much worse than a sync that stops and says why.
            local d = downloader({ { code = 200, body = '{"lists":[]}' } }, {
                filter_list = "Vanished",
                filter_list_id = "gone",
            })

            local scope = d:resolveScope()

            assert.equals("list_not_found", scope:errorCode())
            assert.matches("Vanished", scope.message)
            assert.matches("Download settings", scope.message)
        end)

        it("resolves a single tag server-side", function()
            local d = downloader({
                { code = 200, body = '{"tags":[{"id":"t1","name":"Philosophie"}]}' },
            }, { filter_tags = "Philosophie" })

            local scope = d:resolveScope()

            assert.equals("tag", scope.value.scope)
            assert.equals("t1", scope.value.scope_id)
            assert.same({}, scope.value.extra_tags)
        end)

        it("narrows on the first tag and leaves the rest for the device", function()
            -- Karakeep's tag endpoint takes one tag. The rest are a correct
            -- client-side filter, just not necessarily the most selective one.
            local d = downloader({
                { code = 200, body = '{"tags":[{"id":"t1","name":"a"},{"id":"t2","name":"b"}]}' },
            }, { filter_tags = "a, b, c" })

            local scope = d:resolveScope()

            assert.equals("t1", scope.value.scope_id)
            assert.same({ "b", "c" }, scope.value.extra_tags)
        end)

        it("prefers a list over tags, keeping the tags as an extra filter", function()
            local d = downloader({
                { code = 200, body = '{"lists":[{"id":"l1","name":"L"}]}' },
            }, { filter_list = "L", filter_tags = "x" })

            local scope = d:resolveScope()

            assert.equals("list", scope.value.scope)
            assert.same({ "x" }, scope.value.extra_tags)
        end)

        it("propagates a server failure rather than silently syncing everything", function()
            local d = downloader({ { code = 401, body = "" } }, { filter_list = "L" })
            assert.equals("unauthorized", d:resolveScope():errorCode())
        end)
    end)

    describe("hasAllTags", function()
        local tagged = { tags = { { name = "Philosophie" }, { name = "Wissen" } } }

        it("accepts anything when no tags are required", function()
            assert.is_true(Downloader.hasAllTags(tagged, {}))
            assert.is_true(Downloader.hasAllTags(tagged, nil))
        end)

        it("requires every tag, not just one", function()
            assert.is_true(Downloader.hasAllTags(tagged, { "Philosophie", "Wissen" }))
            assert.is_false(Downloader.hasAllTags(tagged, { "Philosophie", "Nihilismus" }))
        end)

        it("is case-insensitive", function()
            assert.is_true(Downloader.hasAllTags(tagged, { "philosophie" }))
        end)

        it("rejects an untagged bookmark when tags are required", function()
            assert.is_false(Downloader.hasAllTags({ tags = {} }, { "x" }))
            assert.is_false(Downloader.hasAllTags({}, { "x" }))
        end)
    end)

    describe("fetchBookmarks", function()
        local function page(bookmarks, cursor)
            local items = {}
            for _, b in ipairs(bookmarks) do
                table.insert(items, b)
            end
            local Json = require("spec.mocks.json")
            return { code = 200, body = Json.encode({ bookmarks = items, nextCursor = cursor }) }
        end

        local function readable(id, extra)
            local b = { id = id, archived = false, content = { type = "link", url = "https://x/" .. id } }
            for k, v in pairs(extra or {}) do
                b[k] = v
            end
            return b
        end

        it("follows the cursor and reports a complete walk", function()
            local d = downloader({
                page({ readable("a") }, "c1"),
                page({ readable("b") }, nil),
            })

            local fetched = d:fetchBookmarks({ scope = "all", extra_tags = {} })

            assert.equals(2, #fetched.value.items)
            assert.is_true(fetched.value.complete)
        end)

        it("stops at the per-sync cap and says the walk was not complete", function()
            -- A capped run must not be mistaken for "everything the server
            -- has": deleting local files on that basis loses reading.
            local d = downloader({
                page({ readable("a"), readable("b"), readable("c") }, "c1"),
            }, { articles_per_sync = 2 })

            local fetched = d:fetchBookmarks({ scope = "all", extra_tags = {} })

            assert.equals(2, #fetched.value.items)
            assert.is_false(fetched.value.complete)
        end)

        it("drops archived bookmarks that a list scope returned anyway", function()
            -- The list and tag endpoints accept no archived filter.
            local d = downloader({
                page({ readable("a"), readable("b", { archived = true }) }, nil),
            })

            local fetched = d:fetchBookmarks({ scope = "list", scope_id = "l1", extra_tags = {} })

            assert.equals(1, #fetched.value.items)
            assert.equals("a", fetched.value.items[1].id)
        end)

        it("keeps archived bookmarks when the user asked for them", function()
            local d = downloader({
                page({ readable("a"), readable("b", { archived = true }) }, nil),
            }, { include_archived = true })

            local fetched = d:fetchBookmarks({ scope = "all", extra_tags = {} })
            assert.equals(2, #fetched.value.items)
        end)

        it("drops asset bookmarks, which are already a file", function()
            local d = downloader({
                page({ readable("a"), { id = "b", content = { type = "asset" } } }, nil),
            })

            assert.equals(1, #d:fetchBookmarks({ scope = "all", extra_tags = {} }).value.items)
        end)

        it("applies the client-side tag filter", function()
            local d = downloader({
                page({
                    readable("a", { tags = { { name = "keep" } } }),
                    readable("b", { tags = { { name = "other" } } }),
                }, nil),
            })

            local fetched = d:fetchBookmarks({ scope = "all", extra_tags = { "keep" } })

            assert.equals(1, #fetched.value.items)
            assert.equals("a", fetched.value.items[1].id)
        end)

        it("propagates a failure instead of returning a short list", function()
            local d = downloader({ { code = 500, body = "" }, { code = 500, body = "" }, { code = 500, body = "" } })
            assert.is_true(d:fetchBookmarks({ scope = "all", extra_tags = {} }):isErr())
        end)
    end)

    describe("resolveContent", function()
        it("uses inline HTML without making a request", function()
            local d, _ = downloader({})
            local html = d:resolveContent({
                id = "b1",
                content = { type = "link", htmlContent = "<p>inline</p>" },
            })

            assert.equals("<p>inline</p>", html)
        end)

        it("renders a text bookmark's markdown body", function()
            local d = downloader({})
            local html = d:resolveContent({ id = "b1", content = { type = "text", text = "# Heading" } })

            assert.matches("<h1>Heading</h1>", html)
        end)

        it("falls through to the endpoint and renders its markdown", function()
            local d = downloader({
                { code = 200, body = '{"content":"# From endpoint","truncated":false}' },
            })

            local html = d:resolveContent({ id = "b1", content = { type = "link" } })
            assert.matches("<h1>From endpoint</h1>", html)
        end)

        it("returns nothing when every source is exhausted", function()
            local d = downloader({ { code = 404, body = "" } })
            assert.is_nil(d:resolveContent({ id = "b1", content = { type = "link" } }))
        end)

        it("reports which source produced the content", function()
            local d = downloader({})
            local _, label = d:resolveContent({
                id = "b1",
                content = { type = "link", htmlContent = "<p>x</p>" },
            })

            assert.equals("inline readable HTML", label)
        end)
    end)

    describe("summarise", function()
        local function summary(overrides)
            local base = {
                total = 0,
                downloaded = 0,
                skipped = 0,
                failed = 0,
                complete = true,
                cancelled = false,
                scope = "all unarchived bookmarks",
            }
            for k, v in pairs(overrides or {}) do
                base[k] = v
            end
            return base
        end

        it("uses the singular for one article", function()
            assert.equals("Downloaded 1 article.", Downloader.summarise(summary({ downloaded = 1 }))[1])
        end)

        it("uses the plural otherwise", function()
            assert.equals("Downloaded 3 articles.", Downloader.summarise(summary({ downloaded = 3 }))[1])
        end)

        it("mentions what was already present", function()
            local lines = Downloader.summarise(summary({ downloaded = 1, skipped = 2 }))
            assert.matches("2 already on the device", table.concat(lines, "\n"))
        end)

        it("says when the run was cancelled", function()
            local lines = Downloader.summarise(summary({ downloaded = 1, cancelled = true }))
            assert.matches("Cancelled", table.concat(lines, "\n"))
        end)

        it("gives the first reason for a failure", function()
            local lines = Downloader.summarise(summary({ failed = 2, first_error = "No readable content." }))
            local text = table.concat(lines, "\n")

            assert.matches("2 could not be downloaded", text)
            assert.matches("No readable content", text)
        end)

        it("says plainly when the scope was empty", function()
            local lines = Downloader.summarise(summary({ scope = "list 'X'" }))
            assert.matches("Nothing to download in list 'X'", table.concat(lines, "\n"))
        end)
    end)

    describe("run", function()
        it("refuses before touching the network when the folder is unusable", function()
            -- Up front, because otherwise the failure surfaces as every article
            -- failing separately from inside the zip writer.
            local d, _ = downloader({}, { download_folder = "" })
            local result = d:run()

            assert.is_true(result:isErr())
            assert.equals("invalid_path", result:errorCode())
        end)
    end)
end)

describe("article_download.Library.classify", function()
    -- "Is this ID already on the device" is not enough: Karakeep re-crawls, so
    -- an article that arrived as a paywall stub becomes the full text later.
    -- Skipping it for ever leaves the user with the stub; replacing it
    -- unconditionally loses the reading position of one they have opened.
    local function bookmark(id, modified)
        return { id = id, modifiedAt = modified }
    end

    local function plan(bookmarks, index, metadata, opened)
        return Library.classify(bookmarks, index, function(path)
            return metadata[path]
        end, function(path)
            return opened[path] == true
        end)
    end

    it("downloads an article that is not here yet", function()
        local result = plan({ bookmark("a", "2026-01-01") }, {}, {}, {})

        assert.equals(1, #result.download)
        assert.equals(0, #result.refresh)
    end)

    it("leaves an unchanged article alone", function()
        local result = plan(
            { bookmark("a", "2026-01-01") },
            { a = "/d/a.epub" },
            { ["/d/a.epub"] = { article = { remote_modified_at = "2026-01-01" } } },
            {}
        )

        assert.equals(1, result.unchanged)
        assert.equals(0, #result.refresh)
    end)

    it("refreshes a changed article that was never opened", function()
        local result = plan(
            { bookmark("a", "2026-02-01") },
            { a = "/d/a.epub" },
            { ["/d/a.epub"] = { article = { remote_modified_at = "2026-01-01" } } },
            {}
        )

        assert.equals(1, #result.refresh)
        assert.equals("/d/a.epub", result.refresh[1].path)
    end)

    it("refuses to replace a changed article the user has opened", function()
        -- Replacing it would take the reading position and any highlights
        -- with it. Reported instead, so the user can decide.
        local result = plan(
            { bookmark("a", "2026-02-01") },
            { a = "/d/a.epub" },
            { ["/d/a.epub"] = { article = { remote_modified_at = "2026-01-01" } } },
            { ["/d/a.epub"] = true }
        )

        assert.equals(0, #result.refresh)
        assert.equals(1, #result.stale)
    end)

    it("treats a server that sends no modifiedAt as unchanged", function()
        -- Safe default: the previous behaviour, rather than refreshing
        -- everything on every sync because a field is missing.
        local result = plan(
            { bookmark("a", nil) },
            { a = "/d/a.epub" },
            { ["/d/a.epub"] = { article = { remote_modified_at = "2026-01-01" } } },
            {}
        )

        assert.equals(1, result.unchanged)
    end)

    it("treats an article with no recorded provenance as unchanged", function()
        -- Downloaded before this field existed, or its sidecar write failed.
        -- Refreshing on that basis would replace every such article once, for
        -- no benefit.
        local result = plan({ bookmark("a", "2026-02-01") }, { a = "/d/a.epub" }, {}, {})

        assert.equals(1, result.unchanged)
    end)
end)
