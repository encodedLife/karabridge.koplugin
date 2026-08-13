--[[--
The sidecar is not the truth while the book is open.

Three defects came out of assuming it was, and they are all the same mistake:

  * a highlight made this session reached the card but never became a Karakeep
    highlight, because `clip.lua` renders the card from
    `ui.annotation.annotations` while the sync read the `.sdr` file;
  * a note pulled from Karakeep was written to that file and then erased,
    because `ReaderAnnotation:onSaveSettings` writes its in-memory array over
    the whole thing on close;
  * the card's own bookmark ID went the same way, which would have produced a
    duplicate card on the next export.
]]

local Helper = require("spec.support.helper")

local Annotations = require("karabridge.features.article_sync.annotations")
local Metadata = require("karabridge.shared.metadata")

local BOOK = "/books/open.epub"

describe("Metadata.liveDocument", function()
    before_each(function()
        Helper.install()
    end)

    after_each(function()
        Metadata.setLiveDocumentProvider(nil)
        Helper.uninstall()
    end)

    it("is nil without a provider", function()
        assert.is_nil(Metadata.liveDocument(BOOK))
    end)

    it("is nil for a different file than the one open", function()
        Metadata.setLiveDocumentProvider(function()
            return { file = "/books/other.epub", annotations = {} }
        end)
        assert.is_nil(Metadata.liveDocument(BOOK))
    end)

    it("survives a provider that throws", function()
        -- It runs on every sidecar access, so it must never take an export down.
        Metadata.setLiveDocumentProvider(function()
            error("no UI here")
        end)
        assert.is_nil(Metadata.liveDocument(BOOK))
    end)

    it("returns KOReader's objects for the open file", function()
        local live = { file = BOOK, annotations = { { text = "one" } } }
        Metadata.setLiveDocumentProvider(function()
            return live
        end)
        assert.equals(live, Metadata.liveDocument(BOOK))
    end)
end)

describe("Annotations against an open document", function()
    before_each(function()
        Helper.install()
    end)

    after_each(function()
        Metadata.setLiveDocumentProvider(nil)
        Helper.uninstall()
    end)

    it("sees a highlight that has not reached the sidecar yet", function()
        -- Exactly the reported symptom: mark a passage, export without closing
        -- the book. The card body has it, because KOReader builds that from the
        -- live array; the sidecar still holds two.
        Helper.mocks.docsettings.seed(BOOK, {
            annotations = { { text = "one" }, { text = "two" } },
        })

        local live = {
            file = BOOK,
            annotations = { { text = "one" }, { text = "two" }, { text = "three" } },
        }
        Metadata.setLiveDocumentProvider(function()
            return live
        end)

        local read = Annotations.read(BOOK)

        assert.equals(3, #read)
        assert.equals("three", read[3].text)
    end)

    it("falls back to the sidecar for a book that is not open", function()
        Helper.mocks.docsettings.seed(BOOK, { annotations = { { text = "one" } } })
        Metadata.setLiveDocumentProvider(function()
            return { file = "/books/elsewhere.epub", annotations = {} }
        end)

        assert.equals(1, #Annotations.read(BOOK))
    end)

    it("writes a pulled note into the array KOReader will save", function()
        -- Writing the sidecar instead would look like it worked and then be
        -- overwritten wholesale when the book closes.
        Helper.mocks.docsettings.seed(BOOK, { annotations = { { text = "one" } } })

        local live_array = { { text = "one" } }
        Metadata.setLiveDocumentProvider(function()
            return {
                file = BOOK,
                annotations = live_array,
                doc_settings = Helper.mocks.docsettings:open(BOOK),
            }
        end)

        local ok, applied = Annotations.apply(BOOK, {
            { index = 1, expect_text = "one", note = "from Karakeep" },
        })

        assert.is_true(ok)
        assert.equals(1, applied)
        assert.equals("from Karakeep", live_array[1].note)
    end)

    it("still writes the sidecar for a book that is not open", function()
        Helper.mocks.docsettings.seed(BOOK, { annotations = { { text = "one" } } })

        local ok = Annotations.apply(BOOK, {
            { index = 1, expect_text = "one", note = "from Karakeep" },
        })

        assert.is_true(ok)
        assert.equals("from Karakeep", Helper.mocks.docsettings.peek(BOOK).annotations[1].note)
    end)
end)

describe("Metadata against an open document", function()
    before_each(function()
        Helper.install()
    end)

    after_each(function()
        Metadata.setLiveDocumentProvider(nil)
        Helper.uninstall()
    end)

    it("writes the card ID where KOReader's own flush will keep it", function()
        -- DocSettings:flush dumps its instance's table wholesale. A key written
        -- through a second instance is erased when KOReader flushes its own on
        -- close -- and losing the card ID means a duplicate card next time.
        Helper.mocks.docsettings.seed(BOOK, { annotations = {} })

        local live_settings = Helper.mocks.docsettings:open(BOOK)
        Metadata.setLiveDocumentProvider(function()
            return { file = BOOK, annotations = {}, doc_settings = live_settings }
        end)

        assert.is_true(Metadata.write(BOOK, { book_card = { bookmark_id = "card1" } }))
        assert.equals("card1", live_settings:readSetting("karabridge").book_card.bookmark_id)
    end)
end)
