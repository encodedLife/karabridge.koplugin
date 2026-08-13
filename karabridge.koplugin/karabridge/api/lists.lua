--[[--
Karakeep list endpoints.

Verified against Karakeep's `packages/api/routes/lists.ts`:

    GET    /lists                                 { lists: [...] }
    POST   /lists
    GET    /lists/:id
    GET    /lists/:id/bookmarks
    PUT    /lists/:listId/bookmarks/:bookmarkId   204, adds to the list
    DELETE /lists/:listId/bookmarks/:bookmarkId   204

Note the verb: adding a bookmark to a list is a PUT with no body, not a POST.
Getting that wrong produces a 404 that looks exactly like a wrong list ID.

@module karabridge.api.lists
]]

local Result = require("karabridge.shared.result")
local Text = require("karabridge.shared.text")

local Lists = {}
Lists.__index = Lists

-- From `zNewBookmarkListSchema`; refused server-side above this.
Lists.MAX_NAME_LENGTH = 100

-- Karakeep requires an icon and has no default. This one at least says where
-- the list came from.
Lists.DEFAULT_ICON = "\240\159\147\154"

--- @tparam table client A `karabridge.api.client`.
function Lists.new(client)
    return setmetatable({ client = client }, Lists)
end

--- Every list on the account.
--
-- Deliberately *not* paginated. `GET /lists` takes no pagination parameters
-- and returns the whole set in one response (`routes/lists.ts:15-18`, which
-- calls `api.lists.list()` with no arguments and has no `zPagination`
-- validator) — unlike `GET /tags`, which does paginate and is walked properly
-- in `api/tags.lua`. Adding a cursor loop here would send a parameter the
-- endpoint ignores and imply a guarantee the API does not make.
--
-- If Karakeep ever paginates lists, this is the function to change, and
-- `spec/integration/karakeep_api_spec.lua` is where it would show up.
--
-- @treturn Result Value is an array of `{ id, name, … }`.
function Lists:all()
    local result = self.client:get("/lists")
    if result:isErr() then
        return result
    end
    return Result.ok((result.value or {}).lists or {})
end

--- Find a list by its display name, case-insensitively.
--
-- `book_list` in `karabridge.conf` is a name, because a user editing a text
-- file on a computer has a name in front of them and not an opaque ID. The
-- lookup happens once per sync and is cached by the caller.
--
-- @tparam string name
-- @treturn Result Value is the list, or nil when there is no such list.
function Lists:findByName(name)
    if type(name) ~= "string" or name == "" then
        return Result.ok(nil)
    end

    local result = self:all()
    if result:isErr() then
        return result
    end

    local wanted = name:lower()
    for _, list in ipairs(result.value) do
        if type(list.name) == "string" and list.name:lower() == wanted then
            return Result.ok(list)
        end
    end

    return Result.ok(nil)
end

--- Create a list.
--
-- `icon` is **required** by `zNewBookmarkListSchema` -- a bare `z.string()`
-- with no default -- so one is always sent; omitting it is a 400 that says
-- nothing useful. `type` defaults to "manual" server-side, which is what a list
-- picked by hand should be: a smart list is defined by a query and would refuse
-- the bookmarks we add to it.
--
-- @tparam string name
-- @tparam[opt] string icon
-- @treturn Result Value is the created list.
function Lists:create(name, icon)
    local trimmed = Text.trim(name or "")
    if trimmed == "" then
        return Result.err("invalid_request", "A list needs a name.")
    end
    if #trimmed > Lists.MAX_NAME_LENGTH then
        return Result.err(
            "invalid_request",
            string.format("A list name can be at most %d characters.", Lists.MAX_NAME_LENGTH)
        )
    end

    return self.client:post("/lists", {
        body = { name = trimmed, icon = icon or Lists.DEFAULT_ICON },
    })
end

--- Add a bookmark to a list.
-- @tparam string list_id
-- @tparam string bookmark_id
-- @treturn Result
function Lists:addBookmark(list_id, bookmark_id)
    return self.client:put("/lists/" .. tostring(list_id) .. "/bookmarks/" .. tostring(bookmark_id))
end

--- Remove a bookmark from a list.
-- @tparam string list_id
-- @tparam string bookmark_id
-- @treturn Result
function Lists:removeBookmark(list_id, bookmark_id)
    return self.client:delete("/lists/" .. tostring(list_id) .. "/bookmarks/" .. tostring(bookmark_id))
end

return Lists
