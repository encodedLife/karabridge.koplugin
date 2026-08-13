local Helper = require("spec.support.helper")

local Filesystem = require("karabridge.shared.filesystem")

-- readFile and writeFile go through io.open, so they are exercised against a
-- real temporary directory rather than the mock. The interesting failures
-- there -- a rename that fails, a directory that is not writable -- are
-- exactly the ones a mock would paper over.
local TMP = "/tmp/karabridge-fs-test"

local function shell(command)
    -- os.execute's return convention differs between Lua 5.1 and later; the
    -- specs only need the side effect.
    os.execute(command)
end

describe("Filesystem", function()
    describe("with a mocked lfs", function()
        before_each(function()
            Helper.install()
        end)

        after_each(function()
            Helper.uninstall()
        end)

        it("distinguishes a file from a directory", function()
            Helper.mocks.filesystem.addFile("/a/file.txt", 12)
            Helper.mocks.filesystem.addDirectory("/a/dir")

            assert.is_true(Filesystem.fileExists("/a/file.txt"))
            assert.is_false(Filesystem.directoryExists("/a/file.txt"))
            assert.is_true(Filesystem.directoryExists("/a/dir"))
            assert.is_false(Filesystem.fileExists("/a/dir"))
        end)

        it("answers no for a missing path rather than throwing", function()
            assert.is_false(Filesystem.fileExists("/nope"))
            assert.is_false(Filesystem.directoryExists("/nope"))
            assert.is_nil(Filesystem.fileSize("/nope"))
        end)

        it("answers no for a nil or empty path", function()
            assert.is_false(Filesystem.fileExists(nil))
            assert.is_false(Filesystem.directoryExists(""))
        end)

        it("reports a file's size", function()
            Helper.mocks.filesystem.addFile("/a/file.txt", 4096)
            assert.equals(4096, Filesystem.fileSize("/a/file.txt"))
        end)

        it("creates missing parent directories", function()
            local result = Filesystem.ensureDirectory("/a/b/c")

            assert.is_true(result:isOk())
            assert.is_true(Filesystem.directoryExists("/a"))
            assert.is_true(Filesystem.directoryExists("/a/b"))
            assert.is_true(Filesystem.directoryExists("/a/b/c"))
        end)

        it("succeeds when the directory already exists", function()
            Helper.mocks.filesystem.addDirectory("/a")
            assert.is_true(Filesystem.ensureDirectory("/a"):isOk())
        end)

        it("refuses an empty path", function()
            assert.equals("invalid_path", Filesystem.ensureDirectory(""):errorCode())
        end)

        it("lists a directory without . and ..", function()
            Helper.mocks.filesystem.addDirectory("/books")
            Helper.mocks.filesystem.addFile("/books/one.epub")
            Helper.mocks.filesystem.addFile("/books/two.epub")
            Helper.mocks.filesystem.addFile("/books/nested/three.epub")

            assert.same({ "one.epub", "two.epub" }, Filesystem.listDirectory("/books"))
        end)

        it("lists nothing for a path that is not a directory", function()
            assert.same({}, Filesystem.listDirectory("/nope"))
        end)
    end)

    describe("against a real directory", function()
        before_each(function()
            shell("rm -rf " .. TMP)
            shell("mkdir -p " .. TMP)
        end)

        teardown(function()
            shell("rm -rf " .. TMP)
        end)

        it("round-trips a file", function()
            local path = TMP .. "/note.md"

            assert.is_true(Filesystem.writeFile(path, "# Notes\n"):isOk())
            assert.equals("# Notes\n", Filesystem.readFile(path).value)
        end)

        it("reports a missing file rather than returning empty content", function()
            -- An empty read and a failed read must not look the same, or a
            -- book's highlights would silently export as nothing.
            local result = Filesystem.readFile(TMP .. "/absent.md")

            assert.is_true(result:isErr())
            assert.equals("not_found", result:errorCode())
        end)

        it("replaces an existing file", function()
            local path = TMP .. "/note.md"
            Filesystem.writeFile(path, "first")
            Filesystem.writeFile(path, "second")

            assert.equals("second", Filesystem.readFile(path).value)
        end)

        it("leaves no temporary file behind", function()
            local path = TMP .. "/note.md"
            Filesystem.writeFile(path, "content")

            local leftover = io.open(path .. ".tmp", "r")
            assert.is_nil(leftover)
        end)

        describe("replaceFile", function()
            -- The dangerous version of this is `os.remove(target)` followed by
            -- `os.rename(source, target)`: if the rename then fails, the only
            -- good copy is already gone. These specs pin the property that
            -- matters -- the previous file survives every failure.
            it("moves a file into place", function()
                local source, target = TMP .. "/new", TMP .. "/live"
                Filesystem.writeFile(source, "new content")

                assert.is_true(Filesystem.replaceFile(source, target):isOk())
                assert.equals("new content", Filesystem.readFile(target).value)
                assert.is_false(Filesystem.fileExists(source))
            end)

            it("replaces an existing file", function()
                local source, target = TMP .. "/new", TMP .. "/live"
                Filesystem.writeFile(target, "old content")
                Filesystem.writeFile(source, "new content")

                assert.is_true(Filesystem.replaceFile(source, target):isOk())
                assert.equals("new content", Filesystem.readFile(target).value)
            end)

            it("keeps the old file when the replacement cannot be moved in", function()
                -- Simulated by pointing the target at a directory: renaming a
                -- file onto a non-empty directory fails on every filesystem.
                local source = TMP .. "/new"
                local target = TMP .. "/occupied"
                shell("mkdir -p " .. target .. " && touch " .. target .. "/keep")
                Filesystem.writeFile(source, "new content")

                local result = Filesystem.replaceFile(source, target)

                assert.is_true(result:isErr())
                assert.equals("rename_failed", result:errorCode())
                assert.is_true(Filesystem.directoryExists(target), "the old target must survive")
            end)

            it("leaves no temporary or backup file behind on success", function()
                local source, target = TMP .. "/new", TMP .. "/live"
                Filesystem.writeFile(target, "old")
                Filesystem.writeFile(source, "new")
                Filesystem.replaceFile(source, target)

                assert.is_false(Filesystem.fileExists(target .. ".karabridge-old"))
                assert.is_false(Filesystem.fileExists(source))
            end)

            it("reports a failure when the destination folder does not exist", function()
                local source = TMP .. "/new"
                Filesystem.writeFile(source, "x")

                local result = Filesystem.replaceFile(source, TMP .. "/missing/live")

                assert.is_true(result:isErr())
                assert.equals("rename_failed", result:errorCode())
            end)
        end)

        it("does not destroy the previous file when a write fails", function()
            -- writeFile goes through replaceFile, so the same property holds
            -- for the queue and for any metadata helper file.
            local path = TMP .. "/queue.lua"
            Filesystem.writeFile(path, "good content")

            -- A directory where the temporary file would go makes io.open fail.
            shell("mkdir -p " .. path .. ".karabridge-tmp")
            local result = Filesystem.writeFile(path, "replacement")
            shell("rmdir " .. path .. ".karabridge-tmp")

            assert.is_true(result:isErr())
            assert.equals("good content", Filesystem.readFile(path).value)
        end)

        it("reports a write into a directory that does not exist", function()
            local result = Filesystem.writeFile(TMP .. "/missing/note.md", "x")

            assert.is_true(result:isErr())
            assert.equals("open_failed", result:errorCode())
        end)

        it("accepts a writable directory", function()
            assert.is_true(Filesystem.checkWritableDirectory(TMP):isOk())
        end)

        it("creates the directory if it is missing, then accepts it", function()
            local path = TMP .. "/downloads/karabridge"
            assert.is_true(Filesystem.checkWritableDirectory(path):isOk())
            assert.is_true(Filesystem.directoryExists(path))
        end)

        it("leaves no probe file behind", function()
            Filesystem.checkWritableDirectory(TMP)

            local probe = io.open(TMP .. "/" .. Filesystem.PROBE_NAME, "r")
            assert.is_nil(probe)
        end)

        it("rejects an unwritable directory up front", function()
            -- Without this the failure surfaces later as every article failing
            -- to build, one confusing line at a time, from inside the zip
            -- writer. Skipped when running as root, for whom nothing is
            -- unwritable.
            local readonly = TMP .. "/readonly"
            shell("mkdir -p " .. readonly .. " && chmod 500 " .. readonly)

            local probe = io.open(readonly .. "/probe", "w")
            if probe then
                probe:close()
                shell("chmod 700 " .. readonly)
                return -- running as root; the check is not meaningful here
            end

            local result = Filesystem.checkWritableDirectory(readonly)
            shell("chmod 700 " .. readonly)

            assert.is_true(result:isErr())
            assert.equals("not_writable", result:errorCode())
        end)

        it("refuses an empty folder setting with a message about the folder", function()
            local result = Filesystem.checkWritableDirectory("")

            assert.equals("invalid_path", result:errorCode())
            assert.matches("download folder", result.message)
        end)
    end)
end)
