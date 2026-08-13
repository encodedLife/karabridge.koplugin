--[[--
Karakeep assets: uploading a file and attaching it to a bookmark.

Two steps, deliberately separate on Karakeep's side. `POST /assets` stores the
bytes and hands back an `assetId`; `POST /bookmarks/:id/assets` says what that
asset *is* to a particular bookmark. An upload that is never attached is just an
orphan in the asset store.

The only asset KaraBridge sends today is a book cover, attached as
`bannerImage`.

## What the server does with the bytes

`packages/api/utils/upload.ts` sniffs the real type with `fileTypeFromBlob` and
ignores the declared one where they disagree; anything outside
`SUPPORTED_UPLOAD_ASSET_TYPES` — for images, GIF, JPEG, PNG and WebP — is a 400.
So the content type sent here is a courtesy, not a promise, and a cover in some
other format is refused by the server rather than by us.

@module karabridge.api.assets
]]

local Logging = require("karabridge.shared.logging")
local Result = require("karabridge.shared.result")

local log = Logging.forModule("api.assets")

local Assets = {}
Assets.__index = Assets

--- Image types Karakeep accepts, keyed by the magic bytes that identify them.
--
-- Sniffed rather than guessed from a file extension, because the bytes come out
-- of an EPUB where the name means nothing, and because the server sniffs too:
-- disagreeing with it only produces a confusing 400.
local SIGNATURES = {
    { prefix = "\255\216\255", type = "image/jpeg", extension = "jpg" },
    { prefix = "\137PNG\13\10\26\10", type = "image/png", extension = "png" },
    { prefix = "GIF87a", type = "image/gif", extension = "gif" },
    { prefix = "GIF89a", type = "image/gif", extension = "gif" },
}

--- Identify image bytes.
--
-- @tparam any bytes
-- @treturn string|nil MIME type, or nil when it is not one Karakeep takes.
-- @treturn string|nil A matching file extension.
function Assets.identify(bytes)
    if type(bytes) ~= "string" or #bytes < 12 then
        return nil, nil
    end

    for _, signature in ipairs(SIGNATURES) do
        if bytes:sub(1, #signature.prefix) == signature.prefix then
            return signature.type, signature.extension
        end
    end

    -- WebP is the one that needs two checks: "RIFF", four bytes of length, then
    -- "WEBP". Testing only "RIFF" would also match a WAV file.
    if bytes:sub(1, 4) == "RIFF" and bytes:sub(9, 12) == "WEBP" then
        return "image/webp", "webp"
    end

    return nil, nil
end

--- A multipart boundary that does not occur in the payload.
--
-- A boundary appearing inside the bytes would split the body in the wrong place
-- and the server would see a truncated image. Unlikely with a real boundary and
-- a real JPEG, but "unlikely" is not a property worth relying on when checking
-- costs one string search.
--
-- @tparam string payload
-- @treturn string
function Assets.boundary(payload)
    local candidate = "KaraBridgeAssetBoundary"
    local suffix = 0

    while payload:find(candidate, 1, true) do
        suffix = suffix + 1
        candidate = "KaraBridgeAssetBoundary" .. suffix
    end

    return candidate
end

--- Build a multipart/form-data body with one file part.
-- @tparam string field
-- @tparam string filename
-- @tparam string content_type
-- @tparam string bytes
-- @treturn string body
-- @treturn string content type header value
function Assets.multipart(field, filename, content_type, bytes)
    local boundary = Assets.boundary(bytes)

    local body = table.concat({
        "--" .. boundary,
        string.format('Content-Disposition: form-data; name="%s"; filename="%s"', field, filename),
        "Content-Type: " .. content_type,
        "",
        bytes,
        "--" .. boundary .. "--",
        "",
    }, "\r\n")

    return body, "multipart/form-data; boundary=" .. boundary
end

--- Create an assets API.
-- @tparam table client
-- @treturn Assets
function Assets.new(client)
    assert(client, "Assets.new requires a client")
    return setmetatable({ client = client }, Assets)
end

--- Upload bytes and get an asset ID back.
--
-- @tparam string bytes
-- @tparam[opt] string filename Defaults to `cover.<ext>`.
-- @treturn Result Value is `{ assetId, contentType, size, fileName }`.
function Assets:upload(bytes, filename)
    if type(bytes) ~= "string" or bytes == "" then
        return Result.err("invalid_request", "There is nothing to upload.")
    end

    local content_type, extension = Assets.identify(bytes)
    if not content_type then
        return Result.err("unsupported_image", "Karakeep does not accept this image format.")
    end

    local body, header = Assets.multipart("file", filename or ("cover." .. extension), content_type, bytes)

    log.dbg("uploading", #bytes, "bytes of", content_type)

    return self.client:post("/assets", { raw_body = body, content_type = header })
end

--- Attach an uploaded asset to a bookmark.
-- @tparam string bookmark_id
-- @tparam string asset_id
-- @tparam[opt] string asset_type Defaults to `bannerImage`.
-- @treturn Result
function Assets:attach(bookmark_id, asset_id, asset_type)
    return self.client:post("/bookmarks/" .. tostring(bookmark_id) .. "/assets", {
        body = { id = asset_id, assetType = asset_type or "bannerImage" },
    })
end

--- Swap one attached asset for another, keeping its role on the bookmark.
-- @tparam string bookmark_id
-- @tparam string asset_id The one currently attached.
-- @tparam string replacement_id
-- @treturn Result
function Assets:replace(bookmark_id, asset_id, replacement_id)
    return self.client:put(
        "/bookmarks/" .. tostring(bookmark_id) .. "/assets/" .. tostring(asset_id),
        { body = { assetId = replacement_id } }
    )
end

--- Every asset attached to a bookmark.
-- @tparam string bookmark_id
-- @treturn Result Value is an array.
function Assets:forBookmark(bookmark_id)
    local result = self.client:get("/bookmarks/" .. tostring(bookmark_id) .. "/assets")
    if result:isErr() then
        return result
    end

    local payload = result.value or {}
    return Result.ok(payload.assets or payload)
end

return Assets
