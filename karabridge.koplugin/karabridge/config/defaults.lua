--[[--
The one authoritative description of every KaraBridge setting.

Everything else about configuration is derived from this table: the
`karabridge.conf` parser knows which keys exist and what type each coerces to,
the validator knows which are required, the menu knows which to hide behind
`Advanced`, and the diagnostics dump knows which must be masked. Adding a
setting anywhere else is therefore a bug, and adding one here is enough.

A flat schema of key -> type is the obvious start. This extends it with a
default, a group, a secret flag and a one-line description, because those four
facts otherwise end up spread across four files.

@module karabridge.config.defaults
]]

local Defaults = {}

--- Setting definitions, keyed by setting name.
--
-- Fields:
--   type        "string" | "number" | "boolean"
--   default     value used when neither the file nor the menu has set it
--   group       used to order the settings menu and the example config file
--   secret      never log, never show in full, never write to a diagnostics dump
--   description one line, used as help text and as a comment in the template
--   min, max    numeric bounds, enforced by the validator and the spin widget
--   deprecated  still parsed and still valid in an existing config file, but no
--               longer used for anything
Defaults.SCHEMA = {
    -- Server -----------------------------------------------------------------
    server_url = {
        type = "string",
        default = "",
        group = "server",
        description = "Karakeep base address, without /api/v1.",
    },
    api_token = {
        type = "string",
        default = "",
        group = "server",
        secret = true,
        description = "Karakeep API key. Give the device its own key so it can be revoked alone.",
    },

    -- Article download -------------------------------------------------------
    download_enabled = {
        type = "boolean",
        default = true,
        group = "download",
        description = "Download Karakeep articles onto the device.",
    },
    download_folder = {
        type = "string",
        default = nil,
        group = "download",
        description = "Where downloaded articles are kept. Normally set with the folder picker.",
    },
    articles_per_sync = {
        type = "number",
        default = 30,
        min = 1,
        max = 200,
        group = "download",
        description = "How many of the newest unread articles to fetch in one sync.",
    },
    download_images = {
        type = "boolean",
        default = true,
        group = "download",
        description = "Embed article images in the generated EPUB.",
    },
    max_images = {
        type = "number",
        default = 20,
        min = 0,
        max = 200,
        group = "download",
        description = "Cap on images embedded per article.",
    },
    prefer_archive = {
        type = "boolean",
        default = false,
        group = "download",
        description = "Use the saved page archive instead of Karakeep's extracted article.",
    },
    max_archive_mb = {
        type = "number",
        default = 4,
        min = 1,
        max = 64,
        group = "download",
        description = "Refuse a page archive larger than this, in megabytes.",
    },

    -- What to sync -----------------------------------------------------------
    filter_list = {
        type = "string",
        default = "",
        group = "filter",
        description = "Only sync bookmarks in this Karakeep list. Empty means all.",
    },
    filter_tags = {
        type = "string",
        default = "",
        group = "filter",
        description = "Comma-separated tags to sync. Empty means all.",
    },
    include_archived = {
        type = "boolean",
        default = false,
        group = "filter",
        description = "Include bookmarks already archived in Karakeep.",
    },

    -- Article synchronisation ------------------------------------------------
    sync_read_status = {
        type = "boolean",
        default = true,
        group = "sync",
        description = "Send reading status for downloaded articles back to Karakeep.",
    },
    sync_article_highlights = {
        type = "boolean",
        default = true,
        group = "sync",
        description = "Send highlights made in downloaded articles back to Karakeep.",
    },
    pull_remote_notes = {
        type = "boolean",
        default = true,
        group = "sync",
        description = "Bring notes edited in Karakeep back into the matching KOReader highlight.",
    },
    archive_after_read = {
        type = "boolean",
        default = false,
        group = "sync",
        description = "Archive an article in Karakeep once it is 100% read.",
    },
    archive_finished = {
        type = "boolean",
        default = true,
        group = "sync",
        description = "Archive an article when it is marked as finished.",
    },
    archive_abandoned = {
        type = "boolean",
        default = false,
        group = "sync",
        description = "Archive an article when it is marked as abandoned.",
    },
    archive_tag = {
        type = "string",
        default = "",
        group = "sync",
        description = "Tag to add when archiving. Empty adds none.",
    },
    delete_local_after_archive = {
        type = "boolean",
        default = true,
        group = "sync",
        description = "Delete the local copy once the article is archived.",
    },

    -- Local book export ------------------------------------------------------
    export_local_books = {
        type = "boolean",
        default = true,
        group = "books",
        description = "Offer KaraBridge as a target for KOReader's highlight exporter.",
    },
    book_tag = {
        type = "string",
        default = "",
        group = "books",
        description = "Tag applied to the Karakeep card created for a local book.",
    },
    book_list = {
        type = "string",
        default = "",
        group = "books",
        description = "Karakeep list the card for a local book is added to.",
    },
    book_card_template = {
        type = "string",
        default = "grouped_by_chapter",
        group = "books",
        -- Deprecated and inert. It chose how a book's highlights were rendered
        -- into the card body; nothing renders them there any more, because the
        -- body belongs to the user and highlights are real Karakeep highlights.
        -- Still accepted, and still validated against the old values, so an
        -- existing karabridge.conf keeps loading rather than erroring on a key
        -- it was told to write.
        deprecated = true,
        description = "Deprecated and ignored. The card body is no longer generated from highlights.",
    },
    book_list_id = {
        type = "string",
        default = "",
        group = "books",
        -- Written by the menu picker and re-resolved automatically; a user
        -- editing karabridge.conf by hand sets `book_list` and leaves this
        -- alone. Kept because a name breaks the moment the list is renamed in
        -- Karakeep, and an ID does not.
        description = "Karakeep list ID for book cards. Normally set from the menu, not by hand.",
    },
    filter_list_id = {
        type = "string",
        default = "",
        group = "filter",
        -- As with book_list_id: a name breaks when the list is renamed in
        -- Karakeep, an ID when it is deleted and recreated. Storing both means
        -- neither failure stops a sync on its own.
        description = "Karakeep list ID to sync. Normally set from the menu, not by hand.",
    },
    upload_book_cover = {
        type = "boolean",
        default = true,
        group = "books",
        -- Karakeep shows it in the list layout and on the preview page, but a
        -- text bookmark's bannerImageUrl is null by design, so never as a grid
        -- thumbnail. Worth having; worth not overselling.
        description = "Upload the book's cover and attach it to its card.",
    },

    -- Updates ----------------------------------------------------------------
    update_repo = {
        type = "string",
        default = "",
        group = "updates",
        description = "GitHub repository to update from, as owner/name. Empty turns updates off.",
    },
    update_token = {
        type = "string",
        default = "",
        group = "updates",
        secret = true,
        -- Whether the repository is public or private is not a separate
        -- setting: this token decides. Absent means anonymous, which is all a
        -- public repository needs. Present means authenticated, which a
        -- private one requires and a public one merely benefits from -- 5000
        -- requests an hour instead of 60.
        description = "GitHub token for a private repository. Leave empty for a public one.",
    },
    update_check_on_sync = {
        type = "boolean",
        default = false,
        group = "updates",
        description = "Check for a new version during a normal sync. Never installs by itself.",
    },

    -- Automation -------------------------------------------------------------
    auto_sync_on_wifi = {
        type = "boolean",
        default = false,
        group = "automation",
        description = "Sync when Wi-Fi connects. Never turns the radio on by itself.",
    },
    auto_sync_interval = {
        type = "number",
        default = 30,
        min = 5,
        max = 720,
        group = "automation",
        description = "Shortest gap between two automatic syncs, in minutes.",
    },
}

--- Settings written by the plugin itself, never by a user or a config file.
--
-- Kept out of SCHEMA so that a `karabridge.conf` mentioning one of them is
-- reported as an unknown key rather than quietly rewriting internal state.
Defaults.INTERNAL_KEYS = {
    last_auto_sync = true,
    metadata_schema_version = true,
    -- The lists last fetched from Karakeep, so the picker can be opened and
    -- used without a connection. Purely a cache: losing it costs one request.
    -- One catalogue, not one per setting: both name a list, and they name it
    -- from the same set.
    list_catalogue = true,
}

--- Allowed values for the settings that are effectively enumerations.
Defaults.ENUMS = {
    book_card_template = { "grouped_by_chapter", "flat" },
}

--- The default value for a key.
-- @tparam string key
-- @return any
function Defaults.get(key)
    local definition = Defaults.SCHEMA[key]
    return definition and definition.default
end

--- Is this key a secret that must never be logged?
-- @tparam string key
-- @treturn boolean
function Defaults.isSecret(key)
    local definition = Defaults.SCHEMA[key]
    return (definition and definition.secret) == true
end

--- Every setting key, sorted, so output is stable and testable.
-- @treturn table Array of strings.
function Defaults.keys()
    local keys = {}
    for key in pairs(Defaults.SCHEMA) do
        table.insert(keys, key)
    end
    table.sort(keys)
    return keys
end

--- Setting keys in a group, sorted.
-- @tparam string group
-- @treturn table Array of strings.
function Defaults.keysInGroup(group)
    local keys = {}
    for key, definition in pairs(Defaults.SCHEMA) do
        if definition.group == group then
            table.insert(keys, key)
        end
    end
    table.sort(keys)
    return keys
end

--- A fresh table of every default value.
-- @treturn table
function Defaults.all()
    local values = {}
    for key, definition in pairs(Defaults.SCHEMA) do
        values[key] = definition.default
    end
    return values
end

return Defaults
