--[[--
KaraBridge's slice of a document's KOReader sidecar (`.sdr`) metadata.

Why the sidecar and not a database of our own: it travels with the file when
the user moves or renames it, it survives a plugin reinstall, and KOReader
already keeps it consistent. The pattern is not new; what is
added here is a version field and a migration path, because a metadata schema
without one can only ever be extended, never corrected.

Layout under the `karabridge` sidecar key:

    {
        version = 1,
        article = {                 -- set for files downloaded from Karakeep
            bookmark_id  = "…",
            source_url   = "…",
            content_hash = "…",
            downloaded_at = 1700000000,
            status_synced_at = 1700000000,
        },
        book_card = {               -- set for local books exported as a card
            bookmark_id  = "…",
            content_hash = "…",
            exported_at  = 1700000000,
        },
    }

`article` and `book_card` are independent: an article downloaded from Karakeep
is synced through its own bookmark, and a local book gets a text card. A single
file never legitimately has both, but nothing here forbids it, because refusing
to record something is a worse failure than recording something redundant.

Reads and writes go through KOReader's DocSettings, injected so the specs can
supply a mock rather than a real `.sdr` directory.

@module karabridge.shared.metadata
]]

local Metadata = {}

--- Sidecar key. Distinct from the legacy `karakeep` key, so both can
--- can be installed at once and neither corrupts the other's records.
Metadata.KEY = "karabridge"

--- Current schema version. Bump it and add a branch to `migrate()`.
--
-- 1 -> 2 added `highlights`, the fingerprint-keyed map that makes two-way
-- highlight synchronisation possible. Before it, a pushed highlight's remote
-- ID was discarded, so nothing could ever be updated -- only created.
Metadata.SCHEMA_VERSION = 2

local docsettings_backend

local function docSettings()
    if docsettings_backend then
        return docsettings_backend
    end

    local ok, module = pcall(require, "docsettings")
    if ok and type(module) == "table" then
        docsettings_backend = module
    end

    return docsettings_backend
end

-- Supplies the document KOReader currently holds open. Injected by `main.lua`
-- from `Runtime.openDocument`, and left nil in the specs that do not care.
local live_document_provider

--- Point the metadata layer at the open-document provider.
-- @tparam function|nil provider Returns `{ file, doc_settings, annotations }`.
function Metadata.setLiveDocumentProvider(provider)
    live_document_provider = provider
end

--- KOReader's live objects for this file, when it is the one open.
--
-- A `.sdr` file is a serialisation of state KOReader holds in memory while the
-- book is open, and it lags: a highlight made this session is not in the file
-- until the book closes. Worse, `DocSettings:flush` writes its instance's table
-- wholesale, so a key written through a second instance is erased when
-- KOReader flushes its own on close. Both were live defects -- a highlight
-- made and exported in one sitting reached the card but not Karakeep's
-- highlight list, and the card's own bookmark ID was silently lost, which
-- would have produced a duplicate card on the next export.
--
-- @tparam any file_path
-- @treturn table|nil
function Metadata.liveDocument(file_path)
    if not live_document_provider or type(file_path) ~= "string" then
        return nil
    end

    local ok, document = pcall(live_document_provider)
    if not ok or type(document) ~= "table" or document.file ~= file_path then
        return nil
    end

    return document
end

--- The DocSettings instance to use for a file: KOReader's own where it exists.
-- @tparam string file_path
-- @treturn table|nil settings
-- @treturn boolean Whether it is KOReader's live instance.
local function settingsFor(file_path)
    local live = Metadata.liveDocument(file_path)
    if live and type(live.doc_settings) == "table" then
        return live.doc_settings, true
    end

    local DocSettings = docSettings()
    if not DocSettings then
        return nil, false
    end
    return DocSettings:open(file_path), false
end

--- Replace the DocSettings backend. Used by the specs.
-- @tparam table|nil module DocSettings-compatible table, or nil to reset.
function Metadata.setBackend(module)
    docsettings_backend = module
end

--- The DocSettings module, or nil when KOReader is not present.
--
-- Exposed so the one module that writes KOReader's own annotations can reach
-- it through the same injectable seam as everything else, rather than
-- requiring `docsettings` a second time and bypassing the specs' mock.
--
-- @treturn table|nil
function Metadata.docSettings()
    return docSettings()
end

--- Does this document have a KOReader sidecar?
--
-- Exposed because it answers a question several features need — "has this
-- file ever been opened" — and because routing every sidecar access through
-- this module keeps the DocSettings seam to exactly one place.
--
-- @tparam any file_path
-- @treturn boolean
function Metadata.hasSidecar(file_path)
    local DocSettings = docSettings()
    if not DocSettings or not file_path then
        return false
    end
    return DocSettings:hasSidecarFile(file_path) == true
end

-- Keys KOReader itself writes once a document has actually been opened and
-- rendered. `doc_path` is deliberately absent: DocSettings adds it whenever a
-- sidecar is created, including one KaraBridge creates during a download, so
-- it says nothing about whether anyone read the file.
Metadata.READER_STATE_KEYS = {
    "annotations",
    "bookmarks",
    "doc_pages",
    "doc_props",
    "highlight",
    "last_page",
    "last_xpointer",
    "percent_finished",
    "stats",
    "summary",
}

--- Has KOReader actually opened this document?
--
-- **Not** the same question as "does a sidecar exist". KaraBridge writes
-- `article` metadata into the sidecar the moment it downloads a file, so from
-- that point on a sidecar exists for something nobody has read. Treating the
-- two as equivalent made the sync's cleanup pass a no-op — every downloaded
-- article looked like one the user had opened, so the download folder grew for
-- ever and nothing was ever tidied away.
--
-- The reliable signal is the presence of a key KOReader writes and KaraBridge
-- never does. `copt_*` (the per-document reader configuration) counts too,
-- because it appears as soon as a document is rendered.
--
-- @tparam any file_path
-- @treturn boolean
function Metadata.wasOpened(file_path)
    local DocSettings = docSettings()
    if not DocSettings or not file_path then
        return false
    end
    if not DocSettings:hasSidecarFile(file_path) then
        return false
    end

    local doc_settings = DocSettings:open(file_path)

    for _, key in ipairs(Metadata.READER_STATE_KEYS) do
        if doc_settings:readSetting(key) ~= nil then
            return true
        end
    end

    -- The reader configuration, which appears the first time a document is
    -- rendered. Checked through the raw table where one is available, since
    -- DocSettings has no "list my keys" call.
    local raw = doc_settings.data
    if type(raw) == "table" then
        for key in pairs(raw) do
            if type(key) == "string" and key:sub(1, 5) == "copt_" then
                return true
            end
        end
    end

    return false
end

--- Does this document have any user annotations?
--
-- Asked separately from `wasOpened` because deleting a file someone has
-- highlighted is worse than deleting one they merely opened, and the cleanup
-- rule checks both.
--
-- @tparam any file_path
-- @treturn boolean
function Metadata.hasAnnotations(file_path)
    local annotations = Metadata.readSidecar(file_path, "annotations")
    return type(annotations) == "table" and #annotations > 0
end

--- Read any sidecar key, not just KaraBridge's own.
--
-- Needed for `annotations`, `summary` and `percent_finished`, which are
-- KOReader's and which the sync flow has to read to decide what to send.
--
-- @tparam any file_path
-- @tparam string key
-- @return any
function Metadata.readSidecar(file_path, key)
    local DocSettings = docSettings()
    if not DocSettings or not file_path then
        return nil
    end
    local live = Metadata.liveDocument(file_path)
    if live and type(live.doc_settings) == "table" then
        return live.doc_settings:readSetting(key)
    end

    if not DocSettings:hasSidecarFile(file_path) then
        return nil
    end
    return DocSettings:open(file_path):readSetting(key)
end

--- Bring a raw sidecar table up to the current schema.
--
-- Pure, and the whole reason the schema is versioned: every migration is a
-- branch here with a spec next to it, rather than defensive `or` chains
-- scattered across the features that read the metadata.
--
-- @tparam any raw The value stored under `Metadata.KEY`, or nil.
-- @tparam[opt] table legacy_karakeep The value stored under `karakeep` by
--   an older integration, so a user switching over keeps their book cards.
-- @treturn table|nil Migrated metadata, or nil when there is nothing to migrate.
-- @treturn boolean Whether anything changed and should be written back.
function Metadata.migrate(raw, legacy_karakeep)
    -- Nothing of ours, but an older integration may have been here first. Its
    -- bookmark ID is the one thing worth adopting: without it, the first
    -- KaraBridge export would create a second card for a book that already has
    -- one, which is exactly the duplicate the ID exists to prevent.
    if type(raw) ~= "table" then
        if type(legacy_karakeep) == "table"
            and type(legacy_karakeep.bookmark) == "table"
            and type(legacy_karakeep.bookmark.id) == "string"
        then
            return {
                version = Metadata.SCHEMA_VERSION,
                book_card = {
                    bookmark_id = legacy_karakeep.bookmark.id,
                    -- Deliberately no content_hash: we cannot know what
                    -- was last sent, so the next export must run
                    -- rather than be skipped as unchanged.
                    imported_from = "legacy",
                },
            }, true
        end
        return nil, false
    end

    local version = tonumber(raw.version) or 0
    if version == Metadata.SCHEMA_VERSION then
        return raw, false
    end

    local migrated = {}
    for key, value in pairs(raw) do
        migrated[key] = value
    end

    -- Version 0: written before the field existed. Shape is already current
    -- for its era, so it just falls through the 1 -> 2 step below.
    --
    -- Version 1 -> 2: add the highlight map. Existing highlights were pushed
    -- without their remote IDs being recorded, so the map starts empty and the
    -- first two-way sync adopts them by text where that is unambiguous. Adding
    -- rather than rebuilding, so nothing already recorded is lost.
    if type(migrated.highlights) ~= "table" then
        migrated.highlights = {}
    end

    migrated.version = Metadata.SCHEMA_VERSION

    return migrated, true
end

--- The highlight mapping for a document.
-- @tparam string file_path
-- @treturn table Fingerprint -> record. Empty when there is none.
function Metadata.highlightMap(file_path)
    local data = Metadata.read(file_path)
    if not data or type(data.highlights) ~= "table" then
        return {}
    end
    return data.highlights
end

--- Which bookmark the stored highlight mapping was built against.
--
-- A mapping is a set of remote highlight IDs, and a Karakeep highlight belongs
-- to exactly one bookmark. Point the same mapping at a different bookmark and
-- every ID in it is meaningless -- not "deleted by the user", which is what
-- the reconciliation would otherwise conclude, but void.
--
-- That is not hypothetical. Delete a book's card in Karakeep and export again:
-- the card is recreated under a new ID, its highlights died with the old one,
-- and without this the mapping would report them all as deliberately deleted
-- and leave the new card empty for good.
--
-- @tparam string file_path
-- @treturn string|nil nil for a mapping written before this was recorded.
function Metadata.highlightMapOwner(file_path)
    local data = Metadata.read(file_path)
    if not data then
        return nil
    end
    return data.highlights_bookmark_id
end

--- Replace the highlight mapping for a document.
--
-- Written whole rather than key by key: a sync produces all its changes at
-- once, and one write is one chance to fail instead of twenty.
--
-- @tparam string file_path
-- @tparam table mapping
-- @tparam[opt] string bookmark_id The bookmark the mapping was built against.
-- @treturn boolean Whether the write succeeded.
function Metadata.setHighlightMap(file_path, mapping, bookmark_id)
    local current = Metadata.read(file_path) or { version = Metadata.SCHEMA_VERSION }
    current.highlights = mapping
    if bookmark_id ~= nil then
        current.highlights_bookmark_id = bookmark_id
    end
    return Metadata.write(file_path, current)
end

--- Read KaraBridge metadata for a document.
-- @tparam string file_path
-- @treturn table|nil Migrated metadata, or nil when the file has none.
function Metadata.read(file_path)
    local DocSettings = docSettings()
    if not DocSettings or not file_path then
        return nil
    end
    local doc_settings, is_live = settingsFor(file_path)
    if not doc_settings then
        return nil
    end
    if not is_live and not DocSettings:hasSidecarFile(file_path) then
        return nil
    end

    local raw = doc_settings:readSetting(Metadata.KEY)
    local legacy = doc_settings:readSetting("karakeep")

    local migrated, changed = Metadata.migrate(raw, legacy)
    if migrated and changed then
        doc_settings:saveSetting(Metadata.KEY, migrated)
        doc_settings:flush()
    end

    return migrated
end

--- Overwrite KaraBridge metadata for a document.
--
-- Opens the sidecar even when there is none yet: exporting highlights from a
-- book always implies the sidecar exists, but creating one is harmless and
-- avoids a class of "the ID vanished" bug.
--
-- @tparam string file_path
-- @tparam table data
-- @treturn boolean Whether the write happened.
function Metadata.write(file_path, data)
    local DocSettings = docSettings()
    if not DocSettings or not file_path or type(data) ~= "table" then
        return false
    end

    local stored = {}
    for key, value in pairs(data) do
        stored[key] = value
    end
    stored.version = Metadata.SCHEMA_VERSION

    -- Everything from here is wrapped and then verified, because this return
    -- value is load-bearing: the caller has usually just created something in
    -- Karakeep, and a false "it was saved" is what produces duplicate cards on
    -- the next run. A sidecar write fails for ordinary reasons — an SD card
    -- pulled out, a read-only mount, a full disk, a deleted .sdr directory.
    local ok, err = pcall(function()
        local doc_settings = settingsFor(file_path)
        doc_settings:saveSetting(Metadata.KEY, stored)
        doc_settings:flush()
    end)

    if not ok then
        require("karabridge.shared.logging").forModule("metadata").err(
            "could not write the sidecar for",
            tostring(file_path),
            "-",
            tostring(err)
        )
        return false
    end

    -- Read it back. flush() reports nothing useful, so the only honest way to
    -- know the write landed is to look.
    local verify_ok, readback = pcall(function()
        return DocSettings:open(file_path):readSetting(Metadata.KEY)
    end)

    if not verify_ok or type(readback) ~= "table" then
        return false
    end

    return true
end

--- Merge one section into a document's metadata, leaving the rest alone.
-- @tparam string file_path
-- @tparam string section "article" or "book_card".
-- @tparam table values
-- @treturn boolean
function Metadata.update(file_path, section, values)
    local current = Metadata.read(file_path) or { version = Metadata.SCHEMA_VERSION }

    local existing = current[section]
    local merged = {}
    if type(existing) == "table" then
        for key, value in pairs(existing) do
            merged[key] = value
        end
    end
    for key, value in pairs(values or {}) do
        merged[key] = value
    end

    current[section] = merged
    return Metadata.write(file_path, current)
end

--- The Karakeep bookmark ID recorded for a locally exported book, if any.
-- @tparam string file_path
-- @treturn string|nil
function Metadata.getBookCardId(file_path)
    local data = Metadata.read(file_path)
    return data and data.book_card and data.book_card.bookmark_id or nil
end

--- The Karakeep bookmark ID an article was downloaded from, if any.
-- @tparam string file_path
-- @treturn string|nil
function Metadata.getArticleId(file_path)
    local data = Metadata.read(file_path)
    return data and data.article and data.article.bookmark_id or nil
end

return Metadata
