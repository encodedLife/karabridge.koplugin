local Helper = require("spec.support.helper")

local Json = require("karabridge.shared.json")

describe("Json", function()
    before_each(function()
        Helper.install()
    end)

    after_each(function()
        Helper.uninstall()
    end)

    describe("stripNulls", function()
        -- KOReader's decoder represents null as a function, because a nil would
        -- vanish from the table and become indistinguishable from a key the
        -- server never sent. A function is truthy, so every `or` fallback in
        -- the plugin depends on this stripping happening first.
        local null = Helper.mocks.json.null

        it("removes a null field", function()
            local stripped = Json.stripNulls({ id = "a", title = null })

            assert.equals("a", stripped.id)
            assert.is_nil(stripped.title)
        end)

        it("makes an `or` fallback work again", function()
            local bookmark = Json.stripNulls({ title = null })
            assert.equals("Untitled", bookmark.title or "Untitled")
        end)

        it("recurses into nested tables", function()
            local stripped = Json.stripNulls({ content = { htmlContent = null, url = "https://x" } })

            assert.is_nil(stripped.content.htmlContent)
            assert.equals("https://x", stripped.content.url)
        end)

        it("rebuilds an array so a removed null leaves no hole", function()
            -- Editing in place would leave a gap that silently truncates a
            -- later ipairs(), losing every item after the null.
            local stripped = Json.stripNulls({ "a", null, "c" })

            assert.equals(2, #stripped)
            assert.same({ "a", "c" }, stripped)
        end)

        it("recurses into arrays of tables", function()
            local stripped = Json.stripNulls({ { title = null, id = "1" } })
            assert.is_nil(stripped[1].title)
            assert.equals("1", stripped[1].id)
        end)

        it("leaves ordinary values alone", function()
            assert.equals("x", Json.stripNulls("x"))
            assert.equals(1, Json.stripNulls(1))
            assert.is_true(Json.stripNulls(true))
        end)

        it("turns a bare null into nil", function()
            assert.is_nil(Json.stripNulls(null))
        end)

        it("gives up rather than recursing forever on a cyclic table", function()
            local cyclic = {}
            cyclic.self = cyclic

            assert.is_table(Json.stripNulls(cyclic))
        end)
    end)

    describe("decode", function()
        it("decodes and strips in one step", function()
            local decoded = Json.decode('{"id":"a","title":null}')

            assert.equals("a", decoded.id)
            assert.is_nil(decoded.title)
        end)

        it("reports empty input rather than throwing", function()
            local decoded, err = Json.decode("")
            assert.is_nil(decoded)
            assert.matches("empty", err)
        end)

        it("reports malformed input rather than throwing", function()
            local decoded, err = Json.decode("{not json")
            assert.is_nil(decoded)
            assert.matches("malformed", err)
        end)
    end)

    describe("encode", function()
        it("encodes a table", function()
            assert.equals('{"a":1}', Json.encode({ a = 1 }))
        end)

        it("reports a value it cannot encode rather than throwing", function()
            local encoded, err = Json.encode({ fn = print })
            assert.is_nil(encoded)
            assert.is_string(err)
        end)
    end)

    describe("codec detection", function()
        -- Regression. KOReader's json module exports decode and encode as
        -- *tables* with a __call metamethod, not as functions. A
        -- `type(x) == "function"` check rejects the real codec, and every
        -- response then comes back as "malformed" -- which is what the
        -- connection test reported against a live Karakeep that was answering
        -- 200 with perfectly good JSON.
        --
        -- The mock codec uses plain functions, which is a legitimate shape and
        -- worth keeping covered, but it is why the unit suite passed while the
        -- device failed. Hence this pair.
        local function callable(fn)
            return setmetatable({}, { __call = function(_, ...) return fn(...) end })
        end

        it("accepts a codec whose decode is a callable table", function()
            Json.setCodec({
                decode = callable(function(text)
                    return { echoed = text }
                end),
                encode = callable(function()
                    return "{}"
                end),
            })

            local decoded = Json.decode('{"a":1}')
            assert.is_table(decoded)
            assert.equals('{"a":1}', decoded.echoed)
        end)

        it("accepts a codec whose encode is a callable table", function()
            Json.setCodec({
                decode = callable(function() end),
                encode = callable(function()
                    return '{"encoded":true}'
                end),
            })

            assert.equals('{"encoded":true}', Json.encode({ a = 1 }))
        end)

        it("still accepts a codec of plain functions", function()
            Json.setCodec({
                decode = function()
                    return { ok = true }
                end,
                encode = function()
                    return "{}"
                end,
            })

            assert.is_true(Json.decode("{}").ok)
        end)

        it("rejects a table whose decode is neither callable nor a function", function()
            Json.setCodec(nil)
            package.loaded["json"] = { decode = "not callable" }

            local decoded, err = Json.decode("{}")
            assert.is_nil(decoded)
            assert.matches("no JSON codec", err)
        end)
    end)

    describe("without a codec", function()
        it("degrades rather than throwing", function()
            Json.setCodec(nil)
            package.loaded["json"] = nil

            local decoded, err = Json.decode("{}")
            assert.is_nil(decoded)
            assert.is_string(err)
        end)
    end)
end)
