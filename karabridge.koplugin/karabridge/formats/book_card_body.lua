--[[--
The body and title KaraBridge writes when it *creates* a book's card.

Replaces `formats/markdown_book.lua`, which rendered every highlight into the
card as Markdown blockquotes. That model made the card a generated artefact:
anything the user typed into it was overwritten by the next export, because the
export's job was to regenerate the whole body from the annotations.

The model now is:

    1 local book
      = 1 editable Karakeep text bookmark
      + real Karakeep highlights attached to that bookmark

The two are independent. Highlights are highlight objects — searchable, listed
in Karakeep's Highlights view, synchronised in both directions. The body is the
user's: notes, a summary, questions, links to other books, whatever they want.

So this module writes exactly once, at creation, and never again. There is no
`render(book)` any more, because there is nothing to re-render: no chapter
grouping, no page locators, no colour labels, no highlight text. Those
functions were deleted rather than left behind, so nothing in the source still
describes the old duplication as if it were the current model.

Pure Lua: no KOReader, no network.

@module karabridge.formats.book_card_body
]]

local Text = require("karabridge.shared.text")

local BookCardBody = {}

--- The body a newly created card starts with.
--
-- Deliberately almost empty. It says what the card is for, gives three headings
-- to start from, and stops. It carries nothing derived from the annotations —
-- no passages, no notes, no chapters, no page numbers, no colours — and no
-- hidden markers delimiting a "managed" region, because a managed region is
-- just the old problem with a smaller footprint.
--
-- The user is free to rewrite or delete all of it.
BookCardBody.INITIAL = table.concat({
    "*This card is yours to edit. The book's highlights are synchronised"
        .. " separately as Karakeep highlights and are never written into this text.*",
    "",
    "## Notes",
    "",
    "## Summary",
    "",
    "## Questions and connections",
    "",
}, "\n")

--- The Markdown body for a new card.
-- @treturn string
function BookCardBody.initial()
    return BookCardBody.INITIAL
end

--- The card's title in Karakeep, used only when creating the card.
--
-- The book's title, with the author when there is one: a Karakeep list showing
-- twenty cards called "Notes" would be useless.
--
-- Once the card exists this is never sent again, so a title the user changes in
-- Karakeep stays changed.
--
-- @tparam table book
-- @treturn string
function BookCardBody.cardTitle(book)
    local title = Text.trim((type(book) == "table" and book.title) or "")
    if title == "" then
        title = "Untitled"
    end

    local author = Text.trim((type(book) == "table" and book.author) or "")
    if author ~= "" and author ~= "N/A" then
        author = author:gsub("\n", ", ")
        return string.format("%s " .. Text.EM_DASH .. " %s", title, author)
    end

    return title
end

return BookCardBody
