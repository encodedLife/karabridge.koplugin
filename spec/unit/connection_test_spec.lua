local Helper = require("spec.support.helper")

local Client = require("karabridge.api.client")
local ConnectionTest = require("karabridge.features.connection_test")

describe("ConnectionTest", function()
    before_each(function()
        Helper.install()
    end)

    after_each(function()
        Helper.uninstall()
    end)

    describe("run", function()
        it("probes /users/me", function()
            local client, stub = Helper.client({ { code = 200, body = '{"name":"Ada"}' } })
            ConnectionTest.run(client)

            assert.matches("/api/v1/users/me$", stub.requests[1].request.url)
        end)

        it("succeeds with the account details", function()
            local client = Helper.client({ { code = 200, body = '{"name":"Ada","email":"a@example.org"}' } })
            local result = ConnectionTest.run(client)

            assert.is_true(result:isOk())
            assert.equals("Ada", result.value.name)
        end)

        it("refuses to probe when unconfigured", function()
            local result = ConnectionTest.run(Client.new({}))
            assert.equals("not_configured", result:errorCode())
        end)

        it("reports a wrong key distinctly from a wrong address", function()
            local client = Helper.client({ { code = 401, body = "" } })
            assert.equals("unauthorized", ConnectionTest.run(client):errorCode())
        end)

        it("reads a 404 as 'not a Karakeep API', not 'no such user'", function()
            -- /users/me has no ID in it, so a 404 means nothing is listening
            -- on /api/v1 at this address -- usually the web UI URL was pasted.
            local client = Helper.client({ { code = 404, body = "" } })
            assert.equals("not_karakeep", ConnectionTest.run(client):errorCode())
        end)

        it("reports an unreachable server", function()
            local client = Helper.client({
                { transport_error = "timeout" },
                { transport_error = "timeout" },
                { transport_error = "timeout" },
            })
            assert.equals("unreachable", ConnectionTest.run(client):errorCode())
        end)

        it("never logs the token", function()
            local client = Helper.client({ { code = 401, body = "" } })
            ConnectionTest.run(client)

            assert.is_false(Helper.mocks.logger.contains(Helper.TOKEN))
        end)
    end)

    describe("describe", function()
        it("names the account on success", function()
            local client = Helper.client({ { code = 200, body = '{"name":"Ada"}' } })
            local message = ConnectionTest.describe(ConnectionTest.run(client), "https://k.example.org")

            assert.matches("Connected to Karakeep as Ada", message)
        end)

        it("falls back to the email, then to a generic phrase", function()
            local client = Helper.client({ { code = 200, body = '{"email":"a@example.org"}' } })
            assert.matches("a@example.org", ConnectionTest.describe(ConnectionTest.run(client)))

            local bare = Helper.client({ { code = 200, body = "{}" } })
            assert.matches("your account", ConnectionTest.describe(ConnectionTest.run(bare)))
        end)

        it("warns once that a plain http address sends the key unencrypted", function()
            local client = Helper.client({ { code = 200, body = '{"name":"Ada"}' } })
            local message = ConnectionTest.describe(ConnectionTest.run(client), "http://192.168.1.10:3000")

            assert.matches("unencrypted", message)
        end)

        it("does not warn about https", function()
            local client = Helper.client({ { code = 200, body = '{"name":"Ada"}' } })
            local message = ConnectionTest.describe(ConnectionTest.run(client), "https://k.example.org")

            assert.is_nil(message:find("unencrypted", 1, true))
        end)

        it("tells the user what to change, per failure", function()
            local cases = {
                { responses = { { code = 401, body = "" } }, expected = "API Keys" },
                { responses = { { code = 404, body = "" } }, expected = "without /api/v1" },
                {
                    responses = {
                        { transport_error = "t" },
                        { transport_error = "t" },
                        { transport_error = "t" },
                    },
                    expected = "on the network",
                },
            }

            for _, case in ipairs(cases) do
                local client = Helper.client(case.responses)
                local message = ConnectionTest.describe(ConnectionTest.run(client))
                assert.matches(case.expected, message)
            end
        end)

        it("has a message for an unconfigured client", function()
            local message = ConnectionTest.describe(ConnectionTest.run(Client.new({})))
            assert.matches("Enter the server address", message)
        end)
    end)
end)
