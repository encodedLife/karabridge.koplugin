--[[--
Version comparison, GitHub, and replacing the running plugin.

The installer is the only thing in KaraBridge that overwrites itself, so most
of what is asserted here is about the paths where it must *not* do that: a
truncated download, an archive that is not the plugin, a rename that fails
half-way.
]]

local Helper = require("spec.support.helper")

local Check = require("karabridge.features.update.check")
local Github = require("karabridge.api.github")
local Install = require("karabridge.features.update.install")
local Version = require("karabridge.shared.version")

describe("Version", function()
    describe("parse", function()
        it("reads the shapes that actually occur", function()
            assert.same({ major = 0, minor = 7, patch = 1 }, Version.parse("0.7.1"))
            assert.same({ major = 0, minor = 7, patch = 1 }, Version.parse("v0.7.1"))
            assert.same({ major = 1, minor = 0, patch = 0 }, Version.parse("1"))
            assert.same({ major = 1, minor = 2, patch = 0 }, Version.parse("1.2"))
        end)

        it("keeps a pre-release marker", function()
            assert.equals("beta.3", Version.parse("2.0.0-beta.3").prerelease)
        end)

        it("returns nothing for what is not a version", function()
            assert.is_nil(Version.parse("latest"))
            assert.is_nil(Version.parse(""))
            assert.is_nil(Version.parse(nil))
            assert.is_nil(Version.parse({}))
        end)
    end)

    describe("compare", function()
        it("orders by major, then minor, then patch", function()
            assert.equals(1, Version.compare("1.0.0", "0.9.9"))
            assert.equals(1, Version.compare("0.2.0", "0.1.9"))
            assert.equals(1, Version.compare("0.0.2", "0.0.1"))
            assert.equals(-1, Version.compare("0.0.1", "0.0.2"))
            assert.equals(0, Version.compare("v1.2.3", "1.2.3"))
        end)

        it("puts a release above its own pre-release", function()
            assert.equals(1, Version.compare("1.0.0", "1.0.0-beta"))
            assert.equals(-1, Version.compare("1.0.0-beta", "1.0.0"))
        end)

        it("says nothing rather than guessing", function()
            assert.is_nil(Version.compare("latest", "1.0.0"))
            assert.is_nil(Version.compare("1.0.0", nil))
        end)
    end)

    describe("isNewer", function()
        it("is false for equal, older and unreadable", function()
            -- Unreadable matters most: offering to install something we could
            -- not identify is not a reasonable thing to ask of anyone.
            assert.is_true(Version.isNewer("0.0.2", "0.0.1"))
            assert.is_false(Version.isNewer("0.0.1", "0.0.1"))
            assert.is_false(Version.isNewer("0.0.1", "0.0.2"))
            assert.is_false(Version.isNewer("nightly", "0.0.1"))
        end)
    end)
end)

describe("Github", function()
    before_each(function()
        Helper.install()
    end)

    after_each(function()
        Helper.uninstall()
    end)

    local RELEASE = [[{
        "tag_name": "v0.0.2",
        "name": "KaraBridge 0.0.2",
        "html_url": "https://github.com/o/r/releases/tag/v0.0.2",
        "assets": [
            { "id": 11, "name": "notes.txt", "size": 3, "browser_download_url": "https://x/notes.txt" },
            { "id": 22, "name": "karabridge-0.0.2.zip", "size": 4096,
              "browser_download_url": "https://x/karabridge-0.0.2.zip" }
        ]
    }]]

    describe("parseRepo", function()
        it("accepts owner/name and nothing else", function()
            local owner, name = Github.parseRepo("some-owner/karabridge.koplugin")
            assert.equals("some-owner", owner)
            assert.equals("karabridge.koplugin", name)

            assert.is_nil(Github.parseRepo("just-a-name"))
            assert.is_nil(Github.parseRepo("https://github.com/o/r"))
            assert.is_nil(Github.parseRepo(""))
        end)
    end)

    it("picks the zip out of a release, ignoring other assets", function()
        local stub = Helper.httpStub({ { code = 200, body = RELEASE } })
        local api = Github.new({ repo = "o/r", request = stub.fn })

        local release = api:latestRelease()

        assert.equals("v0.0.2", release.value.tag)
        assert.equals("karabridge-0.0.2.zip", release.value.asset.name)
        assert.equals(22, release.value.asset.id)
    end)

    it("says so when a release has no zip", function()
        local stub = Helper.httpStub({ { code = 200, body = '{"tag_name":"v0.0.2","assets":[]}' } })
        local release = Github.new({ repo = "o/r", request = stub.fn }):latestRelease()

        assert.is_true(release:isOk())
        assert.is_nil(release.value.asset)
    end)

    it("turns a 404 into a sentence about privacy, not a status code", function()
        local stub = Helper.httpStub({ { code = 404, body = '{"message":"Not Found"}' } })
        local release = Github.new({ repo = "o/r", request = stub.fn }):latestRelease()

        assert.equals("not_found", release:errorCode())
        assert.matches("private", release.message)
    end)

    it("sends no Authorization header without a token", function()
        local stub = Helper.httpStub({ { code = 200, body = RELEASE } })
        Github.new({ repo = "o/r", request = stub.fn }):latestRelease()

        assert.is_nil(stub.requests[1].request.headers["Authorization"])
    end)

    it("sends one with a token", function()
        local stub = Helper.httpStub({ { code = 200, body = RELEASE } })
        Github.new({ repo = "o/r", token = "not-a-real-token", request = stub.fn }):latestRelease()

        assert.matches("Bearer", stub.requests[1].request.headers["Authorization"])
    end)

    it("never lets the token reach the log", function()
        -- The same guarantee the Karakeep key has, and for the same reason: a
        -- rule at each call site is a rule someone will forget.
        local logged = {}
        require("karabridge.shared.logging").setBackend({
            info = function(...)
                table.insert(logged, table.concat({ ... }, " "))
            end,
            warn = function(...)
                table.insert(logged, table.concat({ ... }, " "))
            end,
            err = function(...)
                table.insert(logged, table.concat({ ... }, " "))
            end,
            dbg = function(...)
                table.insert(logged, table.concat({ ... }, " "))
            end,
        })

        local stub = Helper.httpStub({ { code = 404, body = "{}" } })
        Github.new({ repo = "o/r", token = "not-a-real-token-9f2b", request = stub.fn }):latestRelease()

        require("karabridge.shared.logging").setBackend(nil)

        local all = table.concat(logged, "\n")
        assert.is_nil(all:find("not-a-real-token-9f2b", 1, true))
        assert.is_nil(all:find("Bearer", 1, true))
    end)

    describe("downloading the asset", function()
        it("fetches the public URL directly when there is no token", function()
            local stub = Helper.httpStub({ { code = 200, body = "" } })
            local api = Github.new({ repo = "o/r", request = stub.fn })

            api:downloadAsset({ id = 22, url = "https://x/karabridge.zip" }, "/tmp/out.zip")

            assert.equals("https://x/karabridge.zip", stub.requests[1].request.url)
        end)

        it("follows the redirect itself, and drops the token on the way", function()
            -- The signed storage URL rejects a request that carries an
            -- Authorization header, and LuaSocket would re-send it.
            local stub = Helper.httpStub({
                { code = 302, headers = { location = "https://storage.example/signed?sig=abc" } },
                { code = 200, body = "" },
            })
            local api = Github.new({ repo = "o/r", token = "not-a-real-token", request = stub.fn })

            local got = api:downloadAsset({ id = 22, url = "https://x/k.zip" }, "/tmp/out.zip")

            assert.is_true(got:isOk())
            assert.equals(2, #stub.requests)
            assert.matches("/releases/assets/22", stub.requests[1].request.url)
            assert.matches("Bearer", stub.requests[1].request.headers["Authorization"])

            assert.equals("https://storage.example/signed?sig=abc", stub.requests[2].request.url)
            assert.is_nil(stub.requests[2].request.headers["Authorization"])
        end)
    end)
end)

describe("update.Check", function()
    before_each(function()
        Helper.install()
    end)

    after_each(function()
        Helper.uninstall()
    end)

    local function run(current, responses, values)
        local stub = Helper.httpStub(responses)
        return Check.run({
            settings = Helper.settings(values or { update_repo = "o/r" }),
            current = current,
            request = stub.fn,
        })
    end

    it("reports a newer release", function()
        local result = run("0.0.1", { { code = 200, body = '{"tag_name":"v0.0.2","assets":[]}' } })

        assert.is_true(result.value.available)
        assert.equals("v0.0.2", result.value.latest)
    end)

    it("reports no update when the running version is the newest", function()
        local result = run("0.0.2", { { code = 200, body = '{"tag_name":"v0.0.2","assets":[]}' } })
        assert.is_false(result.value.available)
    end)

    it("never offers a downgrade", function()
        local result = run("0.1.0", { { code = 200, body = '{"tag_name":"v0.0.9","assets":[]}' } })
        assert.is_false(result.value.available)
    end)

    it("refuses a tag that is not a version", function()
        local result = run("0.0.1", { { code = 200, body = '{"tag_name":"nightly","assets":[]}' } })
        assert.equals("bad_tag", result:errorCode())
    end)

    it("asks for nothing when no repository is set", function()
        local stub = Helper.httpStub({})
        local result = Check.run({
            settings = Helper.settings({ update_repo = "" }),
            current = "0.0.1",
            request = stub.fn,
        })

        assert.equals("not_configured", result:errorCode())
        assert.equals(0, #stub.requests)
    end)

    it("explains a repository that is not owner/name", function()
        local result = run("0.0.1", {}, { update_repo = "nonsense" })
        assert.equals("bad_repo", result:errorCode())
    end)
end)

describe("update.Install", function()
    describe("looksRight", function()
        it("accepts an archive with the plugin's own files", function()
            assert.is_true(Install.looksRight({
                "karabridge.koplugin/_meta.lua",
                "karabridge.koplugin/main.lua",
                "karabridge.koplugin/karabridge/runtime.lua",
            }))
        end)

        it("accepts one without a root directory", function()
            assert.is_true(Install.looksRight({ "_meta.lua", "main.lua" }))
        end)

        it("names what is missing", function()
            local ok, missing = Install.looksRight({ "karabridge.koplugin/main.lua" })
            assert.is_false(ok)
            assert.equals("_meta.lua", missing)
        end)

        it("rejects an archive with a path that climbs out", function()
            local ok, why = Install.looksRight({
                "karabridge.koplugin/_meta.lua",
                "karabridge.koplugin/main.lua",
                "../../../.ssh/authorized_keys",
            })

            assert.is_false(ok)
            assert.matches("outside the plugin folder", why)
        end)

        it("rejects an archive with two top-level directories", function()
            -- Only one is stripped on the way out, so the other would land a
            -- level too high.
            local ok, why = Install.looksRight({
                "karabridge.koplugin/_meta.lua",
                "karabridge.koplugin/main.lua",
                "somethingelse/main.lua",
            })

            assert.is_false(ok)
            assert.matches("more than one top%-level", why)
        end)

        it("rejects an empty archive", function()
            assert.is_false(Install.looksRight({}))
            assert.is_false(Install.looksRight(nil))
        end)
    end)

    describe("isSafeEntry", function()
        -- An archive says where its contents go, and that is a decision made by
        -- whoever built it. `destination .. "/" .. entry.path` walks out of the
        -- destination given `../../`, and an absolute path ignores it entirely.
        it("accepts an ordinary entry", function()
            assert.is_true(Install.isSafeEntry("karabridge.koplugin/main.lua"))
            assert.is_true(Install.isSafeEntry("main.lua"))
        end)

        it("refuses a path that climbs out", function()
            assert.is_false(Install.isSafeEntry("../evil.lua"))
            assert.is_false(Install.isSafeEntry("karabridge.koplugin/../../evil.lua"))
            assert.is_false(Install.isSafeEntry("a/b/../../../c"))
        end)

        it("refuses an absolute path", function()
            assert.is_false(Install.isSafeEntry("/etc/passwd"))
            assert.is_false(Install.isSafeEntry("C:/windows/system32"))
        end)

        it("refuses a backslash, which means two different things", function()
            assert.is_false(Install.isSafeEntry("a\\..\\b"))
        end)

        it("is not fooled by a file merely containing dots", function()
            assert.is_true(Install.isSafeEntry("karabridge.koplugin/a..b.lua"))
            assert.is_true(Install.isSafeEntry("karabridge.koplugin/..hidden"))
        end)

        it("refuses nothing at all", function()
            assert.is_false(Install.isSafeEntry(""))
            assert.is_false(Install.isSafeEntry(nil))
        end)
    end)

    describe("paths", function()
        it("keeps every working copy beside the live one", function()
            -- os.rename does not cross filesystems, and on a Kobo the cache and
            -- the plugins need not share one.
            local paths = Install.paths("/mnt/onboard/.adds/koreader/plugins/karabridge.koplugin")

            assert.equals("/mnt/onboard/.adds/koreader/plugins/karabridge.koplugin", paths.live)
            assert.equals("/mnt/onboard/.adds/koreader/plugins/karabridge.koplugin.new", paths.staging)
            assert.equals("/mnt/onboard/.adds/koreader/plugins/karabridge.koplugin.old", paths.previous)
            assert.matches("^/mnt/onboard/.adds/koreader/plugins/", paths.download)
        end)

        it("tolerates a trailing slash", function()
            assert.equals("/p/karabridge.koplugin", Install.paths("/p/karabridge.koplugin/").live)
        end)

        it("names nothing that KOReader would try to load", function()
            -- The plugin loader takes directories ending in .koplugin, and
            -- neither of these does.
            local paths = Install.paths("/p/karabridge.koplugin")
            assert.is_nil(paths.staging:match("%.koplugin$"))
            assert.is_nil(paths.previous:match("%.koplugin$"))
        end)
    end)

    describe("run", function()
        before_each(function()
            Helper.install()
        end)

        after_each(function()
            Install.setArchiver(nil)
            Helper.uninstall()
        end)

        it("refuses a release with no zip, before downloading anything", function()
            local stub = Helper.httpStub({})

            local result = Install.run({
                settings = Helper.settings({ update_repo = "o/r" }),
                plugin_dir = "/p/karabridge.koplugin",
                release = { tag = "v0.0.2" },
                request = stub.fn,
            })

            assert.equals("no_asset", result:errorCode())
            assert.equals(0, #stub.requests)
        end)

        it("stops when the download is not a KaraBridge plugin", function()
            -- The working copy must still be there afterwards, which is why
            -- this check happens before anything is renamed.
            Install.setArchiver({
                entries = function()
                    return { "some-other-plugin/main.lua" }
                end,
                unpack = function()
                    error("must not be reached")
                end,
            })

            local stub = Helper.httpStub({ { code = 200, body = "" } })

            local result = Install.run({
                settings = Helper.settings({ update_repo = "o/r" }),
                plugin_dir = "/p/karabridge.koplugin",
                release = { tag = "v0.0.2", asset = { id = 22, url = "https://x/k.zip" } },
                request = stub.fn,
            })

            assert.equals("bad_archive", result:errorCode())
            assert.matches("_meta.lua", result.message)
        end)

        it("stops when the archive cannot be read at all", function()
            Install.setArchiver({
                entries = function()
                    return nil, "truncated"
                end,
                unpack = function()
                    error("must not be reached")
                end,
            })

            local stub = Helper.httpStub({ { code = 200, body = "" } })

            local result = Install.run({
                settings = Helper.settings({ update_repo = "o/r" }),
                plugin_dir = "/p/karabridge.koplugin",
                release = { tag = "v0.0.2", asset = { id = 22, url = "https://x/k.zip" } },
                request = stub.fn,
            })

            assert.equals("bad_archive", result:errorCode())
        end)
    end)
end)
