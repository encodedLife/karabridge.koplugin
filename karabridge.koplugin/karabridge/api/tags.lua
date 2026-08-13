--[[--
Karakeep tag endpoints.

Verified against Karakeep's `packages/api/routes/tags.ts`:

    GET    /tags          ?limit&sort   { tags: [...] }
    POST   /tags
    GET    /tags/:id
    DELETE /tags/:id
    GET    /tags/:id/bookmarks

Attaching a tag to a bookmark lives on the bookmark, not here: it is
`POST /bookmarks/:id/tags`, and it is in `karabridge.api.bookmarks` next to the
other bookmark mutations.

@module karabridge.api.tags
]]

local Result = require("karabridge.shared.result")

local Tags = {}
Tags.__index = Tags

--- @tparam table client A `karabridge.api.client`.
function Tags.new(client)
    return setmetatable({ client = client }, Tags)
end

-- A cap on how far a walk will go. An account with more tags than this has
-- other problems, and an unbounded loop on a device with a slow radio is worse
-- than an incomplete answer.
Tags.MAX_PAGES = 20
Tags.PAGE_SIZE = 100

--- Tags on the account, most-used first, following pagination.
--
-- `GET /tags` is cursor-paginated (`routes/tags.ts` encodes `nextCursor` as
-- base64url). Fetching a single page and calling it "all the tags" is what
-- makes a lookup by name silently fail for an account with more tags than the
-- page size — the tag exists, the plugin reports it does not.
--
-- @tparam[opt] number limit Stop after this many tags.
-- @treturn Result Value is an array of `{ id, name, … }`.
function Tags:all(limit)
    local collected = self.client:collect("/tags", {
        field = "tags",
        query = { limit = Tags.PAGE_SIZE, sort = "usage" },
        limit = limit,
        max_pages = Tags.MAX_PAGES,
    })

    if collected:isErr() then
        return collected
    end
    return Result.ok(collected.value.items)
end

--- Delete a tag.
--
-- Not used by the plugin itself — KaraBridge creates tags and never removes
-- them. It exists for the integration suite, which must be able to undo
-- everything it does.
--
-- @tparam string id
-- @treturn Result
function Tags:delete(id)
    return self.client:delete("/tags/" .. tostring(id))
end

--- Find a tag by name, case-insensitively.
--
-- Narrowed server-side first. `GET /tags` accepts `nameContains`
-- (`zTagListQueryParamsSchema`), so an account with thousands of tags costs
-- one small request instead of twenty large ones. The match is still made
-- here, because `nameContains` is a substring filter: asking for "book" also
-- returns "cookbook", and only an exact comparison can tell them apart.
--
-- Case is folded on both sides, so `Ebook` matches `ebook`. When two tags
-- differ only by case, the one Karakeep returns first wins — arbitrary, but
-- stable, and Karakeep itself treats them as distinct.
--
-- @tparam string name
-- @treturn Result Value is the tag, or nil.
function Tags:findByName(name)
    if type(name) ~= "string" or name == "" then
        return Result.ok(nil)
    end

    local wanted = name:lower()

    local narrowed = self.client:collect("/tags", {
        field = "tags",
        query = { limit = Tags.PAGE_SIZE, nameContains = name },
        max_pages = Tags.MAX_PAGES,
    })

    if narrowed:isOk() then
        for _, tag in ipairs(narrowed.value.items) do
            if type(tag.name) == "string" and tag.name:lower() == wanted then
                return Result.ok(tag)
            end
        end

        -- A complete walk of the narrowed set found nothing, so the tag does
        -- not exist. Only when the walk was cut short is a full search worth
        -- the requests.
        if narrowed.value.complete then
            return Result.ok(nil)
        end
    end

    local everything = self:all()
    if everything:isErr() then
        return everything
    end

    for _, tag in ipairs(everything.value) do
        if type(tag.name) == "string" and tag.name:lower() == wanted then
            return Result.ok(tag)
        end
    end

    return Result.ok(nil)
end

return Tags
