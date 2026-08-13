--[[--
KaraBridge plugin entry point.

Kept small on purpose. This file does four things and delegates everything
else:

  1. records which copy of the plugin is running,
  2. opens the settings store and seeds it from `karabridge.conf`,
  3. builds the API client from those settings,
  4. hands the menu to KOReader.

Anything that grows — the menu, synchronisation, export — lives under
`karabridge/`. The rule is that a new feature adds a module and at most a line
here.

@module koplugin.karabridge.main
]]

local LuaSettings = require("luasettings")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local ffiUtil = require("ffi/util")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")

local Automation = require("karabridge.features.automation")
local BookExporter = require("karabridge.features.book_export.exporter")
local Client = require("karabridge.api.client")
local ConfigPaths = require("karabridge.config.paths")
local DownloadMenu = require("karabridge.features.article_download.menu")
local LinkCapture = require("karabridge.features.link_capture")
local MainMenu = require("karabridge.features.menu.main_menu")
local QueueManager = require("karabridge.features.queue.manager")
local QueueStore = require("karabridge.features.queue.store")
local Recovery = require("karabridge.shared.recovery")
local Metadata = require("karabridge.shared.metadata")
local Runtime = require("karabridge.runtime")
local Settings = require("karabridge.config.settings")

-- Registered here, at module load, and not in init(). exporter.koplugin
-- snapshots the provider registry in its own init(), and instantiation order is
-- alphabetical, so by the time KaraBridge:init() runs the snapshot has already
-- been taken. See ADR-002 in docs/architecture/overview.md.
BookExporter.register()

-- The name is deliberately its own: other Karakeep integrations for KOReader
-- exist, one may already be installed on the same device, and sharing a plugin
-- name, a menu key or a settings file would stop them coexisting while a user
-- moves over.
local KaraBridge = WidgetContainer:extend({
    name = "karabridge",
    is_doc_only = false,
})

--- Log which copy of the plugin is actually running.
--
-- The version alone does not distinguish a fixed copy from a stale one still
-- sitting in the plugins directory — a symlinked development checkout and a
-- forgotten manual install have the same version string. The path and the
-- modification time of main.lua settle it immediately.
function KaraBridge:logBuild()
    local path = self.path or "?"
    local main_lua = ffiUtil.joinPath(path, "main.lua")
    local modified = lfs.attributes(main_lua, "modification")

    logger.info(
        string.format(
            "KaraBridge: loaded version %s, main.lua modified %s, from %s",
            self.version or "unknown",
            modified and os.date("%Y-%m-%d %H:%M:%S", modified) or "?",
            path
        )
    )
end

function KaraBridge:init()
    self:logBuild()

    self.settings = Settings.new({
        store = LuaSettings:open(ConfigPaths.settingsFile()),
        plugin_dir = self.path,
    })

    -- Before anything reads a setting: KOReader's LuaSettings writes a default
    -- back into the store when a setting is read with one, after which nothing
    -- looks unset and there is no gap left for the config file to seed.
    self.settings:seedFromConfigFile()

    -- Where a remote ID goes when its sidecar write fails, so the next run
    -- adopts it instead of creating a duplicate.
    self.recovery = Recovery.new({ store = LuaSettings:open(ConfigPaths.recoveryFile()) })

    self.queue = QueueManager.new({
        store = QueueStore.new({ store = LuaSettings:open(ConfigPaths.queueFile()) }),
        client_factory = function()
            return self:getClient()
        end,
    })

    -- The exporter registered before any of this existed; this is how it
    -- reaches the live settings and API client.
    Runtime.attach(self)

    -- While a book is open, KOReader's in-memory annotations are the real ones
    -- and the .sdr file is a stale copy. Everything of ours that touches a
    -- sidecar goes through this so it reads and writes the same objects
    -- KOReader does -- see Runtime.openDocument for what went wrong without it.
    Metadata.setLiveDocumentProvider(Runtime.openDocument)

    -- Only present on a ReaderUI, so this is a no-op in the file manager.
    LinkCapture.attach(self)

    Automation.registerDispatcherActions(self)
    Automation.setup(self)

    self.ui.menu:registerToMainMenu(self)
end

--------------------------------------------------------------------------------
-- Events
--
-- Thin by design: each one names the feature that does the work. KOReader
-- sandboxes plugin event handlers, so one that throws disables itself for the
-- rest of the session -- another reason to keep them to a single call.
--------------------------------------------------------------------------------

function KaraBridge:onSynchroniseKaraBridge()
    DownloadMenu.synchronise(self)
    return true
end

function KaraBridge:onSendKaraBridgeStatus()
    DownloadMenu.upload(self)
    return true
end

function KaraBridge:onGoToKaraBridgeFolder()
    DownloadMenu.openFolder(self)
    return true
end

--- A Karakeep client built from the current settings.
--
-- Built per call rather than cached: the settings dialog can change the
-- address or the key at any moment, and a stale client would keep talking to
-- the old server with no sign of it. Construction is a table allocation.
--
-- @treturn Client
function KaraBridge:getClient()
    return Client.new({
        server_url = self.settings:get("server_url"),
        api_token = self.settings:get("api_token"),
    })
end

function KaraBridge:addToMainMenu(menu_items)
    menu_items.karabridge = MainMenu.build(self)
end

--- KOReader asks every plugin to persist state before suspend or exit.
function KaraBridge:onFlushSettings()
    if self.settings then
        self.settings:flush()
    end
    if self.queue then
        -- No-op unless something changed; this event fires often and a Kobo's
        -- flash does not enjoy being rewritten for nothing.
        self.queue.store:flush()
    end
    if self.recovery then
        self.recovery:flush()
    end
end

return KaraBridge
