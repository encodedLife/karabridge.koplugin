require("spec.support.helper")

local Paths = require("karabridge.shared.paths")

describe("Paths", function()
    describe("join", function()
        it("joins with a single separator", function()
            assert.equals("/a/b/c", Paths.join("/a", "b", "c"))
        end)

        it("does not double a separator", function()
            assert.equals("/a/b", Paths.join("/a/", "/b"))
        end)

        it("skips empty segments", function()
            assert.equals("/a/b", Paths.join("/a", "", "b"))
        end)
    end)

    describe("basename and dirname", function()
        it("splits a normal path", function()
            assert.equals("book.epub", Paths.basename("/mnt/onboard/book.epub"))
            assert.equals("/mnt/onboard", Paths.dirname("/mnt/onboard/book.epub"))
        end)

        it("handles a path with no directory", function()
            assert.equals("book.epub", Paths.basename("book.epub"))
            assert.equals(".", Paths.dirname("book.epub"))
        end)

        it("handles a file at the root", function()
            assert.equals("/", Paths.dirname("/book.epub"))
        end)
    end)

    describe("sanitiseFilename", function()
        it("replaces characters FAT32 refuses", function()
            assert.equals("a_b_c_d", Paths.sanitiseFilename('a/b:c"d'))
        end)

        it("turns brackets into parentheses so the ID prefix stays unambiguous", function()
            assert.equals("(draft) Title", Paths.sanitiseFilename("[draft] Title"))
        end)

        it("strips control characters", function()
            assert.equals("a b", Paths.sanitiseFilename("a\1\2b"))
        end)

        it("never ends in a dot or a space", function()
            assert.equals("Title", Paths.sanitiseFilename("Title. . "))
        end)

        it("never returns an empty name", function()
            assert.equals("Untitled", Paths.sanitiseFilename(""))
            assert.equals("Untitled", Paths.sanitiseFilename(nil))
            assert.equals("Untitled", Paths.sanitiseFilename("..."))
        end)

        it("truncates without splitting a character", function()
            local name = Paths.sanitiseFilename(string.rep("\195\164", 10), 5)
            assert.equals("\195\164\195\164", name)
        end)
    end)

    describe("article filenames", function()
        it("embeds the bookmark ID so it survives the filesystem", function()
            local name = Paths.buildArticleFilename("abc123", "A Title")
            assert.equals("[kb-id_abc123] A Title.epub", name)
        end)

        it("reads the ID back out", function()
            local name = Paths.buildArticleFilename("abc123", "A Title")
            assert.equals("abc123", Paths.parseArticleId(name))
        end)

        it("reads the ID out of a full path", function()
            assert.equals("xyz", Paths.parseArticleId("/mnt/onboard/karabridge/[kb-id_xyz] T.epub"))
        end)

        it("does not claim another plugin's files", function()
            -- Other plugins tag their downloads with their own prefixes.
            -- Mistaking one
            -- for ours would mean archiving or deleting a file we do not own.
            assert.is_nil(Paths.parseArticleId("[xx-id_abc] Title.epub"))
            assert.is_nil(Paths.parseArticleId("[w-id_123] Title.epub"))
            assert.is_nil(Paths.parseArticleId("Ordinary Book.epub"))
        end)

        it("rejects a malformed prefix", function()
            assert.is_nil(Paths.parseArticleId("[kb-id_] Title.epub"))
            assert.is_nil(Paths.parseArticleId("[kb-id_abc Title.epub"))
        end)

        it("rejects an ID containing a path separator", function()
            assert.is_nil(Paths.parseArticleId("[kb-id_../../etc] x.epub"))
        end)

        it("keeps the whole name within the filesystem limit", function()
            local name = Paths.buildArticleFilename("abc123", string.rep("x", 400))
            assert.is_true(#name <= Paths.MAX_FILENAME_BYTES)
        end)

        it("survives an implausibly long ID without producing a negative budget", function()
            local name = Paths.buildArticleFilename(string.rep("i", 300), "Title")
            assert.is_string(name)
            assert.is_true(#name > 0)
        end)
    end)

    describe("normalise", function()
        it("removes . segments", function()
            assert.equals("/a/b", Paths.normalise("/a/./b"))
        end)

        it("resolves .. segments", function()
            assert.equals("/a/c", Paths.normalise("/a/b/../c"))
        end)

        it("cannot climb above an absolute root", function()
            assert.equals("/a", Paths.normalise("/../../a"))
        end)

        it("keeps leading .. on a relative path", function()
            assert.equals("../a", Paths.normalise("../a"))
        end)

        it("collapses duplicate separators", function()
            assert.equals("/a/b", Paths.normalise("/a//b"))
        end)
    end)

    describe("traversal prevention", function()
        it("accepts a path inside the root", function()
            assert.is_true(Paths.isInside("/downloads", "/downloads/a/b.epub"))
        end)

        it("accepts the root itself", function()
            assert.is_true(Paths.isInside("/downloads", "/downloads"))
        end)

        it("rejects an escape via ..", function()
            assert.is_false(Paths.isInside("/downloads", "/downloads/../etc/passwd"))
        end)

        it("rejects a sibling directory with a shared prefix", function()
            -- "/downloads-other" starts with "/downloads" as a string but is
            -- not inside it; a naive prefix check gets this wrong.
            assert.is_false(Paths.isInside("/downloads", "/downloads-other/x"))
        end)

        describe("resolveInside", function()
            it("resolves an ordinary relative path", function()
                assert.equals("/downloads/images/img1.jpg", Paths.resolveInside("/downloads", "images/img1.jpg"))
            end)

            it("refuses a path that climbs out", function()
                assert.is_nil(Paths.resolveInside("/downloads", "../../etc/passwd"))
            end)

            it("refuses an absolute path", function()
                assert.is_nil(Paths.resolveInside("/downloads", "/etc/passwd"))
            end)
        end)
    end)
end)
