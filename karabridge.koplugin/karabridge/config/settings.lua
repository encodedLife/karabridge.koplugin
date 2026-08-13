--[[--
The one way to read or write a KaraBridge setting.

## Precedence, stated exactly

Three sources, in increasing authority:

  1. **Schema defaults** (`karabridge.config.defaults`) — used when nothing
     else has an opinion.
  2. **`karabridge.conf`** — *seeds* settings. On startup, every key present in
     the file that is not already set on the device is written to the device
     store. A key already set on the device is left alone and counted as
     "kept". The file is not consulted again.
  3. **The device store** (`settings/karabridge.lua`) — whatever the menu has
     saved. This wins.

The one exception is the explicit **"Reload it now"** action, which applies
every value in the file over the device store. That is an override, and it is
the only override, because the user asked for it by name.

The alternative — treating the file as authoritative on every start — was
rejected: a setting changed in the menu would silently revert at the next
restart, with the menu still showing the value the user chose until then. That
arrived at the same conclusion -- seed rather than override -- and
the reasoning holds here.

## Testability

The backing store is injected. Anything with `readSetting`, `saveSetting`,
`has`, `delSetting` and `flush` will do, which is KOReader's LuaSettings and
also a twenty-line table in `spec/mocks/luasettings.lua`.

@module karabridge.config.settings
]]

local ConfigFile = require("karabridge.config.config_file")
local ConfigPaths = require("karabridge.config.paths")
local Defaults = require("karabridge.config.defaults")
local Filesystem = require("karabridge.shared.filesystem")
local Logging = require("karabridge.shared.logging")
local Url = require("karabridge.shared.url")
local Validation = require("karabridge.config.validation")

local log = Logging.forModule("config.settings")

local Settings = {}
Settings.__index = Settings

--- Create a settings facade over a store.
-- @tparam table opts
--   store       required; LuaSettings-compatible
--   plugin_dir  optional; used when searching for a config file
-- @treturn Settings
function Settings.new(opts)
    assert(type(opts) == "table" and type(opts.store) == "table", "Settings.new requires a store")

    return setmetatable({
        store = opts.store,
        plugin_dir = opts.plugin_dir,
        config_path = nil,
        config_problems = {},
        -- Per-session record of where each effective value came from, so the
        -- menu can say "from the settings file" instead of leaving the user to
        -- guess why a value they never typed is there.
        origin = {},
    }, Settings)
end

--- The effective value of a setting.
-- @tparam string key
-- @return any
function Settings:get(key)
    if self.store:has(key) then
        return self.store:readSetting(key)
    end
    return Defaults.get(key)
end

--- Has this key been set explicitly, rather than falling back to a default?
-- @tparam string key
-- @treturn boolean
function Settings:has(key)
    return self.store:has(key) == true
end

--- Set a value, after validating it.
--
-- Rejects rather than coerces: a value that fails validation is a mistake
-- somewhere upstream, and writing a corrected version of it would hide that.
--
-- @tparam string key
-- @param value any
-- @treturn boolean ok
-- @treturn string|nil Problem description.
function Settings:set(key, value)
    -- The server address is the one value normalised on the way in, because
    -- the same address typed three ways must produce one cache key, one log
    -- line and one set of request URLs.
    if key == "server_url" and type(value) == "string" then
        value = Url.normaliseServerUrl(value)
    end

    local ok, problem = Validation.checkValue(key, value)
    if not ok then
        log.warn("refusing", key, "-", problem)
        return false, problem
    end

    self.store:saveSetting(key, value)
    self.origin[key] = "device"
    return true
end

--- Set a value without validating. For internal bookkeeping keys only.
-- @tparam string key
-- @param value any
function Settings:setInternal(key, value)
    assert(Defaults.INTERNAL_KEYS[key], "setInternal is only for internal keys")
    self.store:saveSetting(key, value)
end

--- Read an internal bookkeeping key.
-- @tparam string key
-- @return any
function Settings:getInternal(key)
    return self.store:readSetting(key)
end

--- Every effective setting value.
-- @treturn table
function Settings:all()
    local values = {}
    for _, key in ipairs(Defaults.keys()) do
        values[key] = self:get(key)
    end
    return values
end

--- Where the effective value of a key came from.
-- @tparam string key
-- @treturn string "file", "device" or "default"
function Settings:originOf(key)
    if self.origin[key] then
        return self.origin[key]
    end
    if self:has(key) then
        return "device"
    end
    return "default"
end

function Settings:flush()
    self.store:flush()
end

--- Which capabilities the current configuration supports.
-- @treturn table See `karabridge.config.validation`.checkReadiness.
function Settings:readiness()
    return Validation.checkReadiness(self:all())
end

--- Read and parse the config file, if there is one.
-- @treturn string|nil path
-- @treturn table values
-- @treturn table problems
function Settings:readConfigFile()
    local path = ConfigPaths.find(self.plugin_dir)
    if not path then
        return nil, {}, {}
    end

    local read = Filesystem.readFile(path)
    if read:isErr() then
        return path, {}, { "the file could not be read" }
    end

    local values, problems = ConfigFile.parse(read.value)

    -- Parsing only checks shape; a syntactically fine `articles_per_sync = 0`
    -- still has to be caught, and caught here rather than at the point of use.
    for _, problem in ipairs(Validation.check(values)) do
        table.insert(problems, problem)
    end
    for key in pairs(values) do
        local ok = Validation.checkValue(key, values[key])
        if not ok then
            values[key] = nil
        end
    end

    return path, values, problems
end

--- Seed unset settings from the config file. Called once, at startup.
--
-- Must run before anything reads a setting with a default: KOReader's
-- LuaSettings writes a default back into the store when it is read that way,
-- after which `has()` is true for everything and there is no gap left to seed.
--
-- @treturn table { path, problems, seeded, kept }
function Settings:seedFromConfigFile()
    local path, values, problems = self:readConfigFile()

    self.config_path = path
    self.config_problems = problems

    if not path then
        return { path = nil, problems = problems, seeded = 0, kept = 0 }
    end

    local seeded, kept = 0, 0
    for key, value in pairs(values) do
        if self.store:has(key) then
            kept = kept + 1 -- already set on the device, which wins
        else
            self.store:saveSetting(key, value)
            self.origin[key] = "file"
            seeded = seeded + 1
        end
    end

    if seeded > 0 then
        self.store:flush()
    end

    log.info(
        string.format("seeded %d setting(s) from %s; %d already set on the device and left alone", seeded, path, kept)
    )
    for _, problem in ipairs(problems) do
        log.warn(path .. ": " .. problem)
    end

    return { path = path, problems = problems, seeded = seeded, kept = kept }
end

--- Apply every value in the config file over the current settings.
--
-- Only ever reached from "Reload it now", where overriding is exactly what was
-- asked for.
--
-- @treturn table { path, problems, applied }
function Settings:reloadConfigFile()
    local path, values, problems = self:readConfigFile()

    self.config_path = path
    self.config_problems = problems

    if not path then
        return { path = nil, problems = problems, applied = 0 }
    end

    local applied = 0
    for key, value in pairs(values) do
        if self:set(key, value) then
            self.origin[key] = "file"
            applied = applied + 1
        end
    end

    self.store:flush()

    log.info("reloaded", applied, "setting(s) from", path)
    for _, problem in ipairs(problems) do
        log.warn(path .. ": " .. problem)
    end

    return { path = path, problems = problems, applied = applied }
end

--- Write the example config file, refusing to clobber an existing one.
-- @treturn table { ok, path, reason }
function Settings:writeConfigTemplate()
    local path = ConfigPaths.templateTarget()
    if not path then
        return { ok = false, reason = "no_data_dir" }
    end
    if Filesystem.fileExists(path) then
        return { ok = false, path = path, reason = "exists" }
    end

    local written = Filesystem.writeFile(path, ConfigFile.template())
    if written:isErr() then
        return { ok = false, path = path, reason = "write_failed" }
    end

    -- The file that did not exist a moment ago is now the one the search order
    -- would find, so the menu should say "Settings file: found" straight away
    -- rather than only after the next restart.
    if not self.config_path then
        self.config_path = path
    end

    return { ok = true, path = path }
end

--- A masked, human-readable dump of the whole configuration.
--
-- Safe to paste into a bug report: every value the schema marks secret is
-- replaced by `Logging.mask`, and the server address has any userinfo removed.
--
-- @treturn table Array of "key = value" lines.
function Settings:describe()
    local lines = {}

    for _, key in ipairs(Defaults.keys()) do
        local value = self:get(key)
        local shown

        if Defaults.isSecret(key) then
            shown = Logging.mask(value)
        elseif key == "server_url" then
            shown = Logging.maskUrl(value)
        elseif value == nil then
            shown = "(unset)"
        else
            shown = tostring(value)
        end

        table.insert(lines, string.format("%s = %s  [%s]", key, shown, self:originOf(key)))
    end

    return lines
end

return Settings
