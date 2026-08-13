local Helper = require("spec.support.helper")

local Status = require("karabridge.features.article_sync.status")
local Sync = require("karabridge.features.sync")
local Uploader = require("karabridge.features.article_sync.uploader")

local BOOK = "/downloads/[kb-id_b1] An Article.epub"

describe("article_sync.Status", function()
    before_each(function()
        Helper.install()
    end)

    after_each(function()
        Helper.uninstall()
    end)

    describe("read", function()
        it("reports an unopened article", function()
            local state = Status.read(BOOK)

            assert.is_false(state.opened)
            assert.equals(0, state.percent)
        end)

        it("reads the explicit status and the percentage", function()
            Helper.mocks.docsettings.seed(BOOK, {
                summary = { status = "complete" },
                percent_finished = 1,
            })

            local state = Status.read(BOOK)

            assert.is_true(state.opened)
            assert.equals("complete", state.status)
            assert.equals(1, state.percent)
        end)

        it("does not call a KaraBridge-written sidecar 'opened'", function()
            -- The download writes `karabridge` into the sidecar, so a sidecar
            -- exists for an article nobody has read. Treating that as opened
            -- made the sync's cleanup pass a no-op.
            Helper.mocks.docsettings.seed(BOOK, {
                doc_path = BOOK,
                karabridge = { version = 1, article = { bookmark_id = "b1" } },
            })

            assert.is_false(Status.read(BOOK).opened)
        end)

        it("recognises a document KOReader has rendered but not progressed in", function()
            -- copt_* appears the first time a document is opened, before any
            -- percentage is recorded.
            Helper.mocks.docsettings.seed(BOOK, { doc_path = BOOK, copt_font_size = 22 })

            local state = Status.read(BOOK)

            assert.is_true(state.opened)
            assert.is_nil(state.status)
            assert.equals(0, state.percent)
        end)

        it("recognises a document with reading state but no explicit status", function()
            Helper.mocks.docsettings.seed(BOOK, { doc_pages = 12, percent_finished = 0.4 })

            local state = Status.read(BOOK)

            assert.is_true(state.opened)
            assert.equals(0.4, state.percent)
        end)
    end)

    describe("isFinished", function()
        local all_on = { archive_finished = true, archive_abandoned = true, archive_after_read = true }

        it("never counts an unopened article", function()
            assert.is_false(Status.isFinished({ opened = false }, all_on))
        end)

        it("honours 'complete' when archive_finished is on", function()
            assert.is_true(Status.isFinished({ opened = true, status = "complete" }, all_on))
            assert.is_false(Status.isFinished({ opened = true, status = "complete" }, { archive_finished = false }))
        end)

        it("treats archive_finished as on by default", function()
            assert.is_true(Status.isFinished({ opened = true, status = "complete" }, {}))
        end)

        it("honours 'abandoned' only when asked", function()
            assert.is_true(Status.isFinished({ opened = true, status = "abandoned" }, all_on))
            assert.is_false(Status.isFinished({ opened = true, status = "abandoned" }, {}))
        end)

        it("honours reading to the end only when asked", function()
            assert.is_true(Status.isFinished({ opened = true, percent = 1 }, all_on))
            assert.is_false(Status.isFinished({ opened = true, percent = 1 }, {}))
        end)

        it("accepts 99.5% as finished", function()
            -- Requiring exactly 1.0 means an article whose last page is mostly
            -- whitespace never counts, which fails invisibly.
            assert.is_true(Status.isFinished({ opened = true, percent = 0.996 }, all_on))
            assert.is_false(Status.isFinished({ opened = true, percent = 0.8 }, all_on))
        end)

        it("prefers an explicit status over the percentage", function()
            local state = { opened = true, status = "abandoned", percent = 1 }
            assert.is_false(Status.isFinished(state, { archive_after_read = true }))
        end)
    end)
end)

describe("article_sync.Uploader", function()
    before_each(function()
        Helper.install()
    end)

    after_each(function()
        Helper.uninstall()
    end)

    local function uploader(responses, settings_values, deleted)
        local client = Helper.client(responses)
        local settings = Helper.settings(settings_values)
        return Uploader.new({
            client = client,
            settings = settings,
            delete_file = function(path)
                table.insert(deleted or {}, path)
            end,
        })
    end

    it("does nothing for an article that was never opened", function()
        local summary = uploader({}, {}):run({ b1 = BOOK }).value

        assert.equals(1, summary.examined)
        assert.equals(0, summary.archived)
        assert.equals(0, summary.highlights_created)
    end)

    it("archives a finished article and deletes the local copy", function()
        Helper.mocks.docsettings.seed(BOOK, { summary = { status = "complete" } })

        local deleted = {}
        -- No annotations, so Highlights.push returns without a request and
        -- the archive PATCH is the first thing the stub sees.
        local u = uploader({ { code = 200, body = '{"id":"b1"}' } }, {}, deleted)

        local summary = u:run({ b1 = BOOK }).value

        assert.equals(1, summary.archived)
        assert.equals(1, summary.deleted)
        assert.same({ BOOK }, deleted)
    end)

    it("keeps the local copy when asked, and records that the status went up", function()
        Helper.mocks.docsettings.seed(BOOK, { summary = { status = "complete" } })

        local deleted = {}
        local u = uploader({ { code = 200, body = '{"id":"b1"}' } }, { delete_local_after_archive = false }, deleted)

        local summary = u:run({ b1 = BOOK }).value

        assert.equals(1, summary.archived)
        assert.equals(0, summary.deleted)
        assert.same({}, deleted)

        local stored = Helper.mocks.docsettings.peek(BOOK).karabridge
        assert.is_not_nil(stored.article.status_synced_at)
    end)

    it("leaves the file alone when archiving fails, so the next run retries", function()
        -- This is what makes having no queue safe: the sidecar is the state.
        Helper.mocks.docsettings.seed(BOOK, { summary = { status = "complete" } })

        local deleted = {}
        local u = uploader({
            { code = 500, body = "" },
            { code = 500, body = "" },
            { code = 500, body = "" },
        }, {}, deleted)

        local summary = u:run({ b1 = BOOK }).value

        assert.equals(0, summary.archived)
        assert.equals(1, summary.failed)
        assert.same({}, deleted)
    end)

    it("pushes highlights for an opened but unfinished article", function()
        -- Notes must not be lost when the user never marks it read.
        Helper.mocks.docsettings.seed(BOOK, {
            percent_finished = 0.3,
            annotations = { { drawer = "lighten", text = "a passage" } },
        })

        local u = uploader({
            { code = 200, body = '{"highlights":[]}' },
            { code = 200, body = '{"content":{"htmlContent":"<p>a passage</p>"}}' },
            { code = 201, body = '{"id":"h1"}' },
        }, {})

        local summary = u:run({ b1 = BOOK }).value

        assert.equals(1, summary.highlights_created)
        assert.equals(0, summary.archived)
    end)

    it("respects the highlight switch", function()
        Helper.mocks.docsettings.seed(BOOK, {
            percent_finished = 0.3,
            annotations = { { drawer = "lighten", text = "a passage" } },
        })

        local u = uploader({}, { sync_article_highlights = false })
        assert.equals(0, u:run({ b1 = BOOK }).value.highlights_created)
    end)

    it("respects the read-status switch", function()
        Helper.mocks.docsettings.seed(BOOK, { summary = { status = "complete" } })

        local u = uploader({}, { sync_read_status = false })
        assert.equals(0, u:run({ b1 = BOOK }).value.archived)
    end)

    describe("summarise", function()
        local function summary(overrides)
            local base = {
                examined = 0,
                total = 0,
                highlights_created = 0,
                unresolved = 0,
                archived = 0,
                deleted = 0,
                failed = 0,
                cancelled = false,
            }
            for k, v in pairs(overrides or {}) do
                base[k] = v
            end
            return base
        end

        it("says so plainly when nothing happened", function()
            assert.same({ "Nothing new to send." }, Uploader.summarise(summary()))
        end)

        it("reports archives and highlights", function()
            local text = table.concat(Uploader.summarise(summary({ archived = 2, highlights_created = 5 })), "\n")

            assert.matches("Archived 2 articles", text)
            assert.matches("Sent 5 new highlights", text)
        end)

        it("uses the singular for one", function()
            local text = table.concat(Uploader.summarise(summary({ archived = 1, highlights_created = 1 })), "\n")

            assert.matches("Archived 1 article in", text)
            assert.matches("Sent 1 new highlight%.", text)
        end)

        it("mentions unpositioned highlights rather than hiding them", function()
            local text = table.concat(Uploader.summarise(summary({ highlights_created = 3, unresolved = 1 })), "\n")
            assert.matches("could not be positioned", text)
        end)

        it("says failures will be retried", function()
            local text = table.concat(Uploader.summarise(summary({ failed = 2 })), "\n")
            assert.matches("retried next sync", text)
        end)
    end)
end)

describe("Sync.removeVanished", function()
    before_each(function()
        Helper.install()
        Helper.mocks.filesystem.addDirectory("/downloads")
    end)

    after_each(function()
        Helper.uninstall()
    end)

    it("removes nothing when the sync did not see the whole scope", function()
        -- A capped sync cannot tell "archived elsewhere" from "did not fit".
        Helper.mocks.filesystem.addFile("/downloads/[kb-id_gone] Old.epub")

        local deleted = {}
        local removed = Sync.removeVanished("/downloads", {}, {
            complete = false,
            delete_file = function(p)
                table.insert(deleted, p)
            end,
        })

        assert.equals(0, removed)
        assert.same({}, deleted)
    end)

    it("removes an unopened article that is gone remotely", function()
        Helper.mocks.filesystem.addFile("/downloads/[kb-id_gone] Old.epub")

        local deleted = {}
        local removed = Sync.removeVanished("/downloads", {}, {
            complete = true,
            delete_file = function(p)
                table.insert(deleted, p)
            end,
        })

        assert.equals(1, removed)
        assert.same({ "/downloads/[kb-id_gone] Old.epub" }, deleted)
    end)

    it("keeps an article that is still on the server", function()
        Helper.mocks.filesystem.addFile("/downloads/[kb-id_here] Current.epub")

        local removed = Sync.removeVanished("/downloads", { here = true }, {
            complete = true,
            delete_file = function() end,
        })

        assert.equals(0, removed)
    end)

    it("keeps an article the user has opened, even when it is gone remotely", function()
        -- Deleting something someone is part way through is the worst thing
        -- this plugin could do.
        Helper.mocks.filesystem.addFile("/downloads/[kb-id_reading] In Progress.epub")
        Helper.mocks.docsettings.seed("/downloads/[kb-id_reading] In Progress.epub", { percent_finished = 0.4 })

        local removed = Sync.removeVanished("/downloads", {}, {
            complete = true,
            delete_file = function() end,
        })

        assert.equals(0, removed)
    end)

    it("still removes an article whose only sidecar content KaraBridge wrote", function()
        -- The regression this whole distinction exists for. The download writes
        -- `karabridge` into the sidecar, so hasSidecar was true for every
        -- article and this pass removed nothing at all -- the download folder
        -- simply grew for ever.
        local path = "/downloads/[kb-id_untouched] Never Opened.epub"
        Helper.mocks.filesystem.addFile(path)
        Helper.mocks.docsettings.seed(path, {
            doc_path = path,
            karabridge = { version = 1, article = { bookmark_id = "untouched" } },
        })

        local deleted = {}
        local removed = Sync.removeVanished("/downloads", {}, {
            complete = true,
            delete_file = function(p)
                table.insert(deleted, p)
            end,
        })

        assert.equals(1, removed)
        assert.same({ path }, deleted)
    end)

    it("keeps an article with annotations even if the reader state looks absent", function()
        local path = "/downloads/[kb-id_marked] Highlighted.epub"
        Helper.mocks.filesystem.addFile(path)
        Helper.mocks.docsettings.seed(path, {
            annotations = { { drawer = "lighten", text = "a passage" } },
        })

        local removed = Sync.removeVanished("/downloads", {}, {
            complete = true,
            delete_file = function() end,
        })

        assert.equals(0, removed)
    end)
end)
