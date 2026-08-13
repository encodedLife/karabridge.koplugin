require("spec.support.helper")

local ConfigFile = require("karabridge.config.config_file")
local Defaults = require("karabridge.config.defaults")
local Validation = require("karabridge.config.validation")

describe("ConfigFile.parse", function()
    it("reads key = value", function()
        local values = ConfigFile.parse("server_url = https://k.example.org")
        assert.equals("https://k.example.org", values.server_url)
    end)

    it("reads key: value as well", function()
        local values = ConfigFile.parse("server_url: https://k.example.org")
        assert.equals("https://k.example.org", values.server_url)
    end)

    it("ignores blank lines and both comment markers", function()
        local values, problems = ConfigFile.parse(table.concat({
            "# a comment",
            "; another",
            "",
            "   ",
            "articles_per_sync = 5",
        }, "\n"))

        assert.equals(5, values.articles_per_sync)
        assert.same({}, problems)
    end)

    it("takes a value to the end of the line, so a URL needs no quoting", function()
        local values = ConfigFile.parse("server_url = https://k.example.org:3000/path?x=1")
        assert.equals("https://k.example.org:3000/path?x=1", values.server_url)
    end)

    it("strips surrounding quotes, which is the only way to keep edge whitespace", function()
        local values = ConfigFile.parse('archive_tag = " read on kobo "')
        assert.equals(" read on kobo ", values.archive_tag)
    end)

    it("coerces numbers", function()
        local values = ConfigFile.parse("articles_per_sync = 42")
        assert.equals(42, values.articles_per_sync)
        assert.is_number(values.articles_per_sync)
    end)

    it("accepts every spelling of a boolean", function()
        for _, word in ipairs({ "true", "yes", "on", "1", "TRUE", "Yes" }) do
            local values = ConfigFile.parse("download_images = " .. word)
            assert.is_true(values.download_images, word .. " should be true")
        end
        for _, word in ipairs({ "false", "no", "off", "0", "FALSE" }) do
            local values = ConfigFile.parse("download_images = " .. word)
            assert.is_false(values.download_images, word .. " should be false")
        end
    end)

    it("reports an unknown key instead of ignoring it", function()
        -- A typo in a config file is otherwise completely invisible: the
        -- setting simply never takes effect and there is nothing to see.
        local values, problems = ConfigFile.parse("server_ur1 = https://k.example.org")
        assert.is_nil(values.server_ur1)
        assert.equals(1, #problems)
        assert.matches("unknown setting", problems[1])
        assert.matches("line 1", problems[1])
    end)

    it("refuses to let the file write an internal bookkeeping key", function()
        local values, problems = ConfigFile.parse("last_auto_sync = 1")
        assert.is_nil(values.last_auto_sync)
        assert.matches("managed by the plugin", problems[1])
    end)

    it("reports a malformed line", function()
        local _, problems = ConfigFile.parse("this is not a setting")
        assert.equals(1, #problems)
        assert.matches("expected 'key = value'", problems[1])
    end)

    it("reports a bad number and a bad boolean by name", function()
        local values, problems = ConfigFile.parse(table.concat({
            "articles_per_sync = many",
            "download_images = maybe",
        }, "\n"))

        assert.is_nil(values.articles_per_sync)
        assert.is_nil(values.download_images)
        assert.equals(2, #problems)
        assert.matches("needs a number", problems[1])
        assert.matches("needs true or false", problems[2])
    end)

    it("keeps the good lines when one line is bad", function()
        local values, problems = ConfigFile.parse(table.concat({
            "server_url = https://k.example.org",
            "nonsense",
            "articles_per_sync = 7",
        }, "\n"))

        assert.equals("https://k.example.org", values.server_url)
        assert.equals(7, values.articles_per_sync)
        assert.equals(1, #problems)
    end)

    it("handles CRLF line endings, because the file is edited on a computer", function()
        local values = ConfigFile.parse("server_url = https://k.example.org\r\narticles_per_sync = 3\r\n")
        assert.equals("https://k.example.org", values.server_url)
        assert.equals(3, values.articles_per_sync)
    end)

    it("returns empty results for a non-string", function()
        local values, problems = ConfigFile.parse(nil)
        assert.same({}, values)
        assert.same({}, problems)
    end)
end)

describe("ConfigFile.template", function()
    local template = ConfigFile.template()

    it("parses cleanly, so the example we ship is never itself broken", function()
        local _, problems = ConfigFile.parse(template)
        assert.same({}, problems)
    end)

    it("mentions every setting in the schema", function()
        -- Generated from the schema rather than kept as a literal, so a new
        -- setting cannot be forgotten here.
        for _, key in ipairs(Defaults.keys()) do
            assert.matches(key, template, key .. " is missing from the template")
        end
    end)

    it("leaves only the two settings the file exists for uncommented", function()
        local values = ConfigFile.parse(template)
        local count = 0
        for _ in pairs(values) do
            count = count + 1
        end
        assert.equals(2, count)
        assert.is_not_nil(values.server_url)
        assert.is_not_nil(values.api_token)
    end)

    it("warns that the file holds a key in plain text", function()
        assert.matches("plain text", template)
    end)
end)

describe("Defaults", function()
    it("gives every setting a type and a group", function()
        for _, key in ipairs(Defaults.keys()) do
            local definition = Defaults.SCHEMA[key]
            assert.is_string(definition.type, key .. " has no type")
            assert.is_string(definition.group, key .. " has no group")
            assert.is_string(definition.description, key .. " has no description")
        end
    end)

    it("marks the API token, and only the API token, as secret", function()
        assert.is_true(Defaults.isSecret("api_token"))
        assert.is_false(Defaults.isSecret("server_url"))
    end)

    it("gives every default a value that passes validation", function()
        for _, key in ipairs(Defaults.keys()) do
            local ok, problem = Validation.checkValue(key, Defaults.get(key))
            assert.is_true(ok, key .. ": " .. tostring(problem))
        end
    end)

    it("keeps internal keys out of the user-facing schema", function()
        for key in pairs(Defaults.INTERNAL_KEYS) do
            assert.is_nil(Defaults.SCHEMA[key], key .. " must not be user-settable")
        end
    end)
end)

describe("Validation", function()
    describe("checkValue", function()
        it("rejects an unknown key", function()
            local ok, problem = Validation.checkValue("nope", 1)
            assert.is_false(ok)
            assert.equals("unknown setting", problem)
        end)

        it("accepts nil as 'not set'", function()
            assert.is_true(Validation.checkValue("download_folder", nil))
        end)

        it("enforces numeric bounds", function()
            assert.is_true(Validation.checkValue("articles_per_sync", 30))
            assert.is_false(Validation.checkValue("articles_per_sync", 0))
            assert.is_false(Validation.checkValue("articles_per_sync", 500))
        end)

        it("enforces types", function()
            assert.is_false(Validation.checkValue("articles_per_sync", "thirty"))
            assert.is_false(Validation.checkValue("download_images", "yes"))
        end)

        it("enforces enumerations", function()
            assert.is_true(Validation.checkValue("book_card_template", "flat"))
            local ok, problem = Validation.checkValue("book_card_template", "fancy")
            assert.is_false(ok)
            assert.matches("must be one of", problem)
        end)

        it("accepts an empty server address as 'not configured yet'", function()
            assert.is_true(Validation.checkValue("server_url", ""))
        end)

        it("rejects a malformed server address", function()
            local ok, problem = Validation.checkValue("server_url", "karakeep.example.org")
            assert.is_false(ok)
            assert.matches("https://", problem)
        end)

        it("rejects credentials in the server address", function()
            local ok, problem = Validation.checkValue("server_url", "https://u:p@k.example.org")
            assert.is_false(ok)
            assert.matches("API key field", problem)
        end)
    end)

    describe("checkReadiness", function()
        it("reports nothing usable on a fresh install", function()
            local readiness = Validation.checkReadiness(Defaults.all())
            assert.is_false(readiness.connect)
            assert.is_false(readiness.download)
            assert.equals(2, #readiness.missing)
        end)

        it("allows connecting before a download folder is chosen", function()
            local readiness = Validation.checkReadiness({
                server_url = "https://k.example.org",
                api_token = "ak1_x",
            })
            assert.is_true(readiness.connect)
            assert.is_false(readiness.download)
        end)

        it("is fully ready once a folder is set", function()
            local readiness = Validation.checkReadiness({
                server_url = "https://k.example.org",
                api_token = "ak1_x",
                download_folder = "/downloads",
            })
            assert.is_true(readiness.connect)
            assert.is_true(readiness.download)
            assert.same({}, readiness.missing)
        end)

        it("respects the download_enabled switch", function()
            local readiness = Validation.checkReadiness({
                server_url = "https://k.example.org",
                api_token = "ak1_x",
                download_folder = "/downloads",
                download_enabled = false,
            })
            assert.is_false(readiness.download)
        end)
    end)

    describe("describeMissing", function()
        it("says nothing when nothing is missing", function()
            assert.equals("", Validation.describeMissing({}))
        end)

        it("reads naturally for one item", function()
            assert.equals("Set an API key first.", Validation.describeMissing({ "an API key" }))
        end)

        it("reads naturally for several", function()
            assert.equals(
                "Set a, b and c first.",
                Validation.describeMissing({ "a", "b", "c" })
            )
        end)
    end)
end)

describe("the README's settings table", function()
    -- The install section had drifted for weeks before anyone noticed, and the
    -- settings table is the part people copy from. A setting that exists but is
    -- undocumented is a setting nobody uses; one that is documented but gone is
    -- worse, because it looks like a bug in the plugin.
    local function readme()
        local handle = io.open("README.md", "r")
        if not handle then
            return nil
        end
        local content = handle:read("*a")
        handle:close()
        return content
    end

    it("documents every setting in the schema", function()
        local content = readme()
        assert.is_string(content)

        local missing = {}
        for key in pairs(Defaults.SCHEMA) do
            if not content:find("| `" .. key .. "`", 1, true) then
                table.insert(missing, key)
            end
        end
        table.sort(missing)

        assert.equals("", table.concat(missing, ", "))
    end)

    it("names the required ones as required", function()
        local content = readme()
        assert.matches("| `server_url` |[^\n]*Required", content)
        assert.matches("| `api_token` |[^\n]*Required", content)
    end)
end)

describe("ConfigFile.parse quoting and comments", function()
    it("takes a value with or without quotes", function()
        assert.equals("ak1_x", ConfigFile.parse("api_token = ak1_x").api_token)
        assert.equals("ak1_x", ConfigFile.parse('api_token = "ak1_x"').api_token)
        assert.equals("ak1_x", ConfigFile.parse("api_token = 'ak1_x'").api_token)
    end)

    it("strips only a matching pair around the whole value", function()
        assert.equals('a"b', ConfigFile.parse('api_token = a"b').api_token)
        assert.equals('"unbalanced', ConfigFile.parse('api_token = "unbalanced').api_token)
    end)

    it("accepts a colon as well as an equals sign", function()
        assert.equals("ak1_x", ConfigFile.parse("api_token: ak1_x").api_token)
    end)

    it("has no trailing comments, and says so rather than guessing", function()
        -- The failure this prevents is invisible: the token becomes the comment
        -- and the next request comes back 401, saying nothing about why.
        local values, problems = ConfigFile.parse("update_token =        # only for a private repo")

        assert.equals("# only for a private repo", values.update_token)
        assert.equals(1, #problems)
        assert.matches("looks like a comment", problems[1])
    end)

    it("does not rewrite the value it is suspicious of", function()
        -- Guessing where a comment starts would corrupt any value that
        -- legitimately contains a #, such as a URL fragment.
        local values, problems = ConfigFile.parse("server_url = https://example.org/x#y")

        assert.equals("https://example.org/x#y", values.server_url)
        assert.equals(0, #problems)
    end)

    it("still treats a whole-line comment as a comment", function()
        local values, problems = ConfigFile.parse("# api_token = nope\n; server_url = nope")

        assert.is_nil(values.api_token)
        assert.equals(0, #problems)
    end)
end)
