--[[--
Parser for `karabridge.conf`.

Typing a Karakeep API key on an e-reader keyboard is miserable, which is the
whole reason this file exists. The format is deliberately plain; this
is a reimplementation driven by `karabridge.config.defaults`.SCHEMA rather than
a second copy of the key list, so a setting cannot exist in the menu and be
rejected by the file (or the reverse).

Format, one setting per line:

    # comments start with # or ;
    server_url = https://karakeep.example.org
    api_token: ak1_example          ; ":" works as well as "="
    filter_tags = read-later, ebook
    download_images = true          ; true/yes/on/1 and false/no/off/0

Values run to the end of the line and need no quoting; surrounding quotes are
stripped if present, which is the only way to give a value meaningful leading
or trailing space.

An unrecognised key is reported as a problem rather than ignored, because a
typo in a config file is otherwise completely invisible: the setting simply
never takes effect and there is nothing to see.

No KOReader dependencies, so the specs exercise it directly.

@module karabridge.config.config_file
]]

local Defaults = require("karabridge.config.defaults")
local Text = require("karabridge.shared.text")

local ConfigFile = {}

local TRUE_WORDS = { ["true"] = true, yes = true, on = true, ["1"] = true }
local FALSE_WORDS = { ["false"] = true, no = true, off = true, ["0"] = true }

--- Parse the contents of a config file.
--
-- Never throws and never stops at the first bad line: a file with one typo in
-- it should still deliver the other nine settings, with the typo reported.
--
-- @tparam any text
-- @treturn table Recognised settings, coerced to their schema type.
-- @treturn table Array of human-readable problems; empty when all is well.
function ConfigFile.parse(text)
    local values, problems = {}, {}

    if type(text) ~= "string" then
        return values, problems
    end

    local line_number = 0
    for line in (text .. "\n"):gmatch("(.-)\r?\n") do
        line_number = line_number + 1
        local trimmed = Text.trim(line)

        if trimmed ~= "" and not trimmed:match("^[#;]") then
            local key, value = trimmed:match("^([%w_]+)%s*[=:]%s*(.*)$")

            if not key then
                table.insert(problems, string.format("line %d: expected 'key = value'", line_number))
            else
                value = Text.trim(value)
                local unquoted = value:match('^"(.*)"$') or value:match("^'(.*)'$")
                if unquoted then
                    value = unquoted
                end

                -- A trailing comment is not a thing this format has: comments
                -- occupy a whole line. Someone who writes
                --
                --     update_token =        # only for a private repository
                --
                -- gets that sentence as their token, and then a 401 that says
                -- nothing about why. The value is left exactly as written --
                -- guessing where a comment starts would corrupt any value that
                -- legitimately contains a #, such as a URL fragment -- but the
                -- suspicion is reported.
                if value:match("^[#;]") then
                    table.insert(
                        problems,
                        string.format(
                            "line %d: the value of '%s' starts with %s, which looks like a comment. "
                                .. "Comments need a line of their own.",
                            line_number,
                            key,
                            value:sub(1, 1)
                        )
                    )
                end

                local definition = Defaults.SCHEMA[key]

                if Defaults.INTERNAL_KEYS[key] then
                    table.insert(
                        problems,
                        string.format("line %d: '%s' is managed by the plugin and cannot be set here", line_number, key)
                    )
                elseif not definition then
                    table.insert(problems, string.format("line %d: unknown setting '%s'", line_number, key))
                elseif definition.type == "string" then
                    values[key] = value
                elseif definition.type == "number" then
                    local number = tonumber(value)
                    if number then
                        values[key] = number
                    else
                        table.insert(
                            problems,
                            string.format("line %d: '%s' needs a number, got '%s'", line_number, key, value)
                        )
                    end
                elseif definition.type == "boolean" then
                    local lowered = value:lower()
                    if TRUE_WORDS[lowered] then
                        values[key] = true
                    elseif FALSE_WORDS[lowered] then
                        values[key] = false
                    else
                        table.insert(
                            problems,
                            string.format("line %d: '%s' needs true or false, got '%s'", line_number, key, value)
                        )
                    end
                end
            end
        end
    end

    return values, problems
end

local GROUP_TITLES = {
    server = "Karakeep server",
    download = "Downloading articles",
    filter = "What to sync",
    sync = "Sending reading status and highlights back",
    books = "Exporting your own books",
    automation = "Automatic syncing",
    updates = "Updating the plugin",
}

local GROUP_ORDER = { "server", "download", "filter", "sync", "books", "automation", "updates" }

--- Render a commented example config file from the schema.
--
-- Generated rather than kept as a literal, so a new setting appears in the
-- example the moment it is added to the schema and cannot be forgotten.
--
-- Only `server_url` and `api_token` are uncommented: those two are what the
-- file exists for, and a user who uncomments nothing else still gets a working
-- setup rather than a file that overrides two dozen menu choices they never
-- made.
--
-- @treturn string
function ConfigFile.template()
    local lines = {
        "# KaraBridge settings. Lines starting with # or ; are ignored.",
        "#",
        "# These seed KaraBridge's settings the first time it runs. They then appear",
        "# in the KaraBridge menu like any other setting, and whatever you change",
        "# there wins from that point on. Editing this file later does nothing by",
        '# itself -- use "Settings file -> Reload it now" to pull the changes in.',
        "#",
        "# This file contains your API key in plain text. Keep it readable only by",
        "# you, and give the device its own Karakeep key so it can be revoked alone.",
        "",
    }

    for _, group in ipairs(GROUP_ORDER) do
        local keys = Defaults.keysInGroup(group)
        if #keys > 0 then
            table.insert(lines, "# --- " .. (GROUP_TITLES[group] or group) .. " ---")

            for _, key in ipairs(keys) do
                local definition = Defaults.SCHEMA[key]
                table.insert(lines, "# " .. definition.description)

                local shown
                if key == "api_token" then
                    shown = "paste-your-key-here"
                elseif key == "server_url" then
                    shown = "https://karakeep.example.org"
                elseif definition.default == nil then
                    shown = ""
                elseif definition.type == "boolean" then
                    shown = definition.default and "true" or "false"
                else
                    shown = tostring(definition.default)
                end

                local prefix = (key == "server_url" or key == "api_token") and "" or "# "
                table.insert(lines, string.format("%s%s = %s", prefix, key, shown))
                table.insert(lines, "")
            end
        end
    end

    return table.concat(lines, "\n")
end

return ConfigFile
