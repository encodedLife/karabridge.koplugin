--[[--
Sending reading status and highlights back to Karakeep.

Runs over every article already on the device, and for each one:

  1. pushes any new highlights, if the file has been opened at all — not only
     if it is finished, so notes are not lost when the user never marks an
     article read;
  2. decides whether it counts as finished, from the sidecar and the three
     archive preferences;
  3. if so, archives it in Karakeep, applies `archive_tag`, and deletes the
     local copy when `delete_local_after_archive` is on.

**There is deliberately no queue here.** "Finished" and "highlighted" already
live durably in KOReader's `.sdr` sidecar, which this reconciles against the
server on every run. An upload that fails because the network dropped is simply
retried next time, with no separate queue state that could drift from what is
actually on disk. What a queue *is*
needed for is an action with no local state to reconstruct it from — capturing
a link while offline — and that lives in `features/queue/`.

The one thing worth saying out loud is when uploads did fail, so the counts are
reported rather than only logged.

@module karabridge.features.article_sync.uploader
]]

local Bookmarks = require("karabridge.api.bookmarks")
local HighlightSync = require("karabridge.features.article_sync.highlight_sync")
local HighlightsApi = require("karabridge.api.highlights")
local Library = require("karabridge.features.article_download.library")
local Logging = require("karabridge.shared.logging")
local Metadata = require("karabridge.shared.metadata")
local Result = require("karabridge.shared.result")
local Status = require("karabridge.features.article_sync.status")
local Text = require("karabridge.shared.text")

local log = Logging.forModule("article_sync")

local Uploader = {}
Uploader.__index = Uploader

--- Create an uploader.
-- @tparam table opts client, settings, progress, delete_file
-- @treturn Uploader
function Uploader.new(opts)
    assert(type(opts) == "table" and opts.client and opts.settings, "Uploader.new requires a client and settings")

    return setmetatable({
        client = opts.client,
        settings = opts.settings,
        bookmarks = Bookmarks.new(opts.client),
        highlights = HighlightsApi.new(opts.client),
        progress = opts.progress or function()
            return true
        end,
        -- Injected so a spec can watch what would be deleted without a
        -- filesystem, and so the real deletion goes through KOReader's
        -- FileManager, which also removes the sidecar and the history entry.
        delete_file = opts.delete_file or Uploader.defaultDelete,
    }, Uploader)
end

--- Delete a local article, its sidecar and its history entry.
function Uploader.defaultDelete(path)
    local ok, FileManager = pcall(require, "apps/filemanager/filemanager")
    if not ok then
        os.remove(path)
        return
    end
    -- deleteFile() takes care of the sidecar and the history entry too.
    FileManager:deleteFile(path, true)
end

--- Send status and highlights for one article.
--
-- @tparam string bookmark_id
-- @tparam string path
-- @tparam table preferences From `Status.preferences`.
-- @treturn table `{ highlights_created, unresolved, archived, deleted, failed }`
function Uploader:syncOne(bookmark_id, path, preferences)
    local outcome = {
        highlights_created = 0,
        highlights_pushed = 0,
        highlights_pulled = 0,
        conflicts = 0,
        remote_deleted = 0,
        adopted = 0,
        orphans = 0,
        unresolved = 0,
        highlight_failures = 0,
        mapping_lost = 0,
        archived = false,
        deleted = false,
        failed = false,
    }

    local state = Status.read(path)

    -- Highlights first, and for anything opened rather than only for finished
    -- articles: a passage marked in an article the user never finishes is
    -- still worth keeping.
    if self.settings:get("sync_article_highlights") ~= false and state.opened then
        local synced = HighlightSync.run({
            apis = { highlights = self.highlights, bookmarks = self.bookmarks },
            bookmark_id = bookmark_id,
            file_path = path,
            allow_pull = self.settings:get("pull_remote_notes") ~= false,
        })

        if synced:isOk() then
            local counts = synced.value
            outcome.highlights_created = counts.created
            outcome.highlights_pushed = counts.pushed
            outcome.highlights_pulled = counts.pulled
            outcome.conflicts = counts.conflicts
            outcome.remote_deleted = counts.remote_deleted
            outcome.adopted = counts.adopted
            outcome.orphans = counts.orphans
            outcome.unresolved = counts.unresolved
            outcome.highlight_failures = counts.failed
            outcome.mapping_lost = counts.mapping_saved and 0 or 1
        end
    end

    if self.settings:get("sync_read_status") == false then
        return outcome
    end

    if not Status.isFinished(state, preferences) then
        return outcome
    end

    local archived = self.bookmarks:update(bookmark_id, { archived = true })
    if archived:isErr() then
        -- Left on the device with its sidecar intact, so the next run picks it
        -- up again. This is what makes the absence of a queue safe.
        log.warn("could not archive", bookmark_id, "- will retry next sync:", archived:describe())
        outcome.failed = true
        return outcome
    end

    outcome.archived = true

    local tag = Text.trim(self.settings:get("archive_tag") or "")
    if tag ~= "" then
        self.bookmarks:attachTags(bookmark_id, { tag })
    end

    if self.settings:get("delete_local_after_archive") ~= false then
        self.delete_file(path)
        outcome.deleted = true
    else
        -- Kept locally, so record that the status has gone up. Without this
        -- the next run re-sends the same archive request for every article
        -- the user chose to keep.
        Metadata.update(path, "article", { status_synced_at = os.time() })
    end

    return outcome
end

--- Send status and highlights for every article on the device.
--
-- @tparam[opt] table index From `Library.index`; built from the download
--   folder when not supplied.
-- @treturn Result Value is a summary.
function Uploader:run(index)
    local folder = self.settings:get("download_folder")
    index = index or Library.index(folder)

    local preferences = Status.preferences(self.settings)

    local summary = {
        examined = 0,
        total = Library.count(index),
        highlights_created = 0,
        highlights_pushed = 0,
        highlights_pulled = 0,
        conflicts = 0,
        remote_deleted = 0,
        adopted = 0,
        orphans = 0,
        unresolved = 0,
        mapping_lost = 0,
        archived = 0,
        deleted = 0,
        failed = 0,
        cancelled = false,
    }

    -- Sorted, so a run is reproducible and a spec can assert on order. pairs()
    -- over a hash is deterministic within one Lua state but not across them.
    local ids = {}
    for id in pairs(index) do
        table.insert(ids, id)
    end
    table.sort(ids)

    for _, id in ipairs(ids) do
        summary.examined = summary.examined + 1

        local go_on = self.progress(
            string.format(
                "Sending read status and highlights (%d of %d)%s",
                summary.examined,
                summary.total,
                Text.ELLIPSIS
            )
        )
        if go_on == false then
            summary.cancelled = true
            break
        end

        local outcome = self:syncOne(id, index[id], preferences)

        summary.highlights_created = summary.highlights_created + outcome.highlights_created
        summary.highlights_pushed = summary.highlights_pushed + outcome.highlights_pushed
        summary.highlights_pulled = summary.highlights_pulled + outcome.highlights_pulled
        summary.conflicts = summary.conflicts + outcome.conflicts
        summary.remote_deleted = summary.remote_deleted + outcome.remote_deleted
        summary.adopted = summary.adopted + outcome.adopted
        summary.orphans = summary.orphans + outcome.orphans
        summary.unresolved = summary.unresolved + outcome.unresolved
        summary.mapping_lost = summary.mapping_lost + outcome.mapping_lost
        -- A highlight that could not be sent is a failure of the run, even
        -- when the article's status went up fine. Counting only archive
        -- failures made "Nothing new to send" appear after real errors.
        summary.failed = summary.failed + outcome.highlight_failures
        if outcome.archived then
            summary.archived = summary.archived + 1
        end
        if outcome.deleted then
            summary.deleted = summary.deleted + 1
            index[id] = nil
        end
        if outcome.failed then
            summary.failed = summary.failed + 1
        end
    end

    log.info(
        string.format(
            "upload done - %d examined, %d highlights, %d archived, %d deleted, %d failed",
            summary.examined,
            summary.highlights_created,
            summary.archived,
            summary.deleted,
            summary.failed
        )
    )

    return Result.ok(summary)
end

--- Turn a summary into the lines shown to the user.
-- @tparam table summary
-- @treturn table Array of lines.
function Uploader.summarise(summary)
    local lines = {}

    if summary.archived == 1 then
        table.insert(lines, "Archived 1 article in Karakeep.")
    elseif summary.archived > 1 then
        table.insert(lines, string.format("Archived %d articles in Karakeep.", summary.archived))
    end

    if summary.highlights_created == 1 then
        table.insert(lines, "Sent 1 new highlight.")
    elseif summary.highlights_created > 1 then
        table.insert(lines, string.format("Sent %d new highlights.", summary.highlights_created))
    end

    if (summary.highlights_pushed or 0) > 0 then
        table.insert(lines, string.format("Updated %d highlight(s) in Karakeep.", summary.highlights_pushed))
    end
    if (summary.highlights_pulled or 0) > 0 then
        table.insert(lines, string.format("Brought %d note(s) back from Karakeep.", summary.highlights_pulled))
    end
    if (summary.adopted or 0) > 0 then
        table.insert(lines, string.format("Matched %d existing highlight(s) to Karakeep.", summary.adopted))
    end
    if (summary.conflicts or 0) > 0 then
        table.insert(
            lines,
            string.format(
                "%d note(s) changed on both sides. Nothing was overwritten; see Diagnostics.",
                summary.conflicts
            )
        )
    end
    if (summary.remote_deleted or 0) > 0 then
        table.insert(
            lines,
            string.format(
                "%d highlight(s) were deleted in Karakeep. Your annotations were kept.",
                summary.remote_deleted
            )
        )
    end
    if (summary.orphans or 0) > 0 then
        table.insert(lines, string.format("%d Karakeep highlight(s) have no match in this book.", summary.orphans))
    end
    if (summary.mapping_lost or 0) > 0 then
        table.insert(
            lines,
            string.format("%d article(s) synced, but the highlight mapping could not be saved.", summary.mapping_lost)
        )
    end

    if summary.unresolved > 0 then
        table.insert(
            lines,
            string.format("%d highlight(s) could not be positioned, and were sent without one.", summary.unresolved)
        )
    end

    if summary.failed > 0 then
        table.insert(lines, string.format("%d could not be sent, and will be retried next sync.", summary.failed))
    end

    if summary.cancelled then
        table.insert(lines, "Cancelled; the rest were left alone.")
    end

    if #lines == 0 then
        -- Only when genuinely nothing happened. A failure anywhere above adds
        -- a line, so this can no longer appear after a real error.
        table.insert(lines, "Nothing new to send.")
    end

    return lines
end

return Uploader
