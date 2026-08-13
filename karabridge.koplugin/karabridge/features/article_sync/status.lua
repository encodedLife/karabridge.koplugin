--[[--
Deciding whether the user is done with an article.

KOReader records this in three places and they do not agree with each other:

  * `summary.status` — "complete" or "abandoned", set explicitly by the user.
  * `percent_finished` — 0..1, set by reading to the end.
  * the absence of any *reader* state — never opened. Note that a sidecar on
    its own does not mean opened: KaraBridge creates one during a download.

Which of those count as "finished" is a user preference, so the reading is
separated from the judgement: `read()` reports what KOReader knows, and
`isFinished()` applies the three settings to it. The second is pure, so every
combination is covered by a spec rather than by trying them on a device.

@module karabridge.features.article_sync.status
]]

local Metadata = require("karabridge.shared.metadata")

local Status = {}

-- Reading to 99.5% is finishing it. Requiring exactly 1.0 means an article
-- whose last page is mostly whitespace never counts, which is a fiddly and
-- invisible way to fail.
Status.FINISHED_THRESHOLD = 0.995

--- What KOReader knows about a document's reading state.
-- @tparam string file_path
-- @treturn table `{ opened, status, percent }`
function Status.read(file_path)
    -- wasOpened, not hasSidecar: KaraBridge writes a sidecar when it downloads
    -- a file, so a sidecar proves nothing about whether anyone read it.
    if not Metadata.wasOpened(file_path) then
        return { opened = false, status = nil, percent = 0 }
    end

    local summary = Metadata.readSidecar(file_path, "summary")
    local percent = Metadata.readSidecar(file_path, "percent_finished")

    return {
        opened = true,
        status = type(summary) == "table" and summary.status or nil,
        percent = tonumber(percent) or 0,
    }
end

--- Should this article be archived in Karakeep?
--
-- Pure. `state` comes from `read()`, `settings` is the three archive
-- preferences as a plain table so a spec need not build a Settings object.
--
-- @tparam table state
-- @tparam table settings `{ archive_finished, archive_abandoned, archive_after_read }`
-- @treturn boolean
function Status.isFinished(state, settings)
    if not state or not state.opened then
        return false -- never opened; nothing to report
    end

    settings = settings or {}

    if state.status == "complete" then
        return settings.archive_finished ~= false
    end
    if state.status == "abandoned" then
        return settings.archive_abandoned == true
    end
    if (state.percent or 0) >= Status.FINISHED_THRESHOLD then
        return settings.archive_after_read == true
    end

    return false
end

--- The archive preferences, pulled out of a Settings object.
-- @tparam table settings A `karabridge.config.settings`.
-- @treturn table
function Status.preferences(settings)
    return {
        archive_finished = settings:get("archive_finished") ~= false,
        archive_abandoned = settings:get("archive_abandoned") == true,
        archive_after_read = settings:get("archive_after_read") == true,
    }
end

return Status
