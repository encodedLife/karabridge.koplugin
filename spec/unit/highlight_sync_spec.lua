local Helper = require("spec.support.helper")

local Bookmarks = require("karabridge.api.bookmarks")
local HighlightSync = require("karabridge.features.article_sync.highlight_sync")
local HighlightsApi = require("karabridge.api.highlights")
local Identity = require("karabridge.features.article_sync.identity")
local Json = require("karabridge.shared.json")
local Metadata = require("karabridge.shared.metadata")
local Reconcile = require("karabridge.features.article_sync.reconcile")

local BOOK = "/downloads/[kb-id_b1] An Article.epub"

-- "Remove this field". A plain nil in an override table is simply an absent
-- key, so the merge below would leave the base value and the spec would test
-- nothing -- which is exactly how the first version of these two specs passed
-- for the wrong reason.
local NONE = setmetatable({}, { __tostring = function() return "NONE" end })

--- A KOReader annotation, with a position so it has a strong identity.
local function annotation(overrides)
    local base = {
        drawer = "lighten",
        text = "a passage",
        note = nil,
        color = "yellow",
        chapter = nil,
        datetime = "2026-08-02 10:00:00",
        pos0 = "/body/DocFragment[1]/body/p[1]/text().0",
        pos1 = "/body/DocFragment[1]/body/p[1]/text().9",
    }
    for key, value in pairs(overrides or {}) do
        base[key] = (value ~= NONE) and value or nil
    end
    return base
end

describe("Identity", function()
    describe("fingerprint", function()
        it("uses the position when there is one", function()
            local _, basis = Identity.fingerprint(annotation())
            assert.equals("position", basis)
        end)

        it("distinguishes the same text at two positions", function()
            -- The case text alone cannot resolve, and the reason a fingerprint
            -- exists at all.
            local first = Identity.fingerprint(annotation({ pos0 = "p[1].0", pos1 = "p[1].9" }))
            local second = Identity.fingerprint(annotation({ pos0 = "p[7].0", pos1 = "p[7].9" }))

            assert.is_true(first ~= second)
        end)

        it("is stable when the note changes", function()
            -- The note is the field synchronisation edits. A fingerprint that
            -- moved with it would lose the mapping exactly when it is needed.
            local before = Identity.fingerprint(annotation({ note = nil }))
            local after = Identity.fingerprint(annotation({ note = "added later" }))

            assert.equals(before, after)
        end)

        it("is stable when the colour changes", function()
            local before = Identity.fingerprint(annotation({ color = "yellow" }))
            local after = Identity.fingerprint(annotation({ color = "red" }))

            assert.equals(before, after)
        end)

        it("falls back to datetime when there is no position", function()
            local _, basis = Identity.fingerprint(annotation({ pos0 = NONE, pos1 = NONE }))
            assert.equals("datetime", basis)
        end)

        it("falls back to text alone as a last resort", function()
            local _, basis = Identity.fingerprint(annotation({ pos0 = NONE, pos1 = NONE, datetime = NONE }))
            assert.equals("text", basis)
        end)

        it("handles a PDF position table", function()
            local fingerprint, basis = Identity.fingerprint(annotation({
                pos0 = { page = 4, x = 10, y = 20 },
                pos1 = { page = 4, x = 90, y = 20 },
            }))

            assert.equals("position", basis)
            assert.is_string(fingerprint)
        end)

        it("survives a non-table", function()
            assert.is_string(Identity.fingerprint(nil))
        end)
    end)

    describe("index", function()
        it("skips page bookmarks, which have no drawer", function()
            local indexed = Identity.index({ { text = "a bookmark" }, annotation() })

            local count = 0
            for _ in pairs(indexed) do
                count = count + 1
            end
            assert.equals(1, count)
        end)

        it("reports two annotations that cannot be told apart", function()
            -- No position, same datetime, same text. Rather than silently
            -- picking one, the collision is surfaced.
            local twin = { drawer = "lighten", text = "same", datetime = "2026-01-01 00:00:00" }
            local _, collisions = Identity.index({ twin, twin })

            assert.equals(1, #collisions)
        end)
    end)
end)

describe("Reconcile.plan", function()
    local function fields(note, color)
        return Identity.contentHash({ note = note or "", color = color or "yellow" })
    end

    it("plans a create for an annotation with no mapping", function()
        local plan = Reconcile.plan({ annotations = { annotation() }, remote = {}, mapping = {} })

        assert.equals(1, Reconcile.counts(plan).create)
    end)

    it("does nothing when neither side changed", function()
        local a = annotation({ note = "same" })
        local fingerprint = Identity.fingerprint(a)

        local plan = Reconcile.plan({
            annotations = { a },
            remote = { { id = "h1", text = "a passage", note = "same", color = "yellow" } },
            mapping = {
                [fingerprint] = {
                    remote_id = "h1",
                    local_hash = fields("same"),
                    remote_hash = fields("same"),
                },
            },
        })

        local counts = Reconcile.counts(plan)
        assert.equals(0, counts.push)
        assert.equals(0, counts.pull)
        assert.equals(0, counts.conflict)
    end)

    it("plans a push when only the local note changed", function()
        local a = annotation({ note = "edited locally" })
        local fingerprint = Identity.fingerprint(a)

        local plan = Reconcile.plan({
            annotations = { a },
            remote = { { id = "h1", note = "original", color = "yellow" } },
            mapping = {
                [fingerprint] = {
                    remote_id = "h1",
                    local_hash = fields("original"),
                    remote_hash = fields("original"),
                },
            },
        })

        assert.equals(1, Reconcile.counts(plan).push)
    end)

    it("plans a pull when only the remote note changed", function()
        local a = annotation({ note = "original" })
        local fingerprint = Identity.fingerprint(a)

        local plan = Reconcile.plan({
            annotations = { a },
            remote = { { id = "h1", note = "Edited on Karakeep", color = "yellow" } },
            mapping = {
                [fingerprint] = {
                    remote_id = "h1",
                    local_hash = fields("original"),
                    remote_hash = fields("original"),
                },
            },
        })

        assert.equals(1, Reconcile.counts(plan).pull)
    end)

    it("reports a conflict when both sides changed, and plans neither", function()
        -- Whichever side were chosen automatically, the other person's edit
        -- would vanish with no way to recover it.
        local a = annotation({ note = "edited in KOReader" })
        local fingerprint = Identity.fingerprint(a)

        local plan = Reconcile.plan({
            annotations = { a },
            remote = { { id = "h1", note = "edited in Karakeep", color = "yellow" } },
            mapping = {
                [fingerprint] = {
                    remote_id = "h1",
                    local_hash = fields("original"),
                    remote_hash = fields("original"),
                },
            },
        })

        local counts = Reconcile.counts(plan)
        assert.equals(1, counts.conflict)
        assert.equals(0, counts.push)
        assert.equals(0, counts.pull)
    end)

    it("reports a remote deletion without planning a local change", function()
        local a = annotation()
        local fingerprint = Identity.fingerprint(a)

        local plan = Reconcile.plan({
            annotations = { a },
            remote = {},
            mapping = { [fingerprint] = { remote_id = "gone", local_hash = fields(), remote_hash = fields() } },
        })

        assert.equals(1, Reconcile.counts(plan).remote_deleted)
    end)

    it("adopts a remote highlight that matches exactly one unmapped annotation", function()
        local plan = Reconcile.plan({
            annotations = { annotation({ text = "unique passage" }) },
            remote = { { id = "h1", text = "unique passage", note = "from Karakeep" } },
            mapping = {},
        })

        local counts = Reconcile.counts(plan)
        assert.equals(1, counts.adopt)
        assert.equals(0, counts.create)
    end)

    it("refuses to adopt when two annotations share the text", function()
        -- Attaching a note to the wrong sentence is worse than leaving it
        -- unattached, and text cannot tell these two apart.
        local plan = Reconcile.plan({
            annotations = {
                annotation({ text = "repeated", pos0 = "p[1].0", pos1 = "p[1].8" }),
                annotation({ text = "repeated", pos0 = "p[9].0", pos1 = "p[9].8" }),
            },
            remote = { { id = "h1", text = "repeated" } },
            mapping = {},
        })

        local counts = Reconcile.counts(plan)
        assert.equals(0, counts.adopt)
        assert.equals(1, counts.orphan)
        assert.equals(2, counts.create)
    end)

    it("reports a remote highlight with no local counterpart as an orphan", function()
        local plan = Reconcile.plan({
            annotations = {},
            remote = { { id = "h1", text = "made in Karakeep" } },
            mapping = {},
        })

        assert.equals(1, Reconcile.counts(plan).orphan)
    end)

    it("compares colour in Karakeep's palette, not KOReader's", function()
        -- KOReader's cyan becomes Karakeep's blue. Comparing raw values would
        -- report a change on every single sync.
        local a = annotation({ color = "cyan" })
        local fingerprint = Identity.fingerprint(a)

        local plan = Reconcile.plan({
            annotations = { a },
            remote = { { id = "h1", note = "", color = "blue" } },
            mapping = {
                [fingerprint] = {
                    remote_id = "h1",
                    local_hash = Identity.contentHash({ note = "", color = "blue" }),
                    remote_hash = Identity.contentHash({ note = "", color = "blue" }),
                },
            },
        })

        assert.equals(0, Reconcile.counts(plan).push)
    end)
end)

describe("HighlightSync.run", function()
    before_each(function()
        Helper.install()
    end)

    after_each(function()
        Helper.uninstall()
    end)

    local function apis(responses)
        local client, stub = Helper.client(responses)
        return { highlights = HighlightsApi.new(client), bookmarks = Bookmarks.new(client) }, stub
    end

    local function run(responses)
        local api, stub = apis(responses)
        return HighlightSync.run({ apis = api, bookmark_id = "b1", file_path = BOOK }), stub
    end

    it("does nothing, and makes no request, when there is nothing on either side", function()
        Helper.mocks.docsettings.seed(BOOK, { annotations = {} })

        local result, stub = run({})

        assert.is_true(result:isOk())
        assert.equals(0, #stub.requests)
    end)

    it("creates a highlight and records its remote ID", function()
        -- The whole reason the old push-only flow could never update anything:
        -- it discarded this ID.
        Helper.mocks.docsettings.seed(BOOK, { annotations = { annotation() } })

        local result = run({
            { code = 200, body = '{"highlights":[]}' },
            { code = 200, body = '{"content":{"htmlContent":"<p>a passage here</p>"}}' },
            { code = 201, body = '{"id":"h1","note":null,"color":"yellow"}' },
        })

        assert.equals(1, result.value.created)

        local mapping = Metadata.highlightMap(BOOK)
        local fingerprint = Identity.fingerprint(annotation())
        assert.equals("h1", mapping[fingerprint].remote_id)
    end)

    it("creates two distinct highlights for the same text at two positions", function()
        -- The old text-keyed deduplication collapsed these into one.
        Helper.mocks.docsettings.seed(BOOK, {
            annotations = {
                annotation({ text = "repeated", pos0 = "p[1].0", pos1 = "p[1].8" }),
                annotation({ text = "repeated", pos0 = "p[9].0", pos1 = "p[9].8" }),
            },
        })

        local result = run({
            { code = 200, body = '{"highlights":[]}' },
            { code = 200, body = '{"content":{"htmlContent":"<p>repeated</p><p>repeated</p>"}}' },
            { code = 201, body = '{"id":"h1"}' },
            { code = 201, body = '{"id":"h2"}' },
        })

        assert.equals(2, result.value.created)

        local mapping = Metadata.highlightMap(BOOK)
        local ids = {}
        for _, record in pairs(mapping) do
            ids[record.remote_id] = true
        end
        assert.is_true(ids.h1 and ids.h2)
    end)

    it("brings a remote note back into the matching annotation", function()
        local a = annotation({ note = "original" })
        local fingerprint = Identity.fingerprint(a)

        Helper.mocks.docsettings.seed(BOOK, {
            annotations = { a },
            karabridge = {
                version = 2,
                highlights = {
                    [fingerprint] = {
                        remote_id = "h1",
                        local_hash = Identity.contentHash({ note = "original", color = "yellow" }),
                        remote_hash = Identity.contentHash({ note = "original", color = "yellow" }),
                    },
                },
            },
        })

        local result = run({
            { code = 200, body = '{"highlights":[{"id":"h1","note":"Edited on Karakeep","color":"yellow"}]}' },
        })

        assert.equals(1, result.value.pulled)

        local stored = Helper.mocks.docsettings.peek(BOOK).annotations
        assert.equals("Edited on Karakeep", stored[1].note)
    end)

    it("does not create a second annotation when pulling", function()
        local a = annotation({ note = "original" })
        local fingerprint = Identity.fingerprint(a)

        Helper.mocks.docsettings.seed(BOOK, {
            annotations = { a },
            karabridge = {
                version = 2,
                highlights = {
                    [fingerprint] = {
                        remote_id = "h1",
                        local_hash = Identity.contentHash({ note = "original", color = "yellow" }),
                        remote_hash = Identity.contentHash({ note = "original", color = "yellow" }),
                    },
                },
            },
        })

        run({ { code = 200, body = '{"highlights":[{"id":"h1","note":"changed","color":"yellow"}]}' } })

        assert.equals(1, #Helper.mocks.docsettings.peek(BOOK).annotations)
    end)

    it("leaves the passage itself untouched when pulling", function()
        local a = annotation({ note = "original" })
        local fingerprint = Identity.fingerprint(a)

        Helper.mocks.docsettings.seed(BOOK, {
            annotations = { a },
            karabridge = {
                version = 2,
                highlights = {
                    [fingerprint] = {
                        remote_id = "h1",
                        local_hash = Identity.contentHash({ note = "original", color = "yellow" }),
                        remote_hash = Identity.contentHash({ note = "original", color = "yellow" }),
                    },
                },
            },
        })

        run({ { code = 200, body = '{"highlights":[{"id":"h1","note":"changed","color":"yellow"}]}' } })

        local stored = Helper.mocks.docsettings.peek(BOOK).annotations[1]
        assert.equals("a passage", stored.text)
        assert.equals("lighten", stored.drawer)
        assert.equals(annotation().pos0, stored.pos0)
    end)

    it("records a conflict and changes neither side", function()
        local a = annotation({ note = "edited in KOReader" })
        local fingerprint = Identity.fingerprint(a)

        Helper.mocks.docsettings.seed(BOOK, {
            annotations = { a },
            karabridge = {
                version = 2,
                highlights = {
                    [fingerprint] = {
                        remote_id = "h1",
                        local_hash = Identity.contentHash({ note = "original", color = "yellow" }),
                        remote_hash = Identity.contentHash({ note = "original", color = "yellow" }),
                    },
                },
            },
        })

        local result, stub = run({
            { code = 200, body = '{"highlights":[{"id":"h1","note":"edited in Karakeep","color":"yellow"}]}' },
        })

        assert.equals(1, result.value.conflicts)
        assert.equals("edited in KOReader", Helper.mocks.docsettings.peek(BOOK).annotations[1].note)
        -- Only the fetch. No PATCH was sent.
        assert.equals(1, #stub.requests)

        local record = Metadata.highlightMap(BOOK)[fingerprint]
        assert.is_not_nil(record.conflict)
    end)

    it("keeps the local annotation when the remote highlight was deleted", function()
        -- The chosen deletion policy. Karakeep is not the system of record for
        -- something the user created in KOReader.
        local a = annotation({ note = "mine" })
        local fingerprint = Identity.fingerprint(a)

        Helper.mocks.docsettings.seed(BOOK, {
            annotations = { a },
            karabridge = {
                version = 2,
                highlights = {
                    [fingerprint] = {
                        remote_id = "gone",
                        local_hash = Identity.contentHash({ note = "mine", color = "yellow" }),
                        remote_hash = Identity.contentHash({ note = "mine", color = "yellow" }),
                    },
                },
            },
        })

        local result = run({ { code = 200, body = '{"highlights":[]}' } })

        assert.equals(1, result.value.remote_deleted)
        assert.equals(1, #Helper.mocks.docsettings.peek(BOOK).annotations)
        assert.equals("mine", Helper.mocks.docsettings.peek(BOOK).annotations[1].note)
        assert.is_true(Metadata.highlightMap(BOOK)[fingerprint].remote_deleted)
    end)

    it("adopts an unmapped remote highlight rather than duplicating it", function()
        -- The migration path: highlights pushed before mappings existed.
        Helper.mocks.docsettings.seed(BOOK, { annotations = { annotation({ text = "unique passage" }) } })

        local result, stub = run({
            { code = 200, body = '{"highlights":[{"id":"h1","text":"unique passage","note":"from Karakeep"}]}' },
        })

        assert.equals(1, result.value.adopted)
        assert.equals(0, result.value.created)
        assert.equals(1, #stub.requests, "adoption must not send anything")
    end)

    it("is idempotent: a second run with no changes does nothing", function()
        Helper.mocks.docsettings.seed(BOOK, { annotations = { annotation() } })

        run({
            { code = 200, body = '{"highlights":[]}' },
            { code = 200, body = '{"content":{"htmlContent":"<p>a passage</p>"}}' },
            { code = 201, body = '{"id":"h1","note":null,"color":"yellow"}' },
        })

        local second, stub = run({
            { code = 200, body = '{"highlights":[{"id":"h1","note":null,"color":"yellow"}]}' },
        })

        assert.equals(0, second.value.created)
        assert.equals(0, second.value.pushed)
        assert.equals(0, second.value.pulled)
        assert.equals(1, #stub.requests, "only the fetch")
    end)

    it("fails closed when the remote set cannot be read", function()
        Helper.mocks.docsettings.seed(BOOK, { annotations = { annotation() } })

        local result = run({ { code = 401, body = "" } })

        assert.equals(0, result.value.created)
        assert.equals(1, result.value.skipped)
    end)

    it("reports when the mapping could not be saved", function()
        Helper.mocks.docsettings.seed(BOOK, { annotations = { annotation() } })
        Helper.mocks.docsettings.makeUnwritable(BOOK)

        local result = run({
            { code = 200, body = '{"highlights":[]}' },
            { code = 200, body = '{"content":{"htmlContent":"<p>a passage</p>"}}' },
            { code = 201, body = '{"id":"h1"}' },
        })

        assert.is_false(result.value.mapping_saved)
    end)

    describe("stripChapter", function()
        it("removes the suffix this plugin adds", function()
            -- Otherwise every round trip appends the chapter again.
            assert.equals("my note", HighlightSync.stripChapter("my note\n\n(Chapter One)", "Chapter One"))
        end)

        it("leaves a note that does not end with it alone", function()
            assert.equals("my note", HighlightSync.stripChapter("my note", "Chapter One"))
        end)

        it("copes with no chapter", function()
            assert.equals("my note", HighlightSync.stripChapter("my note", nil))
        end)
    end)
end)

describe("HighlightSync mapping ownership", function()
    -- A mapping holds remote highlight IDs, and a Karakeep highlight belongs to
    -- exactly one bookmark. Delete a book's card in Karakeep and export again:
    -- the card is recreated under a new ID and its highlights died with the old
    -- one. Before this, the reconciliation read that as "the user deleted every
    -- highlight" and left the new card empty for good.
    before_each(function()
        Helper.install()
    end)

    after_each(function()
        Helper.uninstall()
    end)

    local function run(bookmark_id, responses)
        local client = Helper.client(responses)
        return HighlightSync.run({
            apis = { highlights = HighlightsApi.new(client), bookmarks = Bookmarks.new(client) },
            bookmark_id = bookmark_id,
            file_path = BOOK,
        })
    end

    it("records which bookmark the mapping was built against", function()
        Helper.mocks.docsettings.seed(BOOK, { annotations = { annotation() } })

        run("b1", {
            { code = 200, body = '{"highlights":[]}' },
            { code = 200, body = '{"content":{"htmlContent":"<p>a passage here</p>"}}' },
            { code = 201, body = '{"id":"h1","note":null,"color":"yellow"}' },
        })

        assert.equals("b1", Metadata.highlightMapOwner(BOOK))
    end)

    it("recreates the highlights when the bookmark has changed underneath it", function()
        Helper.mocks.docsettings.seed(BOOK, { annotations = { annotation() } })

        run("b1", {
            { code = 200, body = '{"highlights":[]}' },
            { code = 200, body = '{"content":{"htmlContent":"<p>a passage here</p>"}}' },
            { code = 201, body = '{"id":"h1","note":null,"color":"yellow"}' },
        })

        -- The card was deleted in Karakeep and recreated: new ID, no highlights.
        local result = run("b2", {
            { code = 200, body = '{"highlights":[]}' },
            { code = 200, body = '{"content":{"htmlContent":"<p>a passage here</p>"}}' },
            { code = 201, body = '{"id":"h2","note":null,"color":"yellow"}' },
        })

        assert.equals(1, result.value.created)
        assert.equals(0, result.value.remote_deleted)

        local mapping = Metadata.highlightMap(BOOK)
        assert.equals("h2", mapping[Identity.fingerprint(annotation())].remote_id)
        assert.equals("b2", Metadata.highlightMapOwner(BOOK))
    end)

    it("still reports a genuine remote deletion on the same bookmark", function()
        -- The distinction that matters: a highlight removed in Karakeep from a
        -- bookmark that still exists was removed on purpose, and resurrecting
        -- it would undo the user's action.
        Helper.mocks.docsettings.seed(BOOK, { annotations = { annotation() } })

        run("b1", {
            { code = 200, body = '{"highlights":[]}' },
            { code = 200, body = '{"content":{"htmlContent":"<p>a passage here</p>"}}' },
            { code = 201, body = '{"id":"h1","note":null,"color":"yellow"}' },
        })

        local result = run("b1", { { code = 200, body = '{"highlights":[]}' } })

        assert.equals(1, result.value.remote_deleted)
        assert.equals(0, result.value.created)
    end)
end)

describe("HighlightSync.fetchArticleText", function()
    -- Regression. This used to return HtmlCleaner.toText(html), which turns
    -- every tag into a space -- inserting characters Karakeep's DOM does not
    -- have and shifting every offset after the first block boundary. Doing the
    -- conversion here quietly undid the whole point of Offsets.domText.
    before_each(function()
        Helper.install()
    end)

    after_each(function()
        Helper.uninstall()
    end)

    it("returns the HTML untouched, for Offsets to convert", function()
        local client = Helper.client({
            { code = 200, body = '{"content":{"htmlContent":"<p>one</p><p>two</p>"}}' },
        })

        local text = HighlightSync.fetchArticleText(Bookmarks.new(client), "b1")

        assert.equals("<p>one</p><p>two</p>", text)
        assert.is_nil(text:find("one two", 1, true), "a separator must not have been inserted")
    end)

    it("returns the raw text of a text bookmark", function()
        local client = Helper.client({ { code = 200, body = '{"content":{"text":"# Heading\\n\\nBody"}}' } })

        assert.equals("# Heading\n\nBody", HighlightSync.fetchArticleText(Bookmarks.new(client), "b1"))
    end)

    it("returns nothing when the article cannot be fetched", function()
        local client = Helper.client({ { code = 404, body = "" } })
        assert.equals("", HighlightSync.fetchArticleText(Bookmarks.new(client), "b1"))
    end)

    it("produces the offsets Karakeep would, end to end", function()
        -- The block-boundary case, all the way through: two paragraphs, the
        -- second starting at 3 because the DOM has no separator.
        local Offsets = require("karabridge.features.article_sync.offsets")
        local client = Helper.client({
            { code = 200, body = '{"content":{"htmlContent":"<p>one</p><p>two</p>"}}' },
        })

        local html = HighlightSync.fetchArticleText(Bookmarks.new(client), "b1")

        assert.equals(3, Offsets.locate(html, "two"))
    end)
end)

describe("HighlightSync offset modes", function()
    -- A downloaded article's body contains the highlighted passage, so a
    -- highlight can point at it. A local book's card body is the user's own
    -- free-form text and deliberately does not, so there is nothing to point
    -- at and nothing to download.
    before_each(function()
        Helper.install()
    end)

    after_each(function()
        Helper.uninstall()
    end)

    local function run(mode, responses)
        local client, stub = Helper.client(responses)
        local result = HighlightSync.run({
            apis = { highlights = HighlightsApi.new(client), bookmarks = Bookmarks.new(client) },
            bookmark_id = "b1",
            file_path = BOOK,
            offset_mode = mode,
        })
        return result, stub
    end

    it("does not fetch the card body in detached mode", function()
        Helper.mocks.docsettings.seed(BOOK, { annotations = { annotation() } })

        local _, stub = run("detached", {
            { code = 200, body = '{"highlights":[]}' },
            { code = 201, body = '{"id":"h1","note":null,"color":"yellow"}' },
        })

        assert.equals(2, #stub.requests)
        for _, entry in ipairs(stub.requests) do
            assert.is_nil(entry.request.url:match("includeContent=true"))
        end
    end)

    it("sends neutral offsets in detached mode", function()
        Helper.mocks.docsettings.seed(BOOK, { annotations = { annotation() } })

        local _, stub = run("detached", {
            { code = 200, body = '{"highlights":[]}' },
            { code = 201, body = '{"id":"h1","note":null,"color":"yellow"}' },
        })

        local sent = Json.decode(stub.requests[2].request.body)
        assert.equals(0, sent.startOffset)
        assert.equals(0, sent.endOffset)
    end)

    it("does not count a detached highlight as an unresolved offset", function()
        -- Nothing failed to resolve; there was deliberately nothing to resolve.
        -- Counting it would make a healthy book export look broken.
        Helper.mocks.docsettings.seed(BOOK, { annotations = { annotation() } })

        local result = run("detached", {
            { code = 200, body = '{"highlights":[]}' },
            { code = 201, body = '{"id":"h1","note":null,"color":"yellow"}' },
        })

        assert.equals(1, result.value.created)
        assert.equals(0, result.value.unresolved)
    end)

    it("still records the remote ID, so later updates and pulls work", function()
        Helper.mocks.docsettings.seed(BOOK, { annotations = { annotation() } })

        run("detached", {
            { code = 200, body = '{"highlights":[]}' },
            { code = 201, body = '{"id":"h1","note":null,"color":"yellow"}' },
        })

        local mapping = Metadata.highlightMap(BOOK)
        assert.equals("h1", mapping[Identity.fingerprint(annotation())].remote_id)
        assert.equals("b1", Metadata.highlightMapOwner(BOOK))
    end)

    it("still locates the passage for an article", function()
        -- The article path is untouched: real offsets, from the real body.
        Helper.mocks.docsettings.seed(BOOK, { annotations = { annotation() } })

        local _, stub = run(nil, {
            { code = 200, body = '{"highlights":[]}' },
            { code = 200, body = '{"content":{"htmlContent":"<p>lead in</p><p>a passage here</p>"}}' },
            { code = 201, body = '{"id":"h1","note":null,"color":"yellow"}' },
        })

        -- The DOM text is "lead in" .. "a passage here" with no separator
        -- between the two paragraphs, so the passage runs 7..16.
        local sent = Json.decode(stub.requests[3].request.body)
        assert.equals(7, sent.startOffset)
        assert.equals(16, sent.endOffset)
    end)

    it("still counts an article passage it cannot find", function()
        Helper.mocks.docsettings.seed(BOOK, { annotations = { annotation() } })

        local result = run(nil, {
            { code = 200, body = '{"highlights":[]}' },
            { code = 200, body = '{"content":{"htmlContent":"<p>nothing like it</p>"}}' },
            { code = 201, body = '{"id":"h1","note":null,"color":"yellow"}' },
        })

        assert.equals(1, result.value.unresolved)
    end)
end)
