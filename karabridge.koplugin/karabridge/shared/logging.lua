--[[--
Central logging, and the one place that knows how to hide a secret.

Every KaraBridge log line goes through here so that:

  * a single `grep -i karabridge` finds all of them, and each carries the
    module it came from,
  * an API token can never reach the log by accident. `mask()` is the only
    sanctioned way to put a credential-adjacent value in a message, and it
    never emits enough of it to be useful to someone reading the log.

KOReader's `logger` is required lazily and behind pcall so that this module,
and therefore every module that logs, stays loadable under a plain Lua
interpreter in `spec/`. Tests can also install their own sink with
`Logging.setBackend()`.

@module karabridge.shared.logging
]]

local Logging = {}

Logging.PREFIX = "KaraBridge"

local backend

--- Resolve the log backend, falling back to a silent one off-device.
local function getBackend()
    if backend then
        return backend
    end

    local ok, logger = pcall(require, "logger")
    if ok and type(logger) == "table" and type(logger.info) == "function" then
        backend = logger
    else
        local noop = function() end
        backend = { dbg = noop, info = noop, warn = noop, err = noop }
    end

    return backend
end

--- Replace the log backend. Used by the specs; also allows a future in-app log view.
-- @tparam table|nil sink Table with dbg/info/warn/err functions, or nil to reset.
function Logging.setBackend(sink)
    backend = sink
end

--- Render a secret as something safe to write down.
--
-- Only the last four characters survive, which is enough to tell two keys
-- apart when a user reports a problem but useless to anyone who reads the log.
-- A short value is replaced entirely rather than partly revealed.
--
-- @tparam any secret
-- @treturn string
function Logging.mask(secret)
    if secret == nil or secret == "" then
        return "(unset)"
    end
    if type(secret) ~= "string" then
        return "(set)"
    end
    if #secret <= 8 then
        return "(set, " .. #secret .. " chars)"
    end
    return string.rep("*", 6) .. secret:sub(-4)
end

--- Strip any userinfo from a URL before it is logged.
--
-- A server address is not itself a secret, but `https://user:pw@host` pasted
-- into the settings dialog would otherwise put a password in the log.
--
-- @tparam any url
-- @treturn string
function Logging.maskUrl(url)
    if type(url) ~= "string" or url == "" then
        return "(unset)"
    end
    return (url:gsub("^(%a[%w+.-]*://)[^/@]*@", "%1(userinfo)@"))
end

local function emit(level, module_name, parts)
    local rendered = {}
    for index = 1, parts.n do
        rendered[index] = tostring(parts[index])
    end

    local label = module_name and (Logging.PREFIX .. ":" .. module_name .. ":") or (Logging.PREFIX .. ":")
    getBackend()[level](label, table.concat(rendered, " "))
end

--- A logger scoped to one module.
--
--     local log = Logging.forModule("api.client")
--     log.dbg("GET", path)
--
-- @tparam string module_name Dotted module name, without the `karabridge.` prefix.
-- @treturn table Logger with dbg/info/warn/err.
function Logging.forModule(module_name)
    local scoped = {}
    for _, level in ipairs({ "dbg", "info", "warn", "err" }) do
        scoped[level] = function(...)
            -- Not table.pack(): it is a 5.2 addition and LuaJIT only offers it
            -- when built with the compat flags, which KOReader does not rely on.
            emit(level, module_name, { n = select("#", ...), ... })
        end
    end
    return scoped
end

return Logging
