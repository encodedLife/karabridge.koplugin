local Helper = require("spec.support.helper")

local Metadata = require("karabridge.shared.metadata")

local BOOK = "/books/novel.epub"

describe("Metadata", function()
    before_each(function()
        Helper.install()
    end)

    after_each(function()
        Helper.uninstall()
    end)

    describe("migrate", function()
        it("returns nothing when there is nothing to migrate", function()
            local migrated, changed = Metadata.migrate(nil, nil)
            assert.is_nil(migrated)
            assert.is_false(changed)
        end)

        it("leaves current metadata alone", function()
            local current = { version = Metadata.SCHEMA_VERSION, book_card = { bookmark_id = "b1" } }
            local migrated, changed = Metadata.migrate(current, nil)

            assert.is_false(changed)
            assert.equals("b1", migrated.book_card.bookmark_id)
        end)

        it("stamps a version onto version-less metadata", function()
            local migrated, changed = Metadata.migrate({ book_card = { bookmark_id = "b1" } }, nil)

            assert.is_true(changed)
            assert.equals(Metadata.SCHEMA_VERSION, migrated.version)
            assert.equals("b1", migrated.book_card.bookmark_id)
        end)

        it("adopts a bookmark ID left by an older integration", function()
            -- Without this, the first KaraBridge export would create a second
            -- card for a book that already has one -- exactly the duplicate
            -- the stored ID exists to prevent.
            local legacy = { bookmark = { id = "old1", createdAt = "2024-01-01" }, last_updated = "2024-01-01" }
            local migrated, changed = Metadata.migrate(nil, legacy)

            assert.is_true(changed)
            assert.equals("old1", migrated.book_card.bookmark_id)
            assert.equals("legacy", migrated.book_card.imported_from)
        end)

        it("records no content hash for an adopted card, so the next export runs", function()
            local legacy = { bookmark = { id = "old1" } }
            local migrated = Metadata.migrate(nil, legacy)

            assert.is_nil(migrated.book_card.content_hash)
        end)

        it("ignores a legacy table with no bookmark ID", function()
            assert.is_nil(Metadata.migrate(nil, { last_updated = "x" }))
            assert.is_nil(Metadata.migrate(nil, { bookmark = {} }))
        end)

        it("prefers our own metadata over the legacy plugin's", function()
            local mine = { version = 1, book_card = { bookmark_id = "mine" } }
            local legacy = { bookmark = { id = "theirs" } }

            assert.equals("mine", Metadata.migrate(mine, legacy).book_card.bookmark_id)
        end)
    end)

    describe("read", function()
        it("returns nothing for a document with no sidecar", function()
            assert.is_nil(Metadata.read(BOOK))
        end)

        it("returns nothing for a sidecar with no KaraBridge data", function()
            Helper.mocks.docsettings.seed(BOOK, { summary = { status = "complete" } })
            assert.is_nil(Metadata.read(BOOK))
        end)

        it("reads stored metadata", function()
            Helper.mocks.docsettings.seed(BOOK, {
                karabridge = { version = 1, article = { bookmark_id = "a1" } },
            })

            assert.equals("a1", Metadata.read(BOOK).article.bookmark_id)
        end)

        it("writes a migration back, so it happens once and not on every read", function()
            Helper.mocks.docsettings.seed(BOOK, { karakeep = { bookmark = { id = "old1" } } })

            Metadata.read(BOOK)

            local stored = Helper.mocks.docsettings.peek(BOOK).karabridge
            assert.equals("old1", stored.book_card.bookmark_id)
            assert.equals(1, Helper.mocks.docsettings.flushCount(BOOK))

            Metadata.read(BOOK)
            assert.equals(1, Helper.mocks.docsettings.flushCount(BOOK))
        end)

        it("leaves the legacy plugin's own key untouched", function()
            -- Both plugins may be installed during a migration; corrupting the
            -- other one's records would be a poor way to win the user over.
            Helper.mocks.docsettings.seed(BOOK, { karakeep = { bookmark = { id = "old1" } } })

            Metadata.read(BOOK)

            assert.equals("old1", Helper.mocks.docsettings.peek(BOOK).karakeep.bookmark.id)
        end)
    end)

    describe("write and update", function()
        it("stamps the schema version on every write", function()
            Helper.mocks.docsettings.seed(BOOK, {})
            Metadata.write(BOOK, { book_card = { bookmark_id = "b1" } })

            assert.equals(Metadata.SCHEMA_VERSION, Helper.mocks.docsettings.peek(BOOK).karabridge.version)
        end)

        it("overrides a version a caller tries to set by hand", function()
            Helper.mocks.docsettings.seed(BOOK, {})
            Metadata.write(BOOK, { version = 99 })

            assert.equals(Metadata.SCHEMA_VERSION, Helper.mocks.docsettings.peek(BOOK).karabridge.version)
        end)

        it("merges into one section without disturbing the other", function()
            Helper.mocks.docsettings.seed(BOOK, {
                karabridge = {
                    version = 1,
                    article = { bookmark_id = "a1", source_url = "https://x" },
                    book_card = { bookmark_id = "b1" },
                },
            })

            Metadata.update(BOOK, "article", { content_hash = "deadbeef" })

            local stored = Helper.mocks.docsettings.peek(BOOK).karabridge
            assert.equals("a1", stored.article.bookmark_id)
            assert.equals("https://x", stored.article.source_url)
            assert.equals("deadbeef", stored.article.content_hash)
            assert.equals("b1", stored.book_card.bookmark_id)
        end)

        it("creates the section when it does not exist yet", function()
            Helper.mocks.docsettings.seed(BOOK, {})
            Metadata.update(BOOK, "book_card", { bookmark_id = "b1" })

            assert.equals("b1", Helper.mocks.docsettings.peek(BOOK).karabridge.book_card.bookmark_id)
        end)

        it("refuses a non-table payload rather than corrupting the sidecar", function()
            Helper.mocks.docsettings.seed(BOOK, {})
            assert.is_false(Metadata.write(BOOK, "nonsense"))
        end)
    end)

    describe("accessors", function()
        it("finds the card ID for a local book", function()
            Helper.mocks.docsettings.seed(BOOK, {
                karabridge = { version = 1, book_card = { bookmark_id = "b1" } },
            })
            assert.equals("b1", Metadata.getBookCardId(BOOK))
        end)

        it("finds the article ID for a downloaded article", function()
            Helper.mocks.docsettings.seed(BOOK, {
                karabridge = { version = 1, article = { bookmark_id = "a1" } },
            })
            assert.equals("a1", Metadata.getArticleId(BOOK))
        end)

        it("returns nothing rather than throwing when there is no metadata", function()
            assert.is_nil(Metadata.getBookCardId(BOOK))
            assert.is_nil(Metadata.getArticleId(BOOK))
        end)
    end)
end)
