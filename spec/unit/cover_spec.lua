--[[--
Book covers, on their way to Karakeep.

The interesting cases are not "does it upload" but the ones that decide whether
this feature is a nuisance: sending the same image on every export, corrupting
bytes on the way, and failing an export over a picture.
]]

local Helper = require("spec.support.helper")

local Assets = require("karabridge.api.assets")
local Cover = require("karabridge.features.book_export.cover")
local Json = require("karabridge.shared.json")

-- Real magic bytes, padded past the 12-byte minimum the sniffer needs.
local JPEG = "\255\216\255\224" .. string.rep("j", 40)
local PNG = "\137PNG\13\10\26\10" .. string.rep("p", 40)
local WEBP = "RIFF\0\0\0\0WEBP" .. string.rep("w", 40)

describe("Assets.identify", function()
    it("names the four formats Karakeep accepts", function()
        assert.equals("image/jpeg", Assets.identify(JPEG))
        assert.equals("image/png", Assets.identify(PNG))
        assert.equals("image/webp", Assets.identify(WEBP))
        assert.equals("image/gif", Assets.identify("GIF89a" .. string.rep("g", 40)))
    end)

    it("does not mistake a WAV for a WebP", function()
        -- Both start with RIFF. Checking only that prefix would send audio to an
        -- image endpoint and earn a confusing 400.
        assert.is_nil(Assets.identify("RIFF\0\0\0\0WAVEfmt " .. string.rep("a", 40)))
    end)

    it("refuses what Karakeep would refuse anyway", function()
        assert.is_nil(Assets.identify("<svg xmlns='http://www.w3.org/2000/svg'></svg>"))
        assert.is_nil(Assets.identify(""))
        assert.is_nil(Assets.identify(nil))
    end)
end)

describe("Assets.multipart", function()
    it("wraps the bytes without altering them", function()
        local body = Assets.multipart("file", "cover.jpg", "image/jpeg", JPEG)

        assert.is_truthy(body:find(JPEG, 1, true))
        assert.is_truthy(body:find('name="file"; filename="cover.jpg"', 1, true))
        assert.is_truthy(body:find("Content-Type: image/jpeg", 1, true))
    end)

    it("picks a boundary that does not occur in the payload", function()
        -- An image containing the boundary string would be split in the wrong
        -- place and arrive truncated.
        local hostile = JPEG .. "KaraBridgeAssetBoundary" .. JPEG
        local body, header = Assets.multipart("file", "cover.jpg", "image/jpeg", hostile)

        local boundary = header:match("boundary=(.+)$")
        assert.is_falsy(hostile:find(boundary, 1, true))
        assert.is_truthy(body:find(hostile, 1, true))
    end)
end)

describe("Assets:upload", function()
    before_each(function()
        Helper.install()
    end)

    after_each(function()
        Helper.uninstall()
    end)

    it("sends the bytes as multipart, not as JSON", function()
        local client, stub = Helper.client({ { code = 201, body = '{"assetId":"a1"}' } })

        local result = Assets.new(client):upload(JPEG)

        assert.is_true(result:isOk())
        assert.equals("a1", result.value.assetId)

        local request = stub.requests[1].request
        assert.is_truthy(request.headers["Content-Type"]:find("multipart/form-data", 1, true))
        assert.is_truthy(request.body:find(JPEG, 1, true))
        assert.equals(tostring(#request.body), request.headers["Content-Length"])
    end)

    it("refuses a format Karakeep does not take, without asking it", function()
        local client, stub = Helper.client({})

        local result = Assets.new(client):upload("not an image at all, really")

        assert.equals("unsupported_image", result:errorCode())
        assert.equals(0, #stub.requests)
    end)
end)

describe("Cover.send", function()
    before_each(function()
        Helper.install()
        Cover.setReader(function()
            return JPEG
        end)
    end)

    after_each(function()
        Cover.setReader(nil)
        Helper.uninstall()
    end)

    local function assets(responses)
        local client, stub = Helper.client(responses)
        return Assets.new(client), stub
    end

    it("uploads and attaches a cover the card does not have", function()
        local api, stub = assets({
            { code = 201, body = '{"assetId":"a1"}' },
            { code = 201, body = '{"id":"a1","assetType":"bannerImage"}' },
        })

        local result = Cover.send({ assets = api, file_path = "/b.epub", bookmark_id = "card1" })

        assert.equals("uploaded", result.value.action)
        assert.equals("a1", result.value.asset_id)

        local attach = Json.decode(stub.requests[2].request.body)
        assert.equals("bannerImage", attach.assetType)
        assert.equals("a1", attach.id)
    end)

    it("does nothing at all when the cover has not changed", function()
        -- The whole point of storing the hash: a book exported weekly should not
        -- re-upload the same JPEG every time.
        local api, stub = assets({})
        local hash = require("karabridge.shared.hashing").hash(JPEG)

        local result = Cover.send({
            assets = api,
            file_path = "/b.epub",
            bookmark_id = "card1",
            stored = { asset_id = "a1", hash = hash },
        })

        assert.equals("unchanged", result.value.action)
        assert.equals(0, #stub.requests)
    end)

    it("replaces the old asset rather than attaching a second one", function()
        local api, stub = assets({
            { code = 201, body = '{"assetId":"a2"}' },
            { code = 200, body = "{}" },
        })

        local result = Cover.send({
            assets = api,
            file_path = "/b.epub",
            bookmark_id = "card1",
            stored = { asset_id = "a1", hash = "something-else" },
        })

        assert.equals("replaced", result.value.action)
        assert.equals("PUT", stub.requests[2].request.method)
        assert.is_truthy(stub.requests[2].request.url:find("/assets/a1", 1, true))
    end)

    it("attaches when the old asset is no longer on the card", function()
        -- Otherwise the freshly uploaded image is orphaned in the asset store
        -- and the card stays without a cover for good.
        local api = assets({
            { code = 201, body = '{"assetId":"a2"}' },
            { code = 404, body = '{"error":"not found"}' },
            { code = 201, body = '{"id":"a2"}' },
        })

        local result = Cover.send({
            assets = api,
            file_path = "/b.epub",
            bookmark_id = "card1",
            stored = { asset_id = "gone", hash = "something-else" },
        })

        assert.equals("uploaded", result.value.action)
        assert.equals("a2", result.value.asset_id)
    end)

    it("says nothing happened when the book has no cover", function()
        Cover.setReader(function()
            return nil
        end)
        local api, stub = assets({})

        local result = Cover.send({ assets = api, file_path = "/b.epub", bookmark_id = "card1" })

        assert.equals("unchanged", result.value.action)
        assert.equals(0, #stub.requests)
    end)
end)
