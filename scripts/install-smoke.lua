--[[--
Install the built zip into a throwaway directory, before it is published.

This exists because 0.0.2 shipped an installer that crashed on the very
configuration it was written to preserve. The unit specs could not see it --
their filesystem mock stands in for `lfs`, not for `io` -- and nothing else
exercised the path, because reaching it required a release that did not yet
exist. So the release script now reaches it, against the zip in hand.

    scripts/install-smoke.lua <zip> <koreader dir>

Exits non-zero, loudly, on anything that would have gone wrong on a device.
]]

-- Bootstrapping KOReader outside reader.lua means setting the globals it would
-- have set itself.
-- luacheck: globals G_defaults G_reader_settings

local zip = assert(arg[1], "usage: install-smoke.lua <zip> <koreader dir>")
local ko = assert(arg[2], "usage: install-smoke.lua <zip> <koreader dir>")

local repo = arg[3] or "."

package.path = table.concat({
    repo .. "/karabridge.koplugin/?.lua",
    ko .. "/?.lua",
    ko .. "/frontend/?.lua",
    ko .. "/common/?.lua",
    package.path,
}, ";")
package.cpath = table.concat({ ko .. "/common/?.so", ko .. "/libs/?.so", ko .. "/?.so", package.cpath }, ";")

-- Exit 2 means "this KOReader tree cannot start", which is a different thing
-- from "the archive is bad" and must not be mistaken for it. Some builds have a
-- luajit but not a working frontend, and the caller tries the next one.
local booted = pcall(function()
    require("ffi/loadlib")
    G_defaults = require("luadefaults"):open()
    local DataStorage = require("datastorage")
    G_reader_settings = require("luasettings"):open(DataStorage:getDataDir() .. "/settings.reader.lua")
    require("document/canvascontext"):init(require("device"))
end)

if not booted then
    os.exit(2)
end

-- Also exit 2: a KOReader without libarchive cannot install an update at all,
-- so it cannot be used to prove that one installs.
--
-- This deliberately does NOT require Device:unpackArchive. Requiring it is what
-- let the bug through: every KOReader lacking that recent function was skipped
-- here, which is precisely the population the installer then failed on.
local capable = pcall(function()
    local Archiver = require("ffi/archiver")
    assert(type(Archiver.Reader) == "table", "no Archiver.Reader")
end)

if not capable then
    io.stderr:write("this KOReader cannot unpack archives\n")
    os.exit(2)
end

local Install = require("karabridge.features.update.install")

local root = os.tmpname()
os.remove(root)
local live = root .. "/plugins/karabridge.koplugin"
assert(os.execute("mkdir -p " .. live) == 0 or os.execute("mkdir -p " .. live) == true)

local function write(path, content)
    local handle = assert(io.open(path, "w"))
    handle:write(content)
    handle:close()
end

local function read(path)
    local handle = io.open(path, "r")
    if not handle then
        return nil
    end
    local content = handle:read("*a")
    handle:close()
    return content
end

-- A previous installation, with a configuration inside it: the case 0.0.2
-- crashed on, and the only one where anything can be lost.
write(live .. "/_meta.lua", 'return { version = "0.0.0" }')
write(live .. "/main.lua", "-- the previous copy")
write(live .. "/karabridge.conf", "server_url = https://example.org\napi_token = must-survive\n")

local steps = {}
local installed = Install.fromArchive({
    zip = zip,
    plugin_dir = live,
    progress = function(message)
        table.insert(steps, message)
        return true
    end,
})

local failures = {}
local function check(ok, what)
    print(string.format("  %s %s", ok and "ok  " or "FAIL", what))
    if not ok then
        table.insert(failures, what)
    end
end

print("install smoke test")
check(installed:isOk(), "the archive installs: " .. (installed:isOk() and "yes" or installed:describe()))

if installed:isOk() then
    local meta = read(live .. "/_meta.lua") or ""
    check(meta:match('version%s*=%s*"([^"]+)"') ~= nil, "the installed copy has a version")
    check(meta:match('"0%.0%.0"') == nil, "the previous copy was actually replaced")
    check(read(live .. "/main.lua") ~= "-- the previous copy", "main.lua was replaced")
    check(read(live .. "/karabridge.conf") == "server_url = https://example.org\napi_token = must-survive\n",
        "karabridge.conf survived intact")
    check(#steps >= 3, "progress was reported (" .. #steps .. " steps)")

    local leftovers = io.popen("ls -d " .. root .. "/plugins/*.new " .. root .. "/plugins/*.old 2>/dev/null | wc -l")
    check(tonumber(leftovers:read("*a")) == 0, "no .new or .old left behind")
    leftovers:close()
end

os.execute("rm -rf " .. root)

if #failures > 0 then
    print("\n" .. #failures .. " check(s) failed; not fit to publish")
    os.exit(1)
end
print("  all good")
