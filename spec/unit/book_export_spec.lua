local Helper = require("spec.support.helper")

local AssetsApi = require("karabridge.api.assets")
local BookCardBody = require("karabridge.formats.book_card_body")
local Bookmarks = require("karabridge.api.bookmarks")
local Card = require("karabridge.features.book_export.card")
local CoverModule = require("karabridge.features.book_export.cover")
local HighlightsApi = require("karabridge.api.highlights")
local Json = require("karabridge.shared.json")
local Lists = require("karabridge.api.lists")
local Metadata = require("karabridge.shared.metadata")

-- The shape exporter.koplugin/clip.lua builds: numeric keys are chapters, each
-- an array of clippings, with the book metadata as string keys alongside.
local function book(overrides)
    local base = {
        title = "A Novel",
        author = "A. Writer",
        file = "/books/novel.epub",
        number_of_pages = 312,
        {
            {
                text = "The first passage.",
                note = "why it matters",
                chapter = "Chapter One",
                page = 12,
                time = 1700000000,
                drawer = "lighten",
            },
        },
        {
            {
                text = "The second passage.",
                chapter = "Chapter Two",
                page = 88,
                time = 1700000100,
                drawer = "lighten",
            },
        },
    }

    for key, value in pairs(overrides or {}) do
        base[key] = value
    end

    return base
end

--- The sidecar annotations matching the book above.
local function annotations()
    return {
        {
            drawer = "lighten",
            text = "The first passage.",
            note = "why it matters",
            chapter = "Chapter One",
            datetime = "2026-08-02 17:00:00",
            pos0 = "p1.0",
            pos1 = "p1.18",
        },
        {
            drawer = "lighten",
            text = "The second passage.",
            chapter = "Chapter Two",
            datetime = "2026-08-02 17:01:00",
            pos0 = "p2.0",
            pos1 = "p2.19",
        },
    }
end

--- Every request the stub saw, as "METHOD url".
local function trace(stub)
    local lines = {}
    for _, entry in ipairs(stub.requests) do
        table.insert(lines, entry.request.method .. " " .. entry.request.url)
    end
    return table.concat(lines, "\n")
end

--- Bodies of every PATCH sent to a *bookmark*, decoded.
--
-- Scoped to bookmarks deliberately: a highlight update is a PATCH too, and it
-- is exactly what should still be happening. The invariant under test is that
-- the card itself is never patched.
local function patches(stub)
    local found = {}
    for _, entry in ipairs(stub.requests) do
        local request = entry.request
        if request.method == "PATCH" and request.body and request.url:match("/bookmarks/") then
            table.insert(found, (Json.decode(request.body)))
        end
    end
    return found
end

describe("BookCardBody", function()
    describe("initial", function()
        it("says the card is the user's to edit", function()
            assert.matches("yours to edit", BookCardBody.initial())
        end)

        it("offers headings to start from", function()
            local body = BookCardBody.initial()
            assert.matches("## Notes", body)
            assert.matches("## Summary", body)
            assert.matches("## Questions and connections", body)
        end)

        it("carries nothing derived from the annotations", function()
            -- The whole point of the change. A body containing the passages
            -- would have to be regenerated when they change, and regenerating
            -- it is what destroyed the user's own writing.
            local body = BookCardBody.initial()
            assert.is_nil(body:find("passage", 1, true))
            assert.is_nil(body:find("Chapter", 1, true))
            assert.is_nil(body:find("page ", 1, true))
            assert.is_nil(body:find("why it matters", 1, true))
            assert.is_nil(body:find("yellow", 1, true))
            assert.is_nil(body:find(">", 1, true))
        end)

        it("hides no managed-section markers in it", function()
            -- A delimited "KaraBridge owns this part" region is the same
            -- problem with a smaller footprint: the user still cannot edit
            -- freely, and a stray keystroke still loses data.
            local body = BookCardBody.initial()
            assert.is_nil(body:find("<!--", 1, true))
            assert.is_nil(body:find("karabridge", 1, true))
            assert.is_nil(body:find("KaraBridge:", 1, true))
        end)
    end)

    describe("cardTitle", function()
        it("combines title and author", function()
            assert.matches("^A Novel", BookCardBody.cardTitle(book()))
            assert.matches("A. Writer$", BookCardBody.cardTitle(book()))
        end)

        it("joins several authors onto one line", function()
            assert.matches("One, Two$", BookCardBody.cardTitle(book({ author = "One\nTwo" })))
        end)

        it("uses the title alone when the author is unknown", function()
            assert.equals("A Novel", BookCardBody.cardTitle(book({ author = "N/A" })))
            assert.equals("A Novel", BookCardBody.cardTitle(book({ author = "" })))
        end)

        it("falls back to Untitled", function()
            assert.equals("Untitled", BookCardBody.cardTitle({ author = "" }))
        end)
    end)
end)

describe("book_export.Card creating a card", function()
    before_each(function()
        Helper.install()
    end)

    after_each(function()
        Helper.uninstall()
    end)

    local function card(responses, settings_values)
        local client, stub = Helper.client(responses)
        return Card.new({
            bookmarks = Bookmarks.new(client),
            lists = Lists.new(client),
            settings = Helper.settings(settings_values),
        }),
            stub
    end

    it("creates exactly one text bookmark and stores its ID", function()
        Helper.mocks.docsettings.seed("/books/novel.epub", {})

        local c, stub = card({ { code = 201, body = '{"id":"card1"}' } })
        local result = c:export(book())

        assert.equals("created", result.value.action)
        assert.equals("card1", result.value.bookmark_id)
        assert.equals("card1", Metadata.getBookCardId("/books/novel.epub"))

        local creates = 0
        for _, entry in ipairs(stub.requests) do
            if entry.request.method == "POST" and entry.request.url:match("/bookmarks$") then
                creates = creates + 1
            end
        end
        assert.equals(1, creates)
    end)

    it("gives the new card the editable workspace body", function()
        Helper.mocks.docsettings.seed("/books/novel.epub", { annotations = annotations() })

        local c, stub = card({ { code = 201, body = '{"id":"card1"}' } })
        c:export(book())

        local body = Json.decode(stub.requests[1].request.body)
        assert.equals(BookCardBody.initial(), body.text)
        assert.equals("text", body.type)
        assert.matches("yours to edit", body.text)
    end)

    it("puts no annotation content in that body", function()
        Helper.mocks.docsettings.seed("/books/novel.epub", { annotations = annotations() })

        local c, stub = card({ { code = 201, body = '{"id":"card1"}' } })
        c:export(book())

        local text = Json.decode(stub.requests[1].request.body).text
        assert.is_nil(text:find("The first passage.", 1, true))
        assert.is_nil(text:find("The second passage.", 1, true))
        assert.is_nil(text:find("why it matters", 1, true))
        assert.is_nil(text:find("Chapter One", 1, true))
        assert.is_nil(text:find("Chapter Two", 1, true))
        assert.is_nil(text:find("page 12", 1, true))
        assert.is_nil(text:find("88", 1, true))
    end)

    it("writes no body-content hash", function()
        Helper.mocks.docsettings.seed("/books/novel.epub", {})

        card({ { code = 201, body = '{"id":"card1"}' } }):export(book())

        local stored = Helper.mocks.docsettings.peek("/books/novel.epub").karabridge.book_card
        assert.equals("card1", stored.bookmark_id)
        assert.is_nil(stored.content_hash)
    end)

    it("titles the card from the book", function()
        Helper.mocks.docsettings.seed("/books/novel.epub", {})

        local c, stub = card({ { code = 201, body = '{"id":"card1"}' } })
        c:export(book())

        assert.matches("A Novel", Json.decode(stub.requests[1].request.body).title)
    end)

    it("refuses a book with no file path", function()
        assert.equals("no_file", card({}):export({ title = "x" }):errorCode())
    end)

    it("reports a create that returns no ID", function()
        Helper.mocks.docsettings.seed("/books/novel.epub", {})

        local c = card({ { code = 201, body = "{}" } })
        assert.equals("no_bookmark_id", c:export(book()):errorCode())
    end)

    describe("tags and lists", function()
        it("tags and files a newly created card", function()
            Helper.mocks.docsettings.seed("/books/novel.epub", {})

            local client, stub = Helper.client({
                { code = 201, body = '{"id":"card1"}' }, -- create
                { code = 200, body = "{}" }, -- attach tag
                { code = 200, body = '{"lists":[{"id":"l1","name":"KOReader Books"}]}' },
                { code = 204, body = "" }, -- add to list
            })
            local c = Card.new({
                bookmarks = Bookmarks.new(client),
                lists = Lists.new(client),
                settings = Helper.settings({ book_tag = "koreader", book_list = "KOReader Books" }),
            })

            c:export(book())

            assert.matches("POST .*/bookmarks/card1/tags", trace(stub))
            assert.matches("PUT .*/lists/l1/bookmarks/card1", trace(stub))
        end)

        it("still succeeds when the list does not exist", function()
            -- The card carries the highlights, which is the point. Failing the
            -- whole export over a missing list would be a poor trade.
            Helper.mocks.docsettings.seed("/books/novel.epub", {})

            local c = card({
                { code = 201, body = '{"id":"card1"}' },
                { code = 200, body = '{"lists":[]}' },
            }, { book_list = "Nope" })

            assert.equals("created", c:export(book()).value.action)
        end)
    end)
end)

describe("book_export.Card leaving an existing card alone", function()
    -- The core invariant of the whole model: a user can write in the card and
    -- KaraBridge never touches what they wrote.
    before_each(function()
        Helper.install()
    end)

    after_each(function()
        Helper.uninstall()
    end)

    local USER_BODY = "# My own notes\n\nThis text must survive.\n"

    local function existing(responses, opts)
        opts = opts or {}
        Helper.mocks.docsettings.seed("/books/novel.epub", {
            annotations = opts.annotations or annotations(),
            karabridge = {
                version = 2,
                book_card = opts.book_card or { bookmark_id = "card1" },
                highlights_bookmark_id = opts.owner,
                highlights = opts.mapping,
            },
        })

        local client, stub = Helper.client(responses)
        return Card.new({
            bookmarks = Bookmarks.new(client),
            highlights = HighlightsApi.new(client),
            settings = Helper.settings(),
        }),
            stub
    end

    it("checks that the card is still there without downloading it", function()
        local c, stub = existing({
            { code = 200, body = '{"id":"card1"}' }, -- the existence check
            { code = 200, body = '{"highlights":[]}' },
            { code = 201, body = '{"id":"h1"}' },
            { code = 201, body = '{"id":"h2"}' },
        })

        local result = c:export(book())

        assert.equals("kept", result.value.action)
        assert.equals("card1", result.value.bookmark_id)
        assert.matches("GET .*/bookmarks/card1%?", trace(stub))
        assert.matches("includeContent=false", stub.requests[1].request.url)
    end)

    it("sends no bookmark patch at all", function()
        local c, stub = existing({
            { code = 200, body = '{"id":"card1","content":{"text":"' .. USER_BODY:gsub("\n", "\\n") .. '"}}' },
            { code = 200, body = '{"highlights":[]}' },
            { code = 201, body = '{"id":"h1"}' },
            { code = 201, body = '{"id":"h2"}' },
        })

        c:export(book())

        assert.equals(0, #patches(stub))
    end)

    it("never sends text, title, note or summary for an existing card", function()
        local c, stub = existing({
            { code = 200, body = '{"id":"card1"}' },
            { code = 200, body = '{"highlights":[]}' },
            { code = 201, body = '{"id":"h1"}' },
            { code = 201, body = '{"id":"h2"}' },
        })

        c:export(book())

        for _, entry in ipairs(stub.requests) do
            if entry.request.body and entry.request.url:match("/bookmarks/card1$") then
                local sent = Json.decode(entry.request.body) or {}
                assert.is_nil(sent.text)
                assert.is_nil(sent.title)
                assert.is_nil(sent.note)
                assert.is_nil(sent.summary)
            end
        end
    end)

    it("still creates the highlights against the existing card", function()
        local c, stub = existing({
            { code = 200, body = '{"id":"card1"}' },
            { code = 200, body = '{"highlights":[]}' },
            { code = 201, body = '{"id":"h1"}' },
            { code = 201, body = '{"id":"h2"}' },
        })

        local result = c:export(book())

        assert.equals(2, result.value.highlights.created)
        for _, entry in ipairs(stub.requests) do
            if entry.request.method == "POST" and entry.request.url:match("/highlights$") then
                assert.equals("card1", Json.decode(entry.request.body).bookmarkId)
            end
        end
    end)

    it("ignores a content hash left by an older version", function()
        -- Old sidecars carry one. It must not make anything rewrite the body,
        -- and it must not be treated as a reason to create a second card.
        local c, stub = existing({
            { code = 200, body = '{"id":"card1"}' },
            { code = 200, body = '{"highlights":[]}' },
            { code = 201, body = '{"id":"h1"}' },
            { code = 201, body = '{"id":"h2"}' },
        }, { book_card = { bookmark_id = "card1", content_hash = "a-hash-from-0.5" } })

        local result = c:export(book())

        assert.equals("kept", result.value.action)
        assert.equals(0, #patches(stub))
        assert.equals(2, result.value.highlights.created)
        assert.is_nil(trace(stub):match("POST .*/bookmarks\n"))
    end)

    it("leaves that old hash in the sidecar rather than deleting it", function()
        -- Non-destructive: the field is inert, not purged.
        local c = existing({
            { code = 200, body = '{"id":"card1"}' },
            { code = 200, body = '{"highlights":[]}' },
            { code = 201, body = '{"id":"h1"}' },
            { code = 201, body = '{"id":"h2"}' },
        }, { book_card = { bookmark_id = "card1", content_hash = "a-hash-from-0.5" } })

        c:export(book())

        local stored = Helper.mocks.docsettings.peek("/books/novel.epub").karabridge.book_card
        assert.equals("a-hash-from-0.5", stored.content_hash)
    end)

    it("pulls a note edited in Karakeep without touching the card", function()
        local Identity = require("karabridge.features.article_sync.identity")
        local Reconcile = require("karabridge.features.article_sync.reconcile")
        local first = annotations()[1]

        local c, stub = existing({
            { code = 200, body = '{"id":"card1"}' },
            {
                code = 200,
                body = '{"highlights":[{"id":"h1","note":"Edited on Karakeep","color":"yellow"}]}',
            },
            { code = 201, body = '{"id":"h2"}' },
        }, {
            annotations = { first },
            owner = "card1",
            mapping = {
                [Identity.fingerprint(first)] = {
                    remote_id = "h1",
                    -- Local side unchanged since the last sync...
                    local_hash = Identity.contentHash(Reconcile.localFields(first)),
                    -- ...and the remote note is not what we last sent, so the
                    -- change came from Karakeep.
                    remote_hash = Identity.contentHash({
                        note = "why it matters\n\n(Chapter One)",
                        color = "yellow",
                    }),
                },
            },
        })

        local result = c:export(book())

        assert.equals("kept", result.value.action)
        assert.equals(1, result.value.highlights.pulled)
        assert.equals(0, #patches(stub))
        assert.equals(
            "Edited on Karakeep",
            Helper.mocks.docsettings.peek("/books/novel.epub").annotations[1].note
        )
    end)

    it("does not recreate the card on an answer that is not 404", function()
        -- A timeout or a 500 means try again later. Creating a second card
        -- would duplicate the book and orphan every highlight on the first.
        local c = existing({
            { code = 500, body = "" },
            { code = 500, body = "" },
            { code = 500, body = "" },
        })

        local result = c:export(book())

        assert.is_true(result:isErr())
        assert.equals("card1", Metadata.getBookCardId("/books/novel.epub"))
    end)

    it("does not recreate the card when the key is rejected", function()
        local c = existing({ { code = 401, body = "" } })

        local result = c:export(book())

        assert.equals("unauthorized", result:errorCode())
        assert.equals("card1", Metadata.getBookCardId("/books/novel.epub"))
    end)

    it("keeps a card adopted from a legacy record, body and title untouched", function()
        Helper.mocks.docsettings.seed("/books/legacy.epub", {
            annotations = {},
            karakeep = { bookmark = { id = "legacy1" } },
        })

        local client, stub = Helper.client({ { code = 200, body = '{"id":"legacy1"}' } })
        local c = Card.new({ bookmarks = Bookmarks.new(client), settings = Helper.settings() })

        local result = c:export(book({ file = "/books/legacy.epub" }))

        assert.equals("kept", result.value.action)
        assert.equals("legacy1", result.value.bookmark_id)
        assert.equals(0, #patches(stub))
        assert.is_nil(trace(stub):match("POST"))
    end)
end)

describe("book_export.Card with a book that has no highlights", function()
    before_each(function()
        Helper.install()
    end)

    after_each(function()
        Helper.uninstall()
    end)

    local EMPTY = { title = "Blank", author = "Nobody", file = "/books/blank.epub" }

    it("still creates a card", function()
        Helper.mocks.docsettings.seed("/books/blank.epub", { annotations = {} })

        local client = Helper.client({ { code = 201, body = '{"id":"card1"}' } })
        local c = Card.new({
            bookmarks = Bookmarks.new(client),
            highlights = HighlightsApi.new(client),
            settings = Helper.settings(),
        })

        assert.equals("created", c:export(EMPTY).value.action)
    end)

    it("detects a deleted card without asking about highlights", function()
        -- The old existence probe was the highlights endpoint, which cannot
        -- answer for a book that has none: the sync returns before making any
        -- request at all, so the deletion went unnoticed for good.
        Helper.mocks.docsettings.seed("/books/blank.epub", {
            annotations = {},
            karabridge = { version = 2, book_card = { bookmark_id = "gone" } },
        })

        local client, stub = Helper.client({
            { code = 404, body = '{"error":"not found"}' }, -- the existence check
            { code = 201, body = '{"id":"fresh"}' },
        })
        local c = Card.new({
            bookmarks = Bookmarks.new(client),
            highlights = HighlightsApi.new(client),
            settings = Helper.settings(),
        })

        local result = c:export(EMPTY)

        assert.equals("recreated", result.value.action)
        assert.equals("fresh", result.value.bookmark_id)
        assert.is_nil(trace(stub):match("/highlights"))
    end)
end)

describe("book_export.Card recreating a deleted card", function()
    local Identity = require("karabridge.features.article_sync.identity")

    before_each(function()
        Helper.install()
    end)

    after_each(function()
        Helper.uninstall()
    end)

    local function seeded()
        local first = annotations()[1]
        Helper.mocks.docsettings.seed("/books/novel.epub", {
            annotations = { first },
            karabridge = {
                version = 2,
                book_card = { bookmark_id = "old", content_hash = "stale" },
                highlights_bookmark_id = "old",
                highlights = {
                    [Identity.fingerprint(first)] = {
                        remote_id = "dead",
                        local_hash = "x",
                        remote_hash = "x",
                    },
                },
            },
        })
    end

    local function card(responses)
        local client, stub = Helper.client(responses)
        return Card.new({
            bookmarks = Bookmarks.new(client),
            highlights = HighlightsApi.new(client),
            settings = Helper.settings(),
        }),
            stub
    end

    it("creates a new card after a confirmed 404 and keeps the annotations", function()
        seeded()

        local c = card({
            { code = 404, body = '{"error":"not found"}' },
            { code = 201, body = '{"id":"new"}' },
            { code = 200, body = '{"highlights":[]}' },
            { code = 201, body = '{"id":"h1"}' },
        })

        local result = c:export(book())

        assert.equals("recreated", result.value.action)
        assert.equals("new", result.value.bookmark_id)
        assert.equals("new", Metadata.getBookCardId("/books/novel.epub"))
        assert.equals(1, #Helper.mocks.docsettings.peek("/books/novel.epub").annotations)
    end)

    it("invalidates the old mapping and re-creates the highlights under the new ID", function()
        -- The old remote IDs died with the old card. Treating them as
        -- deliberately deleted would leave the new card empty for good.
        seeded()

        local c, stub = card({
            { code = 404, body = '{"error":"not found"}' },
            { code = 201, body = '{"id":"new"}' },
            { code = 200, body = '{"highlights":[]}' },
            { code = 201, body = '{"id":"h1"}' },
        })

        local result = c:export(book())

        assert.equals(1, result.value.highlights.created)
        assert.equals(0, result.value.highlights.remote_deleted)
        assert.equals("new", Metadata.highlightMapOwner("/books/novel.epub"))

        for _, entry in ipairs(stub.requests) do
            if entry.request.method == "POST" and entry.request.url:match("/highlights$") then
                assert.equals("new", Json.decode(entry.request.body).bookmarkId)
            end
        end

        for _, record in pairs(Metadata.highlightMap("/books/novel.epub")) do
            assert.is_true(record.remote_id ~= "dead")
        end
    end)

    it("gives the replacement the neutral body, not a copy of the highlights", function()
        seeded()

        local c, stub = card({
            { code = 404, body = '{"error":"not found"}' },
            { code = 201, body = '{"id":"new"}' },
            { code = 200, body = '{"highlights":[]}' },
            { code = 201, body = '{"id":"h1"}' },
        })

        c:export(book())

        local created = Json.decode(stub.requests[2].request.body)
        assert.equals(BookCardBody.initial(), created.text)
        assert.is_nil(created.text:find("The first passage.", 1, true))
    end)
end)

describe("book_export.Card exporting twice", function()
    local Identity = require("karabridge.features.article_sync.identity")

    before_each(function()
        Helper.install()
        CoverModule.setReader(function()
            return "\255\216\255\224" .. string.rep("j", 40)
        end)
    end)

    after_each(function()
        CoverModule.setReader(nil)
        Helper.uninstall()
    end)

    local function card(responses)
        local client, stub = Helper.client(responses)
        return Card.new({
            bookmarks = Bookmarks.new(client),
            highlights = HighlightsApi.new(client),
            assets = AssetsApi.new(client),
            settings = Helper.settings(),
        }),
            stub
    end

    it("keeps one bookmark, adds no highlights, patches nothing, re-uploads nothing", function()
        Helper.mocks.docsettings.seed("/books/novel.epub", { annotations = annotations() })

        card({
            { code = 201, body = '{"id":"card1"}' }, -- create
            { code = 200, body = '{"highlights":[]}' },
            { code = 201, body = '{"id":"h1","note":null,"color":"yellow"}' },
            { code = 201, body = '{"id":"h2","note":null,"color":"yellow"}' },
            { code = 201, body = '{"assetId":"a1"}' }, -- cover upload
            { code = 201, body = '{"id":"a1"}' }, -- cover attach
        }):export(book())

        local again, stub = card({
            { code = 200, body = '{"id":"card1"}' }, -- existence check
            {
                code = 200,
                body = '{"highlights":[{"id":"h1","note":null,"color":"yellow"},'
                    .. '{"id":"h2","note":null,"color":"yellow"}]}',
            },
        })

        local result = again:export(book())

        assert.equals("kept", result.value.action)
        assert.equals("card1", result.value.bookmark_id)
        assert.equals(0, result.value.highlights.created)
        assert.equals(0, #patches(stub))
        assert.is_nil(result.value.cover)
        assert.is_nil(trace(stub):match("POST .*/assets"))
        assert.is_nil(trace(stub):match("POST .*/bookmarks\n"))
    end)

    it("still pushes a note the reader changed locally", function()
        local first = annotations()[1]
        local fingerprint = Identity.fingerprint(first)

        Helper.mocks.docsettings.seed("/books/novel.epub", {
            annotations = { first },
            karabridge = {
                version = 2,
                book_card = { bookmark_id = "card1" },
                highlights_bookmark_id = "card1",
                highlights = {
                    [fingerprint] = {
                        remote_id = "h1",
                        -- Recorded before the reader edited the note, so the
                        -- local side reads as changed and the remote does not.
                        local_hash = Identity.contentHash({ note = "old note", color = "yellow" }),
                        remote_hash = Identity.contentHash({ note = "old note", color = "yellow" }),
                    },
                },
            },
        })

        local c, stub = card({
            { code = 200, body = '{"id":"card1"}' },
            { code = 200, body = '{"highlights":[{"id":"h1","note":"old note","color":"yellow"}]}' },
            { code = 200, body = '{"id":"h1"}' },
        })

        local result = c:export(book())

        assert.equals(1, result.value.highlights.pushed)
        assert.matches("/highlights/h1", trace(stub))
        assert.equals(0, #patches(stub))
    end)
end)

describe("book_export.Card and downloaded articles", function()
    -- A file KaraBridge downloaded is already a Karakeep bookmark. Exporting it
    -- as a book made a second, worse copy of it -- mangled title, no source
    -- URL, no tags -- and repointed the highlight mapping from the article at
    -- that copy, orphaning the highlights already on the article.
    before_each(function()
        Helper.install()
    end)

    after_each(function()
        Helper.uninstall()
    end)

    local ARTICLE = "/downloads/[kb-id_b1] An Article.epub"

    it("does not make a card for an article it downloaded", function()
        Helper.mocks.docsettings.seed(ARTICLE, {
            annotations = { { drawer = "lighten", text = "A passage.", datetime = "2026-08-02 17:00:00" } },
            karabridge = { version = 2, article = { bookmark_id = "b1" } },
        })

        local client, stub = Helper.client({})
        local c = Card.new({
            bookmarks = Bookmarks.new(client),
            highlights = HighlightsApi.new(client),
            settings = Helper.settings(),
        })

        local result = c:export(book({ file = ARTICLE }))

        assert.equals("article", result.value.action)
        assert.equals("b1", result.value.bookmark_id)
        assert.equals(0, #stub.requests)
    end)

    it("leaves the article's own highlight mapping pointing at the article", function()
        Helper.mocks.docsettings.seed(ARTICLE, {
            annotations = {},
            karabridge = {
                version = 2,
                article = { bookmark_id = "b1" },
                highlights_bookmark_id = "b1",
            },
        })

        local client = Helper.client({})
        Card.new({ bookmarks = Bookmarks.new(client), settings = Helper.settings() })
            :export(book({ file = ARTICLE }))

        assert.equals("b1", Metadata.highlightMapOwner(ARTICLE))
        assert.is_nil(Metadata.getBookCardId(ARTICLE))
    end)

    it("says so in the summary rather than reporting a silent no-op", function()
        Helper.mocks.docsettings.seed(ARTICLE, {
            annotations = {},
            karabridge = { version = 2, article = { bookmark_id = "b1" } },
        })

        local client = Helper.client({})
        local c = Card.new({ bookmarks = Bookmarks.new(client), settings = Helper.settings() })

        local summary = c:exportAll({ book({ file = ARTICLE }) })

        assert.equals(1, summary.article)
        assert.matches("were articles from Karakeep", table.concat(Card.summarise(summary), "\n"))
    end)
end)

describe("book_export.Card recovery journal", function()
    -- The failure this guards: the card is created, the sidecar write fails,
    -- and the next export creates a *second* card because nothing remembers
    -- the first. The remote side succeeded; only the record of it was lost.
    local Recovery = require("karabridge.shared.recovery")

    before_each(function()
        Helper.install()
    end)

    after_each(function()
        Helper.uninstall()
    end)

    local function cardWithRecovery(responses, journal)
        local client, stub = Helper.client(responses)
        return Card.new({
            bookmarks = Bookmarks.new(client),
            lists = Lists.new(client),
            settings = Helper.settings(),
            recovery = journal,
        }),
            stub
    end

    it("journals the remote ID when the sidecar write fails", function()
        Helper.mocks.docsettings.seed("/books/novel.epub", {})
        Helper.mocks.docsettings.makeUnwritable("/books/novel.epub")

        local journal = Recovery.new({ store = Helper.mocks.luasettings.new() })
        local result = cardWithRecovery({ { code = 201, body = '{"id":"card1"}' } }, journal):export(book())

        assert.is_true(result:isOk())
        assert.is_true(result.value.mapping_lost)
        assert.equals("card1", journal:lookup("book_card", "/books/novel.epub"))
    end)

    it("adopts the journalled ID instead of creating a duplicate", function()
        local journal = Recovery.new({ store = Helper.mocks.luasettings.new() })
        journal:record("book_card", "/books/novel.epub", "card1")

        Helper.mocks.docsettings.seed("/books/novel.epub", {})

        -- Only the existence check is stubbed. A create would consume this
        -- response and the assertion on the action would fail.
        local c, stub = cardWithRecovery({ { code = 200, body = '{"id":"card1"}' } }, journal)
        local result = c:export(book())

        assert.equals("kept", result.value.action)
        assert.equals("card1", result.value.bookmark_id)
        assert.is_nil(trace(stub):match("POST"))
    end)

    it("clears the journal once the mapping is written", function()
        local journal = Recovery.new({ store = Helper.mocks.luasettings.new() })
        journal:record("book_card", "/books/novel.epub", "card1")

        Helper.mocks.docsettings.seed("/books/novel.epub", {})
        -- Gone from Karakeep, so it is recreated and the new ID is persisted.
        cardWithRecovery({
            { code = 404, body = "" },
            { code = 201, body = '{"id":"card2"}' },
        }, journal):export(book())

        assert.is_nil(journal:lookup("book_card", "/books/novel.epub"))
    end)

    it("counts a lost mapping separately from a failure", function()
        -- The card exists, so this is not a failure -- but it is not a clean
        -- success either, and the summary has to say so.
        Helper.mocks.docsettings.seed("/books/a.epub", {})
        Helper.mocks.docsettings.makeUnwritable("/books/a.epub")

        local journal = Recovery.new({ store = Helper.mocks.luasettings.new() })
        local c = cardWithRecovery({ { code = 201, body = '{"id":"c1"}' } }, journal)
        local summary = c:exportAll({ book({ file = "/books/a.epub" }) })

        assert.equals(1, summary.created)
        assert.equals(0, summary.failed)
        assert.equals(1, summary.mapping_lost)
        assert.matches("could not be saved", table.concat(Card.summarise(summary), "\n"))
    end)

    it("survives having no journal at all", function()
        Helper.mocks.docsettings.seed("/books/novel.epub", {})
        local c = Card.new({
            bookmarks = Bookmarks.new(Helper.client({ { code = 201, body = '{"id":"c1"}' } })),
            settings = Helper.settings(),
        })

        assert.is_true(c:export(book()):isOk())
    end)
end)

describe("book_export.Card highlights", function()
    before_each(function()
        Helper.install()
    end)

    after_each(function()
        Helper.uninstall()
    end)

    local function cardWith(responses)
        local client, stub = Helper.client(responses)
        return Card.new({
            bookmarks = Bookmarks.new(client),
            highlights = HighlightsApi.new(client),
            settings = Helper.settings(),
        }),
            stub
    end

    it("attaches every annotation to the one new card", function()
        Helper.mocks.docsettings.seed("/books/novel.epub", { annotations = annotations() })

        local c, stub = cardWith({
            { code = 201, body = '{"id":"card1"}' },
            { code = 200, body = '{"highlights":[]}' },
            { code = 201, body = '{"id":"h1"}' },
            { code = 201, body = '{"id":"h2"}' },
        })

        local result = c:export(book())

        assert.equals(2, result.value.highlights.created)

        local owners = {}
        for _, entry in ipairs(stub.requests) do
            if entry.request.method == "POST" and entry.request.url:match("/highlights$") then
                table.insert(owners, Json.decode(entry.request.body).bookmarkId)
            end
        end
        assert.same({ "card1", "card1" }, owners)
    end)

    it("sends the passage text and the chapter as the note", function()
        Helper.mocks.docsettings.seed("/books/novel.epub", { annotations = { annotations()[1] } })

        local c, stub = cardWith({
            { code = 201, body = '{"id":"card1"}' },
            { code = 200, body = '{"highlights":[]}' },
            { code = 201, body = '{"id":"h1"}' },
        })

        c:export(book())

        local sent = Json.decode(stub.requests[3].request.body)
        assert.equals("The first passage.", sent.text)
        assert.matches("Chapter One", sent.note)
    end)

    it("still writes the card when no highlights API was given", function()
        Helper.mocks.docsettings.seed("/books/novel.epub", { annotations = annotations() })

        local client = Helper.client({ { code = 201, body = '{"id":"card1"}' } })
        local c = Card.new({ bookmarks = Bookmarks.new(client), settings = Helper.settings() })

        local result = c:export(book())

        assert.equals("created", result.value.action)
        assert.is_nil(result.value.highlights)
    end)

    it("reports the highlight counts in the summary", function()
        Helper.mocks.docsettings.seed("/books/a.epub", { annotations = { annotations()[1] } })

        local c = cardWith({
            { code = 201, body = '{"id":"c1"}' },
            { code = 200, body = '{"highlights":[]}' },
            { code = 201, body = '{"id":"h1"}' },
        })

        local summary = c:exportAll({ book({ file = "/books/a.epub" }) })

        assert.equals(1, summary.highlights_created)
        assert.matches("Attached 1 highlight", table.concat(Card.summarise(summary), "\n"))
    end)
end)

describe("book_export.Card and the cover", function()
    local JPEG = "\255\216\255\224" .. string.rep("j", 40)

    before_each(function()
        Helper.install()
        CoverModule.setReader(function()
            return JPEG
        end)
    end)

    after_each(function()
        CoverModule.setReader(nil)
        Helper.uninstall()
    end)

    local function cardWith(responses)
        local client, stub = Helper.client(responses)
        return Card.new({
            bookmarks = Bookmarks.new(client),
            assets = AssetsApi.new(client),
            settings = Helper.settings(),
        }),
            stub
    end

    it("uploads the cover and records the asset so the next export skips it", function()
        Helper.mocks.docsettings.seed("/books/novel.epub", { annotations = {} })

        local c = cardWith({
            { code = 201, body = '{"id":"card1"}' },
            { code = 201, body = '{"assetId":"a1"}' },
            { code = 201, body = '{"id":"a1"}' },
        })

        local result = c:export(book())

        assert.equals("uploaded", result.value.cover)
        assert.equals("a1", Metadata.read("/books/novel.epub").book_card.cover.asset_id)
    end)

    it("does not fail the export when the cover cannot be uploaded", function()
        -- A card without its picture is worth far more than a failed export.
        Helper.mocks.docsettings.seed("/books/novel.epub", { annotations = {} })

        local c = cardWith({
            { code = 201, body = '{"id":"card1"}' },
            { code = 500, body = '{"error":"nope"}' },
        })

        local result = c:export(book())

        assert.is_true(result:isOk())
        assert.equals("created", result.value.action)
        assert.is_nil(result.value.cover)
    end)

    it("leaves the cover alone when the setting is off", function()
        Helper.mocks.docsettings.seed("/books/novel.epub", { annotations = {} })

        local client, stub = Helper.client({ { code = 201, body = '{"id":"card1"}' } })
        local settings = Helper.settings()
        settings:set("upload_book_cover", false)

        local c = Card.new({
            bookmarks = Bookmarks.new(client),
            assets = AssetsApi.new(client),
            settings = settings,
        })

        c:export(book({ file = "/books/novel.epub" }))

        assert.equals(1, #stub.requests)
    end)
end)

describe("book_export.Card exportAll and summarise", function()
    before_each(function()
        Helper.install()
    end)

    after_each(function()
        Helper.uninstall()
    end)

    local function card(responses)
        local client = Helper.client(responses)
        return Card.new({
            bookmarks = Bookmarks.new(client),
            lists = Lists.new(client),
            settings = Helper.settings(),
        })
    end

    it("counts each outcome", function()
        Helper.mocks.docsettings.seed("/books/a.epub", {})
        Helper.mocks.docsettings.seed("/books/b.epub", {})

        local c = card({
            { code = 201, body = '{"id":"c1"}' },
            { code = 201, body = '{"id":"c2"}' },
        })

        local summary = c:exportAll({ book({ file = "/books/a.epub" }), book({ file = "/books/b.epub" }) })

        assert.equals(2, summary.total)
        assert.equals(2, summary.created)
        assert.equals(0, summary.failed)
    end)

    it("stops when the user cancels", function()
        Helper.mocks.docsettings.seed("/books/a.epub", {})

        local c = card({ { code = 201, body = '{"id":"c1"}' } })
        local books = { book({ file = "/books/a.epub" }), book({ file = "/books/b.epub" }) }
        local summary = c:exportAll(books, function()
            return false
        end)

        assert.is_true(summary.cancelled)
        assert.equals(0, summary.created)
    end)

    it("keeps going after one book fails", function()
        Helper.mocks.docsettings.seed("/books/b.epub", {})

        local c = card({
            { code = 400, body = "" }, -- a.epub
            { code = 201, body = '{"id":"c2"}' }, -- b.epub
        })

        local summary = c:exportAll({ book({ file = "/books/a.epub" }), book({ file = "/books/b.epub" }) })

        assert.equals(1, summary.failed)
        assert.equals(1, summary.created)
        assert.is_string(summary.first_error)
    end)

    describe("summarise", function()
        local function summary(overrides)
            local base = {
                total = 0,
                created = 0,
                recreated = 0,
                kept = 0,
                failed = 0,
                cancelled = false,
            }
            for k, v in pairs(overrides or {}) do
                base[k] = v
            end
            return base
        end

        it("says so plainly when nothing happened", function()
            assert.same({ "Nothing to send." }, Card.summarise(summary()))
        end)

        it("counts created and recreated together", function()
            local text = table.concat(Card.summarise(summary({ created = 1, recreated = 2 })), "\n")
            assert.matches("Created 3 book cards", text)
        end)

        it("mentions recreated cards separately", function()
            local text = table.concat(Card.summarise(summary({ recreated = 1 })), "\n")
            assert.matches("had been deleted and were recreated", text)
        end)

        it("says the text of an existing card was left alone", function()
            local text = table.concat(Card.summarise(summary({ kept = 4 })), "\n")
            assert.matches("4 card%(s%) already existed", text)
            assert.matches("left untouched", text)
        end)
    end)
end)

describe("book_export.Card and the Karakeep list", function()
    -- The scenario worth guarding: a card is filed into list A, the user moves
    -- it to list B in Karakeep, then reads on and exports again. Nothing may
    -- drag it back, and finding it must not depend on where it sits.
    before_each(function()
        Helper.install()
    end)

    after_each(function()
        Helper.uninstall()
    end)

    local LISTS = '{"lists":[{"id":"l1","name":"KOReader Books"},{"id":"l2","name":"Fiction"}]}'

    local function cardWith(responses, values)
        local client, stub = Helper.client(responses)
        return Card.new({
            bookmarks = Bookmarks.new(client),
            lists = Lists.new(client),
            settings = Helper.settings(values),
        }),
            stub
    end

    it("files a new card into the configured list", function()
        Helper.mocks.docsettings.seed("/books/novel.epub", {})

        local c, stub = cardWith({
            { code = 201, body = '{"id":"card1"}' },
            { code = 200, body = LISTS },
            { code = 204, body = "" },
        }, { book_list = "Fiction" })

        assert.equals("created", c:export(book()).value.action)
        assert.matches("PUT .*/lists/l2/bookmarks/card1", trace(stub))
    end)

    it("never files a card that already exists", function()
        -- This is what lets a card the user moved to another list stay there.
        Helper.mocks.docsettings.seed("/books/novel.epub", {
            annotations = {},
            karabridge = { version = 2, book_card = { bookmark_id = "card1" } },
        })

        local c, stub = cardWith({
            { code = 200, body = '{"id":"card1"}' }, -- the existence check
        }, { book_list = "Fiction" })

        assert.equals("kept", c:export(book()).value.action)
        assert.is_nil(trace(stub):match("/lists"))
    end)

    it("prefers the stored ID, so a list renamed in Karakeep still works", function()
        Helper.mocks.docsettings.seed("/books/novel.epub", {})

        local settings = Helper.settings({ book_list = "The Old Name", book_list_id = "l2" })
        local client, stub = Helper.client({
            { code = 201, body = '{"id":"card1"}' },
            { code = 200, body = LISTS },
            { code = 204, body = "" },
        })
        local c = Card.new({ bookmarks = Bookmarks.new(client), lists = Lists.new(client), settings = settings })

        c:export(book())

        assert.matches("PUT .*/lists/l2/bookmarks/card1", trace(stub))
        -- ...and the stored name catches up with what the server calls it now.
        assert.equals("Fiction", settings:get("book_list"))
    end)

    it("falls back to the name when the stored ID is gone, and stores the new one", function()
        Helper.mocks.docsettings.seed("/books/novel.epub", {})

        local settings = Helper.settings({ book_list = "Fiction", book_list_id = "deleted" })
        local client, stub = Helper.client({
            { code = 201, body = '{"id":"card1"}' },
            { code = 200, body = LISTS },
            { code = 204, body = "" },
        })
        local c = Card.new({ bookmarks = Bookmarks.new(client), lists = Lists.new(client), settings = settings })

        c:export(book())

        assert.matches("PUT .*/lists/l2/bookmarks/card1", trace(stub))
        assert.equals("l2", settings:get("book_list_id"))
    end)

    it("asks for no lists at all when none is configured", function()
        Helper.mocks.docsettings.seed("/books/novel.epub", {})

        local c, stub = cardWith({ { code = 201, body = '{"id":"card1"}' } })

        c:export(book())

        assert.is_nil(trace(stub):match("/lists"))
    end)

    it("still exports the book when the configured list is gone", function()
        -- A missing list is not a reason to lose the highlights.
        Helper.mocks.docsettings.seed("/books/novel.epub", {})

        local c = cardWith({
            { code = 201, body = '{"id":"card1"}' },
            { code = 200, body = '{"lists":[]}' },
        }, { book_list = "Vanished" })

        assert.equals("created", c:export(book()).value.action)
    end)

    it("looks the list up once, however many books are exported", function()
        Helper.mocks.docsettings.seed("/books/a.epub", {})
        Helper.mocks.docsettings.seed("/books/b.epub", {})

        local c, stub = cardWith({
            { code = 201, body = '{"id":"c1"}' },
            { code = 200, body = LISTS },
            { code = 204, body = "" },
            { code = 201, body = '{"id":"c2"}' },
            { code = 204, body = "" },
        }, { book_list = "Fiction" })

        c:exportAll({ book({ file = "/books/a.epub" }), book({ file = "/books/b.epub" }) })

        local lookups = 0
        for _, entry in ipairs(stub.requests) do
            if entry.request.method == "GET" and entry.request.url:match("/lists$") then
                lookups = lookups + 1
            end
        end
        assert.equals(1, lookups)
    end)
end)
