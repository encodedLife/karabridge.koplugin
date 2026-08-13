--[[--
KaraBridge against a real Karakeep server.

Opt-in, and gated by environment variables so it can never run by accident.
`scripts/test-integration.sh` prints why it did nothing when they are absent.

    KARABRIDGE_TEST_SERVER_URL     base address, without /api/v1
    KARABRIDGE_TEST_API_TOKEN      an API key created for testing
    KARABRIDGE_TEST_ALLOW_WRITES   set to 1 to permit create/update/delete
    KARABRIDGE_TEST_LIST           optional; a list name to file test cards in

This is the only layer that can prove the version assumptions in
`docs/research/karakeep-analysis.md`. The unit suite proves KaraBridge sends
what it believes it is sending; only a real server proves the server agrees.

**Everything created here is titled with `[KaraBridge Test]` and deleted
afterwards.** Nothing without that prefix is ever touched, and no bookmark is
ever archived or modified unless this suite created it.

@module spec.integration.karakeep_api
]]

local Helper = require("spec.support.helper")

-- socketutil pulls in KOReader's device stack, which probes SDL and reads
-- G_reader_settings. These specs make real requests, so that stack has to be
-- up. Both bootstraps are needed and in this order: setupkoenv installs the
-- ffi.load override (without it `package.loadlib` is nil and ffi/utf8proc
-- fails), and commonrequire creates G_reader_settings.
-- scripts/test-integration.sh puts both on the path.
require("setupkoenv")
require("commonrequire")

local Bookmarks = require("karabridge.api.bookmarks")
local Client = require("karabridge.api.client")
local ConnectionTest = require("karabridge.features.connection_test")
local Highlights = require("karabridge.api.highlights")
local Lists = require("karabridge.api.lists")
local Tags = require("karabridge.api.tags")

local SERVER = os.getenv("KARABRIDGE_TEST_SERVER_URL")
local TOKEN = os.getenv("KARABRIDGE_TEST_API_TOKEN")
local ALLOW_WRITES = os.getenv("KARABRIDGE_TEST_ALLOW_WRITES") == "1"
local LIST_NAME = os.getenv("KARABRIDGE_TEST_LIST")

-- The marker that makes cleanup safe. Anything this suite creates carries it,
-- and nothing without it is ever deleted.
local PREFIX = "[KaraBridge Test]"

describe("Karakeep, live", function()
    if not SERVER or not TOKEN then
        pending("integration tests skipped: KARABRIDGE_TEST_SERVER_URL and _API_TOKEN are not set")
        return
    end

    local client = Client.new({ server_url = SERVER, api_token = TOKEN })
    local bookmarks = Bookmarks.new(client)
    local highlights = Highlights.new(client)
    local lists = Lists.new(client)
    local tags = Tags.new(client)

    -- Everything created, so teardown can remove it even after a failure.
    local created = {}

    local function track(id)
        if type(id) == "string" and id ~= "" then
            table.insert(created, id)
        end
        return id
    end

    -- The tag the suite creates. Deleting the bookmarks does not remove it:
    -- Karakeep leaves the tag behind with no bookmarks attached, so a suite
    -- that only deletes bookmarks slowly litters the tag list.
    local TEST_TAG = "karabridge-test-tag"

    teardown(function()
        for _, id in ipairs(created) do
            local removed = bookmarks:delete(id)
            if removed:isErr() then
                io.write("\n  WARNING: could not delete test bookmark " .. id .. ": " .. removed:describe() .. "\n")
            end
        end

        local found = tags:findByName(TEST_TAG)
        if found:isOk() and found.value then
            local removed = tags:delete(found.value.id)
            if removed:isErr() then
                io.write("\n  WARNING: could not delete the test tag: " .. removed:describe() .. "\n")
            end
        end
    end)

    describe("connection", function()
        it("authenticates", function()
            local result = ConnectionTest.run(client)
            assert.is_true(result:isOk(), "connection failed: " .. result:describe())
        end)

        it("rejects a wrong key with unauthorized, not something vaguer", function()
            local bad = Client.new({ server_url = SERVER, api_token = "ak1_definitely_not_valid" })
            assert.equals("unauthorized", ConnectionTest.run(bad):errorCode())
        end)

        it("reports a non-Karakeep address distinctly", function()
            -- /api/v1 left on the end is the commonest mistake, and produces a
            -- 404 that must not read as "wrong key".
            local wrong = Client.new({ server_url = SERVER .. "/nonexistent", api_token = TOKEN })
            assert.equals("not_karakeep", ConnectionTest.run(wrong):errorCode())
        end)
    end)

    describe("reading", function()
        it("lists bookmarks in the shape the client expects", function()
            local page = bookmarks:page({ scope = "all", limit = 5 })

            assert.is_true(page:isOk(), page:describe())
            assert.is_table(page.value.bookmarks)
        end)

        it("honours the limit", function()
            local page = bookmarks:page({ scope = "all", limit = 1 })
            assert.is_true(#page.value.bookmarks <= 1)
        end)

        it("paginates with a cursor, or says there is no more", function()
            -- Both outcomes are correct; what must not happen is a nextCursor
            -- of some other shape, or a cursor that is not accepted back.
            local page = bookmarks:page({ scope = "all", limit = 1 })

            if page.value.nextCursor then
                local second = bookmarks:page({ scope = "all", limit = 1, cursor = page.value.nextCursor })
                assert.is_true(second:isOk(), "the cursor was rejected: " .. second:describe())
            end
        end)

        it("returns lists", function()
            local result = lists:all()
            assert.is_true(result:isOk(), result:describe())
            assert.is_table(result.value)
        end)

        it("returns tags", function()
            local result = tags:all(5)
            assert.is_true(result:isOk(), result:describe())
            assert.is_table(result.value)
        end)

        it("reports a bookmark that does not exist as not_found", function()
            -- The book-card flow depends on this: not_found means recreate,
            -- anything else means try again later.
            assert.equals("not_found", bookmarks:get("definitelynotarealbookmarkid"):errorCode())
        end)
    end)

    if not ALLOW_WRITES then
        pending("write tests skipped: set KARABRIDGE_TEST_ALLOW_WRITES=1 to enable them")
        return
    end

    describe("text bookmarks", function()
        it("creates one", function()
            local result = bookmarks:createText({
                title = PREFIX .. " create",
                text = "# Heading\n\nBody with umlauts: \195\164\195\182\195\188.",
            })

            assert.is_true(result:isOk(), result:describe())
            assert.is_string(track(result.value.id))
        end)

        it("reads back what it wrote, including non-ASCII", function()
            local made = bookmarks:createText({
                title = PREFIX .. " roundtrip",
                text = "\195\164\195\182\195\188 \226\130\172",
            })
            track(made.value.id)

            local fetched = bookmarks:get(made.value.id, true)

            assert.is_true(fetched:isOk(), fetched:describe())
            assert.matches("\195\164\195\182\195\188", fetched.value.content.text)
        end)

        it("rewrites the body in place, which is what one-card-per-book needs", function()
            -- The single most load-bearing API assumption in the plugin.
            local made = bookmarks:createText({ title = PREFIX .. " update", text = "first" })
            track(made.value.id)

            local updated = bookmarks:updateText(made.value.id, "second", PREFIX .. " update")
            assert.is_true(updated:isOk(), updated:describe())

            local fetched = bookmarks:get(made.value.id, true)
            assert.equals("second", fetched.value.content.text)
        end)

        it("archives one", function()
            local made = bookmarks:createText({ title = PREFIX .. " archive", text = "x" })
            track(made.value.id)

            assert.is_true(bookmarks:update(made.value.id, { archived = true }):isOk())
            assert.is_true(bookmarks:get(made.value.id, false).value.archived)
        end)

        it("attaches a tag by name, creating it if needed", function()
            local made = bookmarks:createText({ title = PREFIX .. " tag", text = "x" })
            track(made.value.id)

            assert.is_true(bookmarks:attachTags(made.value.id, { "karabridge-test-tag" }):isOk())

            local names = {}
            for _, tag in ipairs(bookmarks:get(made.value.id, false).value.tags or {}) do
                names[tag.name] = true
            end
            assert.is_true(names["karabridge-test-tag"] == true)
        end)
    end)

    describe("lists", function()
        it("adds a bookmark to a list with PUT", function()
            if not LIST_NAME then
                return -- nothing to file into; not a failure
            end

            local found = lists:findByName(LIST_NAME)
            assert.is_true(found:isOk(), found:describe())
            if not found.value then
                return
            end

            local made = bookmarks:createText({ title = PREFIX .. " list", text = "x" })
            track(made.value.id)

            local filed = lists:addBookmark(found.value.id, made.value.id)
            assert.is_true(filed:isOk(), filed:describe())
        end)
    end)

    describe("highlights", function()
        it("creates one and reads it back", function()
            local made = bookmarks:createText({
                title = PREFIX .. " highlight",
                text = "The quick brown fox jumps over the lazy dog.",
            })
            track(made.value.id)

            local pushed = highlights:create({
                bookmark_id = made.value.id,
                text = "quick brown fox",
                note = "a note",
                color = "cyan", -- must be mapped; Karakeep rejects it raw
                start_offset = 4,
                end_offset = 19,
            })

            assert.is_true(pushed:isOk(), pushed:describe())

            local existing = highlights:existingTexts(made.value.id)
            assert.is_true(existing.value["quick brown fox"] == true)
        end)

        it("maps a colour Karakeep does not accept, rather than being rejected", function()
            local made = bookmarks:createText({ title = PREFIX .. " colour", text = "x" })
            track(made.value.id)

            for _, color in ipairs({ "cyan", "purple", "olive", "orange", "chartreuse" }) do
                local pushed = highlights:create({
                    bookmark_id = made.value.id,
                    text = "passage in " .. color,
                    color = color,
                })
                assert.is_true(pushed:isOk(), color .. ": " .. pushed:describe())
            end
        end)

        it("accepts zero offsets for a passage that could not be positioned", function()
            -- The schema requires numbers with no nullable variant, so this is
            -- what an unresolvable highlight is sent as.
            local made = bookmarks:createText({ title = PREFIX .. " offsets", text = "x" })
            track(made.value.id)

            local pushed = highlights:create({
                bookmark_id = made.value.id,
                text = "not present in the text",
                start_offset = 0,
                end_offset = 0,
            })

            assert.is_true(pushed:isOk(), pushed:describe())
        end)

        it("does not deduplicate, which is why the client must", function()
            -- Asserting the server's behaviour, not ours: if Karakeep ever
            -- starts deduplicating, the client's fetch-and-compare becomes
            -- unnecessary and this spec is where that shows up.
            local made = bookmarks:createText({ title = PREFIX .. " dedup", text = "x" })
            track(made.value.id)

            highlights:create({ bookmark_id = made.value.id, text = "same passage" })
            highlights:create({ bookmark_id = made.value.id, text = "same passage" })

            local all = highlights:forBookmark(made.value.id)
            local count = 0
            for _, h in ipairs((all.value or {}).highlights or {}) do
                if h.text == "same passage" then
                    count = count + 1
                end
            end

            assert.equals(2, count, "Karakeep now deduplicates; the client's check could be simplified")
        end)
    end)

    describe("cleanup", function()
        it("deletes a bookmark", function()
            local made = bookmarks:createText({ title = PREFIX .. " delete", text = "x" })
            local id = made.value.id

            assert.is_true(bookmarks:delete(id):isOk())
            assert.equals("not_found", bookmarks:get(id):errorCode())
        end)
    end)

    describe("secret handling", function()
        it("never writes the token to the log, against a real server", function()
            Helper.install()
            bookmarks:page({ scope = "all", limit = 1 })
            local leaked = Helper.mocks.logger.contains(TOKEN)
            Helper.uninstall()

            assert.is_false(leaked)
        end)
    end)
end)
