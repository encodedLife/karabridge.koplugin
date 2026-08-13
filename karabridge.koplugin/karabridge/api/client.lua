--[[--
Karakeep HTTP transport.

This module knows about URLs, headers, retries, status codes and JSON. It knows
nothing about bookmarks, highlights or lists — those live in the resource
modules next to it, which is what keeps "how do we talk to the server" separate
from "what are we asking it".

Two properties are deliberate and covered by specs:

  * **The Authorization header is built here and nowhere else**, and is never
    passed to the logger. `logRequest()` prints the method, the URL and the
    status; there is no code path that can print the header table.
  * **The socket call is injected.** `Client.new{ request = fn }` replaces the
    real one, so request construction, retry behaviour and error translation
    are all unit-testable without a network. On device the default backend is
    KOReader's `socket.http`.

Verified against Karakeep's own source
(monorepo version 0.1.0): routes are mounted under `/api/v1`, auth is
`Authorization: Bearer <token>` (`packages/api/middlewares/auth.ts`), and
paginated collections answer `{ items…, nextCursor }`.

@module karabridge.api.client
]]

local Json = require("karabridge.shared.json")
local Logging = require("karabridge.shared.logging")
local Result = require("karabridge.shared.result")
local Url = require("karabridge.shared.url")

local log = Logging.forModule("api.client")

local Client = {}
Client.__index = Client

Client.API_BASE = "/api/v1"

-- Karakeep documents a 429 with a retry hint. A couple of quick retries keeps a
-- large first sync from falling over on rate limiting; more than that just
-- makes a genuinely broken server take longer to report.
Client.MAX_RETRIES = 2

--- Create a client.
--
-- Mostly used for Karakeep, but deliberately not welded to it: the update
-- checker talks to GitHub through this same class rather than opening a second
-- socket path of its own. Retries, timeouts, the Result codes and -- above all
-- -- the rule that an Authorization header never reaches the log are then true
-- for both, instead of being true once and hopefully reimplemented correctly
-- the second time.
--
-- @tparam table opts
--   server_url      base address, with or without a trailing slash or /api/v1
--   api_token       bearer token; may be nil when `require_token` is false
--   base_path       path prefix, default "/api/v1"; GitHub uses ""
--   require_token   default true; false lets a server be talked to anonymously
--   extra_headers   merged into every request's headers
--   follow_redirects default true; false turns a 3xx into a `redirect` Result
--                   carrying the Location, which is how a private GitHub asset
--                   has to be fetched
--   request         optional; replaces the socket call, for tests
--   sleep           optional; replaces the retry backoff sleep, for tests
--   timeouts        optional; { block, total, file_block, file_total } in seconds
-- @treturn Client
function Client.new(opts)
    opts = opts or {}

    local timeouts = opts.timeouts or {}

    return setmetatable({
        server_url = Url.normaliseServerUrl(opts.server_url),
        api_token = opts.api_token,
        base_path = opts.base_path or Client.API_BASE,
        require_token = opts.require_token ~= false,
        extra_headers = opts.extra_headers,
        follow_redirects = opts.follow_redirects ~= false,
        request_backend = opts.request,
        sleep_backend = opts.sleep,
        block_timeout = timeouts.block or 20,
        total_timeout = timeouts.total or 60,
        file_block_timeout = timeouts.file_block or 30,
        file_total_timeout = timeouts.file_total or 300,
    }, Client)
end

--- Is there enough configuration to attempt a request at all?
-- @treturn boolean
function Client:isConfigured()
    if self.server_url == nil or self.server_url == "" then
        return false
    end
    if not self.require_token then
        return true
    end
    return self.api_token ~= nil and self.api_token ~= ""
end

--- The absolute URL for an API path.
-- @tparam string path Path below /api/v1, e.g. "/bookmarks".
-- @tparam[opt] table query
-- @treturn string
function Client:buildUrl(path, query)
    -- An absolute path is used as it stands. Following a redirect means going
    -- to a host that is not this client's server -- a signed storage URL, for
    -- instance -- and rebuilding that from server_url would be nonsense.
    if path:match("^https?://") then
        return path .. Url.buildQuery(query)
    end
    return self.server_url .. self.base_path .. path .. Url.buildQuery(query)
end

--- Headers for a request.
--
-- Returned rather than logged. Nothing in KaraBridge logs the return value of
-- this function, and the spec asserts that the token never reaches the log
-- backend during a request.
--
-- @tparam[opt] number content_length
-- @tparam[opt] string content_type Defaults to JSON, which every route but
--   the asset upload wants.
-- @treturn table
function Client:buildHeaders(content_length, content_type)
    local headers = {
        ["Accept"] = "application/json, */*",
        ["User-Agent"] = "KOReader KaraBridge",
    }

    if self.api_token ~= nil and self.api_token ~= "" then
        headers["Authorization"] = "Bearer " .. tostring(self.api_token)
    end

    for key, value in pairs(self.extra_headers or {}) do
        headers[key] = value
    end

    if content_length then
        headers["Content-Type"] = content_type or "application/json"
        headers["Content-Length"] = tostring(content_length)
    end

    return headers
end

--- Translate an HTTP outcome into a Result with a stable code.
--
-- The codes, and what each means to the user:
--   not_configured  no address or no token yet
--   unreachable     the request never completed (DNS, TLS, timeout, no route)
--   unauthorized    401/403 — the key is wrong or lacks a scope
--   not_found       404 — wrong address, or the object is gone
--   rate_limited    429
--   server_error    5xx
--   bad_request     any other 4xx
--   malformed       a 2xx whose body was not JSON
--
-- @tparam number|nil code
-- @tparam string|nil status
-- @treturn Result
local function translateFailure(code, status)
    if not code then
        return Result.err("unreachable", "The Karakeep server could not be reached.", { status = status })
    end
    if code == 401 or code == 403 then
        return Result.err("unauthorized", "Karakeep rejected the API key.", { status = code })
    end
    if code == 404 then
        return Result.err("not_found", "Karakeep answered 'not found' for that address.", { status = code })
    end
    if code == 429 then
        return Result.err("rate_limited", "Karakeep is rate limiting this device.", { status = code })
    end
    if code >= 500 then
        return Result.err("server_error", "The Karakeep server reported an error.", { status = code })
    end
    return Result.err("bad_request", "Karakeep rejected the request.", { status = code })
end

--- Should this failure be retried?
local function isRetriable(result)
    local code = result:errorCode()
    return code == "unreachable" or code == "rate_limited" or code == "server_error"
end

--- The socket call, resolved lazily.
--
-- Required inside the function rather than at the top of the file on purpose:
-- `socketutil` pulls in KOReader's device stack, which probes SDL and wants a
-- display. Keeping it lazy is what lets `api/client.lua` be required by a spec.
function Client:_socketRequest(request, filepath)
    local http = require("socket.http")
    local ltn12 = require("ltn12")
    local socket = require("socket")
    local socketutil = require("socketutil")

    local sink = {}
    local sink_file

    if filepath then
        sink_file = io.open(filepath, "w")
        if not sink_file then
            return nil, nil, "io_error"
        end
        request.sink = ltn12.sink.file(sink_file)
        socketutil:set_timeout(self.file_block_timeout, self.file_total_timeout)
    else
        request.sink = ltn12.sink.table(sink)
        socketutil:set_timeout(self.block_timeout, self.total_timeout)
    end

    if request.body then
        request.source = ltn12.source.string(request.body)
        request.body = nil
    end

    -- LuaSocket follows redirects by default and re-sends every header,
    -- Authorization included. A signed storage URL rejects that outright, so
    -- the redirect has to be followed by hand, without the header.
    if not self.follow_redirects then
        request.redirect = false
    end

    -- Wrapped, and the cleanup put beyond the wrapper, because both things
    -- being cleaned up here are *process-global*:
    --
    --   * `socketutil:set_timeout` writes `http.TIMEOUT`, `https.TIMEOUT` and
    --     the values that `socketutil.tcp` -- which is monkey-patched over
    --     `socket.tcp` itself (`socketutil.lua:88`) -- applies to every socket
    --     KOReader opens afterwards. Leaving them set does not break KaraBridge;
    --     it breaks every other part of KOReader that opens a connection.
    --   * a file handle. Lua closes one on collection, but "eventually" is not
    --     a budget on a Kobo.
    --
    -- `http.request` is not expected to raise, and in testing it does not. But
    -- the cost of being wrong about that is borne by other people's plugins,
    -- which is the wrong place for it, and a pcall costs nothing.
    local ok, code, response_headers, status = pcall(function()
        return socket.skip(1, http.request(request))
    end)

    socketutil:reset_timeout()

    -- ltn12.sink.file closes on a clean end of stream; this covers the paths
    -- where there never was one.
    if sink_file then
        pcall(function()
            sink_file:close()
        end)
    end

    if not ok then
        log.err("the HTTP request raised:", tostring(code))
        return nil, nil, "request_failed"
    end

    if response_headers == nil then
        return nil, nil, status or "network_error"
    end

    return code, table.concat(sink), nil, response_headers
end

local function defaultSleep(seconds)
    local ok, socket = pcall(require, "socket")
    if ok and type(socket.sleep) == "function" then
        socket.sleep(seconds)
    end
end

--- Perform one request, without retries.
-- @treturn Result
function Client:_attempt(method, path, opts)
    local url = self:buildUrl(path, opts.query)

    -- `raw_body` bypasses the JSON encoder entirely. Only the asset upload
    -- needs it: multipart/form-data carries binary image bytes, and running
    -- those through a JSON encoder would corrupt them even if it succeeded.
    local body_json = opts.raw_body
    if body_json == nil and opts.body ~= nil then
        local encoded, encode_error = Json.encode(opts.body)
        if not encoded then
            return Result.err("encode_failed", "The request could not be built.", { reason = encode_error })
        end
        body_json = encoded
    end

    local request = {
        method = method,
        url = url,
        headers = self:buildHeaders(body_json and #body_json or nil, opts.content_type),
        body = body_json,
    }

    log.dbg(method, Url.forLog(url))

    local perform = self.request_backend or function(req, filepath)
        return self:_socketRequest(req, filepath)
    end

    local code, body, transport_error, response_headers = perform(request, opts.filepath)

    if transport_error or not code then
        if opts.filepath then
            os.remove(opts.filepath)
        end
        log.warn(method, Url.forLog(url), "->", tostring(transport_error or "no response"))
        return translateFailure(nil, transport_error)
    end

    log.dbg(method, Url.forLog(url), "->", code)

    -- Only reachable with follow_redirects off, which is deliberate: the caller
    -- wants to decide what to send to the new location.
    if not self.follow_redirects and code and code >= 300 and code < 400 then
        local location = (response_headers or {}).location or (response_headers or {}).Location
        if type(location) ~= "string" or location == "" then
            return Result.err("redirect", "The server redirected without saying where.", { status = code })
        end
        return Result.err("redirect", "The server redirected.", { status = code, location = location })
    end

    if code == 200 or code == 201 or code == 204 then
        if opts.filepath then
            return Result.ok(opts.filepath)
        end
        if body == nil or body == "" then
            return Result.ok({})
        end

        local decoded, decode_error = Json.decode(body)
        if decoded == nil then
            return Result.err("malformed", "Karakeep sent a response KaraBridge could not read.", {
                reason = decode_error,
                -- A short prefix only: a response body can be an entire
                -- article, and the log is not the place for it.
                preview = tostring(body):sub(1, 200),
            })
        end

        return Result.ok(decoded)
    end

    if opts.filepath then
        os.remove(opts.filepath)
    end

    return translateFailure(code, body and tostring(body):sub(1, 200) or nil)
end

--- Perform a request, retrying the failures where retrying can help.
--
-- @tparam string method GET, POST, PATCH, PUT, DELETE
-- @tparam string path Path below /api/v1, e.g. "/bookmarks".
-- @tparam[opt] table opts
--   query     table appended as a query string
--   body      table encoded as JSON
--   filepath  write the response to this path instead of decoding it
-- @treturn Result
function Client:call(method, path, opts)
    opts = opts or {}

    if not self:isConfigured() then
        return Result.err("not_configured", "The Karakeep server address and API key are not set.")
    end

    local sleep = self.sleep_backend or defaultSleep
    local result

    for attempt = 0, Client.MAX_RETRIES do
        result = self:_attempt(method, path, opts)

        if result:isOk() or not isRetriable(result) or attempt == Client.MAX_RETRIES then
            break
        end

        log.dbg("retrying", method, path, "after", result:describe())
        sleep(2 ^ attempt)
    end

    return result
end

function Client:get(path, opts)
    return self:call("GET", path, opts)
end

function Client:post(path, opts)
    return self:call("POST", path, opts)
end

function Client:patch(path, opts)
    return self:call("PATCH", path, opts)
end

function Client:put(path, opts)
    return self:call("PUT", path, opts)
end

function Client:delete(path, opts)
    return self:call("DELETE", path, opts)
end

--- Follow a cursor-paginated collection to the end.
--
-- Karakeep pages everything with `{ <items>, nextCursor }`
-- (`packages/api/utils/pagination.ts`). Every caller would otherwise write the
-- same loop, and every one of them would need the same guard against a server
-- that returns a cursor forever.
--
-- @tparam string path
-- @tparam table opts
--   query      base query; `cursor` is filled in per page
--   field      name of the array in the response, e.g. "bookmarks"
--   limit      stop after this many items, if given
--   max_pages  hard cap; defaults to 50
-- @treturn Result Value is `{ items = {...}, complete = bool }`.
--   `complete` is false when the walk stopped at a cap rather than at the end,
--   and callers must not treat a partial list as "everything the server has".
function Client:collect(path, opts)
    opts = opts or {}
    local field = opts.field
    local max_pages = opts.max_pages or 50
    local limit = opts.limit

    local items = {}
    local cursor = nil
    local complete = false

    for _ = 1, max_pages do
        local query = {}
        for key, value in pairs(opts.query or {}) do
            query[key] = value
        end
        query.cursor = cursor

        local result = self:get(path, { query = query })
        if result:isErr() then
            return result
        end

        local page = result.value or {}
        for _, item in ipairs(page[field] or {}) do
            table.insert(items, item)
            if limit and #items >= limit then
                return Result.ok({ items = items, complete = false })
            end
        end

        cursor = page.nextCursor
        if not cursor then
            complete = true
            break
        end
    end

    return Result.ok({ items = items, complete = complete })
end

return Client
