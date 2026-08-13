--[[--
KaraBridge as a target in KOReader's highlight exporter.

## The registration problem

`exporter.koplugin` snapshots the provider registry in `Exporter:init()`, and
instantiation order is alphabetical, so `exporter.koplugin` runs before
`karabridge.koplugin`. Registering in our own `init()` is too late — see
ADR-002.

So registration happens while `main.lua` is being *loaded*. But at that moment
`require("base")` does not resolve: `PluginLoader:_load` sets `package.path` to
the current plugin's directory only, and the loop that adds every plugin's path
runs after all of them are loaded. `base` lives in `exporter.koplugin`.

The way out is a table that hydrates itself. `Provider:register` only needs a
table; nothing is *called* on it until an `Exporter:init()` later in startup, by
which time `base` resolves. So the registered table carries an `__index` that,
on first access, builds the real BaseExporter-derived object and copies it in
place. After that the metamethod never fires again.

This is more indirection than one likes, and it is confined to this file for
that reason. The alternative — reimplementing BaseExporter's surface — would
drift from KOReader the first time that class changed.

@module karabridge.features.book_export.exporter
]]

local Assets = require("karabridge.api.assets")
local Bookmarks = require("karabridge.api.bookmarks")
local Card = require("karabridge.features.book_export.card")
local Highlights = require("karabridge.api.highlights")
local Lists = require("karabridge.api.lists")
local Logging = require("karabridge.shared.logging")
local Notification = require("karabridge.shared.notification")
local Progress = require("karabridge.features.progress")
local Runtime = require("karabridge.runtime")
local Text = require("karabridge.shared.text")

local log = Logging.forModule("book_export")

local Exporter = {}

-- Why the last hydration attempt failed. Exposed rather than only logged: a
-- provider that silently never appears is very hard to diagnose from a device,
-- and the spec asserts on it.
local hydration_error

--- Why the exporter has not hydrated, or nil if it has or has not been tried.
-- @treturn string|nil
function Exporter.hydrationError()
    return hydration_error
end

--- Build the real exporter object on top of KOReader's BaseExporter.
-- @treturn table|nil nil when `base` is not resolvable yet.
local function buildExporter()
    local ok, BaseExporter = pcall(require, "base")
    if not ok or type(BaseExporter) ~= "table" then
        hydration_error = "require('base') failed: " .. tostring(BaseExporter)
        return nil
    end

    local Target = {}
    Target.__index = Target
    setmetatable(Target, { __index = BaseExporter })

    --- Can this export actually reach Karakeep?
    --
    -- KOReader greys the target out when this is false, and `toggleEnabled`
    -- refuses to tick it -- better than letting the user pick it and fail at
    -- the end of an export they waited for.
    --
    -- `export_local_books` is consulted as well as the connection, so the
    -- setting a user can put in `karabridge.conf` actually governs something.
    -- Until now it was a documented switch wired to nothing.
    function Target.isReadyToExport()
        if not Runtime.isReady() then
            return false
        end

        local settings = Runtime.settings()
        return settings == nil or settings:get("export_local_books") ~= false
    end

    --- Export a table of booknotes. KOReader's exporter contract.
    -- @tparam table book_notes
    -- @treturn boolean success
    function Target.export(_self, book_notes)
        local settings = Runtime.settings()
        local client = Runtime.client()

        if not settings or not client then
            log.err("export attempted before the plugin was initialised")
            Notification.alert("KaraBridge is not ready yet. Open its menu once and try again.")
            return false
        end

        log.info("exporting", #book_notes, "book(s) to Karakeep")

        local card = Card.new({
            assets = Assets.new(client),
            bookmarks = Bookmarks.new(client),
            highlights = Highlights.new(client),
            lists = Lists.new(client),
            settings = settings,
            recovery = Runtime.recovery(),
        })

        -- KOReader's exporter wants a boolean back, but the work now happens
        -- inside a coroutine that outlives this call. Reporting success for
        -- "the export was started" is the honest answer: anything that goes
        -- wrong afterwards is reported by the summary, in a dialog the user is
        -- already looking at.
        Progress.run({
            message = string.format(
                "Sending %d book%s to Karakeep%s",
                #book_notes,
                #book_notes == 1 and "" or "s",
                Text.ELLIPSIS
            ),
            work = function(step)
                return card:exportAll(book_notes, step)
            end,
            done = function(summary)
                Notification.alert(table.concat(Card.summarise(summary), "\n"))
            end,
        })

        return true
    end

    -- BaseExporter:new asserts on its argument and calls _init(), which reads
    -- G_reader_settings. Both can fail in a context where the plugin is loaded
    -- but KOReader is not fully up, so the reason is captured rather than
    -- allowed to propagate out of an __index metamethod.
    local built_ok, built = pcall(BaseExporter.new, Target, {
        name = "karabridge",
        extension = "md",
        -- Remote, so KOReader does not offer to write a file or to share the
        -- text: the destination is a Karakeep card.
        is_remote = true,
        version = "1.0.0",
    })

    if not built_ok or type(built) ~= "table" then
        hydration_error = "BaseExporter.new failed: " .. tostring(built)
        return nil
    end

    hydration_error = nil
    return built
end

--- The table handed to `Provider:register`.
--
-- Empty until something touches it, then it becomes the real exporter.
local registered = {}

setmetatable(registered, {
    __index = function(target, key)
        local built = buildExporter()
        if not built then
            -- Still too early. Returning nil rather than erroring means a
            -- premature access degrades to "this target has no such field"
            -- instead of taking the whole exporter menu down.
            return nil
        end

        -- Copy in place and drop the metatable, so this runs exactly once.
        for k, v in pairs(built) do
            rawset(target, k, v)
        end
        setmetatable(target, getmetatable(built))

        log.dbg("exporter hydrated")
        return target[key]
    end,
})

Exporter.target = registered

--- Register with KOReader's exporter provider.
--
-- Called at the top level of `main.lua`, deliberately. Safe to call more than
-- once: `Provider:register` overwrites by name.
--
-- @treturn boolean Whether the provider accepted the registration.
function Exporter.register()
    local ok, Provider = pcall(require, "provider")
    if not ok or type(Provider) ~= "table" then
        log.warn("frontend/provider is unavailable; book export will not appear")
        return false
    end

    local registered_ok = Provider:register("exporter", "karabridge", registered)
    if not registered_ok then
        log.warn("the exporter provider refused the registration")
    end

    return registered_ok
end

return Exporter
