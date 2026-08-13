--[[--
Pure text helpers.

Deliberately free of KOReader dependencies so the specs exercise them under a
plain Lua 5.1 interpreter. HTML handling lives in `karabridge.formats.*`, not
here: this module is only about strings that are already text.

@module karabridge.shared.text
]]

local Text = {}

--- The non-ASCII characters the UI uses, as explicit UTF-8 bytes.
--
-- Deliberately **not** written with a `\u` escape. That form is a LuaJIT and
-- Lua 5.3 feature; plain Lua 5.1 does not know it and, rather than failing,
-- keeps the sequence's tail verbatim. So the same source produces one
-- character on device (KOReader runs LuaJIT) and seven under the interpreter
-- the unit suite runs on -- meaning the specs would assert on strings the
-- plugin never produces.
--
-- Spelling the bytes out is ugly and unambiguous, which is the right trade for
-- something that silently differs between the test and the runtime.
Text.ELLIPSIS = "\226\128\166" -- …
Text.MIDDLE_DOT = "\194\183" -- ·
Text.EM_DASH = "\226\128\148" -- —
Text.CHECK = "\226\156\147" -- ✓
Text.BULLET = "\194\183" -- · (used as a list marker)

--- Strip leading and trailing whitespace.
-- @tparam any s
-- @treturn string
function Text.trim(s)
    if type(s) ~= "string" then
        return ""
    end
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

--- Collapse every run of whitespace to a single space, and trim.
--
-- Highlight matching compares text captured on the device against text
-- rendered by the server. The two disagree about line breaks and indentation
-- constantly, and about nothing else, so normalising whitespace is what makes
-- the comparison meaningful at all.
--
-- @tparam any s
-- @treturn string
function Text.normaliseWhitespace(s)
    if type(s) ~= "string" then
        return ""
    end
    s = s:gsub("%s+", " ")
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

--- Drop a trailing incomplete UTF-8 sequence left by a byte-wise truncation.
--
-- Filesystem limits are counted in bytes, but titles are UTF-8, so cutting at
-- a byte boundary can leave half a character behind. A Kobo renders that as a
-- replacement glyph, and some tools refuse the name outright.
--
-- @tparam string s
-- @treturn string
function Text.trimPartialUtf8(s)
    if type(s) ~= "string" then
        return ""
    end

    local i = #s
    -- A UTF-8 sequence is at most four bytes, so never walk back further.
    local limit = math.max(1, #s - 3)

    while i >= limit do
        local byte = s:byte(i)
        if byte < 0x80 then
            return s -- plain ASCII, nothing dangling
        elseif byte >= 0xC0 then
            local needed
            if byte >= 0xF0 then
                needed = 4
            elseif byte >= 0xE0 then
                needed = 3
            else
                needed = 2
            end

            if #s - i + 1 >= needed then
                return s -- the sequence starting here is complete
            end
            return s:sub(1, i - 1)
        end
        i = i - 1 -- continuation byte; keep walking back to the start byte
    end

    return s
end

--- Truncate to at most `max_bytes`, never splitting a UTF-8 character.
-- @tparam any s
-- @tparam number max_bytes
-- @treturn string
function Text.truncate(s, max_bytes)
    if type(s) ~= "string" then
        return ""
    end
    if #s <= max_bytes then
        return s
    end
    return Text.trimPartialUtf8(s:sub(1, max_bytes))
end

--- Escape a string for XML/XHTML text or an attribute value.
-- @tparam any s
-- @treturn string
function Text.escapeXml(s)
    if type(s) ~= "string" then
        return ""
    end
    s = s:gsub("&", "&amp;")
    s = s:gsub("<", "&lt;")
    s = s:gsub(">", "&gt;")
    s = s:gsub('"', "&quot;")
    s = s:gsub("'", "&apos;")
    return s
end

--- Coerce a value into something safe to interpolate into a UI string.
--
-- `Json.stripNulls` should mean nothing odd ever reaches formatting, but a
-- surprise from the API must degrade to a readable label rather than throw out
-- of `string.format` and abandon a whole sync.
--
-- @param value any
-- @tparam[opt="?"] string fallback
-- @treturn string
function Text.displayText(value, fallback)
    fallback = fallback or "?"

    if type(value) == "string" and value ~= "" then
        return value
    end
    if type(value) == "number" then
        return tostring(value)
    end

    return fallback
end

--- Split a comma-separated setting into a trimmed, non-empty list.
--
-- Used for `filter_tags = read-later, ebook` in `karabridge.conf`, where a
-- stray space around a comma must not become part of a tag name.
--
-- @tparam any s
-- @treturn table Array of strings; empty when there is nothing to split.
function Text.splitList(s)
    local items = {}
    if type(s) ~= "string" then
        return items
    end

    for part in (s .. ","):gmatch("([^,]*),") do
        local trimmed = Text.trim(part)
        if trimmed ~= "" then
            table.insert(items, trimmed)
        end
    end

    return items
end

return Text
