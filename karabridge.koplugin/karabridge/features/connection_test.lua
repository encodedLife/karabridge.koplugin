--[[--
"Does this actually work?" — the first thing anyone taps after entering a
server address.

Split in two on purpose: `run()` performs the check and returns a Result, and
`describe()` turns that Result into a sentence. The first is a pure function of
the API client and is unit-tested against a fake; the second is where the
wording lives and can be changed without touching any logic.

`GET /api/v1/users/me` is the probe, because it is the cheapest authenticated
endpoint Karakeep has (`packages/api/routes/users.ts`) and it distinguishes the
three failures that actually happen:

  * 401/403 — the address is right and the key is wrong,
  * 404 — the address is not a Karakeep API at all, usually because someone
    pasted the web UI URL or left `/api/v1` on the end,
  * no response — the server is unreachable.

Telling those apart is the difference between "could not connect" and a message
that says what to change.

@module karabridge.features.connection_test
]]

local Logging = require("karabridge.shared.logging")
local Result = require("karabridge.shared.result")
local Url = require("karabridge.shared.url")

local log = Logging.forModule("connection_test")

local ConnectionTest = {}

--- Probe the server.
-- @tparam table client A `karabridge.api.client`.
-- @treturn Result On success, the value is the `/users/me` payload.
function ConnectionTest.run(client)
    if not client or not client:isConfigured() then
        return Result.err("not_configured", "The server address and API key are both required.")
    end

    log.info("testing connection to", Logging.maskUrl(client.server_url))

    local result = client:get("/users/me")

    if result:isOk() then
        log.info("connected")
        return result
    end

    -- A 404 from /users/me does not mean "no such user"; that endpoint has no
    -- ID in it. It means nothing is listening on /api/v1 at this address.
    if result:errorCode() == "not_found" then
        return Result.err(
            "not_karakeep",
            "No Karakeep API answered at that address.",
            result.details
        )
    end

    log.warn("connection test failed:", result:describe())
    return result
end

--- A sentence for the user, given the Result from `run()`.
-- @tparam Result result
-- @tparam[opt] string server_url Used only to warn about plain http.
-- @treturn string
function ConnectionTest.describe(result, server_url)
    if result:isOk() then
        local user = result.value or {}
        local who = user.name or user.email or "your account"
        local message = string.format("Connected to Karakeep as %s.", who)

        -- Worth saying once, at the moment it becomes true: on plain http the
        -- API key travels in a header in clear text on every request.
        if Url.isInsecure(server_url) then
            message = message .. "\n\nThis is a plain http:// address, so the API key is sent unencrypted."
        end

        return message
    end

    local code = result:errorCode()

    if code == "not_configured" then
        return "Enter the server address and API key first."
    elseif code == "unauthorized" then
        return "Karakeep rejected the API key.\n\nCheck it in Karakeep under Settings > API Keys."
    elseif code == "not_karakeep" then
        return "No Karakeep API answered at that address.\n\nEnter the server's base address, without /api/v1."
    elseif code == "unreachable" then
        return "The server could not be reached.\n\nCheck the address, and that this device is on the network."
    elseif code == "rate_limited" then
        return "Karakeep is rate limiting this device. Try again in a minute."
    elseif code == "server_error" then
        return "The Karakeep server reported an internal error."
    elseif code == "malformed" then
        return "Something answered at that address, but it was not Karakeep."
    end

    return "Could not connect to Karakeep."
end

return ConnectionTest
