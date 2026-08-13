require("spec.support.helper")

local Hashing = require("karabridge.shared.hashing")

describe("Hashing", function()
    it("produces a stable 16-character hex value", function()
        local digest = Hashing.hash("hello")
        assert.equals(16, #digest)
        assert.matches("^%x+$", digest)
    end)

    it("matches the published FNV-1a 32 vectors in its first half", function()
        -- Anchoring on the reference vectors is what makes this a hash and not
        -- just "some function that returns different things". If a refactor of
        -- the arithmetic breaks the wrapping multiply, these catch it.
        assert.equals("811c9dc5", Hashing.hash(""):sub(1, 8))
        assert.equals("e40c292c", Hashing.hash("a"):sub(1, 8))
        assert.equals("bf9cf968", Hashing.hash("foobar"):sub(1, 8))
    end)

    it("is deterministic", function()
        assert.equals(Hashing.hash("the same text"), Hashing.hash("the same text"))
    end)

    it("changes when the content changes", function()
        assert.is_true(Hashing.hash("a") ~= Hashing.hash("b"))
    end)

    it("notices a single changed character in a long text", function()
        local long = string.rep("highlight text ", 200)
        assert.is_true(Hashing.hash(long) ~= Hashing.hash(long .. "."))
    end)

    it("handles bytes above 127", function()
        assert.is_string(Hashing.hash("\195\164\255\000"))
    end)

    describe("hashParts", function()
        it("does not confuse different splits of the same characters", function()
            -- Without a separator, {"ab","c"} and {"a","bc"} would hash alike,
            -- and two different highlight sets could look unchanged.
            assert.is_true(Hashing.hashParts({ "ab", "c" }) ~= Hashing.hashParts({ "a", "bc" }))
        end)

        it("is order-sensitive, because reordered chapters are a change", function()
            assert.is_true(Hashing.hashParts({ "a", "b" }) ~= Hashing.hashParts({ "b", "a" }))
        end)

        it("is stable for the same parts", function()
            assert.equals(Hashing.hashParts({ "a", "b" }), Hashing.hashParts({ "a", "b" }))
        end)

        it("tolerates a non-table", function()
            assert.equals(Hashing.hash(""), Hashing.hashParts(nil))
        end)
    end)
end)
