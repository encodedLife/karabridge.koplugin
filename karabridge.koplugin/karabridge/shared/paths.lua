--[[--
Pure path and filename helpers.

Separate from `karabridge.shared.filesystem`, which touches the disk: keeping
the string manipulation pure means filename generation, sanitisation and
traversal prevention are all covered by fast specs with no temporary
directories involved.

@module karabridge.shared.paths
]]

local Text = require("karabridge.shared.text")

local Paths = {}

-- Downloaded articles are named "[kb-id_<bookmarkId>] <title>.epub" so the
-- Karakeep bookmark ID survives a round trip through the filesystem. Several
-- KOReader plugins tag their downloads this way, each with its own prefix.
--
-- A distinct prefix is deliberate: a device may hold articles another plugin
-- downloaded, and mistaking one plugin's file for another's would make
-- KaraBridge archive or delete files it does not own.
Paths.ID_PREFIX = "[kb-id_"
Paths.ID_POSTFIX = "] "

-- Longest name most e-reader filesystems accept, in bytes.
Paths.MAX_FILENAME_BYTES = 255
-- Longest title portion; the rest of the budget is prefix, ID and extension.
Paths.MAX_TITLE_BYTES = 180

--- Join path segments with a single separator.
-- @tparam string base
-- @tparam string ... Further segments.
-- @treturn string
function Paths.join(base, ...)
    local result = base or ""
    for _, segment in ipairs({ ... }) do
        if segment ~= nil and segment ~= "" then
            result = result:gsub("/+$", "")
            result = result .. "/" .. (segment:gsub("^/+", ""))
        end
    end
    return result
end

--- The last segment of a path.
-- @tparam any path
-- @treturn string
function Paths.basename(path)
    if type(path) ~= "string" then
        return ""
    end
    return path:match("([^/]+)/*$") or path
end

--- Everything before the last segment.
-- @tparam any path
-- @treturn string
function Paths.dirname(path)
    if type(path) ~= "string" then
        return ""
    end
    local dir = path:match("^(.*)/[^/]+/*$")
    if dir == nil or dir == "" then
        return path:sub(1, 1) == "/" and "/" or "."
    end
    return dir
end

--- Turn arbitrary text into a filename safe on a Kobo's FAT32 partition.
--
-- The result is never empty and never ends in a dot or a space, both of which
-- FAT32 cannot represent. Square brackets become parentheses so that the
-- `[kb-id_…]` prefix stays unambiguous when parsing an ID back out.
--
-- @tparam any title
-- @tparam[opt=180] number max_bytes
-- @treturn string
function Paths.sanitiseFilename(title, max_bytes)
    max_bytes = max_bytes or Paths.MAX_TITLE_BYTES

    if type(title) ~= "string" or title == "" then
        return "Untitled"
    end

    title = title:gsub("[%z\1-\31\127]", " ") -- control characters
    title = title:gsub('[/\\%?%*:|"<>]', "_") -- illegal on FAT32/NTFS
    title = title:gsub("%[", "("):gsub("%]", ")")
    title = Text.normaliseWhitespace(title)

    if #title > max_bytes then
        title = Text.truncate(title, max_bytes)
        title = title:gsub("%s+$", "")
    end

    title = title:gsub("[%.%s]+$", "")

    if title == "" then
        return "Untitled"
    end
    return title
end

--- Build the local filename for a Karakeep bookmark.
-- @tparam string id Karakeep bookmark ID.
-- @tparam any title
-- @tparam[opt=".epub"] string ext
-- @treturn string
function Paths.buildArticleFilename(id, title, ext)
    ext = ext or ".epub"
    local budget = Paths.MAX_FILENAME_BYTES - #Paths.ID_PREFIX - #tostring(id) - #Paths.ID_POSTFIX - #ext
    local safe_title = Paths.sanitiseFilename(title, math.min(Paths.MAX_TITLE_BYTES, math.max(1, budget)))
    return Paths.ID_PREFIX .. tostring(id) .. Paths.ID_POSTFIX .. safe_title .. ext
end

--- Extract the Karakeep bookmark ID from one of our filenames.
-- @tparam any path Filename or full path.
-- @treturn string|nil The ID, or nil when this is not a KaraBridge file.
function Paths.parseArticleId(path)
    if type(path) ~= "string" then
        return nil
    end

    local name = Paths.basename(path)
    local prefix_len = #Paths.ID_PREFIX

    if name:sub(1, prefix_len) ~= Paths.ID_PREFIX then
        return nil
    end

    -- Plain find rather than a pattern: the postfix contains "]".
    local endpos = name:find(Paths.ID_POSTFIX, prefix_len + 1, true)
    if not endpos then
        return nil
    end

    local id = name:sub(prefix_len + 1, endpos - 1)
    if id == "" then
        return nil
    end

    -- Karakeep IDs are opaque but always URL-safe, so a separator or a bracket
    -- means we matched something that merely looks like one of our files.
    if id:find("[/%[%]]") then
        return nil
    end

    return id
end

--- Remove `.` and `..` segments, resolving the path textually.
--
-- Textual, not filesystem-resolving: this must work for paths that do not
-- exist yet, which is exactly the case when deciding where to write a file.
--
-- @tparam any path
-- @treturn string
function Paths.normalise(path)
    if type(path) ~= "string" or path == "" then
        return ""
    end

    local absolute = path:sub(1, 1) == "/"
    local segments = {}

    for segment in path:gmatch("[^/]+") do
        if segment == "." then
            -- nothing to do
        elseif segment == ".." then
            if #segments > 0 and segments[#segments] ~= ".." then
                table.remove(segments)
            elseif not absolute then
                table.insert(segments, "..")
            end
        else
            table.insert(segments, segment)
        end
    end

    local joined = table.concat(segments, "/")
    if absolute then
        return "/" .. joined
    end
    return joined == "" and "." or joined
end

--- Is `candidate` inside `root` once both are normalised?
--
-- The guard against path traversal. Remote content controls article titles and
-- image URLs, so every filename derived from them is checked against the
-- folder it is supposed to land in before anything is written.
--
-- @tparam any root
-- @tparam any candidate
-- @treturn boolean
function Paths.isInside(root, candidate)
    if type(root) ~= "string" or type(candidate) ~= "string" then
        return false
    end

    local normalised_root = Paths.normalise(root):gsub("/+$", "")
    local normalised_candidate = Paths.normalise(candidate)

    if normalised_root == "" then
        return false
    end
    if normalised_candidate == normalised_root then
        return true
    end

    return normalised_candidate:sub(1, #normalised_root + 1) == normalised_root .. "/"
end

--- Join `root` and an untrusted relative path, refusing to escape `root`.
-- @tparam string root
-- @tparam string relative
-- @treturn string|nil Resolved path, or nil when it would escape.
function Paths.resolveInside(root, relative)
    if type(root) ~= "string" or type(relative) ~= "string" then
        return nil
    end
    -- An absolute "relative" path is a traversal attempt by another name.
    if relative:sub(1, 1) == "/" then
        return nil
    end

    local candidate = Paths.normalise(Paths.join(root, relative))
    if not Paths.isInside(root, candidate) then
        return nil
    end
    return candidate
end

return Paths
