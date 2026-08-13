--[[--
Where `karabridge.conf` is looked for, and in what order.

The search order is a usability decision, so it is written down rather than
inferred:

  1. `$KARABRIDGE_CONF`, if set. Development and integration testing only —
     it lets a spec point at a fixture without touching the user's data
     directory. Environment variables are not a thing on a Kobo, so this costs
     nothing on device.
  2. `<data dir>/karabridge.conf` — the primary location. On a Kobo the data
     directory *is* on the mounted storage partition (`.adds/koreader`), so
     this is the file a user reaches by plugging the device into a computer,
     which is the entire point of supporting a config file. It also survives
     replacing the plugin folder.
  3. `<settings dir>/karabridge.conf` — next to KOReader's own settings, for
     people who keep configuration together.
  4. `<plugin dir>/karabridge.conf` — the folder just copied onto the device,
     the obvious place to look. Last because a plugin update overwrites it.

First match wins; the rest are not read. Only one file is ever used, because
merging several would make "which value am I actually running with" impossible
to answer from the menu.

DataStorage is injected so the specs can run without KOReader.

@module karabridge.config.paths
]]

local Filesystem = require("karabridge.shared.filesystem")
local Paths = require("karabridge.shared.paths")

local ConfigPaths = {}

ConfigPaths.FILENAME = "karabridge.conf"
ConfigPaths.ENV_VAR = "KARABRIDGE_CONF"

local datastorage_backend

local function dataStorage()
    if datastorage_backend then
        return datastorage_backend
    end

    local ok, module = pcall(require, "datastorage")
    if ok and type(module) == "table" then
        datastorage_backend = module
    end

    return datastorage_backend
end

--- Replace the DataStorage backend. Used by the specs.
-- @tparam table|nil module DataStorage-compatible table, or nil to reset.
function ConfigPaths.setBackend(module)
    datastorage_backend = module
end

--- Read an environment variable, tolerating platforms without `os.getenv`.
local function env(name)
    if type(os.getenv) ~= "function" then
        return nil
    end
    local ok, value = pcall(os.getenv, name)
    if ok and type(value) == "string" and value ~= "" then
        return value
    end
    return nil
end

--- Every candidate location, in search order.
-- @tparam[opt] string plugin_dir The plugin's own directory (`self.path`).
-- @treturn table Array of absolute paths.
function ConfigPaths.candidates(plugin_dir)
    local candidates = {}

    local override = env(ConfigPaths.ENV_VAR)
    if override then
        table.insert(candidates, override)
    end

    local DataStorage = dataStorage()
    if DataStorage then
        if type(DataStorage.getDataDir) == "function" then
            table.insert(candidates, Paths.join(DataStorage:getDataDir(), ConfigPaths.FILENAME))
        end
        if type(DataStorage.getSettingsDir) == "function" then
            table.insert(candidates, Paths.join(DataStorage:getSettingsDir(), ConfigPaths.FILENAME))
        end
    end

    if plugin_dir and plugin_dir ~= "" then
        table.insert(candidates, Paths.join(plugin_dir, ConfigPaths.FILENAME))
    end

    return candidates
end

--- The first candidate that exists.
-- @tparam[opt] string plugin_dir
-- @treturn string|nil
function ConfigPaths.find(plugin_dir)
    for _, path in ipairs(ConfigPaths.candidates(plugin_dir)) do
        if Filesystem.fileExists(path) then
            return path
        end
    end
    return nil
end

--- Where "Create an example file" writes to.
--
-- Always the data directory, never wherever a file happens to have been found:
-- the point of the action is to produce a file the user can reach from a
-- computer, and the plugin folder is not reliably that.
--
-- @treturn string|nil
function ConfigPaths.templateTarget()
    local DataStorage = dataStorage()
    if not DataStorage or type(DataStorage.getDataDir) ~= "function" then
        return nil
    end
    return Paths.join(DataStorage:getDataDir(), ConfigPaths.FILENAME)
end

--- Where KaraBridge keeps its own data (queue, caches).
-- @treturn string|nil
function ConfigPaths.dataDir()
    local DataStorage = dataStorage()
    if not DataStorage then
        return nil
    end

    local base
    if type(DataStorage.getFullDataDir) == "function" then
        base = DataStorage:getFullDataDir()
    elseif type(DataStorage.getDataDir) == "function" then
        base = DataStorage:getDataDir()
    end

    if not base then
        return nil
    end
    return Paths.join(base, "karabridge")
end

--- Path of the LuaSettings file holding the persistent queue.
--
-- Beside the settings rather than in the data directory, so a user clearing
-- KaraBridge's caches cannot take the queue with it: the queue holds intent
-- that exists nowhere else.
--
-- @treturn string|nil
function ConfigPaths.queueFile()
    local DataStorage = dataStorage()
    if not DataStorage or type(DataStorage.getSettingsDir) ~= "function" then
        return nil
    end
    return Paths.join(DataStorage:getSettingsDir(), "karabridge_queue.lua")
end

--- Path of the LuaSettings file holding the recovery journal.
--
-- Beside the settings, and deliberately not in a book's sidecar: the journal
-- records mappings that could not be written to a sidecar in the first place.
--
-- @treturn string|nil
function ConfigPaths.recoveryFile()
    local DataStorage = dataStorage()
    if not DataStorage or type(DataStorage.getSettingsDir) ~= "function" then
        return nil
    end
    return Paths.join(DataStorage:getSettingsDir(), "karabridge_recovery.lua")
end

--- Path of the LuaSettings file holding the on-device settings.
-- @treturn string|nil
function ConfigPaths.settingsFile()
    local DataStorage = dataStorage()
    if not DataStorage or type(DataStorage.getSettingsDir) ~= "function" then
        return nil
    end
    return Paths.join(DataStorage:getSettingsDir(), "karabridge.lua")
end

return ConfigPaths
