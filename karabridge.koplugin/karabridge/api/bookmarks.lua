--[[--
Karakeep bookmark endpoints.

Verified against Karakeep's `packages/api/routes/bookmarks.ts`
and the Zod schemas in `packages/shared/types/bookmarks.ts`:

    GET    /bookmarks                    ?archived&favourited&limit&cursor&includeContent&sortOrder
    POST   /bookmarks                    { type: "link"|"text"|"asset", … }
    GET    /bookmarks/:id                ?includeContent
    PATCH  /bookmarks/:id                partial update; `text` is patchable
    DELETE /bookmarks/:id                204
    GET    /bookmarks/:id/content        ?format&maxChars&cursor
    GET    /bookmarks/:id/highlights
    POST   /bookmarks/:id/tags           { tags: [{ tagName, attachedBy }] }
    GET    /lists/:id/bookmarks          same shape as GET /bookmarks
    GET    /tags/:id/bookmarks           same shape as GET /bookmarks

The two facts the rest of the plugin depends on:

  * `PATCH /bookmarks/:id` accepts `text`, so a text bookmark can be rewritten
    in place. That is what makes "one local book = one Karakeep card, updated
    on every export" possible at all rather than a pile of duplicates.
  * The list and tag collection endpoints take no `archived` filter — only the
    unfiltered `/bookmarks` does. Callers filtering by list or tag must drop
    archived bookmarks themselves.

@module karabridge.api.bookmarks
]]

local Result = require("karabridge.shared.result")

local Bookmarks = {}
Bookmarks.__index = Bookmarks

--- @tparam table client A `karabridge.api.client`.
function Bookmarks.new(client)
    return setmetatable({ client = client }, Bookmarks)
end

--- One page of bookmarks for a sync scope.
-- @tparam table opts
--   scope     "all", "list" or "tag"
--   scope_id  list or tag ID, when scope is not "all"
--   limit     page size, capped at Karakeep's own maximum of 100
--   cursor    pagination cursor
--   archived  only honoured for scope "all"
-- @treturn Result Value is `{ bookmarks = {...}, nextCursor = … }`.
function Bookmarks:page(opts)
    opts = opts or {}

    local query = {
        limit = math.min(opts.limit or 20, 100),
        cursor = opts.cursor,
        includeContent = true,
        -- Newest first, matching Karakeep's own default. With a per-sync cap,
        -- ascending order would bury new articles under an old backlog.
        sortOrder = "desc",
    }

    local path
    if opts.scope == "list" then
        path = "/lists/" .. tostring(opts.scope_id) .. "/bookmarks"
    elseif opts.scope == "tag" then
        path = "/tags/" .. tostring(opts.scope_id) .. "/bookmarks"
    else
        path = "/bookmarks"
        query.archived = opts.archived == true
    end

    return self.client:get(path, { query = query })
end

--- A single bookmark.
-- @tparam string id
-- @tparam[opt=true] boolean include_content
-- @treturn Result
function Bookmarks:get(id, include_content)
    if include_content == nil then
        include_content = true
    end
    return self.client:get("/bookmarks/" .. tostring(id), {
        query = { includeContent = include_content },
    })
end

--- Create a text bookmark. This is the shape used for a local book's card.
-- @tparam table opts title, text, source_url, note
-- @treturn Result
function Bookmarks:createText(opts)
    opts = opts or {}
    if type(opts.text) ~= "string" then
        return Result.err("invalid_request", "A text bookmark needs text.")
    end

    return self.client:post("/bookmarks", {
        body = {
            type = "text",
            title = opts.title,
            text = opts.text,
            sourceUrl = opts.source_url,
            note = opts.note,
        },
    })
end

--- Create a link bookmark.
-- @tparam table opts url, title, note, crawl_priority
-- @treturn Result
function Bookmarks:createLink(opts)
    opts = opts or {}
    if type(opts.url) ~= "string" or opts.url == "" then
        return Result.err("invalid_request", "A link bookmark needs a URL.")
    end

    return self.client:post("/bookmarks", {
        body = {
            type = "link",
            url = opts.url,
            title = opts.title,
            note = opts.note,
            crawlPriority = opts.crawl_priority,
        },
    })
end

--- Update mutable fields of a bookmark, e.g. `{ archived = true }`.
-- @tparam string id
-- @tparam table fields
-- @treturn Result
function Bookmarks:update(id, fields)
    return self.client:patch("/bookmarks/" .. tostring(id), { body = fields })
end

--- Replace the body of a text bookmark.
-- @tparam string id
-- @tparam string text
-- @tparam[opt] string title
-- @treturn Result
function Bookmarks:updateText(id, text, title)
    return self:update(id, { text = text, title = title })
end

--- Delete a bookmark. Answers 204 with no body.
-- @tparam string id
-- @treturn Result
function Bookmarks:delete(id)
    return self.client:delete("/bookmarks/" .. tostring(id))
end

--- Attach tags by name, creating any that do not exist.
-- @tparam string id
-- @tparam table names Array of tag names.
-- @treturn Result
function Bookmarks:attachTags(id, names)
    local tags = {}
    for _, name in ipairs(names or {}) do
        if type(name) == "string" and name ~= "" then
            table.insert(tags, { tagName = name, attachedBy = "human" })
        end
    end

    if #tags == 0 then
        return Result.ok({})
    end

    return self.client:post("/bookmarks/" .. tostring(id) .. "/tags", { body = { tags = tags } })
end

-- The content endpoint returns bounded chunks capped at 50000 characters each.
-- Ten of those is far more than any article and stops a pathological response
-- from looping forever.
local MAX_CONTENT_CHUNKS = 10
local CONTENT_CHUNK_CHARS = 50000

--- Fetch the readable content of a bookmark, following the continuation cursor.
--
-- Used when a bookmark has no inline HTML. Without following the cursor a long
-- article is silently truncated at the first chunk, which is the sort of bug
-- that only shows up in the one article nobody tests with.
--
-- @tparam string id
-- @tparam[opt="markdown"] string format "markdown" or "text"
-- @treturn Result Value is the whole content as a string.
function Bookmarks:readableContent(id, format)
    local chunks = {}
    local cursor = nil

    for _ = 1, MAX_CONTENT_CHUNKS do
        -- The cursor carries the format, so it is sent on the first request
        -- only. Written as an if rather than `cursor and nil or default`:
        -- that idiom always yields the default, because `x and nil` is nil and
        -- `nil or default` is the default. This mistake is easy to make and
        -- that bug and sends the format on every chunk.
        local requested_format = nil
        if not cursor then
            requested_format = format or "markdown"
        end

        local result = self.client:get("/bookmarks/" .. tostring(id) .. "/content", {
            query = {
                format = requested_format,
                maxChars = CONTENT_CHUNK_CHARS,
                cursor = cursor,
            },
        })

        if result:isErr() then
            -- Keep whatever arrived rather than losing the article entirely.
            if #chunks > 0 then
                break
            end
            return result
        end

        local page = result.value or {}
        table.insert(chunks, page.content or "")

        cursor = page.nextCursor
        if not cursor or not page.truncated then
            break
        end
    end

    return Result.ok(table.concat(chunks))
end

--- Download an asset to a local file.
--
-- Requires the "Assets: Read" scope on the API key. Article *images* are not
-- fetched this way — those come from their original URLs, which keeps the
-- Karakeep token off third-party requests.
--
-- @tparam string asset_id
-- @tparam string filepath
-- @treturn Result
function Bookmarks:downloadAsset(asset_id, filepath)
    return self.client:get("/assets/" .. tostring(asset_id), { filepath = filepath })
end

return Bookmarks
