--[[--
The handful of things a module-load-time registration needs at run time.

Exists for exactly one reason, recorded as ADR-002: KaraBridge has to register
its highlight exporter with `frontend/provider.lua` **while its main.lua is
being loaded**, not in `init()`.

Why: `exporter.koplugin` snapshots the provider registry in `Exporter:init()`
(`genExportersTable`, its main.lua:91,124). `PluginLoader:loadPlugins()` sorts
with `sortProvidersFirst` for the `dofile` pass but then re-sorts
`enabled_plugins` by path, so *instantiation* is alphabetical and
`exporter.koplugin` comes before `karabridge.koplugin`. Registering in `init()`
is therefore too late for that UI instance. Registering there does exactly
that, and its exporter is missing from the first screen of a session.

But at module-load time there is no plugin instance and so no settings and no
API client. This module is the seam: `main.lua:init()` attaches the live plugin,
and anything registered earlier reaches it through here.

Deliberately small. It is a pointer to the current plugin, not a service
locator to hang things off — every other module still takes its dependencies as
arguments.

@module karabridge.runtime
]]

local Runtime = {}

local plugin

--- Point the runtime at the live plugin instance. Called from `init()`.
-- @tparam table|nil instance
function Runtime.attach(instance)
    plugin = instance
end

--- The current plugin, or nil before `init()` has run.
-- @treturn table|nil
function Runtime.plugin()
    return plugin
end

--- The current settings, or nil.
-- @treturn table|nil
function Runtime.settings()
    return plugin and plugin.settings or nil
end

--- A Karakeep client built from the current settings, or nil.
-- @treturn table|nil
function Runtime.client()
    if not plugin or type(plugin.getClient) ~= "function" then
        return nil
    end
    return plugin:getClient()
end

--- The recovery journal, or a no-op one before `init()` has run.
-- @treturn table
function Runtime.recovery()
    if plugin and plugin.recovery then
        return plugin.recovery
    end
    return require("karabridge.shared.recovery").none()
end

--- The document KOReader currently holds open, if any.
--
-- This matters more than it looks. While a book is open, KOReader's copy of
-- its annotations lives in `ui.annotation.annotations`, and the `.sdr` file on
-- disk is a stale serialisation of it: a highlight made this session does not
-- reach the file until the book is closed. `DocSettings:open` always builds a
-- fresh instance from that file, so anything reading the sidecar directly is
-- reading the past — and anything *writing* it is writing into a copy that
-- `ReaderAnnotation:onSaveSettings` will overwrite wholesale on close.
--
-- So callers that touch a document's sidecar ask here first, and use
-- KOReader's own live objects when the file matches.
--
-- @treturn table|nil `{ file, doc_settings, annotations }`
function Runtime.openDocument()
    local ui = plugin and plugin.ui
    if type(ui) ~= "table" then
        return nil
    end

    local document = ui.document
    if type(document) ~= "table" or type(document.file) ~= "string" then
        return nil
    end

    return {
        file = document.file,
        -- The document itself, so the cover can be read without opening a
        -- second handle to a book KOReader already has open.
        document = document,
        doc_settings = ui.doc_settings,
        annotations = type(ui.annotation) == "table" and ui.annotation.annotations or nil,
    }
end

--- Is there enough configuration to talk to Karakeep?
-- @treturn boolean
function Runtime.isReady()
    local settings = Runtime.settings()
    if not settings then
        return false
    end
    return settings:readiness().connect == true
end

return Runtime
