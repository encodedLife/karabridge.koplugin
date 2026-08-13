--[[--
Giving a KOReader annotation a stable identity.

KOReader annotations have no UUID. They are entries in a Lua array in the
sidecar, and their index changes whenever one is added or removed, so the index
is useless as an identity. Text is not enough either: the same sentence can be
highlighted twice in one document, and a note attached to the wrong one is
worse than no note at all.

What an annotation *does* carry:

    pos0, pos1    crengine XPointers for an EPUB, or a page/coordinate table
                  for a PDF. Unique per annotation within a document, and
                  stable as long as the file does not change.
    datetime      when it was created, to the second.
    text          the highlighted passage.
    chapter, page, drawer, color, note

The fingerprint is built from position first, because that is what actually
distinguishes two identical passages, and falls back through datetime to text.
Each level is weaker than the last, so the level used is reported alongside:
a mapping built on text alone is one a caller should be careful with.

**Deliberately excluded: the note and the colour.** Those are the fields
synchronisation *changes*. A fingerprint that moved when the note was edited
would lose the mapping at exactly the moment it is needed.

Pure Lua. No KOReader, no network.

@module karabridge.features.article_sync.identity
]]

local Hashing = require("karabridge.shared.hashing")
local Text = require("karabridge.shared.text")

local Identity = {}

--- Render an XPointer or a PDF position as a comparable string.
--
-- EPUB positions are strings. PDF positions are tables of page and
-- coordinates, and the coordinates are floats that can be re-derived slightly
-- differently, so only the page is used — within one page, datetime and text
-- do the distinguishing.
--
-- @param pos any
-- @treturn string
function Identity.renderPosition(pos)
    if type(pos) == "string" then
        return pos
    end
    if type(pos) == "table" then
        if pos.page ~= nil then
            return "page:" .. tostring(pos.page)
        end
        if pos.x ~= nil and pos.y ~= nil then
            return string.format("xy:%s,%s", tostring(pos.x), tostring(pos.y))
        end
    end
    return ""
end

--- The strongest identity basis this annotation supports.
-- @tparam table annotation
-- @treturn string "position", "datetime" or "text"
function Identity.basisOf(annotation)
    if type(annotation) ~= "table" then
        return "text"
    end

    local start_pos = Identity.renderPosition(annotation.pos0)
    local end_pos = Identity.renderPosition(annotation.pos1)

    if start_pos ~= "" and end_pos ~= "" then
        return "position"
    end
    if type(annotation.datetime) == "string" and annotation.datetime ~= "" then
        return "datetime"
    end
    return "text"
end

--- A stable identity for one KOReader annotation.
--
-- @tparam table annotation
-- @treturn string A 16-character hex fingerprint.
-- @treturn string The basis used: "position", "datetime" or "text".
function Identity.fingerprint(annotation)
    if type(annotation) ~= "table" then
        return Hashing.hash(""), "text"
    end

    local basis = Identity.basisOf(annotation)
    local text = Text.normaliseWhitespace(annotation.text or "")

    if basis == "position" then
        return Hashing.hashParts({
            "pos",
            Identity.renderPosition(annotation.pos0),
            Identity.renderPosition(annotation.pos1),
            text,
        }), basis
    end

    if basis == "datetime" then
        return Hashing.hashParts({ "dt", tostring(annotation.datetime), text }), basis
    end

    return Hashing.hashParts({ "txt", text }), basis
end

--- A hash of the parts synchronisation actually moves.
--
-- Compared against what was recorded at the last sync to answer "did this side
-- change". Only the note and the colour are in it, because those are the only
-- fields either side may edit — the passage itself is immutable once made.
--
-- @tparam table|nil fields `{ note, color }`
-- @treturn string
function Identity.contentHash(fields)
    fields = fields or {}
    return Hashing.hashParts({
        Text.normaliseWhitespace(fields.note or ""),
        tostring(fields.color or ""),
    })
end

--- Index a document's annotations by fingerprint.
--
-- Collisions are possible in principle — two annotations with no position, the
-- same datetime and the same text — and are reported rather than silently
-- resolved, because a colliding pair cannot be told apart later either.
--
-- @tparam table annotations Array from the sidecar.
-- @treturn table Map of fingerprint -> `{ index, annotation, basis }`.
-- @treturn table Array of fingerprints that appeared more than once.
function Identity.index(annotations)
    local byFingerprint, collisions = {}, {}

    for index, annotation in ipairs(annotations or {}) do
        -- Only real highlights. An annotation with no drawer is a page
        -- bookmark, which has no counterpart in Karakeep.
        if type(annotation) == "table" and annotation.drawer then
            local fingerprint, basis = Identity.fingerprint(annotation)

            if byFingerprint[fingerprint] then
                table.insert(collisions, fingerprint)
            else
                byFingerprint[fingerprint] = { index = index, annotation = annotation, basis = basis }
            end
        end
    end

    return byFingerprint, collisions
end

return Identity
