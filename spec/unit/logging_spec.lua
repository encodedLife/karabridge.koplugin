local Helper = require("spec.support.helper")

local Logging = require("karabridge.shared.logging")

describe("Logging", function()
    before_each(function()
        Helper.install()
    end)

    after_each(function()
        Helper.uninstall()
    end)

    describe("mask", function()
        it("says so plainly when nothing is set", function()
            assert.equals("(unset)", Logging.mask(nil))
            assert.equals("(unset)", Logging.mask(""))
        end)

        it("reveals only the last four characters of a long secret", function()
            local masked = Logging.mask("ak1_abcdefghijklmnop")
            assert.equals("******mnop", masked)
            assert.is_nil(masked:find("abcdefgh", 1, true))
        end)

        it("reveals nothing at all from a short secret", function()
            -- Four of eight characters is half the key; that is too much.
            local masked = Logging.mask("ak1_abcd")
            assert.equals("(set, 8 chars)", masked)
            assert.is_nil(masked:find("abcd", 1, true))
        end)

        it("does not leak a non-string secret through tostring", function()
            assert.equals("(set)", Logging.mask({ token = "secret" }))
        end)
    end)

    describe("maskUrl", function()
        it("leaves an ordinary address alone", function()
            assert.equals("https://karakeep.example.org", Logging.maskUrl("https://karakeep.example.org"))
        end)

        it("removes credentials embedded in the address", function()
            local masked = Logging.maskUrl("https://user:hunter2@karakeep.example.org/x")
            assert.equals("https://(userinfo)@karakeep.example.org/x", masked)
            assert.is_nil(masked:find("hunter2", 1, true))
        end)

        it("says so plainly when nothing is set", function()
            assert.equals("(unset)", Logging.maskUrl(nil))
        end)
    end)

    describe("forModule", function()
        it("prefixes every line with the plugin and module name", function()
            Logging.forModule("api.client").info("hello")
            assert.is_true(Helper.mocks.logger.contains("KaraBridge:api.client: hello"))
        end)

        it("joins its arguments", function()
            Logging.forModule("x").warn("a", 1, true)
            assert.is_true(Helper.mocks.logger.contains("a 1 true"))
        end)

        it("survives a nil argument rather than throwing mid-failure", function()
            -- Logging is most often reached on an error path; a logger that
            -- itself throws turns a handled problem into a crash.
            Logging.forModule("x").err("value was", nil)
            assert.is_true(Helper.mocks.logger.contains("value was nil"))
        end)
    end)
end)
