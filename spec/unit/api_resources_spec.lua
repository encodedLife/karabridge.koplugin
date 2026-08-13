local Helper = require("spec.support.helper")

local Bookmarks = require("karabridge.api.bookmarks")
local Highlights = require("karabridge.api.highlights")
local Json = require("karabridge.shared.json")
local Lists = require("karabridge.api.lists")
local Tags = require("karabridge.api.tags")

local function bodyOf(stub, index)
    return Json.decode(stub.requests[index].request.body)
end

describe("api.Bookmarks", function()
    before_each(function()
        Helper.install()
    end)

    after_each(function()
        Helper.uninstall()
    end)

    describe("page", function()
        it("asks the unfiltered endpoint for unarchived bookmarks", function()
            local client, stub = Helper.client({ { code = 200, body = "{}" } })
            Bookmarks.new(client):page({ scope = "all", limit = 30 })

            local url = stub.requests[1].request.url
            assert.matches("/api/v1/bookmarks%?", url)
            assert.matches("archived=false", url)
            assert.matches("includeContent=true", url)
            assert.matches("limit=30", url)
            assert.matches("sortOrder=desc", url)
        end)

        it("caps the page size at Karakeep's own maximum", function()
            local client, stub = Helper.client({ { code = 200, body = "{}" } })
            Bookmarks.new(client):page({ scope = "all", limit = 500 })

            assert.matches("limit=100", stub.requests[1].request.url)
        end)

        it("uses the list endpoint for a list scope", function()
            local client, stub = Helper.client({ { code = 200, body = "{}" } })
            Bookmarks.new(client):page({ scope = "list", scope_id = "l1" })

            assert.matches("/api/v1/lists/l1/bookmarks", stub.requests[1].request.url)
        end)

        it("sends no archived filter for a list scope, because the route has none", function()
            -- Only the unfiltered /bookmarks endpoint accepts `archived`.
            -- Sending it to /lists/:id/bookmarks silently does nothing, so
            -- callers filtering by list have to drop archived items locally.
            local client, stub = Helper.client({ { code = 200, body = "{}" } })
            Bookmarks.new(client):page({ scope = "list", scope_id = "l1" })

            assert.is_nil(stub.requests[1].request.url:find("archived", 1, true))
        end)

        it("uses the tag endpoint for a tag scope", function()
            local client, stub = Helper.client({ { code = 200, body = "{}" } })
            Bookmarks.new(client):page({ scope = "tag", scope_id = "t1" })

            assert.matches("/api/v1/tags/t1/bookmarks", stub.requests[1].request.url)
        end)
    end)

    describe("creating", function()
        it("posts a text bookmark", function()
            local client, stub = Helper.client({ { code = 201, body = '{"id":"b1"}' } })
            local result = Bookmarks.new(client):createText({ title = "My Book", text = "# Notes" })

            assert.is_true(result:isOk())
            assert.equals("b1", result.value.id)

            local request = stub.requests[1].request
            assert.equals("POST", request.method)
            assert.matches("/api/v1/bookmarks$", request.url)
            assert.same({ text = "# Notes", title = "My Book", type = "text" }, bodyOf(stub, 1))
        end)

        it("refuses a text bookmark with no text, without calling the server", function()
            local client, stub = Helper.client({})
            local result = Bookmarks.new(client):createText({ title = "x" })

            assert.equals("invalid_request", result:errorCode())
            assert.equals(0, #stub.requests)
        end)

        it("posts a link bookmark", function()
            local client, stub = Helper.client({ { code = 201, body = '{"id":"b2"}' } })
            Bookmarks.new(client):createLink({ url = "https://example.org/a" })

            assert.same({ type = "link", url = "https://example.org/a" }, bodyOf(stub, 1))
        end)

        it("refuses a link bookmark with no URL", function()
            local client = Helper.client({})
            assert.equals("invalid_request", Bookmarks.new(client):createLink({}):errorCode())
        end)
    end)

    describe("updating", function()
        it("patches the text of an existing card", function()
            -- This is what makes "one local book = one Karakeep card" work
            -- instead of accumulating a duplicate on every export.
            local client, stub = Helper.client({ { code = 200, body = '{"id":"b1"}' } })
            Bookmarks.new(client):updateText("b1", "# Updated")

            local request = stub.requests[1].request
            assert.equals("PATCH", request.method)
            assert.matches("/api/v1/bookmarks/b1$", request.url)
            assert.same({ text = "# Updated" }, bodyOf(stub, 1))
        end)

        it("reports a card deleted on the server as not_found", function()
            -- The caller uses this to recreate the card rather than give up.
            local client = Helper.client({ { code = 404, body = "" } })
            assert.equals("not_found", Bookmarks.new(client):updateText("gone", "x"):errorCode())
        end)

        it("patches arbitrary fields", function()
            local client, stub = Helper.client({ { code = 200, body = "{}" } })
            Bookmarks.new(client):update("b1", { archived = true })

            assert.same({ archived = true }, bodyOf(stub, 1))
        end)
    end)

    describe("tags", function()
        it("attaches tags by name", function()
            local client, stub = Helper.client({ { code = 200, body = "{}" } })
            Bookmarks.new(client):attachTags("b1", { "koreader", "ebook" })

            assert.matches("/api/v1/bookmarks/b1/tags$", stub.requests[1].request.url)
            assert.same({
                tags = {
                    { attachedBy = "human", tagName = "koreader" },
                    { attachedBy = "human", tagName = "ebook" },
                },
            }, bodyOf(stub, 1))
        end)

        it("makes no request when there is nothing to attach", function()
            local client, stub = Helper.client({})
            local result = Bookmarks.new(client):attachTags("b1", { "", nil })

            assert.is_true(result:isOk())
            assert.equals(0, #stub.requests)
        end)
    end)

    describe("readableContent", function()
        it("follows the continuation cursor", function()
            -- Without this a long article is silently truncated at the first
            -- 50000-character chunk.
            local client, stub = Helper.client({
                { code = 200, body = '{"content":"part one ","nextCursor":"c1","truncated":true}' },
                { code = 200, body = '{"content":"part two","nextCursor":null,"truncated":false}' },
            })

            local result = Bookmarks.new(client):readableContent("b1")

            assert.equals("part one part two", result.value)
            assert.equals(2, #stub.requests)
        end)

        it("sends the format only on the first request", function()
            -- The cursor carries the format; sending both is rejected.
            local client, stub = Helper.client({
                { code = 200, body = '{"content":"a","nextCursor":"c1","truncated":true}' },
                { code = 200, body = '{"content":"b","truncated":false}' },
            })

            Bookmarks.new(client):readableContent("b1", "markdown")

            assert.matches("format=markdown", stub.requests[1].request.url)
            assert.is_nil(stub.requests[2].request.url:find("format=", 1, true))
        end)

        it("keeps what it already has when a later chunk fails", function()
            local client = Helper.client({
                { code = 200, body = '{"content":"part one","nextCursor":"c1","truncated":true}' },
                { code = 500, body = "" },
                { code = 500, body = "" },
                { code = 500, body = "" },
            })

            local result = Bookmarks.new(client):readableContent("b1")

            assert.is_true(result:isOk())
            assert.equals("part one", result.value)
        end)

        it("reports the failure when the first chunk fails", function()
            local client = Helper.client({ { code = 401, body = "" } })
            assert.equals("unauthorized", Bookmarks.new(client):readableContent("b1"):errorCode())
        end)
    end)
end)

describe("api.Highlights", function()
    before_each(function()
        Helper.install()
    end)

    after_each(function()
        Helper.uninstall()
    end)

    describe("mapColor", function()
        it("passes through the four colours Karakeep accepts", function()
            for _, color in ipairs({ "yellow", "red", "green", "blue" }) do
                assert.equals(color, Highlights.mapColor(color))
            end
        end)

        it("maps KOReader's extra colours to the nearest accepted one", function()
            -- Karakeep's zHighlightColorSchema rejects anything else outright,
            -- so without this a cyan highlight silently fails to sync.
            assert.equals("blue", Highlights.mapColor("cyan"))
            assert.equals("red", Highlights.mapColor("purple"))
            assert.equals("green", Highlights.mapColor("olive"))
            assert.equals("yellow", Highlights.mapColor("orange"))
        end)

        it("falls back to yellow for anything unrecognised", function()
            assert.equals("yellow", Highlights.mapColor("chartreuse"))
            assert.equals("yellow", Highlights.mapColor(nil))
        end)

        it("is case-insensitive", function()
            assert.equals("blue", Highlights.mapColor("Cyan"))
        end)
    end)

    describe("create", function()
        it("posts the full highlight", function()
            local client, stub = Helper.client({ { code = 201, body = '{"id":"h1"}' } })
            Highlights.new(client):create({
                bookmark_id = "b1",
                text = "a passage",
                note = "a note",
                color = "cyan",
                start_offset = 10,
                end_offset = 19,
            })

            assert.same({
                bookmarkId = "b1",
                color = "blue",
                endOffset = 19,
                note = "a note",
                startOffset = 10,
                text = "a passage",
            }, bodyOf(stub, 1))
        end)

        it("sends an explicit null for a missing note, not an absent key", function()
            -- Regression, found by the live integration suite. `note` is
            -- z.string().nullable() -- nullable but NOT optional -- so leaving
            -- the key out is a 400. Every highlight KaraBridge had sent before
            -- then happened to carry a note, so the gap was invisible.
            local client, stub = Helper.client({ { code = 201, body = "{}" } })
            Highlights.new(client):create({ bookmark_id = "b1", text = "a passage" })

            -- Asserted on the raw body: a decoded table cannot distinguish
            -- "key absent" from "key present and null".
            assert.matches('"note":null', stub.requests[1].request.body)
        end)

        it("sends an explicit null for missing text as well", function()
            local client, stub = Helper.client({ { code = 201, body = "{}" } })
            Highlights.new(client):create({ bookmark_id = "b1", note = "just a note" })

            assert.matches('"text":null', stub.requests[1].request.body)
        end)

        it("still sends a real note when there is one", function()
            local client, stub = Helper.client({ { code = 201, body = "{}" } })
            Highlights.new(client):create({ bookmark_id = "b1", text = "p", note = "n" })

            assert.matches('"note":"n"', stub.requests[1].request.body)
        end)

        it("sends zero offsets when the position could not be resolved", function()
            -- The schema requires numbers with no nullable variant, and an
            -- unanchored highlight that keeps its text beats no highlight.
            local client, stub = Helper.client({ { code = 201, body = "{}" } })
            Highlights.new(client):create({ bookmark_id = "b1", text = "x" })

            local body = bodyOf(stub, 1)
            assert.equals(0, body.startOffset)
            assert.equals(0, body.endOffset)
        end)

        it("refuses a highlight with no bookmark", function()
            local client, stub = Helper.client({})
            assert.equals("invalid_request", Highlights.new(client):create({ text = "x" }):errorCode())
            assert.equals(0, #stub.requests)
        end)
    end)

    describe("existingTexts", function()
        it("builds a set keyed by normalised text", function()
            local client = Helper.client({
                { code = 200, body = '{"highlights":[{"text":"a  passage"},{"text":"another"}]}' },
            })

            local result = Highlights.new(client):existingTexts("b1")

            assert.is_true(result.value["a passage"])
            assert.is_true(result.value["another"])
        end)

        it("copes with a bare array response", function()
            local client = Helper.client({ { code = 200, body = '[{"text":"a"}]' } })
            assert.is_true(Highlights.new(client):existingTexts("b1").value["a"])
        end)

        it("propagates a failure, so the caller can skip rather than duplicate", function()
            local client = Helper.client({ { code = 401, body = "" } })
            assert.is_true(Highlights.new(client):existingTexts("b1"):isErr())
        end)
    end)
end)

describe("api.Lists", function()
    before_each(function()
        Helper.install()
    end)

    after_each(function()
        Helper.uninstall()
    end)

    it("unwraps the lists array", function()
        local client = Helper.client({ { code = 200, body = '{"lists":[{"id":"l1","name":"KOReader"}]}' } })
        local result = Lists.new(client):all()

        assert.equals(1, #result.value)
        assert.equals("KOReader", result.value[1].name)
    end)

    it("finds a list by name, case-insensitively", function()
        local client = Helper.client({ { code = 200, body = '{"lists":[{"id":"l1","name":"KOReader Books"}]}' } })
        local result = Lists.new(client):findByName("koreader books")

        assert.equals("l1", result.value.id)
    end)

    it("succeeds with no list when there is no match", function()
        local client = Helper.client({ { code = 200, body = '{"lists":[]}' } })
        local result = Lists.new(client):findByName("Nope")

        assert.is_true(result:isOk())
        assert.is_nil(result.value)
    end)

    it("makes no request for an empty name", function()
        local client, stub = Helper.client({})
        assert.is_true(Lists.new(client):findByName(""):isOk())
        assert.equals(0, #stub.requests)
    end)

    it("adds a bookmark to a list with PUT, not POST", function()
        -- Getting the verb wrong produces a 404 that looks exactly like a
        -- wrong list ID.
        local client, stub = Helper.client({ { code = 204, body = "" } })
        Lists.new(client):addBookmark("l1", "b1")

        assert.equals("PUT", stub.requests[1].request.method)
        assert.matches("/api/v1/lists/l1/bookmarks/b1$", stub.requests[1].request.url)
    end)
end)

describe("api.Tags", function()
    before_each(function()
        Helper.install()
    end)

    after_each(function()
        Helper.uninstall()
    end)

    it("asks for the most-used tags first, a page at a time", function()
        local client, stub = Helper.client({ { code = 200, body = '{"tags":[],"nextCursor":null}' } })
        Tags.new(client):all()

        assert.matches("sort=usage", stub.requests[1].request.url)
        assert.matches("limit=" .. Tags.PAGE_SIZE, stub.requests[1].request.url)
    end)

    it("finds a tag by name", function()
        local client = Helper.client({ { code = 200, body = '{"tags":[{"id":"t1","name":"Ebook"}]}' } })
        assert.equals("t1", Tags.new(client):findByName("ebook").value.id)
    end)
end)

describe("api pagination in name lookups", function()
    -- A lookup that only ever reads the first page reports "no such tag" for a
    -- tag that exists, which then surfaces as a filter silently matching
    -- nothing. GET /tags is cursor-paginated; GET /lists is not.
    before_each(function()
        Helper.install()
    end)

    after_each(function()
        Helper.uninstall()
    end)

    describe("Tags:findByName", function()
        it("narrows server-side with nameContains", function()
            local client, stub = Helper.client({ { code = 200, body = '{"tags":[{"id":"t1","name":"ebook"}]}' } })
            Tags.new(client):findByName("ebook")

            assert.matches("nameContains=ebook", stub.requests[1].request.url)
        end)

        it("finds a tag on a later page", function()
            local client = Helper.client({
                { code = 200, body = '{"tags":[{"id":"t1","name":"other"}],"nextCursor":"c1"}' },
                { code = 200, body = '{"tags":[{"id":"t2","name":"wanted"}],"nextCursor":null}' },
            })

            assert.equals("t2", Tags.new(client):findByName("wanted").value.id)
        end)

        it("does not mistake a substring match for the tag", function()
            -- nameContains is a substring filter: asking for "book" returns
            -- "cookbook" too, so the exact comparison still has to happen here.
            local client = Helper.client({
                { code = 200, body = '{"tags":[{"id":"t1","name":"cookbook"}],"nextCursor":null}' },
                { code = 200, body = '{"tags":[{"id":"t1","name":"cookbook"}],"nextCursor":null}' },
            })

            assert.is_nil(Tags.new(client):findByName("book").value)
        end)

        it("matches case-insensitively", function()
            local client = Helper.client({ { code = 200, body = '{"tags":[{"id":"t1","name":"EBook"}]}' } })
            assert.equals("t1", Tags.new(client):findByName("ebook").value.id)
        end)

        it("falls back to a full walk when the narrowed search was cut short", function()
            local responses = {}
            for _ = 1, Tags.MAX_PAGES do
                table.insert(responses, { code = 200, body = '{"tags":[{"id":"x","name":"noise"}],"nextCursor":"c"}' })
            end
            table.insert(responses, { code = 200, body = '{"tags":[{"id":"t9","name":"wanted"}],"nextCursor":null}' })

            assert.equals("t9", Tags.new(Helper.client(responses)):findByName("wanted").value.id)
        end)

        it("reports nothing found when the walk completed and matched nothing", function()
            local client = Helper.client({ { code = 200, body = '{"tags":[],"nextCursor":null}' } })
            local found = Tags.new(client):findByName("absent")

            assert.is_true(found:isOk())
            assert.is_nil(found.value)
        end)

        it("propagates a pagination failure rather than reporting 'not found'", function()
            -- "The tag does not exist" and "the server would not tell us" must
            -- not look the same: the first silently syncs nothing.
            local client = Helper.client({ { code = 401, body = "" }, { code = 401, body = "" } })
            assert.is_true(Tags.new(client):findByName("anything"):isErr())
        end)
    end)

    describe("Tags:all", function()
        it("follows the cursor", function()
            local client = Helper.client({
                { code = 200, body = '{"tags":[{"id":"t1"}],"nextCursor":"c1"}' },
                { code = 200, body = '{"tags":[{"id":"t2"}],"nextCursor":null}' },
            })

            assert.equals(2, #Tags.new(client):all().value)
        end)

        it("stops at the page cap rather than looping for ever", function()
            local responses = {}
            for _ = 1, Tags.MAX_PAGES + 5 do
                table.insert(responses, { code = 200, body = '{"tags":[{"id":"x"}],"nextCursor":"always"}' })
            end

            local client, stub = Helper.client(responses)
            Tags.new(client):all()

            assert.equals(Tags.MAX_PAGES, #stub.requests)
        end)
    end)

    describe("Lists:all", function()
        it("makes exactly one request, because the endpoint does not paginate", function()
            local client, stub = Helper.client({ { code = 200, body = '{"lists":[{"id":"l1","name":"A"}]}' } })
            Lists.new(client):all()

            assert.equals(1, #stub.requests)
            assert.is_nil(stub.requests[1].request.url:find("cursor", 1, true))
        end)
    end)
end)
