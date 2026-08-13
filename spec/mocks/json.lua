--[[--
A tiny JSON codec for the specs.

Not a general-purpose implementation and not trying to be: it round-trips the
shapes Karakeep actually sends, so the API client specs can assert on decoded
tables and on encoded request bodies without the specs depending on KOReader's
`json` module (which is a C binding and not present under a plain interpreter).

`null` decodes to a *function*, deliberately: that is what KOReader's decoder
does, and `karabridge.shared.json`.stripNulls exists precisely to deal with it.
A mock that decoded null to nil would make the null-stripping specs vacuous.

@module spec.mocks.json
]]

local MockJson = {}

--- The sentinel KOReader's decoder uses for JSON null.
function MockJson.null() end

-- KOReader's codec exposes its sentinel as `json.util.null`, and refuses to
-- encode any other function. Mirroring that here is what lets a unit spec see
-- the difference between an absent key and an explicit null -- a difference
-- Karakeep's Zod schemas care about.
MockJson.util = { null = MockJson.null }

local function skipSpace(text, position)
    local _, stop = text:find("^[ \t\r\n]*", position)
    return stop + 1
end

local decodeValue

local function decodeString(text, position)
    local out = {}
    position = position + 1 -- opening quote

    while position <= #text do
        local char = text:sub(position, position)
        if char == '"' then
            return table.concat(out), position + 1
        elseif char == "\\" then
            local escaped = text:sub(position + 1, position + 1)
            local mapped = ({ n = "\n", t = "\t", r = "\r", b = "\b", f = "\f" })[escaped]
            if escaped == "u" then
                -- Only the BMP, and only as a code point: enough for the
                -- fixtures, and anything beyond belongs in a real codec.
                local hex = text:sub(position + 2, position + 5)
                table.insert(out, string.char(tonumber(hex, 16) % 256))
                position = position + 6
            else
                table.insert(out, mapped or escaped)
                position = position + 2
            end
        else
            table.insert(out, char)
            position = position + 1
        end
    end

    error("unterminated string")
end

local function decodeArray(text, position)
    local out = {}
    position = skipSpace(text, position + 1)

    if text:sub(position, position) == "]" then
        return out, position + 1
    end

    while true do
        local value
        value, position = decodeValue(text, position)
        table.insert(out, value)

        position = skipSpace(text, position)
        local char = text:sub(position, position)
        if char == "]" then
            return out, position + 1
        end
        if char ~= "," then
            error("expected , or ] at " .. position)
        end
        position = skipSpace(text, position + 1)
    end
end

local function decodeObject(text, position)
    local out = {}
    position = skipSpace(text, position + 1)

    if text:sub(position, position) == "}" then
        return out, position + 1
    end

    while true do
        local key
        key, position = decodeString(text, position)
        position = skipSpace(text, position)

        if text:sub(position, position) ~= ":" then
            error("expected : at " .. position)
        end
        position = skipSpace(text, position + 1)

        local value
        value, position = decodeValue(text, position)
        out[key] = value

        position = skipSpace(text, position)
        local char = text:sub(position, position)
        if char == "}" then
            return out, position + 1
        end
        if char ~= "," then
            error("expected , or } at " .. position)
        end
        position = skipSpace(text, position + 1)
    end
end

decodeValue = function(text, position)
    position = skipSpace(text, position)
    local char = text:sub(position, position)

    if char == "{" then
        return decodeObject(text, position)
    elseif char == "[" then
        return decodeArray(text, position)
    elseif char == '"' then
        return decodeString(text, position)
    elseif text:sub(position, position + 3) == "true" then
        return true, position + 4
    elseif text:sub(position, position + 4) == "false" then
        return false, position + 5
    elseif text:sub(position, position + 3) == "null" then
        return MockJson.null, position + 4
    end

    local number = text:match("^%-?%d+%.?%d*[eE]?[%+%-]?%d*", position)
    if number and number ~= "" then
        return tonumber(number), position + #number
    end

    error("unexpected character " .. string.format("%q", char) .. " at " .. position)
end

function MockJson.decode(text)
    local value = decodeValue(text, 1)
    return value
end

local function isArray(value)
    local count = 0
    for key in pairs(value) do
        if type(key) ~= "number" then
            return false
        end
        count = count + 1
    end
    return count == #value
end

local function encodeValue(value)
    local kind = type(value)

    if value == nil then
        return "null"
    elseif kind == "boolean" then
        return tostring(value)
    elseif kind == "number" then
        return tostring(value)
    elseif kind == "string" then
        return '"' .. value:gsub("[\\\"]", "\\%0"):gsub("\n", "\\n"):gsub("\t", "\\t"):gsub("\r", "\\r") .. '"'
    elseif kind == "function" then
        if value == MockJson.null then
            return "null"
        end
        error("cannot encode function")
    elseif kind ~= "table" then
        error("cannot encode " .. kind)
    end

    if isArray(value) then
        local parts = {}
        for index, item in ipairs(value) do
            parts[index] = encodeValue(item)
        end
        return "[" .. table.concat(parts, ",") .. "]"
    end

    -- Keys sorted so an encoded body is byte-for-byte assertable.
    local keys = {}
    for key in pairs(value) do
        table.insert(keys, key)
    end
    table.sort(keys)

    local parts = {}
    for _, key in ipairs(keys) do
        table.insert(parts, encodeValue(tostring(key)) .. ":" .. encodeValue(value[key]))
    end
    return "{" .. table.concat(parts, ",") .. "}"
end

function MockJson.encode(value)
    return encodeValue(value)
end

return MockJson
