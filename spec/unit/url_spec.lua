require("spec.support.helper")

local Url = require("karabridge.shared.url")

describe("Url", function()
    describe("normaliseServerUrl", function()
        it("leaves a clean address alone", function()
            assert.equals("https://karakeep.example.org", Url.normaliseServerUrl("https://karakeep.example.org"))
        end)

        it("strips trailing slashes", function()
            assert.equals("https://karakeep.example.org", Url.normaliseServerUrl("https://karakeep.example.org///"))
        end)

        it("strips a pasted /api/v1 suffix", function()
            -- The single most common mistake: copying the base URL out of
            -- Karakeep's API docs, which show it with the version on the end.
            assert.equals(
                "https://karakeep.example.org",
                Url.normaliseServerUrl("https://karakeep.example.org/api/v1")
            )
        end)

        it("strips /api/v1 together with a trailing slash", function()
            assert.equals(
                "https://karakeep.example.org",
                Url.normaliseServerUrl("https://karakeep.example.org/api/v1/")
            )
        end)

        it("trims surrounding whitespace left by a paste", function()
            assert.equals("https://k.example.org", Url.normaliseServerUrl("  https://k.example.org \n"))
        end)

        it("keeps a path that is not /api/v1", function()
            assert.equals("https://example.org/karakeep", Url.normaliseServerUrl("https://example.org/karakeep/"))
        end)

        it("returns an empty string for a non-string", function()
            assert.equals("", Url.normaliseServerUrl(nil))
        end)
    end)

    describe("validateServerUrl", function()
        it("accepts https and http", function()
            assert.is_true(Url.validateServerUrl("https://k.example.org"))
            assert.is_true(Url.validateServerUrl("http://192.168.1.10:3000"))
        end)

        it("rejects an empty address", function()
            local ok, reason = Url.validateServerUrl("")
            assert.is_false(ok)
            assert.equals("empty", reason)
        end)

        it("rejects an address with no scheme", function()
            local ok, reason = Url.validateServerUrl("karakeep.example.org")
            assert.is_false(ok)
            assert.equals("no_scheme", reason)
        end)

        it("rejects a scheme that is not http(s)", function()
            -- A typo that turned into a local file read would be a nasty way
            -- to find out the address was wrong.
            local ok, reason = Url.validateServerUrl("file:///etc/passwd")
            assert.is_false(ok)
            assert.equals("unsupported_scheme", reason)
        end)

        it("rejects an address with no host", function()
            local ok, reason = Url.validateServerUrl("https:///bookmarks")
            assert.is_false(ok)
            assert.equals("no_host", reason)
        end)

        it("rejects credentials in the address", function()
            local ok, reason = Url.validateServerUrl("https://user:pw@k.example.org")
            assert.is_false(ok)
            assert.equals("has_userinfo", reason)
        end)
    end)

    describe("isInsecure", function()
        it("flags plain http", function()
            assert.is_true(Url.isInsecure("http://k.example.org"))
        end)

        it("does not flag https", function()
            assert.is_false(Url.isInsecure("https://k.example.org"))
        end)
    end)

    describe("encode", function()
        it("leaves unreserved characters alone", function()
            assert.equals("abcXYZ-_.~09", Url.encode("abcXYZ-_.~09"))
        end)

        it("encodes reserved and non-ASCII bytes", function()
            assert.equals("a%20b%26c", Url.encode("a b&c"))
            assert.equals("%C3%A4", Url.encode("\195\164"))
        end)
    end)

    describe("buildQuery", function()
        it("returns an empty string when there is nothing to send", function()
            assert.equals("", Url.buildQuery({}))
            assert.equals("", Url.buildQuery(nil))
        end)

        it("sorts keys, so a request is byte-for-byte assertable", function()
            assert.equals("?a=1&b=2&c=3", Url.buildQuery({ c = 3, a = 1, b = 2 }))
        end)

        it("renders booleans as true and false, not 1 and 0", function()
            assert.equals("?archived=false", Url.buildQuery({ archived = false }))
        end)

        it("skips nil values", function()
            assert.equals("?limit=10", Url.buildQuery({ limit = 10, cursor = nil }))
        end)

        it("repeats the key for an array, as Karakeep's validators expect", function()
            assert.equals("?status=read&status=unread", Url.buildQuery({ status = { "read", "unread" } }))
        end)

        it("encodes values", function()
            assert.equals("?q=a%20b", Url.buildQuery({ q = "a b" }))
        end)
    end)
end)

describe("Url.forLog", function()
    -- A query string is not decoration. A signed storage URL carries its whole
    -- authorisation there, so logging one hands whoever reads the log
    -- time-limited access to what it points at.
    it("keeps the endpoint and drops the query", function()
        assert.equals(
            "https://storage.example/asset?<redacted>",
            Url.forLog("https://storage.example/asset?X-Amz-Signature=deadbeef&Expires=99")
        )
    end)

    it("drops a fragment too", function()
        assert.equals("https://x/y?<redacted>", Url.forLog("https://x/y#token=abc"))
    end)

    it("leaves a plain URL alone, so the log stays useful", function()
        assert.equals("https://karakeep.example.org/api/v1/bookmarks",
            Url.forLog("https://karakeep.example.org/api/v1/bookmarks"))
    end)

    it("says something rather than nothing for a non-string", function()
        assert.equals("<no url>", Url.forLog(nil))
        assert.equals("<no url>", Url.forLog({}))
    end)

    it("never leaks the signature it was given", function()
        local logged = Url.forLog("https://s3.example/k.zip?X-Amz-Signature=SECRETSIG&x=1")
        assert.is_nil(logged:find("SECRETSIG", 1, true))
    end)
end)
