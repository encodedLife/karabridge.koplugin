require("spec.support.helper")

local Result = require("karabridge.shared.result")

describe("Result", function()
    it("carries a value on success", function()
        local result = Result.ok({ id = "abc" })
        assert.is_true(result:isOk())
        assert.is_false(result:isErr())
        assert.equals("abc", result.value.id)
    end)

    it("treats a nil value as a success, not an absence", function()
        -- Operations such as DELETE succeed with no payload; that must not be
        -- confusable with a failure.
        local result = Result.ok(nil)
        assert.is_true(result:isOk())
        assert.is_nil(result.value)
    end)

    it("carries a code and a message on failure", function()
        local result = Result.err("unauthorized", "Karakeep rejected the API key.")
        assert.is_true(result:isErr())
        assert.equals("unauthorized", result:errorCode())
        assert.equals("unauthorized: Karakeep rejected the API key.", result:describe())
    end)

    it("defaults an omitted code rather than producing a nil one", function()
        assert.equals("unknown", Result.err():errorCode())
    end)

    it("reports no error code on success", function()
        assert.is_nil(Result.ok(1):errorCode())
    end)

    it("falls back to the code alone when there is no message", function()
        assert.equals("timeout", Result.err("timeout"):describe())
    end)

    describe("valueOr", function()
        it("returns the value on success", function()
            assert.equals(7, Result.ok(7):valueOr(0))
        end)

        it("returns the fallback on failure", function()
            assert.equals(0, Result.err("nope"):valueOr(0))
        end)
    end)

    describe("map", function()
        it("transforms a successful value", function()
            local result = Result.ok(2):map(function(v)
                return v * 3
            end)
            assert.equals(6, result.value)
        end)

        it("passes an error through without calling the function", function()
            local called = false
            local result = Result.err("boom"):map(function()
                called = true
            end)
            assert.is_false(called)
            assert.equals("boom", result:errorCode())
        end)

        it("does not double-wrap a Result returned by the function", function()
            local result = Result.ok(1):map(function()
                return Result.err("inner")
            end)
            assert.is_true(result:isErr())
            assert.equals("inner", result:errorCode())
        end)
    end)

    it("recognises its own instances", function()
        assert.is_true(Result.is(Result.ok(1)))
        assert.is_false(Result.is({ ok = true }))
        assert.is_false(Result.is(nil))
    end)
end)
