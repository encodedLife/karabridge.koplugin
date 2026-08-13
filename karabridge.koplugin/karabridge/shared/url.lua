--[[--
URL normalisation, validation and query building.

Pure Lua, so the specs cover every branch without a network or KOReader.

@module karabridge.shared.url
]]

local Text = require("karabridge.shared.text")

local Url = {}

--- Clean up a server address typed on an e-reader keyboard.
--
-- Two mistakes are near-universal and both are silently corrected: a trailing
-- slash, and pasting the address straight out of Karakeep's API documentation
-- with `/api/v1` already on the end. Correcting them here means the rest of
-- the plugin can concatenate paths without thinking about it.
--
-- @tparam any url
-- @treturn string Normalised URL, or "" when there was nothing usable.
function Url.normaliseServerUrl(url)
    if type(url) ~= "string" then
        return ""
    end

    url = Text.trim(url)
    url = url:gsub("/+$", "")
    url = url:gsub("/api/v1$", "")
    url = url:gsub("/+$", "")

    return url
end

--- Check that a normalised server URL is one we are willing to talk to.
--
-- Only http and https: KOReader's socket stack will happily be handed a
-- `file://` or `ftp://` address, and a typo that turns into a local file read
-- is worth refusing loudly.
--
-- Plain http is permitted — a Karakeep on a home LAN is a normal setup — but
-- the caller is expected to warn about it, because the API token travels in a
-- header on every request.
--
-- @tparam any url
-- @treturn boolean ok
-- @treturn string|nil Reason code when not ok: "empty", "no_scheme",
--   "unsupported_scheme", "no_host", "has_userinfo".
function Url.validateServerUrl(url)
    if type(url) ~= "string" or Text.trim(url) == "" then
        return false, "empty"
    end

    url = Text.trim(url)

    local scheme, rest = url:match("^(%a[%w+.-]*)://(.*)$")
    if not scheme then
        return false, "no_scheme"
    end

    scheme = scheme:lower()
    if scheme ~= "http" and scheme ~= "https" then
        return false, "unsupported_scheme"
    end

    local authority = rest:match("^([^/%?#]*)") or ""
    if authority == "" then
        return false, "no_host"
    end

    -- Credentials in the URL would end up in every log line that mentions the
    -- server. Refuse them and let the user put the token in the token field.
    if authority:find("@", 1, true) then
        return false, "has_userinfo"
    end

    return true
end

--- Is this a plain-http address? Callers use it to warn about token exposure.
-- @tparam any url
-- @treturn boolean
function Url.isInsecure(url)
    if type(url) ~= "string" then
        return false
    end
    return url:lower():match("^http://") ~= nil
end

--- Percent-encode a string for use in a URL query.
-- @tparam any s
-- @treturn string
function Url.encode(s)
    if type(s) ~= "string" then
        return ""
    end
    return (s:gsub("[^%w%-%_%.%~]", function(c)
        return string.format("%%%02X", string.byte(c))
    end))
end

--- A URL reduced to what is safe to write into a log.
--
-- Everything after `?` or `#` is dropped. A query string is not decoration: a
-- signed storage URL carries its whole authorisation there, so logging one
-- hands a reader time-limited access to whatever it points at. The plugin
-- already refuses to log an Authorization header; a credential in a query
-- parameter is the same thing wearing a different hat.
--
-- The path is kept, because "which endpoint was called" is the entire value of
-- the log line.
--
-- @tparam any url
-- @treturn string
function Url.forLog(url)
    if type(url) ~= "string" then
        return "<no url>"
    end

    local trimmed = url:gsub("[?#].*$", "")
    if trimmed ~= url then
        return trimmed .. "?<redacted>"
    end
    return trimmed
end

--- Build a query string from a table, skipping nils.
--
-- Keys are sorted so the output is stable, which is what makes request
-- construction assertable in a spec. An array value is emitted as a repeated
-- parameter, which is how Karakeep's Hono/Zod validators expect lists.
--
-- @tparam any params
-- @treturn string "" or "?a=1&b=2&b=3"
function Url.buildQuery(params)
    if type(params) ~= "table" then
        return ""
    end

    local keys = {}
    for key, value in pairs(params) do
        if value ~= nil then
            table.insert(keys, key)
        end
    end
    table.sort(keys, function(a, b)
        return tostring(a) < tostring(b)
    end)

    local parts = {}
    for _, key in ipairs(keys) do
        local value = params[key]
        if type(value) == "table" then
            for _, item in ipairs(value) do
                table.insert(parts, Url.encode(tostring(key)) .. "=" .. Url.encode(tostring(item)))
            end
        else
            if type(value) == "boolean" then
                value = value and "true" or "false"
            end
            table.insert(parts, Url.encode(tostring(key)) .. "=" .. Url.encode(tostring(value)))
        end
    end

    if #parts == 0 then
        return ""
    end
    return "?" .. table.concat(parts, "&")
end

return Url
