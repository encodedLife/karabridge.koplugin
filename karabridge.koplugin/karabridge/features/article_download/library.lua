--[[--
The index of articles already on the device.

Answers one question — "which Karakeep bookmarks do I already have, and where"
— by walking the download folder and reading the ID out of each filename.

Why the filename rather than the sidecar: a file that has never been opened has
no sidecar at all, and those are exactly the ones a sync most needs to know
about. The sidecar is authoritative once it exists; the filename is what always
works.

`.sdr` directories are skipped. They are KOReader's metadata, not articles, and
descending into them wastes time on every sync.

@module karabridge.features.article_download.library
]]

local Filesystem = require("karabridge.shared.filesystem")
local Paths = require("karabridge.shared.paths")

local Library = {}

-- A download folder is not a place to recurse without limit. A user who points
-- KaraBridge at their whole library would otherwise walk the entire card.
Library.MAX_DEPTH = 4

--- Map Karakeep bookmark ID to local path, for every downloaded article.
--
-- Recurses into subfolders, because a user may well have sorted the downloads
-- by hand and moving a file should not make the plugin lose track of it.
--
-- @tparam string dir
-- @tparam[opt] table found Accumulator, for recursion.
-- @tparam[opt=0] number depth
-- @treturn table Keyed by bookmark ID.
function Library.index(dir, found, depth)
    found = found or {}
    depth = depth or 0

    if depth > Library.MAX_DEPTH or not Filesystem.directoryExists(dir) then
        return found
    end

    for _, entry in ipairs(Filesystem.listDirectory(dir)) do
        local path = Paths.join(dir, entry)

        if Filesystem.fileExists(path) then
            local id = Paths.parseArticleId(entry)
            if id then
                found[id] = path
            end
        elseif Filesystem.directoryExists(path) and not entry:match("%.sdr$") then
            Library.index(path, found, depth + 1)
        end
    end

    return found
end

--- How many articles the index holds.
-- @tparam table index
-- @treturn number
function Library.count(index)
    local total = 0
    for _ in pairs(index or {}) do
        total = total + 1
    end
    return total
end

--- Which of `bookmarks` are not yet on the device.
-- @tparam table bookmarks Array of Karakeep bookmarks.
-- @tparam table index From `Library.index`.
-- @treturn table Array of bookmarks, in the order given.
-- @treturn number How many were skipped as already present.
function Library.missing(bookmarks, index)
    local missing, skipped = {}, 0

    for _, bookmark in ipairs(bookmarks or {}) do
        if index[bookmark.id] then
            skipped = skipped + 1
        else
            table.insert(missing, bookmark)
        end
    end

    return missing, skipped
end

--- What should happen to each bookmark in scope.
--
-- "Is this ID already on the device" is not enough. Karakeep re-crawls; an
-- article that arrived as a paywall stub becomes the full text later, and a
-- plugin that skips it for ever because the ID matches leaves the user with
-- the stub. But refreshing unconditionally is worse: replacing a file someone
-- is part way through loses their position and their highlights.
--
-- So the rule, and the reason for each branch:
--
-- | On device | Remote changed | Opened here | Outcome |
-- |---|---|---|---|
-- | no  | –   | –   | **download** |
-- | yes | no  | –   | **unchanged** — nothing to do |
-- | yes | yes | no  | **refresh** — nothing local to lose |
-- | yes | yes | yes | **stale** — reported, not touched |
--
-- "Changed" is `modifiedAt` from Karakeep compared with what was recorded at
-- download time. It is the server's own answer to the question, so it costs no
-- extra request, and a server that does not send it simply means nothing is
-- ever considered changed — the previous behaviour, which is safe.
--
-- @tparam table bookmarks
-- @tparam table index From `Library.index`.
-- @tparam function read_metadata `function(path) -> table|nil`, injected so
--   this stays pure enough to test without a sidecar.
-- @tparam function was_opened `function(path) -> boolean`
-- @treturn table `{ download = {...}, refresh = {...}, unchanged = n, stale = {...} }`
function Library.classify(bookmarks, index, read_metadata, was_opened)
    local plan = { download = {}, refresh = {}, unchanged = 0, stale = {} }

    for _, bookmark in ipairs(bookmarks or {}) do
        local path = index[bookmark.id]

        if not path then
            table.insert(plan.download, bookmark)
        else
            local stored = read_metadata(path)
            local article = stored and stored.article or nil
            local recorded = article and article.remote_modified_at or nil
            local remote = bookmark.modifiedAt

            -- Unchanged when the server says nothing, or says the same thing.
            -- Both are treated as "leave it alone", which is the safe default.
            local changed = type(remote) == "string" and remote ~= "" and recorded ~= nil and remote ~= recorded

            if not changed then
                plan.unchanged = plan.unchanged + 1
            elseif was_opened(path) then
                -- Replacing this would take the reading position and any
                -- highlights with it. Report it and let the user decide.
                table.insert(plan.stale, { bookmark = bookmark, path = path })
            else
                table.insert(plan.refresh, { bookmark = bookmark, path = path })
            end
        end
    end

    return plan
end

return Library
