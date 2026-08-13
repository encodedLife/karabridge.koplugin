--[[--
Is there a newer KaraBridge than the one running?

Kept apart from the installer so the question can be answered -- and tested --
without anything being replaced.

@module karabridge.features.update.check
]]

local Github = require("karabridge.api.github")
local Logging = require("karabridge.shared.logging")
local Result = require("karabridge.shared.result")
local Text = require("karabridge.shared.text")
local Version = require("karabridge.shared.version")

local log = Logging.forModule("update.check")

local Check = {}

--- Is the updater configured at all?
-- @tparam table settings
-- @treturn boolean
function Check.isConfigured(settings)
    return Text.trim(settings:get("update_repo") or "") ~= ""
end

--- Ask GitHub what the newest release is, and compare.
--
-- @tparam table opts settings, current (version string), request (tests)
-- @treturn Result Value is `{ available, current, latest, release }`.
function Check.run(opts)
    local settings = opts.settings
    local current = opts.current

    local repo = Text.trim(settings:get("update_repo") or "")
    if repo == "" then
        return Result.err("not_configured", "Set 'update_repo' in karabridge.conf first.")
    end

    local api = Github.new({
        repo = repo,
        token = settings:get("update_token"),
        request = opts.request,
        sleep = opts.sleep,
    })

    if not api then
        return Result.err("bad_repo", "'update_repo' should look like owner/name, not " .. repo .. ".")
    end

    local release = api:latestRelease()
    if release:isErr() then
        return release
    end

    local latest = release.value.tag

    -- An unreadable tag is not an update. Offering to install something we
    -- could not identify is not a reasonable thing to ask of anyone, and the
    -- most likely cause is a tag that was never meant as a release.
    if Version.parse(latest) == nil then
        log.warn("the latest tag is not a version we can read:", tostring(latest))
        return Result.err(
            "bad_tag",
            "The newest release is tagged '" .. tostring(latest) .. "', which is not a version."
        )
    end

    local available = Version.isNewer(latest, current)
    log.info("current", tostring(current), "latest", tostring(latest), available and "- newer" or "- up to date")

    return Result.ok({
        available = available,
        current = current,
        latest = latest,
        release = release.value,
    })
end

return Check
