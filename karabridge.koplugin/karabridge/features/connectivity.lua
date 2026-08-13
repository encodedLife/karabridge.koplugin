--[[--
Asking KOReader whether there is a network, without asking the user twice.

KaraBridge used `NetworkMgr:runWhenOnline`. That turns out to be the wrong
question, and the symptom was a device already on Wi-Fi being asked to connect
to Wi-Fi, over and over.

## Why "online" is not "connected"

`NetworkMgr:isOnline()` does not mean the interface is up. It means
(`manager.lua:588` and `:314`):

```lua
function NetworkMgr:isOnline()
    return self:canResolveHostnames()
end

function NetworkMgr:canResolveHostnames()
    return socket.dns.toip("dns.msftncsi.com") ~= nil
end
```

A DNS lookup of a Microsoft host. It fails on a perfectly working connection
whenever DNS is slow, the resolver is having a moment, or -- the common one on
the sort of network that also self-hosts Karakeep -- a Pi-hole or AdGuard has
that domain on a blocklist. Then KOReader concludes the device is offline while
the Wi-Fi is plainly connected.

## And then it silently drops the work

`runWhenOnline` is worse than a spurious prompt (`manager.lua:645`):

```lua
if self:isOnline() then
    callback()
elseif not self:isConnected() then
    self:beforeWifiAction(callback)
else
    self:beforeWifiAction()          -- the callback is not passed on
end
```

That last branch is exactly this case: connected, but the DNS probe failed. The
user is prompted, agrees, and **nothing happens**, because the callback was
never handed over.

`runWhenConnected` asks the question that was actually meant -- is there an
interface -- and guarantees the callback runs.

## What we give up, and why it does not matter

`isConnected` does not prove the internet is reachable. If it is not, the
request fails and returns a `Result` saying so, which every caller here already
reports properly. A clear "the Karakeep server could not be reached" beats a
prompt that discards the action.

@module karabridge.features.connectivity
]]

local Logging = require("karabridge.shared.logging")

local log = Logging.forModule("connectivity")

local Connectivity = {}

-- Replaced by the specs, which have no KOReader.
local manager_backend

--- Replace the network manager. Used by the specs.
-- @tparam table|nil backend
function Connectivity.setBackend(backend)
    manager_backend = backend
end

--- KOReader's network manager, or nil when there is none.
-- @treturn table|nil
function Connectivity.manager()
    if manager_backend then
        return manager_backend
    end

    local ok, NetworkMgr = pcall(require, "ui/network/manager")
    if not ok or type(NetworkMgr) ~= "table" then
        return nil
    end
    return NetworkMgr
end

--- Is there a usable network connection?
--
-- `isConnected` where it exists, because `isOnline` is a DNS probe that says
-- "offline" on plenty of working connections.
--
-- @treturn boolean
function Connectivity.isConnected()
    local manager = Connectivity.manager()
    if not manager then
        return false
    end

    if type(manager.isConnected) == "function" then
        return manager:isConnected() == true
    end
    -- A KOReader old enough to lack it. Better a stricter check than none.
    if type(manager.isOnline) == "function" then
        return manager:isOnline() == true
    end

    return false
end

--- Run something once there is a connection, asking the user only if needed.
--
-- @tparam function callback
-- @treturn boolean Whether anything could be arranged at all.
function Connectivity.whenConnected(callback)
    local manager = Connectivity.manager()
    if not manager then
        log.warn("no network manager; running anyway and letting the request fail if it must")
        callback()
        return true
    end

    if type(manager.runWhenConnected) == "function" then
        manager:runWhenConnected(callback)
        return true
    end

    -- Older KOReader. `runWhenOnline` is what this module exists to avoid, but
    -- it is better than not running at all.
    if type(manager.runWhenOnline) == "function" then
        log.dbg("this KOReader has no runWhenConnected; falling back")
        manager:runWhenOnline(callback)
        return true
    end

    callback()
    return true
end

return Connectivity
