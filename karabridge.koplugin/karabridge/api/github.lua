--[[--
The two GitHub calls the updater needs: read the latest release, fetch its zip.

Runs on `api/client.lua` rather than opening a second socket path, so retries,
timeouts, the stable error codes and the rule that an Authorization header
never reaches the log hold here too.

## Public and private with the same code

Whether the repository is public or private is not a setting. The **token
decides**: absent means anonymous, present means authenticated. A public
repository works either way -- a token merely lifts GitHub's rate limit from 60
requests an hour to 5000 -- and a private one simply fails without it, with a
404 that this module turns into a sentence saying so.

## The redirect that bites

Downloading a private release asset is a two-step dance, and getting it wrong
is the classic way this feature fails:

    GET /repos/:owner/:repo/releases/assets/:id
        Accept: application/octet-stream
        Authorization: Bearer <token>
    -> 302, Location: https://<storage host>/...?<signature>

That storage URL **rejects any request carrying an Authorization header**. And
LuaSocket follows redirects itself, re-sending every header it was given. So
the redirect is followed by hand, with a second client that has no token at
all.

A public asset needs none of this: `browser_download_url` is fetched directly.

@module karabridge.api.github
]]

local Client = require("karabridge.api.client")
local Logging = require("karabridge.shared.logging")
local Result = require("karabridge.shared.result")
local Text = require("karabridge.shared.text")

local log = Logging.forModule("api.github")

local Github = {}
Github.__index = Github

Github.HOST = "https://api.github.com"

--- Split "owner/name" into its two halves.
-- @tparam any repo
-- @treturn string|nil owner
-- @treturn string|nil name
function Github.parseRepo(repo)
    if type(repo) ~= "string" then
        return nil, nil
    end

    local owner, name = Text.trim(repo):match("^([%w%-%._]+)/([%w%-%._]+)$")
    if not owner then
        return nil, nil
    end
    return owner, name
end

--- Create a GitHub API client.
-- @tparam table opts repo ("owner/name"), token (optional), request (tests)
-- @treturn Github|nil nil when the repo is not "owner/name".
function Github.new(opts)
    opts = opts or {}

    local owner, name = Github.parseRepo(opts.repo)
    if not owner then
        return nil
    end

    local headers = {
        ["Accept"] = "application/vnd.github+json",
        ["X-GitHub-Api-Version"] = "2022-11-28",
    }

    local function client(overrides)
        overrides = overrides or {}

        -- Written out rather than as `overrides.anonymous and nil or token`,
        -- which always yields the token: in Lua, nil cannot be the true branch
        -- of an and/or, so the expression falls through to the right-hand side
        -- every time. That would have sent the Authorization header to the
        -- signed storage URL, which is the one thing this must not do.
        local token = Text.trim(opts.token or "")
        if overrides.anonymous then
            token = nil
        end

        return Client.new({
            server_url = Github.HOST,
            api_token = token,
            base_path = "",
            require_token = false,
            extra_headers = overrides.headers or headers,
            follow_redirects = overrides.follow_redirects,
            request = opts.request,
            sleep = opts.sleep,
        })
    end

    return setmetatable({ owner = owner, name = name, token = opts.token, client = client }, Github)
end

--- Turn a transport failure into something worth showing a person.
local function explain(result, repo)
    local code = result:errorCode()

    if code == "not_found" then
        return Result.err(
            "not_found",
            "No such repository, or it is private and needs a token: " .. repo,
            result.details
        )
    end
    if code == "unauthorized" then
        return Result.err("unauthorized", "GitHub rejected the update token.", result.details)
    end
    if code == "rate_limited" then
        return Result.err("rate_limited", "GitHub is rate limiting this device. Try again later.", result.details)
    end
    return result
end

--- The most recent published release.
--
-- @treturn Result Value is `{ tag, name, notes, url, asset }` where `asset` is
--   `{ id, name, size, url }` for the first zip in the release, or nil.
function Github:latestRelease()
    local path = string.format("/repos/%s/%s/releases/latest", self.owner, self.name)
    local fetched = self.client():get(path)

    if fetched:isErr() then
        return explain(fetched, self.owner .. "/" .. self.name)
    end

    local release = fetched.value or {}
    if type(release.tag_name) ~= "string" or release.tag_name == "" then
        return Result.err("no_release", "That repository has no published release yet.")
    end

    local asset
    for _, candidate in ipairs(release.assets or {}) do
        if type(candidate.name) == "string" and candidate.name:lower():match("%.zip$") then
            asset = {
                id = candidate.id,
                name = candidate.name,
                size = candidate.size,
                url = candidate.browser_download_url,
            }
            break
        end
    end

    return Result.ok({
        tag = release.tag_name,
        name = release.name,
        notes = release.body,
        url = release.html_url,
        asset = asset,
    })
end

--- Download a release asset to a file.
--
-- @tparam table asset From `latestRelease`.
-- @tparam string filepath
-- @treturn Result Value is the filepath.
function Github:downloadAsset(asset, filepath)
    if type(asset) ~= "table" or not (asset.id or asset.url) then
        return Result.err("no_asset", "That release has no zip to download.")
    end

    local token = Text.trim(self.token or "")

    -- Public: the browser URL is a plain download and needs nothing special.
    if token == "" then
        if type(asset.url) ~= "string" or asset.url == "" then
            return Result.err("no_asset", "That release asset has no download address.")
        end
        return self.client():get(asset.url, { filepath = filepath })
    end

    -- Private: ask the API for the bytes, and expect to be sent elsewhere.
    local path = string.format("/repos/%s/%s/releases/assets/%s", self.owner, self.name, tostring(asset.id))
    local authorised = self.client({
        headers = { ["Accept"] = "application/octet-stream" },
        follow_redirects = false,
    })

    local first = authorised:get(path, { filepath = filepath })

    -- Some deployments hand the bytes straight back rather than redirecting.
    if first:isOk() then
        return first
    end

    if first:errorCode() ~= "redirect" then
        return explain(first, self.owner .. "/" .. self.name)
    end

    local location = (first.details or {}).location
    log.dbg("following the asset redirect")

    -- No token on this one. The signed URL carries its own authorisation and
    -- refuses a request that brings a second.
    local anonymous = self.client({
        anonymous = true,
        headers = { ["Accept"] = "application/octet-stream" },
    })

    return anonymous:get(location, { filepath = filepath })
end

return Github
