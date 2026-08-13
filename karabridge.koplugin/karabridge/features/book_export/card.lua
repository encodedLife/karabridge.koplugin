--[[--
One Karakeep text card per local book. The card body belongs to the user.

The model:

    1 local book
      = 1 editable Karakeep text bookmark
      + real Karakeep highlights attached to that bookmark

The bookmark and its highlights are **independent**. Highlights are highlight
objects, synchronised in both directions by the same machinery the articles
use. The body is a workspace: notes, a summary, questions, links to other
books. KaraBridge writes it once, when it creates the card, and never again.

That is the whole point of this rewrite. The previous model regenerated the
body from the annotations on every export, which meant every export destroyed
whatever the user had typed there. A content hash decided whether to rewrite —
so the card was only safe from KaraBridge for as long as the book was never
highlighted again.

The decision table is now:

| Stored ID | Remote card | What happens |
|---|---|---|
| none | — | create a card with the neutral starting body |
| present | exists | **leave the body and title alone**; sync highlights and cover |
| present | 404 | it was deleted on the server; create a new one |
| present | any other failure | report it; **never** recreate on an ambiguous answer |

The last row matters as much as the others. Recreating after a timeout or a 500
would produce a duplicate card and orphan every highlight on the original.

Existence is checked with `GET /bookmarks/:id?includeContent=false`. Asking the
highlights endpoint instead would be cheaper by nothing and wrong for a book
with no annotations at all, which has no highlights to ask about and can still
have had its card deleted.

Separated from the KOReader exporter plumbing so this — the part with the
actual rules in it — is testable with a fake API and no KOReader at all.

@module karabridge.features.book_export.card
]]

local BookCardBody = require("karabridge.formats.book_card_body")
local Cover = require("karabridge.features.book_export.cover")
local HighlightSync = require("karabridge.features.article_sync.highlight_sync")
local Logging = require("karabridge.shared.logging")
local Metadata = require("karabridge.shared.metadata")
local Recovery = require("karabridge.shared.recovery")
local Result = require("karabridge.shared.result")
local Text = require("karabridge.shared.text")

local log = Logging.forModule("book_export.card")

local Card = {}
Card.__index = Card

--- @tparam table opts bookmarks, highlights, lists, settings, recovery
function Card.new(opts)
    assert(type(opts) == "table" and opts.bookmarks and opts.settings, "Card.new requires bookmarks and settings")

    return setmetatable({
        bookmarks = opts.bookmarks,
        -- Optional, like `highlights`. Without it the card is written and only
        -- the cover is skipped.
        assets = opts.assets,
        -- Optional. Without it the card is still written; only the separate
        -- highlight objects are skipped.
        highlights = opts.highlights,
        lists = opts.lists,
        settings = opts.settings,
        -- Where a remote ID goes when the sidecar write fails. Without it the
        -- next export creates a second card for the same book.
        recovery = opts.recovery or Recovery.none(),
        -- Resolved once per export run, not once per book: a hundred books
        -- should not mean a hundred identical list lookups.
        list_id = nil,
        list_resolved = false,
    }, Card)
end

--- The Karakeep list configured for book cards, looked up once.
--
-- Two things identify it, and each survives a failure the other does not. A
-- **name** is what someone writes in `karabridge.conf`, and it breaks the
-- moment the list is renamed in Karakeep. An **ID** survives a rename, and
-- breaks if the list is deleted and made again. So both are kept, the ID is
-- preferred, and whichever matched is written back so the other catches up.
--
-- One request either way: `GET /lists` returns the whole set, so matching on
-- both is free.
--
-- @treturn string|nil
function Card:listId()
    if self.list_resolved then
        return self.list_id
    end
    self.list_resolved = true

    if not self.lists then
        return nil
    end

    local name = Text.trim(self.settings:get("book_list") or "")
    local stored_id = Text.trim(self.settings:get("book_list_id") or "")

    if name == "" and stored_id == "" then
        return nil
    end

    local all = self.lists:all()
    if all:isErr() then
        log.warn("could not read the Karakeep lists -", all:describe())
        return nil
    end

    local by_id, by_name
    local wanted = name:lower()

    for _, list in ipairs(all.value) do
        if stored_id ~= "" and list.id == stored_id then
            by_id = list
        end
        if wanted ~= "" and type(list.name) == "string" and list.name:lower() == wanted then
            by_name = list
        end
    end

    local chosen = by_id or by_name
    if not chosen then
        log.warn("the configured book list is not on the server; cards will not be filed")
        return nil
    end

    self.list_id = chosen.id
    self:rememberList(chosen)
    return self.list_id
end

--- Keep the stored name and ID in step with what the server actually has.
--
-- Renaming the list in Karakeep updates the name here; deleting and recreating
-- it updates the ID. Either way the menu goes on showing the truth, and the
-- next export resolves on the first try.
--
-- @tparam table list
function Card:rememberList(list)
    local changed = false

    if type(list.id) == "string" and self.settings:get("book_list_id") ~= list.id then
        self.settings:set("book_list_id", list.id)
        changed = true
    end
    if type(list.name) == "string" and self.settings:get("book_list") ~= list.name then
        self.settings:set("book_list", list.name)
        changed = true
    end

    if changed then
        self.settings:flush()
        log.info("the book list resolved to", tostring(list.name), tostring(list.id))
    end
end

--- Apply the configured tag and list to a newly created card.
--
-- Failures here are logged, not propagated: the card exists and carries the
-- highlights, which is the point. Refusing the whole export because a tag
-- could not be attached would be a poor trade.
--
-- @tparam string bookmark_id
function Card:file(bookmark_id)
    local tag = Text.trim(self.settings:get("book_tag") or "")
    if tag ~= "" then
        local tagged = self.bookmarks:attachTags(bookmark_id, { tag })
        if tagged:isErr() then
            log.warn("could not tag", bookmark_id, "-", tagged:describe())
        end
    end

    local list_id = self:listId()
    if list_id then
        local filed = self.lists:addBookmark(list_id, bookmark_id)
        if filed:isErr() then
            log.warn("could not add", bookmark_id, "to the list -", filed:describe())
        end
    end
end

--- Make sure the book has a card, then sync its highlights and cover.
--
-- @tparam table book The booknotes structure; `book.file` is the local path.
-- @treturn Result Value is `{ action, bookmark_id }` where action is
--   "created", "recreated", "kept" or "article".
function Card:export(book)
    local file_path = book.file
    if type(file_path) ~= "string" or file_path == "" then
        return Result.err("no_file", "This book has no file path.")
    end

    local stored = Metadata.read(file_path)

    -- A file KaraBridge downloaded is already a Karakeep bookmark. Making a
    -- text card for it would be a second, worse copy of something that exists:
    -- a mangled title, no source URL, no tags, and a highlight mapping quietly
    -- repointed from the article at the copy -- which is exactly what happened
    -- the first time a downloaded article went through this path. Its
    -- highlights belong on the article, and `features/sync.lua` puts them
    -- there.
    if stored and stored.article and stored.article.bookmark_id then
        log.info("skipping", file_path, "- it is article", stored.article.bookmark_id)
        return Result.ok({ action = "article", bookmark_id = stored.article.bookmark_id })
    end

    local card = stored and stored.book_card or nil

    -- A previous run created a card but could not record its ID. Adopt it
    -- rather than creating a duplicate.
    if not (card and card.bookmark_id) then
        local orphan = self.recovery:lookup("book_card", file_path)
        if orphan then
            log.info("adopting", orphan, "from the recovery journal for", file_path)
            card = { bookmark_id = orphan }
        end
    end

    if card and card.bookmark_id then
        -- `includeContent = false`: we need to know the card exists, not what
        -- is in it. The body is the user's, and downloading it would only
        -- invite something to start comparing against it again.
        local present = self.bookmarks:get(card.bookmark_id, false)

        if present:isOk() then
            -- Nothing is written to the card itself: not `text`, `title`,
            -- `note` or `summary`. All four are the user's once it exists.
            return Result.ok({
                action = "kept",
                bookmark_id = card.bookmark_id,
                highlights = self:syncHighlights(file_path, card.bookmark_id),
                cover = self:cover(file_path, card.bookmark_id),
            })
        end

        if present:errorCode() ~= "not_found" then
            -- A timeout, a 500, a rejected key. The card may well still be
            -- there, and creating a second one would duplicate the card and
            -- orphan every highlight on the first. Only a 404 is an answer.
            log.warn("could not confirm card", card.bookmark_id, "-", present:describe())
            return present
        end

        log.info("card", card.bookmark_id, "is gone from Karakeep; creating a new one")
    end

    local created = self.bookmarks:createText({
        title = BookCardBody.cardTitle(book),
        text = BookCardBody.initial(),
        source_url = nil,
    })

    if created:isErr() then
        return created
    end

    local bookmark_id = (created.value or {}).id
    if type(bookmark_id) ~= "string" or bookmark_id == "" then
        return Result.err("no_bookmark_id", "Karakeep created the card but did not return its ID.")
    end

    local persisted = self:persist(file_path, bookmark_id)

    self:file(bookmark_id)

    return Result.ok({
        action = (card and card.bookmark_id) and "recreated" or "created",
        bookmark_id = bookmark_id,
        mapping_lost = not persisted,
        highlights = self:syncHighlights(file_path, bookmark_id),
        cover = self:cover(file_path, bookmark_id),
    })
end

--- Put the book's cover on its card.
--
-- Never fails the export. A cover is decoration: a card without its picture is
-- worth immeasurably more than an export that stopped because an image would
-- not upload.
--
-- @tparam string file_path
-- @tparam string bookmark_id
-- @treturn string|nil "uploaded", "replaced" or nil when nothing happened.
function Card:cover(file_path, bookmark_id)
    if not self.assets or self.settings:get("upload_book_cover") == false then
        return nil
    end

    local stored = Metadata.read(file_path)
    local previous = stored and stored.book_card and stored.book_card.cover or nil

    local sent = Cover.send({
        assets = self.assets,
        file_path = file_path,
        bookmark_id = bookmark_id,
        stored = previous,
    })

    if sent:isErr() then
        log.warn("could not send the cover for", file_path, "-", sent:describe())
        return nil
    end

    if sent.value.action == "unchanged" then
        return nil
    end

    -- Recorded so the next export does not upload the same image again. A
    -- failure here costs one redundant upload, not correctness, so it is
    -- logged rather than reported.
    local current = Metadata.read(file_path) or { version = Metadata.SCHEMA_VERSION }
    current.book_card = current.book_card or {}
    current.book_card.cover = { asset_id = sent.value.asset_id, hash = sent.value.hash }
    if not Metadata.write(file_path, current) then
        log.warn("uploaded the cover for", file_path, "but could not record it")
    end

    return sent.value.action
end

--- Attach real Karakeep highlights to the book's card.
--
-- Until now a book produced only a card: its highlights were Markdown
-- blockquotes inside the text, and Karakeep's Highlights view showed nothing
-- for it. Highlights from a downloaded *article* did appear there, so the two
-- behaved differently for no reason a user could see.
--
-- A Karakeep highlight requires a `bookmarkId`, which is why this cannot
-- happen before the card exists — the card *is* the bookmark. Once it does,
-- the same two-way machinery the articles use applies unchanged: stable
-- per-annotation identity, no duplicates on a repeated export, and a note
-- edited in Karakeep coming back to the right annotation.
--
-- Offsets run in **detached** mode. A book highlight has nowhere to point:
-- the card body is the user's free-form text and the passage is deliberately
-- not in it, so there is no position to compute and nothing to download the
-- body for. Text, note, colour, identity and remote ID all synchronise
-- normally; only the underline position is absent, and a correct
-- synchronisation matters more than a misleading underline.
--
-- @tparam string file_path
-- @tparam string bookmark_id
-- @treturn table|nil Counts from `HighlightSync.run`.
function Card:syncHighlights(file_path, bookmark_id)
    if not self.highlights then
        return nil
    end

    local synced = HighlightSync.run({
        apis = { highlights = self.highlights, bookmarks = self.bookmarks },
        bookmark_id = bookmark_id,
        file_path = file_path,
        allow_pull = self.settings:get("pull_remote_notes") ~= false,
        offset_mode = "detached",
    })

    if synced:isErr() then
        log.warn("could not sync highlights for", file_path, "-", synced:describe())
        return nil
    end

    return synced.value
end

--- Write the card mapping into the sidecar, journalling it if that fails.
--
-- The remote card exists by the time this is called, so a failure here is not
-- "the export failed" -- it is "the export succeeded and we cannot remember
-- it", which is the state that produces duplicates.
--
-- No `content_hash` is written any more: there is no generated body to compare
-- against. An older sidecar may still carry one, and it is left exactly where
-- it is -- `Metadata.update` merges, so not writing the key preserves it. It
-- simply no longer decides anything.
--
-- @tparam string file_path
-- @tparam string bookmark_id
-- @treturn boolean Whether the sidecar write succeeded.
function Card:persist(file_path, bookmark_id)
    local written = Metadata.update(file_path, "book_card", {
        bookmark_id = bookmark_id,
        exported_at = os.time(),
    })

    if written then
        self.recovery:clear("book_card", file_path)
    else
        self.recovery:record("book_card", file_path, bookmark_id)
    end
    self.recovery:flush()

    return written
end

--- Export a list of books.
-- @tparam table books Array of booknotes.
-- @tparam[opt] function progress `function(message) -> boolean`
-- @treturn table Summary.
function Card:exportAll(books, progress)
    progress = progress or function()
        return true
    end

    local summary = {
        total = #books,
        created = 0,
        recreated = 0,
        -- The card already existed and was left untouched. Not "skipped": the
        -- highlights and the cover were still synchronised.
        kept = 0,
        -- Files KaraBridge downloaded from Karakeep. They already are
        -- bookmarks; a card for one would be a duplicate of itself.
        article = 0,
        failed = 0,
        -- Sent, but we could not record where. Counted separately because it
        -- is neither a success the user can forget about nor an outright
        -- failure: the card exists and the next export will find it again.
        mapping_lost = 0,
        covers = 0,
        highlights_created = 0,
        highlights_pushed = 0,
        highlights_pulled = 0,
        highlight_conflicts = 0,
        cancelled = false,
        first_error = nil,
    }

    for index, book in ipairs(books) do
        local go_on = progress(
            string.format("Sending %d of %d to Karakeep:\n\n%s", index, #books, book.title or "Untitled")
        )
        if go_on == false then
            summary.cancelled = true
            break
        end

        local exported = self:export(book)
        if exported:isOk() then
            summary[exported.value.action] = (summary[exported.value.action] or 0) + 1

            if exported.value.cover then
                summary.covers = summary.covers + 1
            end

            if exported.value.mapping_lost then
                summary.mapping_lost = summary.mapping_lost + 1
            end

            local counts = exported.value.highlights
            if counts then
                summary.highlights_created = summary.highlights_created + counts.created
                summary.highlights_pushed = summary.highlights_pushed + counts.pushed
                summary.highlights_pulled = summary.highlights_pulled + counts.pulled
                summary.highlight_conflicts = summary.highlight_conflicts + counts.conflicts
                summary.failed = summary.failed + counts.failed
            end
        else
            summary.failed = summary.failed + 1
            summary.first_error = summary.first_error or exported.message or exported:errorCode()
            log.err("export failed for", tostring(book.file), "-", exported:describe())
        end
    end

    return summary
end

--- The lines shown after an export.
-- @tparam table summary
-- @treturn table
function Card.summarise(summary)
    local lines = {}

    local sent = summary.created + summary.recreated
    if sent == 1 then
        table.insert(lines, "Created 1 book card in Karakeep.")
    elseif sent > 1 then
        table.insert(lines, string.format("Created %d book cards in Karakeep.", sent))
    end

    if (summary.article or 0) > 0 then
        table.insert(
            lines,
            string.format(
                "%d were articles from Karakeep, not local books; their highlights sync with the article.",
                summary.article
            )
        )
    end
    if (summary.covers or 0) > 0 then
        table.insert(lines, string.format("Uploaded %d cover(s).", summary.covers))
    end
    if (summary.highlights_created or 0) > 0 then
        table.insert(lines, string.format("Attached %d highlight(s) to the cards.", summary.highlights_created))
    end
    if (summary.highlights_pushed or 0) > 0 then
        table.insert(lines, string.format("Updated %d highlight(s) in Karakeep.", summary.highlights_pushed))
    end
    if (summary.highlights_pulled or 0) > 0 then
        table.insert(lines, string.format("Brought %d note(s) back from Karakeep.", summary.highlights_pulled))
    end
    if (summary.highlight_conflicts or 0) > 0 then
        table.insert(
            lines,
            string.format(
                "%d note(s) changed on both sides. Nothing was overwritten; see Diagnostics.",
                summary.highlight_conflicts
            )
        )
    end

    if summary.recreated > 0 then
        table.insert(lines, string.format("%d card(s) had been deleted and were recreated.", summary.recreated))
    end
    if summary.kept > 0 then
        table.insert(
            lines,
            string.format("%d card(s) already existed; their text was left untouched.", summary.kept)
        )
    end
    if (summary.mapping_lost or 0) > 0 then
        table.insert(
            lines,
            string.format(
                "%d card(s) were sent, but the link to the book could not be saved. "
                    .. "KaraBridge will remember them; see Diagnostics.",
                summary.mapping_lost
            )
        )
    end
    if summary.cancelled then
        table.insert(lines, "Cancelled; the rest were left alone.")
    end
    if summary.failed > 0 then
        table.insert(lines, string.format("%d could not be sent.", summary.failed))
        if summary.first_error then
            table.insert(lines, "First reason: " .. tostring(summary.first_error))
        end
    end

    if #lines == 0 then
        table.insert(lines, "Nothing to send.")
    end

    return lines
end

return Card
