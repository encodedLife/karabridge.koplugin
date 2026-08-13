--[[--
Karakeep highlight endpoints.

Verified against Karakeep's `packages/api/routes/highlights.ts`
and `packages/shared/types/highlights.ts`:

    GET    /bookmarks/:id/highlights
    POST   /highlights          { bookmarkId, startOffset, endOffset, text, note, color }
    PATCH  /highlights/:id      { color?, note? }
    DELETE /highlights/:id

`zHighlightColorSchema` is `["yellow", "red", "green", "blue"]` — four colours,
and the request is rejected outright for anything else. KOReader offers rather
more, so the mapping below is not cosmetic: without it, highlighting a passage
in cyan silently fails to sync.

`startOffset` and `endOffset` are required numbers with no nullable variant, so
a highlight whose position cannot be resolved is still sent with `0, 0` rather
than dropped. An unanchored highlight that keeps its text and note is worth
more than no highlight at all.

`text` and `note` are `z.string().nullable()` — **nullable, but not optional**.
Leaving either key out is a 400, so an absent value is sent as an explicit JSON
null. This is exactly the sort of thing only a live server can tell you: every
highlight KaraBridge happened to send before the integration suite existed
carried a note, so the gap was invisible.

@module karabridge.api.highlights
]]

local Json = require("karabridge.shared.json")
local Result = require("karabridge.shared.result")
local Text = require("karabridge.shared.text")

local Highlights = {}
Highlights.__index = Highlights

--- The four colours Karakeep accepts.
Highlights.COLORS = { yellow = true, red = true, green = true, blue = true }

--- KOReader's palette, mapped onto Karakeep's four.
--
-- The nearest hue wins; anything unrecognised becomes yellow, which is
-- KOReader's own default and Karakeep's schema default too.
Highlights.COLOR_MAP = {
    red = "red",
    green = "green",
    blue = "blue",
    yellow = "yellow",
    cyan = "blue",
    purple = "red",
    olive = "green",
    orange = "yellow",
    gray = "yellow",
    grey = "yellow",
}

--- Map a KOReader highlight colour to one Karakeep will accept.
-- @tparam any color
-- @treturn string
function Highlights.mapColor(color)
    if type(color) ~= "string" then
        return "yellow"
    end
    return Highlights.COLOR_MAP[color:lower()] or "yellow"
end

--- @tparam table client A `karabridge.api.client`.
function Highlights.new(client)
    return setmetatable({ client = client }, Highlights)
end

--- Every highlight Karakeep already holds for a bookmark.
-- @tparam string bookmark_id
-- @treturn Result Value is the raw response.
function Highlights:forBookmark(bookmark_id)
    return self.client:get("/bookmarks/" .. tostring(bookmark_id) .. "/highlights")
end

--- A set of the normalised texts Karakeep already holds, for duplicate checks.
--
-- Text is the only thing KOReader's XPointer positions and Karakeep's
-- character offsets have in common, so it is also the only usable identity for
-- "have I sent this one already".
--
-- @tparam string bookmark_id
-- @treturn Result Value is a set keyed by normalised text.
function Highlights:existingTexts(bookmark_id)
    local result = self:forBookmark(bookmark_id)
    if result:isErr() then
        return result
    end

    local payload = result.value or {}
    local list = payload.highlights or payload

    local existing = {}
    for _, highlight in ipairs(type(list) == "table" and list or {}) do
        if type(highlight) == "table" and type(highlight.text) == "string" then
            existing[Text.normaliseWhitespace(highlight.text)] = true
        end
    end

    return Result.ok(existing)
end

--- Create a highlight.
-- @tparam table opts bookmark_id, text, note, color, start_offset, end_offset
-- @treturn Result
function Highlights:create(opts)
    opts = opts or {}

    if type(opts.bookmark_id) ~= "string" or opts.bookmark_id == "" then
        return Result.err("invalid_request", "A highlight needs a bookmark ID.")
    end

    -- `text` and `note` are `z.string().nullable()` in zNewHighlightSchema --
    -- nullable, but *not* optional. Omitting either is a 400, so an absent
    -- value has to be sent as an explicit JSON null. The live integration
    -- suite found this; every highlight KaraBridge had sent until then
    -- happened to carry a note.
    return self.client:post("/highlights", {
        body = {
            bookmarkId = opts.bookmark_id,
            startOffset = opts.start_offset or 0,
            endOffset = opts.end_offset or 0,
            text = opts.text ~= nil and opts.text or Json.null(),
            note = opts.note ~= nil and opts.note or Json.null(),
            color = Highlights.mapColor(opts.color),
        },
    })
end

--- Update a highlight's colour or note. Karakeep permits nothing else.
-- @tparam string id
-- @tparam table fields color, note
-- @treturn Result
function Highlights:update(id, fields)
    fields = fields or {}
    return self.client:patch("/highlights/" .. tostring(id), {
        body = {
            color = fields.color and Highlights.mapColor(fields.color) or nil,
            note = fields.note,
        },
    })
end

--- Delete a highlight.
-- @tparam string id
-- @treturn Result
function Highlights:delete(id)
    return self.client:delete("/highlights/" .. tostring(id))
end

return Highlights
