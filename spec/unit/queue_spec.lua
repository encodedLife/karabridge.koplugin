local Helper = require("spec.support.helper")

local Manager = require("karabridge.features.queue.manager")
local Store = require("karabridge.features.queue.store")

local function store(initial)
    local backing = Helper.mocks.luasettings.new(initial)
    return Store.new({ store = backing }), backing
end

describe("queue.Store", function()
    before_each(function()
        Helper.install()
    end)

    after_each(function()
        Helper.uninstall()
    end)

    describe("validate", function()
        it("accepts a well-formed entry", function()
            assert.is_true(Store.validate({ action = "create_link", payload = {} }))
        end)

        it("rejects anything without an action or a payload", function()
            assert.is_false(Store.validate({ payload = {} }))
            assert.is_false(Store.validate({ action = "x" }))
            assert.is_false(Store.validate({ action = "", payload = {} }))
            assert.is_false(Store.validate("nonsense"))
            assert.is_false(Store.validate(nil))
        end)
    end)

    describe("adding and removing", function()
        it("starts empty", function()
            assert.equals(0, store():count())
        end)

        it("stores an entry with its bookkeeping", function()
            local s = store()
            assert.is_true(s:add("https://x/a", "create_link", { url = "https://x/a" }))

            local pending = s:pending()
            assert.equals(1, #pending)
            assert.equals("create_link", pending[1].entry.action)
            assert.equals(0, pending[1].entry.attempts)
            assert.is_number(pending[1].entry.created_at)
        end)

        it("keys entries, so queueing the same thing twice leaves one", function()
            local s = store()
            s:add("https://x/a", "create_link", { url = "https://x/a" })
            s:add("https://x/a", "create_link", { url = "https://x/a" })

            assert.equals(1, s:count())
        end)

        it("keeps the attempt count when the same key is re-queued", function()
            -- Resetting it would defeat MAX_ATTEMPTS for something that keeps
            -- being retried and keeps failing.
            local s = store()
            s:add("k", "create_link", { url = "u" })
            s:recordFailure("k", "nope")
            s:add("k", "create_link", { url = "u" })

            assert.equals(1, s:pending()[1].entry.attempts)
        end)

        it("removes an entry", function()
            local s = store()
            s:add("k", "create_link", { url = "u" })
            s:remove("k")

            assert.equals(0, s:count())
            assert.is_false(s:has("k"))
        end)

        it("orders by creation, so a run is reproducible", function()
            local s = store()
            s:add("b", "create_link", { url = "b" })
            s.data.entries.b.created_at = 100
            s:add("a", "create_link", { url = "a" })
            s.data.entries.a.created_at = 200

            local pending = s:pending()
            assert.equals("b", pending[1].key)
            assert.equals("a", pending[2].key)
        end)
    end)

    describe("failure handling", function()
        it("counts attempts and keeps the last error", function()
            local s = store()
            s:add("k", "create_link", { url = "u" })

            assert.is_true(s:recordFailure("k", "server said no"))

            local entry = s:pending()[1].entry
            assert.equals(1, entry.attempts)
            assert.equals("server said no", entry.last_error)
        end)

        it("parks an entry that has failed too many times", function()
            -- An entry failing deterministically would otherwise be retried on
            -- every sync for ever, drowning out real failures.
            local s = store()
            s:add("k", "create_link", { url = "u" })

            for _ = 1, Store.MAX_ATTEMPTS - 1 do
                assert.is_true(s:recordFailure("k", "nope"))
            end
            assert.is_false(s:recordFailure("k", "nope"))

            assert.equals(0, s:count())
            assert.equals(1, s:parkedCount())
        end)

        it("records why an entry was parked", function()
            local s = store()
            s:add("k", "create_link", { url = "u" })
            for _ = 1, Store.MAX_ATTEMPTS do
                s:recordFailure("k", "server said no")
            end

            local parked = s:parked()
            assert.equals("k", parked[1].key)
            assert.matches("server said no", parked[1].reason)
        end)

        it("can put a parked entry back, with its attempts reset", function()
            local s = store()
            s:add("k", "create_link", { url = "u" })
            s:quarantine("k", "because")

            assert.is_true(s:release("k"))
            assert.equals(1, s:count())
            assert.equals(0, s:pending()[1].entry.attempts)
        end)

        it("ignores a failure for an entry that is not there", function()
            assert.is_false(store():recordFailure("missing", "x"))
        end)
    end)

    describe("corruption recovery", function()
        it("quarantines a corrupt entry and keeps the rest", function()
            -- Silently dropping it is data loss; retrying it for ever blocks
            -- everything behind it. Parked where it can be seen is neither.
            local s = store({
                karabridge_queue = {
                    version = 1,
                    entries = {
                        good = { action = "create_link", payload = { url = "u" } },
                        broken = { payload = { url = "u" } },
                        rubbish = "not even a table",
                    },
                },
            })

            assert.equals(1, s:count())
            assert.equals("good", s:pending()[1].key)
            assert.equals(2, s:parkedCount())
        end)

        it("survives a store holding something that is not a queue at all", function()
            local s = store({ karabridge_queue = "corrupt" })

            assert.equals(0, s:count())
            assert.equals(Store.SCHEMA_VERSION, s.data.version)
        end)

        it("survives an envelope with no entries table", function()
            local s = store({ karabridge_queue = { version = 1 } })
            assert.equals(0, s:count())
        end)
    end)

    describe("persistence", function()
        it("writes the envelope, versioned", function()
            local s, backing = store()
            s:add("k", "create_link", { url = "u" })

            assert.is_true(s:flush())

            local written = backing.data.karabridge_queue
            assert.equals(Store.SCHEMA_VERSION, written.version)
            assert.equals("create_link", written.entries.k.action)
        end)

        it("does not write when nothing changed", function()
            -- The flush event fires often, and a Kobo's flash does not enjoy
            -- being rewritten for nothing.
            local s = store()
            s:add("k", "create_link", { url = "u" })
            s:flush()

            assert.is_false(s:flush())
        end)

        it("round-trips through the store", function()
            local _, backing = store()
            local first = Store.new({ store = backing })
            first:add("k", "create_link", { url = "u" })
            first:flush()

            local second = Store.new({ store = backing })
            assert.equals(1, second:count())
            assert.equals("u", second:pending()[1].entry.payload.url)
        end)

        it("keeps bookkeeping out of the entries namespace", function()
            -- Storing a _length inside the entries table means an
            -- item keyed "_length" would corrupt its count.
            local s = store()
            s:add("_length", "create_link", { url = "u" })
            s:flush()

            assert.equals(1, s:count())
            assert.equals("_length", s:pending()[1].key)
        end)
    end)
end)

describe("queue.Manager", function()
    before_each(function()
        Helper.install()
    end)

    after_each(function()
        Helper.uninstall()
    end)

    local function manager(responses)
        local s = store()
        local client = responses and Helper.client(responses) or nil
        return Manager.new({
            store = s,
            client_factory = function()
                return client
            end,
        }),
            s
    end

    it("reports nothing to do on an empty queue", function()
        local m = manager()
        local summary = m:processAll()

        assert.equals(0, summary.total)
        assert.same({ "Nothing is waiting to be sent." }, Manager.summarise(summary))
    end)

    it("sends a queued link and removes it", function()
        local m, s = manager({ { code = 201, body = '{"id":"b1"}' } })
        m:queueLink("https://example.org/a")

        local summary = m:processAll()

        assert.equals(1, summary.succeeded)
        assert.equals(0, s:count())
    end)

    it("keeps a link that could not be sent, and counts the attempt", function()
        local m, s = manager({ { code = 401, body = "" } })
        m:queueLink("https://example.org/a")

        local summary = m:processAll()

        assert.equals(1, summary.failed)
        assert.equals(1, s:count())
        assert.equals(1, s:pending()[1].entry.attempts)
        assert.is_string(summary.first_error)
    end)

    it("keys queued links by URL, so the same link twice is one entry", function()
        local m, s = manager()
        m:queueLink("https://example.org/a")
        m:queueLink("https://example.org/a")

        assert.equals(1, s:count())
    end)

    it("parks an action it has no handler for", function()
        -- Happens after a downgrade, when entries from a newer version remain.
        -- Retrying them for ever would be noise.
        local m, s = manager()
        s:add("k", "from_the_future", { x = 1 })

        local summary = m:processAll()

        assert.equals(1, summary.parked)
        assert.equals(0, s:count())
        assert.matches("no handler", s:parked()[1].reason)
    end)

    it("survives a handler that throws, and still runs the others", function()
        local m, s = manager({ { code = 201, body = '{"id":"b1"}' } })
        m:register("explodes", function()
            error("boom")
        end)

        s:add("a", "explodes", { x = 1 })
        s.data.entries.a.created_at = 1
        m:queueLink("https://example.org/b")
        s.data.entries["https://example.org/b"].created_at = 2

        local summary = m:processAll()

        assert.equals(1, summary.failed)
        assert.equals(1, summary.succeeded)
    end)

    it("refuses a queued link with no URL rather than calling the API", function()
        local m, s = manager()
        s:add("k", "create_link", {})

        local summary = m:processAll()

        assert.equals(1, summary.failed)
        assert.matches("no URL", summary.first_error)
    end)

    it("stops when the user cancels, leaving the rest queued", function()
        local m, s = manager()
        m:queueLink("https://example.org/a")

        local summary = m:processAll(function()
            return false
        end)

        assert.is_true(summary.cancelled)
        assert.equals(1, s:count())
    end)

    it("persists the outcome without a separate flush", function()
        local m, s = manager({ { code = 201, body = '{"id":"b1"}' } })
        m:queueLink("https://example.org/a")
        m:processAll()

        assert.is_false(s.dirty, "processAll should have flushed")
    end)

    describe("summarise", function()
        it("reports what was sent and what will be retried", function()
            local text = table.concat(
                Manager.summarise({ total = 3, succeeded = 2, failed = 1, parked = 0, first_error = "nope" }),
                "\n"
            )

            assert.matches("Sent 2 queued items", text)
            assert.matches("1 could not be sent", text)
            assert.matches("nope", text)
        end)

        it("points at Diagnostics for items that were set aside", function()
            local text = table.concat(Manager.summarise({ total = 1, succeeded = 0, failed = 0, parked = 1 }), "\n")
            assert.matches("Diagnostics", text)
        end)
    end)
end)

describe("queue.Menu recovery actions", function()
    -- The store could already quarantine an entry; there was no way to do
    -- anything about one. An item set aside where the user can see it but not
    -- touch it is only marginally better than one silently dropped.
    local QueueMenu = require("karabridge.features.queue.menu")

    before_each(function()
        Helper.install()
    end)

    after_each(function()
        Helper.uninstall()
    end)

    local function pluginWithParked(count)
        local s = store()
        for index = 1, count do
            local key = "https://example.org/" .. index
            s:add(key, "create_link", { url = key })
            s:quarantine(key, "failed 5 times: unauthorized")
        end
        return { queue = { store = s } }, s
    end

    it("says so plainly when nothing is set aside", function()
        local plugin = { queue = { store = store() } }
        local items = QueueMenu.buildParkedMenu(plugin)

        assert.equals(1, #items)
        assert.matches("Nothing has been set aside", items[1].text)
        assert.is_false(items[1].enabled_func())
    end)

    it("lists one row per set-aside item, plus the bulk actions", function()
        local plugin = pluginWithParked(2)
        local items = QueueMenu.buildParkedMenu(plugin)

        assert.equals(4, #items) -- two entries, put-all-back, delete-all
    end)

    it("truncates a long key rather than overflowing the row", function()
        local long = "https://example.org/" .. string.rep("x", 200)
        assert.is_true(#QueueMenu.label({ key = long }) <= 49)
    end)

    it("offers inspect, retry, release and delete for one item", function()
        local plugin = pluginWithParked(1)
        local entry = QueueMenu.buildEntryMenu(plugin, plugin.queue.store:parked()[1])

        local labels = {}
        for _, item in ipairs(entry) do
            labels[item.text] = true
        end

        assert.is_true(labels["Why it was set aside"])
        assert.is_true(labels["Try it again now"])
        assert.is_true(labels["Put it back in the queue"])
        assert.is_true(labels["Delete it"])
    end)

    it("puts one item back, with its attempts reset", function()
        local plugin, s = pluginWithParked(1)
        local item = s:parked()[1]

        QueueMenu.buildEntryMenu(plugin, item)[3].callback()

        assert.equals(1, s:count())
        assert.equals(0, s:parkedCount())
        assert.equals(0, s:pending()[1].entry.attempts)
    end)

    it("puts every item back at once", function()
        local plugin, s = pluginWithParked(3)
        local items = QueueMenu.buildParkedMenu(plugin)

        items[#items - 1].callback()

        assert.equals(3, s:count())
        assert.equals(0, s:parkedCount())
    end)

    it("deletes one item", function()
        local plugin, s = pluginWithParked(2)
        local item = s:parked()[1]

        -- No ConfirmBox outside KOReader, so the action runs directly.
        QueueMenu.buildEntryMenu(plugin, item)[4].callback()

        assert.equals(1, s:parkedCount())
    end)

    it("deletes every item at once", function()
        local plugin, s = pluginWithParked(3)
        local items = QueueMenu.buildParkedMenu(plugin)

        items[#items].callback()

        assert.equals(0, s:parkedCount())
    end)

    it("reports the count for the Diagnostics row", function()
        local plugin = pluginWithParked(2)
        assert.matches("Set%-aside items: 2", QueueMenu.describeParked(plugin))
    end)

    it("survives having no queue at all", function()
        local items = QueueMenu.buildParkedMenu({})
        assert.equals(1, #items)
        assert.matches("not available", items[1].text)
    end)
end)
