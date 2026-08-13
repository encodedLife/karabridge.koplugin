--[[--
The book's cover, on its Karakeep card.

## Getting the image out of the book

crengine already holds the cover as the publisher encoded it, and
`getCoverPageImageData()` hands back those bytes directly
(`frontend/document/credocument.lua:561`). KOReader's own
`getCoverPageImage()` is the wrong call here: it decodes them into a
BlitBuffer for drawing, which we would then have to encode again — a
generation of quality lost, and a PNG encoder we do not have.

That restricts covers to formats crengine reads: EPUB, FB2, MOBI and the
rest. A PDF has no cover to fetch, only a first page to render, and rendering
one is a different job with a different cost. PDFs simply get no cover.

## What Karakeep does with it

A text bookmark's `bannerImageUrl` is hard-coded to null
(`packages/trpc/models/bookmarks.ts:910`), so the cover will never appear as a
grid thumbnail. But `TextCard.tsx:25` looks for a `bannerImage` asset directly
and shows it in the **list** layout, and the preview page lists it as an
attachment. So: visible, in two places out of three, and worth sending. Said
plainly here because a feature that works in one layout and silently not in
another is otherwise a bug report waiting to happen.

@module karabridge.features.book_export.cover
]]

local Hashing = require("karabridge.shared.hashing")
local Logging = require("karabridge.shared.logging")
local Metadata = require("karabridge.shared.metadata")
local Result = require("karabridge.shared.result")

local log = Logging.forModule("book_export.cover")

local Cover = {}

-- Replaced by the specs, which have neither crengine nor a real book.
local reader

--- Replace the cover reader. Used by the specs.
-- @tparam function|nil fn Takes a file path, returns image bytes or nil.
function Cover.setReader(fn)
    reader = fn
end

--- Pull the raw cover bytes out of a book.
--
-- Uses KOReader's already-open document when the book is the one being read,
-- and opens a throwaway one otherwise. Opening is not free, which is why the
-- caller stores a hash and only comes back here when it has to.
--
-- @tparam string file_path
-- @treturn string|nil Encoded image bytes, exactly as the publisher stored them.
function Cover.extract(file_path)
    if reader then
        return reader(file_path)
    end

    local ok, bytes = pcall(function()
        local live = Metadata.liveDocument(file_path)
        local document, borrowed = live and live.document, true

        if not document then
            local DocumentRegistry = require("document/documentregistry")
            document, borrowed = DocumentRegistry:openDocument(file_path), false
        end

        if not document then
            return nil
        end

        local extracted
        -- crengine only. `_document` is absent on a PDF, where there is no
        -- stored cover to read.
        if type(document.loadDocument) == "function" and document._document then
            local loaded = document:loadDocument()
            if loaded ~= false then
                local ffi = require("ffi")
                local data, size = document._document:getCoverPageImageData()
                if data and size and size > 0 then
                    extracted = ffi.string(data, size)
                    ffi.C.free(data)
                end
            end
        end

        -- Only close what we opened. Closing the book the user is reading would
        -- be a spectacular way to fail.
        if not borrowed and type(document.close) == "function" then
            document:close()
        end

        return extracted
    end)

    if not ok then
        log.warn("could not read a cover from", tostring(file_path), "-", tostring(bytes))
        return nil
    end

    return bytes
end

--- Upload a book's cover and attach it to its card.
--
-- Skips silently when there is nothing to do: no cover in the book, an image
-- format Karakeep will not take, or the same cover already on the card. Only a
-- genuine failure is reported, and even then the export continues — a card
-- without its picture is worth far more than a failed export.
--
-- @tparam table opts assets, file_path, bookmark_id, stored (previous
--   `{ asset_id, hash }`, may be nil)
-- @treturn Result Value is `{ action, asset_id, hash }` where action is
--   "uploaded", "replaced" or "unchanged".
function Cover.send(opts)
    local assets = opts.assets
    local stored = opts.stored or {}

    if not assets then
        return Result.ok({ action = "unchanged", asset_id = stored.asset_id, hash = stored.hash })
    end

    local bytes = Cover.extract(opts.file_path)
    if not bytes or bytes == "" then
        log.dbg("no cover in", opts.file_path)
        return Result.ok({ action = "unchanged", asset_id = stored.asset_id, hash = stored.hash })
    end

    local hash = Hashing.hash(bytes)
    if stored.asset_id and stored.hash == hash then
        return Result.ok({ action = "unchanged", asset_id = stored.asset_id, hash = hash })
    end

    local uploaded = assets:upload(bytes)
    if uploaded:isErr() then
        return uploaded
    end

    local asset_id = (uploaded.value or {}).assetId
    if type(asset_id) ~= "string" or asset_id == "" then
        return Result.err("no_asset_id", "Karakeep stored the cover but did not return its ID.")
    end

    -- Replacing keeps the bannerImage role on the card. Attaching a second one
    -- would leave the old cover attached and the UI picking whichever it found
    -- first.
    if stored.asset_id then
        local replaced = assets:replace(opts.bookmark_id, stored.asset_id, asset_id)
        if replaced:isOk() then
            return Result.ok({ action = "replaced", asset_id = asset_id, hash = hash })
        end

        -- The old asset is gone from the card, or was never really there. Fall
        -- through to a plain attach rather than leaving the new cover orphaned
        -- in the asset store.
        log.info("could not replace the old cover; attaching the new one instead:", replaced:describe())
    end

    local attached = assets:attach(opts.bookmark_id, asset_id)
    if attached:isErr() then
        return attached
    end

    return Result.ok({ action = "uploaded", asset_id = asset_id, hash = hash })
end

return Cover
