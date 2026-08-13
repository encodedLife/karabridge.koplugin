--[[--
Validation of setting values, separate from where they came from.

Two callers, one rule set: the config file parser reports problems in a file,
and the settings menu refuses a bad value typed into a dialog. Both need the
same answers, so neither owns the rules.

Pure: no filesystem, no network, no KOReader. Whether a folder is writable is
a question for `karabridge.shared.filesystem`, not for this module — it depends
on the state of the device, not on the value.

@module karabridge.config.validation
]]

local Defaults = require("karabridge.config.defaults")
local Text = require("karabridge.shared.text")
local Url = require("karabridge.shared.url")

local Validation = {}

local URL_PROBLEMS = {
    empty = "the server address is empty",
    no_scheme = "the server address needs to start with https:// or http://",
    unsupported_scheme = "only https:// and http:// addresses are supported",
    no_host = "the server address has no host name",
    has_userinfo = "put the API key in the API key field, not in the address",
}

--- Check one setting value.
-- @tparam string key
-- @param value any
-- @treturn boolean ok
-- @treturn string|nil Problem description, without the key name.
function Validation.checkValue(key, value)
    local definition = Defaults.SCHEMA[key]
    if not definition then
        return false, "unknown setting"
    end

    -- nil always means "not set", which is valid for anything without a
    -- required-ness of its own. Required-ness is a question about the whole
    -- configuration, and is answered by checkReadiness().
    if value == nil then
        return true
    end

    if definition.type == "number" then
        if type(value) ~= "number" then
            return false, "needs a number"
        end
        if definition.min and value < definition.min then
            return false, string.format("must be at least %s", definition.min)
        end
        if definition.max and value > definition.max then
            return false, string.format("must be at most %s", definition.max)
        end
        return true
    end

    if definition.type == "boolean" then
        if type(value) ~= "boolean" then
            return false, "needs true or false"
        end
        return true
    end

    if type(value) ~= "string" then
        return false, "needs text"
    end

    local allowed = Defaults.ENUMS[key]
    if allowed then
        for _, candidate in ipairs(allowed) do
            if value == candidate then
                return true
            end
        end
        return false, "must be one of: " .. table.concat(allowed, ", ")
    end

    -- An empty server address is "not configured yet", which is the normal
    -- state on first run and not something to complain about. A non-empty one
    -- that is malformed is worth reporting.
    if key == "server_url" and Text.trim(value) ~= "" then
        local ok, reason = Url.validateServerUrl(Url.normaliseServerUrl(value))
        if not ok then
            return false, URL_PROBLEMS[reason] or "is not a valid address"
        end
    end

    return true
end

--- Check a whole table of values.
-- @tparam table values
-- @treturn table Array of "key: problem" strings; empty when all is well.
function Validation.check(values)
    local problems = {}
    if type(values) ~= "table" then
        return problems
    end

    local keys = {}
    for key in pairs(values) do
        table.insert(keys, key)
    end
    table.sort(keys)

    for _, key in ipairs(keys) do
        local ok, problem = Validation.checkValue(key, values[key])
        if not ok then
            table.insert(problems, string.format("%s: %s", key, problem))
        end
    end

    return problems
end

--- Which capabilities the current configuration can actually deliver.
--
-- Returned as flags rather than one boolean, so the menu can grey out exactly
-- the actions that will not work instead of refusing everything the moment one
-- field is blank.
--
-- @tparam table values
-- @treturn table
--   connect        server address and token are both present and plausible
--   download       connect, plus a download folder is set
--   export_books   connect, plus local book export is switched on
--   missing        array of human-readable descriptions of what is missing
function Validation.checkReadiness(values)
    values = values or {}
    local missing = {}

    local url = Text.trim(values.server_url or "")
    local token = Text.trim(values.api_token or "")

    if url == "" then
        table.insert(missing, "the Karakeep server address")
    else
        local ok, reason = Url.validateServerUrl(Url.normaliseServerUrl(url))
        if not ok then
            table.insert(missing, "a valid server address (" .. (URL_PROBLEMS[reason] or reason) .. ")")
        end
    end

    if token == "" then
        table.insert(missing, "an API key")
    end

    local can_connect = #missing == 0

    local folder = Text.trim(values.download_folder or "")
    if can_connect and folder == "" then
        table.insert(missing, "a download folder")
    end

    return {
        connect = can_connect,
        download = can_connect and folder ~= "" and values.download_enabled ~= false,
        export_books = can_connect and values.export_local_books ~= false,
        missing = missing,
    }
end

--- Turn `checkReadiness().missing` into one sentence for a dialog.
-- @tparam table missing
-- @treturn string
function Validation.describeMissing(missing)
    if type(missing) ~= "table" or #missing == 0 then
        return ""
    end
    if #missing == 1 then
        return "Set " .. missing[1] .. " first."
    end

    local head = {}
    for index = 1, #missing - 1 do
        table.insert(head, missing[index])
    end
    return "Set " .. table.concat(head, ", ") .. " and " .. missing[#missing] .. " first."
end

return Validation
