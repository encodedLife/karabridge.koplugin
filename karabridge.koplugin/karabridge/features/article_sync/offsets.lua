--[[--
Working out where a highlight sits, in the units Karakeep actually counts.

## What Karakeep counts

From `packages/shared-react/components/BookmarkHtmlHighlighter.tsx:307-332`:

```js
const getTextNodeOffset = (node) => {
  let offset = 0;
  const walker = document.createTreeWalker(contentRef.current, NodeFilter.SHOW_TEXT, null);
  while (walker.nextNode()) {
    if (walker.currentNode === node) return offset;
    offset += walker.currentNode.textContent?.length ?? 0;
  }
  return -1;
};
```

Two consequences, and the previous implementation got both wrong:

**Offsets are UTF-16 code units.** `String.length` in JavaScript counts UTF-16
code units, not bytes and not code points. A Lua string is bytes. They agree
for ASCII and diverge for everything else: `ä` is two UTF-8 bytes but one UTF-16
unit; `😀` is four bytes but *two* units. Any non-ASCII before a highlight
shifted its offset — silently, because the API accepts any number.

**No separator between elements.** The walk concatenates text nodes and nothing
else, so `<p>one</p><p>two</p>` is `onetwo`, eleven characters shorter than the
`one two` that `HtmlCleaner.toText` produces by turning every tag into a space.
That function is right for *matching* — a highlight spanning a block boundary
contains a space on the device — but wrong for *counting*.

So this module builds the DOM text the way the browser does, matches against a
whitespace-normalised view of it, and maps the result back.

## The honest limitation

Even with both fixed, an offset is a guess about a DOM this plugin never sees.
Karakeep may re-crawl and change the content, and the extraction that produced
`htmlContent` is not guaranteed to match what the reader renders. So offsets
are best-effort by nature, and note synchronisation deliberately does **not**
depend on them: it uses the stored highlight ID. A wrong offset misplaces a
highlight's underline in Karakeep's web reader; it does not lose a note.

Pure Lua.

@module karabridge.features.article_sync.offsets
]]

local HtmlCleaner = require("karabridge.formats.html_cleaner")
local Text = require("karabridge.shared.text")

local Offsets = {}

--- How many UTF-16 code units this UTF-8 string would occupy.
--
-- One per code point below U+10000, two above — the surrogate pair. This is
-- what JavaScript's `String.length` reports, and therefore what Karakeep's
-- offsets are measured in.
--
-- @tparam any s
-- @treturn number
function Offsets.utf16Length(s)
    if type(s) ~= "string" then
        return 0
    end

    local units = 0
    local index = 1
    local length = #s

    while index <= length do
        local byte = s:byte(index)

        if byte < 0x80 then
            index = index + 1
            units = units + 1
        elseif byte < 0xE0 then
            index = index + 2
            units = units + 1
        elseif byte < 0xF0 then
            index = index + 3
            units = units + 1
        else
            -- Above the basic plane: two UTF-16 units for one code point.
            index = index + 4
            units = units + 2
        end
    end

    return units
end

--- The text a browser's TreeWalker would see: text nodes, concatenated.
--
-- No separator is inserted between elements, because the DOM walk inserts
-- none. Entities are decoded, because `textContent` yields decoded text.
--
-- @tparam any html
-- @treturn string
function Offsets.domText(html)
    if type(html) ~= "string" then
        return ""
    end

    -- Elements whose text a browser does not put in the rendered tree at all.
    local stripped = HtmlCleaner.sanitise(html)

    -- Tags removed, not replaced: this is the difference from
    -- HtmlCleaner.toText, and the reason offsets were shifted at every block
    -- boundary.
    stripped = stripped:gsub("<[^>]*>", "")

    return HtmlCleaner.decodeEntities(stripped)
end

--- A whitespace-normalised view of `text`, plus a map back to byte positions.
--
-- Matching has to tolerate whitespace differences — the device's captured text
-- and the server's rendering disagree about line breaks constantly — but the
-- *offset* must be into the original. So the normalised form is built
-- alongside an index from each normalised byte to the original byte it came
-- from.
--
-- @tparam string text
-- @tparam[opt="collapse"] string mode
--   "collapse" — runs of whitespace become one space, as
--     `Text.normaliseWhitespace` does.
--   "strip" — whitespace is removed entirely. Needed because the DOM has no
--     separator between elements while the device's selection does: a passage
--     spanning a block boundary is `onetwo` on the server and `one two` on the
--     device, and only a whitespace-free comparison sees them as the same.
-- @treturn string normalised
-- @treturn table map Normalised 1-based position -> original 1-based position.
function Offsets.normaliseWithMap(text, mode)
    local strip = mode == "strip"
    local out, map = {}, {}
    local index = 1
    local length = #text
    local in_space = false
    -- Leading whitespace is dropped, matching Text.normaliseWhitespace.
    local started = false

    while index <= length do
        local char = text:sub(index, index)

        if char:match("%s") then
            if started and not strip then
                in_space = true
            end
            index = index + 1
        else
            if in_space then
                table.insert(out, " ")
                table.insert(map, index)
                in_space = false
            end
            table.insert(out, char)
            table.insert(map, index)
            started = true
            index = index + 1
        end
    end

    return table.concat(out), map
end

--- Locate a highlighted passage, in UTF-16 code units.
--
-- @tparam any html_or_text The article content. HTML is converted the way the
--   browser would; anything without a tag is used as-is.
-- @tparam any needle The highlighted passage, as KOReader captured it.
-- @treturn number|nil Zero-based start offset in UTF-16 code units.
-- @treturn number|nil End offset, exclusive.
function Offsets.locate(html_or_text, needle)
    if type(html_or_text) ~= "string" or type(needle) ~= "string" then
        return nil
    end

    local text = html_or_text
    if text:find("<", 1, true) then
        text = Offsets.domText(text)
    end

    local wanted = Text.normaliseWhitespace(needle)
    if wanted == "" or text == "" then
        return nil
    end

    -- Three attempts, weakest last.
    local normalised, map = Offsets.normaliseWithMap(text, "collapse")
    local start_pos = normalised:find(wanted, 1, true)
    local matched = wanted

    if not start_pos then
        -- The DOM inserts no separator between elements, so a passage spanning
        -- a block boundary reads `onetwo` here and `one two` on the device.
        -- Comparing with all whitespace removed is the only way to see those
        -- as the same passage.
        local compact_text, compact_map = Offsets.normaliseWithMap(text, "strip")
        local compact_needle = wanted:gsub("%s+", "")

        local compact_pos = compact_text:find(compact_needle, 1, true)
        if compact_pos then
            normalised, map = compact_text, compact_map
            start_pos, matched = compact_pos, compact_needle
        end
    end

    if not start_pos then
        -- KOReader may have captured a partial word at either end, or the
        -- crawler and the renderer may disagree about punctuation. Retry on a
        -- distinctive middle slice before giving up.
        if #wanted > Offsets.MIN_PROBE_LENGTH then
            local probe = wanted:sub(Offsets.PROBE_MARGIN + 1, #wanted - Offsets.PROBE_MARGIN)
            start_pos = normalised:find(probe, 1, true)
            matched = probe
        end
        if not start_pos then
            return nil
        end
    end

    local end_pos = start_pos + #matched - 1

    -- Back to positions in the original text, then to UTF-16 units.
    local original_start = map[start_pos]
    local original_end = map[end_pos]
    if not original_start or not original_end then
        return nil
    end

    local prefix = text:sub(1, original_start - 1)
    local matched_original = text:sub(original_start, original_end)

    local start_units = Offsets.utf16Length(prefix)
    return start_units, start_units + Offsets.utf16Length(matched_original)
end

-- Below this length a middle-slice retry is meaningless: the slice would be
-- too short to identify a passage and would match almost anywhere.
Offsets.MIN_PROBE_LENGTH = 40
-- How much to trim from each end when retrying.
Offsets.PROBE_MARGIN = 10

return Offsets
