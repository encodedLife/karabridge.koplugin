--[[--
Comparing two version strings.

Small, pure and separate because "is this newer" is the one question the whole
updater turns on, and getting it wrong in either direction is bad in a
different way: too eager and it reinstalls the running version forever, too shy
and it never offers the update that exists.

Semantic versioning, with the parts that actually occur:

  * a leading `v` is optional, because a git tag usually has one and
    `_meta.lua` never does;
  * missing minor or patch count as zero, so `1` and `1.0.0` are the same;
  * a pre-release suffix makes a version *lower* than the same version without
    one, which is what semver says and what anyone expects of `1.0.0-beta`;
  * anything unparseable is nil rather than a guess.

@module karabridge.shared.version
]]

local Version = {}

--- Break a version string into its parts.
--
-- @tparam any value e.g. "v0.7.1", "1.2", "2.0.0-beta.3"
-- @treturn table|nil `{ major, minor, patch, prerelease }`
function Version.parse(value)
    if type(value) ~= "string" then
        return nil
    end

    local text = value:gsub("^%s+", ""):gsub("%s+$", "")
    text = text:gsub("^[vV]", "")

    local major, rest = text:match("^(%d+)(.*)$")
    if not major then
        return nil
    end

    local minor, patch = 0, 0
    local prerelease

    local minor_text, after_minor = rest:match("^%.(%d+)(.*)$")
    if minor_text then
        minor = tonumber(minor_text)
        rest = after_minor

        local patch_text, after_patch = rest:match("^%.(%d+)(.*)$")
        if patch_text then
            patch = tonumber(patch_text)
            rest = after_patch
        end
    end

    if rest ~= "" then
        -- A pre-release marker, or build metadata, or something we do not
        -- recognise. All three are treated the same: present, and therefore
        -- lower than the bare version.
        prerelease = rest:gsub("^[%-%+]", "")
        if prerelease == "" then
            prerelease = nil
        end
    end

    return { major = tonumber(major), minor = minor, patch = patch, prerelease = prerelease }
end

--- Compare two version strings.
--
-- @tparam any a
-- @tparam any b
-- @treturn number|nil -1 when a < b, 0 when equal, 1 when a > b. nil when
--   either side cannot be parsed, so a caller can tell "older" from "no idea".
function Version.compare(a, b)
    local left, right = Version.parse(a), Version.parse(b)
    if not left or not right then
        return nil
    end

    for _, part in ipairs({ "major", "minor", "patch" }) do
        if left[part] ~= right[part] then
            return left[part] < right[part] and -1 or 1
        end
    end

    if left.prerelease == right.prerelease then
        return 0
    end
    -- 1.0.0 beats 1.0.0-beta; a release is never worse than its own preview.
    if left.prerelease == nil then
        return 1
    end
    if right.prerelease == nil then
        return -1
    end
    return left.prerelease < right.prerelease and -1 or 1
end

--- Is `candidate` newer than `current`?
--
-- False when they are equal, when candidate is older, and when either cannot
-- be read. That last case is the important one: an unreadable tag must not be
-- offered as an update, because "install something I could not identify" is
-- not a reasonable thing to ask of anyone.
--
-- @tparam any candidate
-- @tparam any current
-- @treturn boolean
function Version.isNewer(candidate, current)
    return Version.compare(candidate, current) == 1
end

return Version
