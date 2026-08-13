--[[--
Two-way highlight synchronisation for one article.

Replaces the push-only flow. That version created remote highlights and threw
the returned IDs away, so nothing could ever be *updated* — only created — and
a note edited in Karakeep had no way back to KOReader. It also deduplicated by
text, which meant the same sentence highlighted twice was silently treated as
one.

What happens here, per article:

1. read the local annotations and the recorded mapping,
2. fetch the remote highlights,
3. ask `reconcile.lua` what to do — a pure decision, so every branch is tested,
4. carry the actions out,
5. write the mapping back in one go.

The mapping is written **whole and last**: a sync produces all its changes at
once, so one write is one chance to fail rather than twenty. When that write
fails, the remote side has still moved, and the failure is reported rather than
swallowed — the next sync will re-derive most of it from the hashes it can
still see.

@module karabridge.features.article_sync.highlight_sync
]]

local Annotations = require("karabridge.features.article_sync.annotations")
local Identity = require("karabridge.features.article_sync.identity")
local Logging = require("karabridge.shared.logging")
local Metadata = require("karabridge.shared.metadata")
local Offsets = require("karabridge.features.article_sync.offsets")
local Reconcile = require("karabridge.features.article_sync.reconcile")
local Result = require("karabridge.shared.result")
local Text = require("karabridge.shared.text")

local log = Logging.forModule("article_sync.highlights")

local HighlightSync = {}

--- The article content offsets are measured against.
--
-- Fetched from Karakeep rather than read out of the local EPUB, because the
-- offsets have to index the content *Karakeep* renders, not the file we
-- generated from it. Fetched at most once per article, and only when there is
-- something to create.
--
-- **Returned as HTML, not as text.** `Offsets.locate` does the conversion
-- itself, with `Offsets.domText`, which concatenates text nodes the way a
-- browser's TreeWalker does. Converting here with `HtmlCleaner.toText` — which
-- turns every tag into a space — would insert characters Karakeep's DOM does
-- not have and shift every offset after the first block boundary. That is
-- exactly the bug the offset work set out to fix, so doing it one layer up
-- would have quietly undone it.
--
-- Never called in `detached` mode -- see `run`. A local book's card body is the
-- user's own text and does not contain the highlighted passages, so there is
-- nothing to search and no reason to download it.
--
-- @tparam table bookmarks_api
-- @tparam string bookmark_id
-- @treturn string
function HighlightSync.fetchArticleText(bookmarks_api, bookmark_id)
    local fetched = bookmarks_api:get(bookmark_id, true)
    if fetched:isErr() then
        return ""
    end

    local content = (fetched.value or {}).content or {}

    if type(content.htmlContent) == "string" and content.htmlContent ~= "" then
        return content.htmlContent
    end
    if type(content.text) == "string" then
        return content.text
    end

    return ""
end

--- Build the note Karakeep stores, folding in the chapter.
--
-- Karakeep has no chapter field, and losing which chapter a passage came from
-- makes a long article's highlights much harder to use later.
--
-- @tparam table annotation
-- @treturn string|nil
function HighlightSync.buildNote(annotation)
    local note = annotation.note

    if type(annotation.chapter) == "string" and annotation.chapter ~= "" then
        if type(note) == "string" and note ~= "" then
            note = note .. "\n\n(" .. annotation.chapter .. ")"
        else
            note = "(" .. annotation.chapter .. ")"
        end
    end

    if note == "" then
        return nil
    end
    return note
end

--- Strip the chapter suffix this plugin adds, so a pull does not accumulate it.
--
-- Without this, every round trip would append the chapter again: the note goes
-- out as `text\n\n(Chapter One)` and comes back as the user's new note, which
-- would then have a second `(Chapter One)` added on the way out.
--
-- @tparam any note
-- @tparam any chapter
-- @treturn string
function HighlightSync.stripChapter(note, chapter)
    if type(note) ~= "string" then
        return ""
    end
    if type(chapter) ~= "string" or chapter == "" then
        return note
    end

    local suffix = "(" .. chapter .. ")"
    if note:sub(-#suffix) == suffix then
        note = note:sub(1, #note - #suffix)
    end

    return (note:gsub("%s+$", ""))
end

--- Synchronise one article's highlights in both directions.
--
-- @tparam table opts
--   apis        `{ highlights = …, bookmarks = … }`
--   bookmark_id
--   file_path
--   allow_push  send local changes (default true)
--   allow_pull  apply remote changes (default true)
--   offset_mode "locate" (default) or "detached"
--
-- ## Offset modes
--
-- **locate** — for a downloaded Karakeep article. The article body is fetched
-- once and each passage is found inside it, so the highlight underlines the
-- right words in Karakeep's reader. Offsets are UTF-16 code units over the
-- DOM's text, which is how Karakeep's own reader counts them.
--
-- **detached** — for a local book's card. The card body is the user's editable
-- workspace and deliberately does not contain the passages, so there is no
-- position to compute. Offsets are sent as `0, 0`, the body is never fetched,
-- and this is **not** counted as an unresolved offset: nothing failed to
-- resolve, there was nothing to resolve. Everything else — text, note, colour,
-- identity, the stored remote ID used for later updates and pulls — is
-- unchanged.
--
-- @treturn Result Value is a counts table plus `mapping_saved`.
function HighlightSync.run(opts)
    local apis = opts.apis
    local bookmark_id = opts.bookmark_id
    local file_path = opts.file_path

    local annotations = Annotations.read(file_path)
    local mapping = Metadata.highlightMap(file_path)

    -- A mapping holds remote highlight IDs, and every Karakeep highlight
    -- belongs to exactly one bookmark. If the bookmark has changed underneath
    -- us -- a book card deleted in Karakeep and recreated under a new ID -- the
    -- IDs are void rather than deleted, and keeping them would make the
    -- reconciliation report every highlight as deliberately removed and leave
    -- the new card permanently empty. Owner nil means the mapping predates
    -- this field; it is trusted, because it was written against whatever
    -- bookmark the caller is passing now.
    local owner = Metadata.highlightMapOwner(file_path)
    local mapping_voided = owner ~= nil and owner ~= bookmark_id
    if mapping_voided then
        log.info("highlight mapping belonged to", owner, "not", bookmark_id, "- starting again")
        mapping = {}
    end

    -- Nothing here and nothing recorded: there is neither anything to send nor
    -- anywhere for a remote note to land. Returning before the fetch saves one
    -- request per article per sync, which on a Kobo over Wi-Fi with thirty
    -- articles is the difference between a quick sync and a slow one.
    if #annotations == 0 and next(mapping) == nil and not mapping_voided then
        return Result.ok({
            skipped = 0,
            created = 0,
            pushed = 0,
            pulled = 0,
            conflicts = 0,
            remote_deleted = 0,
            adopted = 0,
            orphans = 0,
            unresolved = 0,
            failed = 0,
            mapping_saved = true,
        })
    end

    local existing = apis.highlights:forBookmark(bookmark_id)
    if existing:isErr() then
        -- Fail closed. Without the remote side there is no way to tell a new
        -- highlight from one already sent, and creating duplicates is the one
        -- outcome only a human can undo.
        log.warn("cannot read remote highlights for", bookmark_id, "- skipping:", existing:describe())
        return Result.ok({
            -- Positive evidence that the bookmark itself is gone, as opposed to
            -- a network failure. Book export uses it to notice a card deleted
            -- in Karakeep's web UI on an export it would otherwise skip.
            remote_missing = existing:errorCode() == "not_found",
            skipped = #annotations,
            created = 0,
            pushed = 0,
            pulled = 0,
            conflicts = 0,
            remote_deleted = 0,
            adopted = 0,
            orphans = 0,
            unresolved = 0,
            failed = 0,
            mapping_saved = true,
        })
    end

    local payload = existing.value or {}
    local remote_list = payload.highlights or payload

    local plan = Reconcile.plan({
        annotations = annotations,
        remote = type(remote_list) == "table" and remote_list or {},
        mapping = mapping,
    })

    local counts = {
        skipped = 0,
        created = 0,
        pushed = 0,
        pulled = 0,
        conflicts = 0,
        remote_deleted = 0,
        adopted = 0,
        orphans = 0,
        unresolved = 0,
        failed = 0,
    }

    if #plan.collisions > 0 then
        -- Two annotations that cannot be told apart. Reported rather than
        -- guessed at; a mapping built on a collision would attach notes to the
        -- wrong passage later.
        log.warn(#plan.collisions, "annotation(s) in", file_path, "could not be given a distinct identity")
    end

    local allow_push = opts.allow_push ~= false
    local allow_pull = opts.allow_pull ~= false
    local detached = opts.offset_mode == "detached"

    local article_text
    local pending_annotation_changes = {}

    local function ensureArticleText()
        if article_text == nil then
            article_text = HighlightSync.fetchArticleText(apis.bookmarks, bookmark_id)
        end
        return article_text
    end

    for _, action in ipairs(plan.actions) do
        if (action.kind == "create" or action.kind == "adopt") and not allow_push and action.kind == "create" then
            counts.skipped = counts.skipped + 1
        elseif action.kind == "create" then
            local start_offset, end_offset = 0, 0

            if not detached then
                local located, located_end = Offsets.locate(ensureArticleText(), action.annotation.text)
                if located then
                    start_offset, end_offset = located, located_end
                else
                    -- The passage should have been in the article and was not.
                    -- Worth counting, unlike the detached case, where there is
                    -- deliberately nothing to find.
                    counts.unresolved = counts.unresolved + 1
                end
            end

            local created = apis.highlights:create({
                bookmark_id = bookmark_id,
                start_offset = start_offset,
                end_offset = end_offset,
                text = Text.normaliseWhitespace(action.annotation.text or ""),
                note = HighlightSync.buildNote(action.annotation),
                color = action.annotation.color,
            })

            if created:isOk() and type((created.value or {}).id) == "string" then
                counts.created = counts.created + 1
                mapping[action.fingerprint] = {
                    remote_id = created.value.id,
                    local_hash = Identity.contentHash(action.fields),
                    remote_hash = Identity.contentHash(Reconcile.remoteFields(created.value)),
                    basis = action.basis,
                    synced_at = os.time(),
                }
            else
                counts.failed = counts.failed + 1
                log.warn("could not create a highlight for", bookmark_id, "-", created:describe())
            end
        elseif action.kind == "adopt" then
            -- A remote highlight that matched exactly one unmapped local
            -- annotation. Recorded, not re-sent.
            counts.adopted = counts.adopted + 1
            mapping[action.fingerprint] = {
                remote_id = action.remote_id,
                local_hash = Identity.contentHash(action.fields),
                remote_hash = Identity.contentHash(action.remote_fields),
                basis = action.basis,
                adopted = true,
                synced_at = os.time(),
            }
        elseif action.kind == "push" then
            if not allow_push then
                counts.skipped = counts.skipped + 1
            else
                local updated = apis.highlights:update(action.remote_id, {
                    note = HighlightSync.buildNote(action.annotation),
                    color = action.annotation.color,
                })

                if updated:isOk() then
                    counts.pushed = counts.pushed + 1
                    local record = mapping[action.fingerprint]
                    record.local_hash = Identity.contentHash(action.fields)
                    record.remote_hash = Identity.contentHash({
                        note = HighlightSync.buildNote(action.annotation) or "",
                        color = action.fields.color,
                    })
                    record.synced_at = os.time()
                else
                    counts.failed = counts.failed + 1
                    log.warn("could not update highlight", action.remote_id, "-", updated:describe())
                end
            end
        elseif action.kind == "pull" then
            if not allow_pull then
                counts.skipped = counts.skipped + 1
            else
                local note = HighlightSync.stripChapter(action.remote_fields.note, action.annotation.chapter)
                local color = Annotations.colorFromKarakeep(action.remote_fields.color)

                table.insert(pending_annotation_changes, {
                    index = action.index,
                    expect_text = action.annotation.text,
                    note = note,
                    color = color,
                })

                counts.pulled = counts.pulled + 1

                local record = mapping[action.fingerprint]
                record.remote_hash = Identity.contentHash(action.remote_fields)
                -- The local side is about to become the remote side, so its
                -- hash is the remote one. Recording the pre-edit local hash
                -- would make the next sync see a spurious local change.
                record.local_hash = Identity.contentHash({
                    note = note,
                    color = color or action.fields.color,
                })
                record.synced_at = os.time()
            end
        elseif action.kind == "conflict" then
            -- Neither side is overwritten. See reconcile.lua for why.
            counts.conflicts = counts.conflicts + 1
            local record = mapping[action.fingerprint]
            record.conflict = {
                at = os.time(),
                local_note = action.fields.note,
                remote_note = action.remote_fields.note,
            }
            log.warn("conflict on a highlight in", file_path, "- both sides changed; neither was overwritten")
        elseif action.kind == "remote_deleted" then
            counts.remote_deleted = counts.remote_deleted + 1
            local record = mapping[action.fingerprint]
            record.remote_deleted = true
            record.synced_at = os.time()
        elseif action.kind == "orphan" then
            -- A remote highlight with no local counterpart, or an ambiguous
            -- one. Counted so the user knows the two sides differ.
            counts.orphans = counts.orphans + 1
        end
    end

    if #pending_annotation_changes > 0 then
        local ok, applied = Annotations.apply(file_path, pending_annotation_changes)
        if ok then
            -- `applied` can be lower than the count planned: an annotation the
            -- array no longer holds at that index is skipped rather than
            -- written over, so the difference is a real failure to report.
            counts.failed = counts.failed + (counts.pulled - applied)
            counts.pulled = applied
        else
            counts.failed = counts.failed + counts.pulled
            counts.pulled = 0
        end
    end

    local mapping_saved = Metadata.setHighlightMap(file_path, mapping, bookmark_id)
    if not mapping_saved then
        log.err("highlights were synced for", file_path, "but the mapping could not be saved")
    end

    counts.mapping_saved = mapping_saved
    return Result.ok(counts)
end

return HighlightSync
