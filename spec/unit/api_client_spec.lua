local Helper = require("spec.support.helper")

local Client = require("karabridge.api.client")
local Json = require("karabridge.shared.json")

describe("api.Client", function()
    before_each(function()
        Helper.install()
    end)

    after_each(function()
        Helper.uninstall()
    end)

    describe("configuration", function()
        it("is not configured without an address or a token", function()
            assert.is_false(Client.new({}):isConfigured())
            assert.is_false(Client.new({ server_url = "https://k.example.org" }):isConfigured())
            assert.is_false(Client.new({ api_token = "x" }):isConfigured())
        end)

        it("refuses to make a request when unconfigured", function()
            local result = Client.new({}):get("/users/me")
            assert.equals("not_configured", result:errorCode())
        end)

        it("normalises the address it was given", function()
            local client = Client.new({ server_url = "https://k.example.org/api/v1/", api_token = "x" })
            assert.equals("https://k.example.org", client.server_url)
        end)
    end)

    describe("request construction", function()
        it("puts the path under /api/v1", function()
            local client, stub = Helper.client({ { code = 200, body = "{}" } })
            client:get("/bookmarks")

            assert.equals("https://karakeep.example.org/api/v1/bookmarks", stub.requests[1].request.url)
        end)

        it("appends a sorted query string", function()
            local client, stub = Helper.client({ { code = 200, body = "{}" } })
            client:get("/bookmarks", { query = { limit = 10, archived = false } })

            assert.equals(
                "https://karakeep.example.org/api/v1/bookmarks?archived=false&limit=10",
                stub.requests[1].request.url
            )
        end)

        it("sends a bearer token", function()
            local client, stub = Helper.client({ { code = 200, body = "{}" } })
            client:get("/users/me")

            assert.equals("Bearer " .. Helper.TOKEN, stub.requests[1].request.headers["Authorization"])
        end)

        it("encodes a body as JSON and sets the content headers", function()
            local client, stub = Helper.client({ { code = 201, body = "{}" } })
            client:post("/bookmarks", { body = { type = "text", text = "hello" } })

            local request = stub.requests[1].request
            assert.equals("POST", request.method)
            assert.equals("application/json", request.headers["Content-Type"])
            assert.equals(tostring(#request.body), request.headers["Content-Length"])
            assert.same({ text = "hello", type = "text" }, Json.decode(request.body))
        end)

        it("sends no body headers on a GET", function()
            local client, stub = Helper.client({ { code = 200, body = "{}" } })
            client:get("/users/me")

            assert.is_nil(stub.requests[1].request.headers["Content-Type"])
        end)
    end)

    describe("secret handling", function()
        it("never writes the token to the log, on success or failure", function()
            -- The assertion that matters most in this file. It also catches
            -- the next person's logger.dbg("request", request).
            local client = Helper.client({
                { code = 200, body = '{"id":"1"}' },
                { code = 401, body = "unauthorized" },
                { transport_error = "timeout" },
                { transport_error = "timeout" },
                { transport_error = "timeout" },
            })

            client:get("/users/me")
            client:post("/bookmarks", { body = { type = "text", text = "x" } })
            client:get("/bookmarks")

            assert.is_true(#Helper.mocks.logger.lines > 0, "nothing was logged, so the check proves nothing")
            assert.is_false(Helper.mocks.logger.contains(Helper.TOKEN))
            assert.is_false(Helper.mocks.logger.contains("Bearer"))
        end)
    end)

    describe("response handling", function()
        it("decodes a JSON body", function()
            local client = Helper.client({ { code = 200, body = '{"id":"abc","title":"T"}' } })
            local result = client:get("/bookmarks/abc")

            assert.is_true(result:isOk())
            assert.equals("abc", result.value.id)
        end)

        it("strips JSON nulls, so `or` fallbacks work", function()
            -- KOReader decodes null to a function, which is truthy. Without
            -- stripping, `bookmark.title or fallback` keeps the sentinel.
            local client = Helper.client({ { code = 200, body = '{"id":"abc","title":null}' } })
            local result = client:get("/bookmarks/abc")

            assert.is_nil(result.value.title)
            assert.equals("Untitled", result.value.title or "Untitled")
        end)

        it("treats an empty 204 as success", function()
            local client = Helper.client({ { code = 204, body = "" } })
            local result = client:delete("/bookmarks/abc")

            assert.is_true(result:isOk())
            assert.same({}, result.value)
        end)

        it("reports a 2xx with an unreadable body as malformed", function()
            local client = Helper.client({ { code = 200, body = "<html>login</html>" } })
            local result = client:get("/users/me")

            assert.equals("malformed", result:errorCode())
        end)

        it("truncates the body preview it keeps for the log", function()
            local client = Helper.client({ { code = 200, body = string.rep("x", 5000) } })
            local result = client:get("/users/me")

            assert.is_true(#result.details.preview <= 200)
        end)
    end)

    describe("error translation", function()
        local cases = {
            { code = 401, expected = "unauthorized" },
            { code = 403, expected = "unauthorized" },
            { code = 404, expected = "not_found" },
            { code = 400, expected = "bad_request" },
            { code = 422, expected = "bad_request" },
        }

        for _, case in ipairs(cases) do
            it("maps HTTP " .. case.code .. " to " .. case.expected, function()
                local client = Helper.client({ { code = case.code, body = "" } })
                assert.equals(case.expected, client:get("/x"):errorCode())
            end)
        end

        it("maps a missing response to unreachable", function()
            local client = Helper.client({
                { transport_error = "timeout" },
                { transport_error = "timeout" },
                { transport_error = "timeout" },
            })
            assert.equals("unreachable", client:get("/x"):errorCode())
        end)
    end)

    describe("retries", function()
        it("retries a 429 and succeeds on the second attempt", function()
            local client, stub = Helper.client({
                { code = 429, body = "" },
                { code = 200, body = '{"ok":true}' },
            })

            local result = client:get("/bookmarks")
            assert.is_true(result:isOk())
            assert.equals(2, #stub.requests)
        end)

        it("retries a 500", function()
            local client, stub = Helper.client({
                { code = 500, body = "" },
                { code = 200, body = "{}" },
            })

            assert.is_true(client:get("/x"):isOk())
            assert.equals(2, #stub.requests)
        end)

        it("does not retry a 401, because retrying cannot help", function()
            local client, stub = Helper.client({
                { code = 401, body = "" },
                { code = 200, body = "{}" },
            })

            assert.equals("unauthorized", client:get("/x"):errorCode())
            assert.equals(1, #stub.requests)
        end)

        it("gives up after a bounded number of attempts", function()
            -- A retry loop without a cap turns a dead server into a hung device.
            local client, stub = Helper.client({
                { code = 500, body = "" },
                { code = 500, body = "" },
                { code = 500, body = "" },
                { code = 500, body = "" },
            })

            assert.equals("server_error", client:get("/x"):errorCode())
            assert.equals(Client.MAX_RETRIES + 1, #stub.requests)
        end)
    end)

    describe("collect", function()
        it("follows the cursor to the end", function()
            local client, stub = Helper.client({
                { code = 200, body = '{"bookmarks":[{"id":"1"}],"nextCursor":"c1"}' },
                { code = 200, body = '{"bookmarks":[{"id":"2"}],"nextCursor":null}' },
            })

            local result = client:collect("/bookmarks", { field = "bookmarks" })

            assert.is_true(result:isOk())
            assert.equals(2, #result.value.items)
            assert.is_true(result.value.complete)
            assert.matches("cursor=c1", stub.requests[2].request.url)
        end)

        it("does not send a cursor on the first page", function()
            local client, stub = Helper.client({ { code = 200, body = '{"bookmarks":[]}' } })
            client:collect("/bookmarks", { field = "bookmarks" })

            assert.is_nil(stub.requests[1].request.url:find("cursor", 1, true))
        end)

        it("stops at the limit and says the walk was not complete", function()
            -- Callers must not treat a capped list as everything the server
            -- has: deleting local files on that basis would lose data.
            local client = Helper.client({
                { code = 200, body = '{"bookmarks":[{"id":"1"},{"id":"2"},{"id":"3"}],"nextCursor":"c1"}' },
            })

            local result = client:collect("/bookmarks", { field = "bookmarks", limit = 2 })

            assert.equals(2, #result.value.items)
            assert.is_false(result.value.complete)
        end)

        it("stops at the page cap rather than looping forever", function()
            local responses = {}
            for _ = 1, 10 do
                table.insert(responses, { code = 200, body = '{"bookmarks":[{"id":"x"}],"nextCursor":"always"}' })
            end

            local client, stub = Helper.client(responses)
            local result = client:collect("/bookmarks", { field = "bookmarks", max_pages = 3 })

            assert.equals(3, #stub.requests)
            assert.is_false(result.value.complete)
        end)

        it("propagates a failure instead of returning a short list", function()
            local client = Helper.client({ { code = 401, body = "" } })
            local result = client:collect("/bookmarks", { field = "bookmarks" })

            assert.is_true(result:isErr())
            assert.equals("unauthorized", result:errorCode())
        end)
    end)
end)

describe("api.Client URL logging", function()
    -- The Karakeep token has been kept out of the log since the beginning. A
    -- credential in a query parameter is the same thing wearing a different
    -- hat, and the update path fetches exactly such a URL.
    local Logging = require("karabridge.shared.logging")

    before_each(function()
        Helper.install()
    end)

    after_each(function()
        Logging.setBackend(nil)
        Helper.uninstall()
    end)

    it("never writes a query string to the log", function()
        local logged = {}
        local function record(...)
            table.insert(logged, table.concat({ ... }, " "))
        end
        Logging.setBackend({ info = record, warn = record, err = record, dbg = record })

        local stub = Helper.httpStub({ { code = 200, body = "{}" } })
        local client = Client.new({
            server_url = "https://storage.example",
            api_token = "x",
            base_path = "",
            request = stub.fn,
        })

        client:get("/asset.zip?X-Amz-Signature=SECRETSIG&Expires=99")

        local all = table.concat(logged, "\n")
        assert.is_nil(all:find("SECRETSIG", 1, true))
        assert.is_nil(all:find("X-Amz-Signature", 1, true))
        -- ...while the endpoint itself is still there, or the log is pointless.
        assert.is_truthy(all:find("/asset.zip", 1, true))
    end)
end)
