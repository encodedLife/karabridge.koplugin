--[[--
JSON encode/decode, and the null sentinel workaround.

KOReader's JSON decoder represents `null` as a *function*, not nil: a nil would
simply vanish from the table and the key would become indistinguishable from
one the server never sent. A function is truthy, so without stripping,
`bookmark.title or fallback` keeps the sentinel and it goes on to reach
`string.format` or a URL. Karakeep marks a great many fields nullable — title,
note, author, htmlContent, datePublished and nextCursor among them — so this is
applied to every decoded response, once, at the transport boundary.

Diagnosed the hard way, and handled once at the transport boundary rather than
guarded against at every call site.

@module karabridge.shared.json
]]

local Json = {}

local codec

--- Can this value be called?
--
-- Not the same question as `type(v) == "function"`. KOReader's `json` module
-- exports `decode` and `encode` as *tables* carrying a `__call` metamethod, so
-- a function-only check rejects the real codec and every response then looks
-- malformed. That is what this exists for; it cost one debugging session.
local function isCallable(value)
    if type(value) == "function" then
        return true
    end
    if type(value) ~= "table" then
        return false
    end
    local mt = getmetatable(value)
    return mt ~= nil and type(mt.__call) == "function"
end

local function getCodec()
    if codec then
        return codec
    end

    local ok, module = pcall(require, "json")
    if ok and type(module) == "table" and isCallable(module.decode) then
        codec = module
    end

    return codec
end

--- Replace the JSON codec. Used by the specs.
-- @tparam table|nil module Table with encode/decode, or nil to reset.
function Json.setCodec(module)
    codec = module
end

--- A value that encodes to JSON `null`.
--
-- Needed because "absent" and "null" are different to a Zod schema, and
-- Karakeep uses the difference. `zNewHighlightSchema` declares
-- `note: z.string().nullable()` — *nullable, not optional* — so a highlight
-- with no note must send `"note": null` and is rejected with a 400 if the key
-- is simply left out. Found by the live integration suite; the unit specs
-- could not see it, because a mock JSON codec has no opinion about which keys
-- a server requires.
--
-- KOReader's codec has its own sentinel and refuses to encode any other
-- function, so this resolves to that one where it exists.
--
-- @return any
function Json.null()
    local module = getCodec()
    if module and type(module.util) == "table" and module.util.null ~= nil then
        return module.util.null
    end
    -- No codec, or one without a sentinel: nil is the closest honest answer,
    -- and the key is then simply absent rather than wrongly encoded.
    return nil
end

--- Replace JSON nulls with nil throughout a decoded value.
--
-- A decoded JSON value can never legitimately be a function, so testing the
-- type is enough to identify the sentinel.
--
-- @param value any Decoded JSON.
-- @tparam[opt=0] number depth Recursion guard against a pathological response.
-- @return any The same value with nulls removed.
function Json.stripNulls(value, depth)
    if type(value) ~= "table" then
        if type(value) == "function" then
            return nil
        end
        return value
    end

    depth = (depth or 0) + 1
    if depth > 32 then
        return value
    end

    if value[1] ~= nil then
        -- Array-like: rebuilt rather than edited in place, so removing a null
        -- cannot leave a hole that would silently truncate a later ipairs().
        local out = {}
        for _, item in ipairs(value) do
            if type(item) ~= "function" then
                table.insert(out, Json.stripNulls(item, depth))
            end
        end
        return out
    end

    for key, item in pairs(value) do
        if type(item) == "function" then
            value[key] = nil
        elseif type(item) == "table" then
            value[key] = Json.stripNulls(item, depth)
        end
    end

    return value
end

--- Decode JSON text, never throwing.
-- @tparam any text
-- @treturn table|nil Decoded and null-stripped value, or nil.
-- @treturn string|nil Error message when decoding failed.
function Json.decode(text)
    if type(text) ~= "string" or text == "" then
        return nil, "empty response"
    end

    local module = getCodec()
    if not module then
        return nil, "no JSON codec available"
    end

    local ok, decoded = pcall(module.decode, text)
    if not ok or decoded == nil then
        return nil, "malformed JSON"
    end

    return Json.stripNulls(decoded), nil
end

--- Encode a value as JSON text, never throwing.
-- @param value any
-- @treturn string|nil
-- @treturn string|nil Error message when encoding failed.
function Json.encode(value)
    local module = getCodec()
    if not module or not isCallable(module.encode) then
        return nil, "no JSON codec available"
    end

    local ok, encoded = pcall(module.encode, value)
    if not ok or type(encoded) ~= "string" then
        return nil, "value could not be encoded"
    end

    return encoded, nil
end

return Json
