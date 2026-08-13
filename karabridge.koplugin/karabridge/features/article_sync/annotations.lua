--[[--
Reading and — carefully — writing KOReader's own annotations.

This is the only place in KaraBridge that modifies data KOReader owns, so it is
deliberately narrow. It changes the `note` and the `color` of an annotation
that already exists. It never adds one, never removes one, and never touches
`pos0`, `pos1`, `text`, `datetime` or `drawer`.

That restraint is the point. A remote edit in Karakeep is a note someone typed;
it is not authority over where a highlight sits in a book or whether it exists
at all. Every field outside the two this writes is either the identity of the
annotation or something only the reader can meaningfully change.

Writes go through DocSettings, and the whole `annotations` array is written
back at once because that is the granularity DocSettings offers.

@module karabridge.features.article_sync.annotations
]]

local Logging = require("karabridge.shared.logging")
local Metadata = require("karabridge.shared.metadata")

local log = Logging.forModule("article_sync.annotations")

local Annotations = {}

--- Karakeep's four colours, mapped back onto KOReader's palette.
--
-- The reverse of `api/highlights.lua:COLOR_MAP`, and necessarily lossy: several
-- KOReader colours map to one Karakeep colour, so coming back gives the
-- canonical KOReader name rather than whatever the user originally chose.
--
-- The practical consequence: a highlight the user made cyan, synced, and then
-- pulled back would become blue. So a pull only changes the colour when the
-- *remote* colour actually changed since the last sync — see
-- `reconcile.lua`, which compares in Karakeep's colour space precisely so that
-- an unchanged cyan highlight is never reported as different.
Annotations.COLOR_FROM_KARAKEEP = {
    yellow = "yellow",
    red = "red",
    green = "green",
    blue = "blue",
}

--- Map a Karakeep colour to a KOReader one.
-- @tparam any color
-- @treturn string|nil nil when it is not one KOReader knows.
function Annotations.colorFromKarakeep(color)
    if type(color) ~= "string" then
        return nil
    end
    return Annotations.COLOR_FROM_KARAKEEP[color:lower()]
end

--- Every annotation of a document.
--
-- KOReader's live array when the book is open, the sidecar otherwise. The
-- distinction is not academic: `clip.lua:418` builds the card body from
-- `ui.annotation.annotations`, and a highlight made this session is in that
-- array long before it reaches the `.sdr` file. Reading the file here meant a
-- passage appeared in the card but was invisible to the highlight sync until
-- the book was closed and exported a second time.
--
-- @tparam string file_path
-- @treturn table Array; empty when there are none.
function Annotations.read(file_path)
    local live = Metadata.liveDocument(file_path)
    if live and type(live.annotations) == "table" then
        return live.annotations
    end

    local annotations = Metadata.readSidecar(file_path, "annotations")
    if type(annotations) ~= "table" then
        return {}
    end
    return annotations
end

--- Apply note and colour changes to specific annotations.
--
-- @tparam string file_path
-- @tparam table changes Array of `{ index, note, color }`. `note` and `color`
--   are applied only when present, so a change may carry either or both.
-- @treturn boolean ok
-- @treturn number How many annotations were actually modified.
function Annotations.apply(file_path, changes)
    if #(changes or {}) == 0 then
        return true, 0
    end

    local DocSettings = Metadata.docSettings()
    local live = Metadata.liveDocument(file_path)

    if not DocSettings and not live then
        return false, 0
    end

    local ok, applied = pcall(function()
        -- While the book is open, KOReader's array is the real one and the
        -- sidecar is a stale copy of it. Writing the copy would look like it
        -- worked and then be overwritten wholesale by
        -- `ReaderAnnotation:onSaveSettings` when the book closes -- a note
        -- pulled from Karakeep would simply vanish. So the live array is
        -- mutated in place: it is the same table `ui.annotation` holds, so the
        -- change is already in whatever KOReader saves next.
        local doc_settings = (live and live.doc_settings) or DocSettings:open(file_path)
        local annotations = (live and live.annotations) or doc_settings:readSetting("annotations")

        if type(annotations) ~= "table" then
            return 0
        end

        local count = 0

        for _, change in ipairs(changes) do
            local annotation = annotations[change.index]

            -- The index came from a read of this same array, but a sidecar can
            -- be rewritten by KOReader between the read and the write. The text
            -- is checked as a guard: if it no longer matches, the array shifted
            -- and writing here would edit the wrong passage.
            if type(annotation) == "table" and annotation.text == change.expect_text then
                if change.note ~= nil then
                    annotation.note = change.note ~= "" and change.note or nil
                end
                if change.color ~= nil then
                    annotation.color = change.color
                end
                count = count + 1
            else
                log.warn("skipping annotation", change.index, "- it is not the one that was read")
            end
        end

        if count > 0 then
            doc_settings:saveSetting("annotations", annotations)
            doc_settings:flush()
        end

        return count
    end)

    if not ok then
        log.err("could not write annotations for", tostring(file_path), "-", tostring(applied))
        return false, 0
    end

    return true, applied
end

return Annotations
