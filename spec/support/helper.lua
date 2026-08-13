--[[--
Shared spec setup.

Two jobs:

  1. Put the *installable* plugin directory on `package.path`, exactly the way
     KOReader's PluginLoader does (`plugin_root/?.lua`). The specs therefore
     require modules by the same names the plugin uses at runtime, and a
     require that would fail on device fails here too.
  2. Wire the mocks into the injection points the plugin modules expose, and
     put them back afterwards.

Nothing here reaches into a module's internals. Every seam used below is a
public `setBackend`-style function that exists because the module was designed
to be testable, not because a test needed a way in.

@module spec.support.helper
]]

local Helper = {}

--- Work out the repository root from this file's own location.
--
-- Independent of the current working directory, so `test-unit.sh` can be run
-- from anywhere and so the KOReader-hosted suite can require these specs from
-- a symlink.
local function repositoryRoot()
    local source = debug.getinfo(1, "S").source:sub(2)
    -- .../spec/support/helper.lua -> ...
    return source:gsub("/spec/support/helper%.lua$", "")
end

Helper.root = repositoryRoot()
Helper.plugin_dir = Helper.root .. "/karabridge.koplugin"

-- Exactly `plugin_root/?.lua`, and deliberately *not* `?/init.lua`. KOReader's
-- PluginLoader adds only the first form (frontend/pluginloader.lua:_load), so a
-- module written as `features/x/init.lua` resolves in a spec and then fails to
-- load on device. Matching the real search path is what makes a passing spec
-- mean something. Found the hard way: the emulator rejected a plugin whose
-- specs were green.
package.path = table.concat({
    Helper.plugin_dir .. "/?.lua",
    Helper.root .. "/?.lua",
    package.path,
}, ";")

Helper.mocks = {
    datastorage = require("spec.mocks.datastorage"),
    docsettings = require("spec.mocks.docsettings"),
    filesystem = require("spec.mocks.filesystem"),
    json = require("spec.mocks.json"),
    logger = require("spec.mocks.logger"),
    luasettings = require("spec.mocks.luasettings"),
}

--- Install every mock and clear its state.
--
-- Call from `before_each`. Modules are required here rather than at the top of
-- the file so that a spec which only needs one of them does not drag the rest
-- in.
function Helper.install()
    Helper.mocks.docsettings.reset()
    Helper.mocks.filesystem.reset()
    Helper.mocks.logger.reset()

    require("karabridge.config.paths").setBackend(Helper.mocks.datastorage)
    require("karabridge.shared.filesystem").setBackend(Helper.mocks.filesystem)
    require("karabridge.shared.json").setCodec(Helper.mocks.json)
    require("karabridge.shared.logging").setBackend(Helper.mocks.logger)
    require("karabridge.shared.metadata").setBackend(Helper.mocks.docsettings)
end

--- Put the real backends back.
--
-- Call from `after_each`, so that one spec leaving a mock installed cannot
-- make an unrelated spec pass for the wrong reason.
function Helper.uninstall()
    require("karabridge.config.paths").setBackend(nil)
    require("karabridge.shared.filesystem").setBackend(nil)
    require("karabridge.shared.json").setCodec(nil)
    require("karabridge.shared.logging").setBackend(nil)
    require("karabridge.shared.metadata").setBackend(nil)
end

--- A settings facade over an in-memory store.
-- @tparam[opt] table initial Values already "on disk".
-- @tparam[opt] string plugin_dir
-- @treturn table, table The Settings instance and the underlying store.
function Helper.settings(initial, plugin_dir)
    local Settings = require("karabridge.config.settings")
    local store = Helper.mocks.luasettings.new(initial)
    return Settings.new({ store = store, plugin_dir = plugin_dir }), store
end

--- A recording HTTP backend for `karabridge.api.client`.
--
-- Responses are supplied as a list, consumed in order. Every request is
-- recorded, so a spec can assert on the URL, the method and the body that were
-- actually built.
--
-- @tparam table responses Array of `{ code = 200, body = "…" }`, or
--   `{ transport_error = "timeout" }` to simulate no response at all.
-- @treturn table `{ fn, requests, remaining }`
function Helper.httpStub(responses)
    local stub = {
        requests = {},
        responses = responses or {},
        index = 0,
    }

    stub.fn = function(request, filepath)
        table.insert(stub.requests, { request = request, filepath = filepath })

        stub.index = stub.index + 1
        local response = stub.responses[stub.index]

        if not response then
            return nil, nil, "no stubbed response"
        end
        if response.transport_error then
            return nil, nil, response.transport_error
        end
        -- The fourth value is the response headers, which only the redirect
        -- path reads -- a Location is the whole point of a 302.
        return response.code, response.body, nil, response.headers
    end

    return stub
end

--- A client wired to a stubbed transport.
-- @tparam table responses See `httpStub`.
-- @tparam[opt] table opts Extra options for `Client.new`.
-- @treturn table, table The Client and the stub.
function Helper.client(responses, opts)
    local Client = require("karabridge.api.client")
    local stub = Helper.httpStub(responses)

    local config = {
        server_url = "https://karakeep.example.org",
        api_token = "ak1_secret_token_value",
        request = stub.fn,
        -- No real sleeping in a unit test; retries would otherwise add
        -- three seconds to the suite for every retry case.
        sleep = function() end,
    }
    for key, value in pairs(opts or {}) do
        config[key] = value
    end

    return Client.new(config), stub
end

--- The token `Helper.client` authenticates with, for leak assertions.
Helper.TOKEN = "ak1_secret_token_value"

return Helper
