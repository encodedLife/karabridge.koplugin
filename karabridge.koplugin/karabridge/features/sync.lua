--[[--
The full synchronisation: send back, then fetch, then tidy up.

The order matters and is not arbitrary.

**Upload first.** An article archived now drops out of the list about to be
fetched, so it is never re-downloaded a moment after being finished. Doing it
the other way round produces the single most annoying possible bug: you finish
an article, sync, and it comes straight back.

**Then download.**

**Then remove what is gone remotely — but only under three conditions.** A
local file is deleted only when:

  * the fetch saw the *whole* scope (not capped, not cancelled), because a
    partial list cannot distinguish "archived on another device" from "did not
    fit in this run";
  * the file has no *reader* state and no annotations, meaning it was never
    opened — a sidecar alone does not qualify, because KaraBridge writes one
    when it downloads;
  * it is not one we just downloaded.

Getting this wrong deletes something the user was part way through. The rule is
restated here because it is the most dangerous thing the plugin does.

@module karabridge.features.sync
]]

local Downloader = require("karabridge.features.article_download.downloader")
local Library = require("karabridge.features.article_download.library")
local Logging = require("karabridge.shared.logging")
local Metadata = require("karabridge.shared.metadata")
local Result = require("karabridge.shared.result")
local Uploader = require("karabridge.features.article_sync.uploader")

local log = Logging.forModule("sync")

local Sync = {}
Sync.__index = Sync

--- @tparam table opts client, settings, progress, delete_file
function Sync.new(opts)
    assert(type(opts) == "table" and opts.client and opts.settings, "Sync.new requires a client and settings")

    return setmetatable({
        client = opts.client,
        settings = opts.settings,
        -- Optional: a sync is useful without one, and the specs do not need a
        -- queue to exercise the upload/download/cleanup order.
        queue = opts.queue,
        progress = opts.progress or function()
            return true
        end,
        delete_file = opts.delete_file,
    }, Sync)
end

--- Remove local articles that are no longer in the remote result.
--
-- @tparam string folder
-- @tparam table remote_ids Set of every ID the fetch saw.
-- @tparam table opts `{ complete, delete_file }`
-- @treturn number How many were removed.
function Sync.removeVanished(folder, remote_ids, opts)
    opts = opts or {}

    if not opts.complete then
        -- Not an error, and worth a log line: a capped sync silently skipping
        -- cleanup is otherwise mystifying when the folder keeps growing.
        log.info("skipping cleanup: the sync did not see the whole scope")
        return 0
    end

    local delete_file = opts.delete_file or Uploader.defaultDelete
    local removed = 0

    for id, path in pairs(Library.index(folder)) do
        if not remote_ids[id] then
            -- wasOpened, not hasSidecar. KaraBridge writes a sidecar during the
            -- download, so hasSidecar was true for everything and this pass
            -- removed nothing at all -- the folder simply grew for ever.
            --
            -- Annotations are checked separately: a file someone highlighted
            -- must survive even if the reader state somehow looks absent.
            if Metadata.wasOpened(path) or Metadata.hasAnnotations(path) then
                log.dbg("keeping", id, "- gone remotely but opened here")
            else
                log.info("removing", id, "- gone remotely and never opened")
                delete_file(path)
                removed = removed + 1
            end
        end
    end

    return removed
end

--- Run the whole synchronisation.
-- @treturn Result Value is `{ upload, download, removed }`.
function Sync:run()
    -- The queue first. It holds intent that exists nowhere else -- a link
    -- tapped while offline -- so it is the thing most worth getting out of the
    -- door before anything slower has a chance to fail.
    local queue_summary
    if self.queue then
        queue_summary = self.queue:processAll(self.progress)
    end

    local uploader = Uploader.new({
        client = self.client,
        settings = self.settings,
        progress = self.progress,
        delete_file = self.delete_file,
    })

    local uploaded = uploader:run()
    if uploaded:isErr() then
        return uploaded
    end

    local downloader = Downloader.new({
        client = self.client,
        settings = self.settings,
        progress = self.progress,
    })

    local downloaded = downloader:run()
    if downloaded:isErr() then
        -- The upload half succeeded, so report that rather than throwing the
        -- whole run away: the user's reading status did reach Karakeep.
        log.warn("download failed after a successful upload:", downloaded:describe())
        return Result.ok({
            queue = queue_summary,
            upload = uploaded.value,
            download = nil,
            download_error = downloaded,
            removed = 0,
        })
    end

    local removed = 0
    if self.settings:get("download_enabled") ~= false then
        removed = Sync.removeVanished(self.settings:get("download_folder"), downloaded.value.remote_ids or {}, {
            complete = downloaded.value.complete and not downloaded.value.cancelled,
            delete_file = self.delete_file,
        })
    end

    return Result.ok({
        queue = queue_summary,
        upload = uploaded.value,
        download = downloaded.value,
        removed = removed,
    })
end

--- The lines shown after a full sync.
-- @tparam table summary
-- @treturn table
function Sync.summarise(summary)
    local lines = {}

    if summary.download then
        for _, line in ipairs(Downloader.summarise(summary.download)) do
            table.insert(lines, line)
        end
    elseif summary.download_error then
        table.insert(lines, "Could not fetch articles: " .. (summary.download_error.message or "unknown reason"))
    end

    for _, line in ipairs(Uploader.summarise(summary.upload)) do
        -- "Nothing new to send" is noise next to a download summary; it only
        -- helps when it is the only thing that happened.
        if line ~= "Nothing new to send." or #lines == 0 then
            table.insert(lines, line)
        end
    end

    if summary.queue and (summary.queue.succeeded or 0) > 0 then
        table.insert(lines, string.format("Sent %d queued item(s).", summary.queue.succeeded))
    end

    if (summary.removed or 0) > 0 then
        table.insert(lines, string.format("Removed %d local article(s) no longer in Karakeep.", summary.removed))
    end

    return lines
end

return Sync
