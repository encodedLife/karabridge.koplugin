local Helper = require("spec.support.helper")

local Defaults = require("karabridge.config.defaults")

local CONF_PATH = "/tmp/karabridge-test/karabridge.conf"

--- Make a config file appear at the primary search location.
--
-- Filesystem.readFile uses io.open directly, so the mock lfs is not enough:
-- the file has to exist. It is written to the real temporary directory the
-- mock DataStorage points at.
local function writeConfig(contents)
    os.execute("mkdir -p /tmp/karabridge-test")
    local handle = assert(io.open(CONF_PATH, "w"))
    handle:write(contents)
    handle:close()
    Helper.mocks.filesystem.addFile(CONF_PATH)
end

local function removeConfig()
    os.remove(CONF_PATH)
end

describe("Settings", function()
    before_each(function()
        Helper.install()
        Helper.mocks.datastorage.setRoot("/tmp/karabridge-test")
        removeConfig()
    end)

    after_each(function()
        Helper.uninstall()
        removeConfig()
    end)

    describe("reading and writing", function()
        it("falls back to the schema default", function()
            local settings = Helper.settings()
            assert.equals(30, settings:get("articles_per_sync"))
            assert.equals("default", settings:originOf("articles_per_sync"))
        end)

        it("prefers a value in the store", function()
            local settings = Helper.settings({ articles_per_sync = 5 })
            assert.equals(5, settings:get("articles_per_sync"))
            assert.equals("device", settings:originOf("articles_per_sync"))
        end)

        it("does not write a default back when reading it", function()
            -- The whole config-seeding scheme depends on an unset key staying
            -- unset until something actually sets it.
            local settings, store = Helper.settings()
            settings:get("articles_per_sync")
            assert.is_false(store:has("articles_per_sync"))
        end)

        it("normalises the server address on the way in", function()
            local settings = Helper.settings()
            settings:set("server_url", "  https://k.example.org/api/v1/  ")
            assert.equals("https://k.example.org", settings:get("server_url"))
        end)

        it("refuses an invalid value instead of coercing it", function()
            local settings = Helper.settings()
            local ok, problem = settings:set("articles_per_sync", 0)
            assert.is_false(ok)
            assert.matches("at least", problem)
            assert.equals(30, settings:get("articles_per_sync"))
        end)

        it("guards the internal keys behind a separate setter", function()
            local settings = Helper.settings()
            assert.has_error(function()
                settings:setInternal("articles_per_sync", 1)
            end)
            settings:setInternal("last_auto_sync", 12345)
            assert.equals(12345, settings:getInternal("last_auto_sync"))
        end)
    end)

    describe("seeding from the config file", function()
        it("does nothing when there is no file", function()
            local settings = Helper.settings()
            local outcome = settings:seedFromConfigFile()

            assert.is_nil(outcome.path)
            assert.equals(0, outcome.seeded)
        end)

        it("fills in settings that are not set on the device", function()
            writeConfig("server_url = https://k.example.org\narticles_per_sync = 7\n")

            local settings = Helper.settings()
            local outcome = settings:seedFromConfigFile()

            assert.equals(CONF_PATH, outcome.path)
            assert.equals(2, outcome.seeded)
            assert.equals("https://k.example.org", settings:get("server_url"))
            assert.equals(7, settings:get("articles_per_sync"))
        end)

        it("records that a seeded value came from the file", function()
            writeConfig("articles_per_sync = 7\n")

            local settings = Helper.settings()
            settings:seedFromConfigFile()

            assert.equals("file", settings:originOf("articles_per_sync"))
        end)

        it("leaves a value already set on the device alone", function()
            -- The precedence rule, stated as a test: the menu wins. A setting
            -- changed on the device must not silently revert at the next start.
            writeConfig("articles_per_sync = 7\n")

            local settings = Helper.settings({ articles_per_sync = 99 })
            local outcome = settings:seedFromConfigFile()

            assert.equals(0, outcome.seeded)
            assert.equals(1, outcome.kept)
            assert.equals(99, settings:get("articles_per_sync"))
        end)

        it("seeds only the keys the file does not already cover on the device", function()
            writeConfig("server_url = https://k.example.org\narticles_per_sync = 7\n")

            local settings = Helper.settings({ articles_per_sync = 99 })
            local outcome = settings:seedFromConfigFile()

            assert.equals(1, outcome.seeded)
            assert.equals(1, outcome.kept)
            assert.equals(99, settings:get("articles_per_sync"))
            assert.equals("https://k.example.org", settings:get("server_url"))
        end)

        it("reports problems without abandoning the good lines", function()
            writeConfig("server_url = https://k.example.org\nbogus_key = 1\n")

            local settings = Helper.settings()
            local outcome = settings:seedFromConfigFile()

            assert.equals(1, outcome.seeded)
            assert.equals(1, #outcome.problems)
            assert.matches("unknown setting", outcome.problems[1])
        end)

        it("rejects a value that parses but fails validation", function()
            writeConfig("articles_per_sync = 0\n")

            local settings = Helper.settings()
            local outcome = settings:seedFromConfigFile()

            assert.equals(0, outcome.seeded)
            assert.equals(1, #outcome.problems)
            assert.equals(30, settings:get("articles_per_sync"))
        end)

        it("never writes the token to the log", function()
            writeConfig("api_token = ak1_super_secret_value\n")

            local settings = Helper.settings()
            settings:seedFromConfigFile()

            assert.equals("ak1_super_secret_value", settings:get("api_token"))
            assert.is_false(Helper.mocks.logger.contains("ak1_super_secret_value"))
        end)

        it("flushes once, not once per key", function()
            writeConfig("server_url = https://k.example.org\narticles_per_sync = 7\n")

            local settings, store = Helper.settings()
            settings:seedFromConfigFile()

            assert.equals(1, store.flush_count)
        end)
    end)

    describe("reloading the config file", function()
        it("overrides a value already set on the device", function()
            -- The one sanctioned override, because the user asked for it by name.
            writeConfig("articles_per_sync = 7\n")

            local settings = Helper.settings({ articles_per_sync = 99 })
            local outcome = settings:reloadConfigFile()

            assert.equals(1, outcome.applied)
            assert.equals(7, settings:get("articles_per_sync"))
            assert.equals("file", settings:originOf("articles_per_sync"))
        end)

        it("reports when there is no file to reload", function()
            local settings = Helper.settings()
            local outcome = settings:reloadConfigFile()

            assert.is_nil(outcome.path)
            assert.equals(0, outcome.applied)
        end)

        it("leaves settings the file does not mention untouched", function()
            writeConfig("articles_per_sync = 7\n")

            local settings = Helper.settings({ articles_per_sync = 99, max_images = 3 })
            settings:reloadConfigFile()

            assert.equals(3, settings:get("max_images"))
        end)
    end)

    describe("describe", function()
        it("masks the API token", function()
            local settings = Helper.settings({ api_token = "ak1_super_secret_value" })
            local dump = table.concat(settings:describe(), "\n")

            assert.is_nil(dump:find("ak1_super_secret_value", 1, true))
            assert.matches("api_token = %*+alue", dump)
        end)

        it("strips credentials from the server address", function()
            local settings, store = Helper.settings()
            -- Written straight to the store: set() would refuse this, which is
            -- the point -- describe() still has to cope with a value that got
            -- in some other way, such as an older version of the plugin.
            store:saveSetting("server_url", "https://u:pw@k.example.org")

            local dump = table.concat(settings:describe(), "\n")
            assert.is_nil(dump:find("pw@", 1, true))
        end)

        it("covers every setting and says where each came from", function()
            local settings = Helper.settings()
            local lines = settings:describe()

            assert.equals(#Defaults.keys(), #lines)
            for _, line in ipairs(lines) do
                assert.matches("%[%a+%]$", line)
            end
        end)
    end)

    describe("readiness", function()
        it("reflects the current values", function()
            local settings = Helper.settings({
                server_url = "https://k.example.org",
                api_token = "ak1_x",
                download_folder = "/downloads",
            })
            local readiness = settings:readiness()

            assert.is_true(readiness.connect)
            assert.is_true(readiness.download)
        end)
    end)
end)
