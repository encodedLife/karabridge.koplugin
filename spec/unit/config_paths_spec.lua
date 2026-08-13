local Helper = require("spec.support.helper")

local ConfigPaths = require("karabridge.config.paths")

describe("ConfigPaths", function()
    before_each(function()
        Helper.install()
        Helper.mocks.datastorage.setRoot("/tmp/karabridge-test")
    end)

    after_each(function()
        Helper.uninstall()
    end)

    describe("candidates", function()
        it("lists the data directory first", function()
            -- On a Kobo the data directory is on the mounted storage
            -- partition, so this is the file a user reaches by plugging the
            -- device into a computer -- the entire point of a config file.
            local candidates = ConfigPaths.candidates("/plugins/karabridge.koplugin")
            assert.equals("/tmp/karabridge-test/karabridge.conf", candidates[1])
        end)

        it("lists the settings directory second and the plugin directory last", function()
            local candidates = ConfigPaths.candidates("/plugins/karabridge.koplugin")
            assert.equals("/tmp/karabridge-test/settings/karabridge.conf", candidates[2])
            assert.equals("/plugins/karabridge.koplugin/karabridge.conf", candidates[3])
        end)

        it("omits the plugin directory when it is unknown", function()
            local candidates = ConfigPaths.candidates(nil)
            assert.equals(2, #candidates)
        end)

        it("always uses the same filename", function()
            for _, path in ipairs(ConfigPaths.candidates("/plugins/x")) do
                assert.matches("karabridge%.conf$", path)
            end
        end)
    end)

    describe("find", function()
        it("returns nothing when no file exists", function()
            assert.is_nil(ConfigPaths.find("/plugins/karabridge.koplugin"))
        end)

        it("returns the first candidate that exists", function()
            Helper.mocks.filesystem.addFile("/tmp/karabridge-test/karabridge.conf")
            Helper.mocks.filesystem.addFile("/plugins/karabridge.koplugin/karabridge.conf")

            assert.equals("/tmp/karabridge-test/karabridge.conf", ConfigPaths.find("/plugins/karabridge.koplugin"))
        end)

        it("falls through to a later candidate", function()
            Helper.mocks.filesystem.addFile("/plugins/karabridge.koplugin/karabridge.conf")

            assert.equals(
                "/plugins/karabridge.koplugin/karabridge.conf",
                ConfigPaths.find("/plugins/karabridge.koplugin")
            )
        end)

        it("ignores a directory that happens to have the right name", function()
            Helper.mocks.filesystem.addDirectory("/tmp/karabridge-test/karabridge.conf")
            assert.is_nil(ConfigPaths.find(nil))
        end)
    end)

    describe("derived locations", function()
        it("always writes the example file to the data directory", function()
            -- Not wherever a file happened to be found: the point of the
            -- action is a file the user can reach from a computer, and the
            -- plugin folder is not reliably that.
            assert.equals("/tmp/karabridge-test/karabridge.conf", ConfigPaths.templateTarget())
        end)

        it("keeps plugin data in its own directory", function()
            assert.equals("/tmp/karabridge-test/karabridge", ConfigPaths.dataDir())
        end)

        it("names the settings store distinctly from the other two plugins", function()
            -- Another Karakeep integration may write its own file into the
            -- same settings directory. Sharing either
            -- name would corrupt that plugin's settings during a migration.
            local path = ConfigPaths.settingsFile()
            assert.equals("/tmp/karabridge-test/settings/karabridge.lua", path)
        end)
    end)

    describe("without a DataStorage backend", function()
        before_each(function()
            ConfigPaths.setBackend(nil)
            -- Force the lazy require to resolve to nothing, as it would under
            -- a plain interpreter with no KOReader present.
            package.loaded["datastorage"] = nil
        end)

        it("degrades to the plugin directory rather than throwing", function()
            local candidates = ConfigPaths.candidates("/plugins/karabridge.koplugin")
            assert.equals("/plugins/karabridge.koplugin/karabridge.conf", candidates[#candidates])
        end)
    end)
end)
