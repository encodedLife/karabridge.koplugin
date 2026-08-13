--[[--
The checks that need a real KOReader, run by `scripts/test-koreader.sh`.

Everything here is something a mock cannot honestly answer:

  * that every module resolves under the *exact* `package.path` PluginLoader
    installs, which is `plugin_root/?.lua` and nothing else,
  * that `main.lua` evaluates to something KOReader can instantiate,
  * that the menu table is shaped the way TouchMenu expects,
  * that sidecar metadata survives a round trip through the real DocSettings,
  * that DataStorage yields absolute paths.

The first of these already caught a plugin that loaded fine in the unit suite
and failed in the emulator, because the unit harness had `?/init.lua` on the
path and KOReader does not.

@module spec.integration.plugin_loading
]]

local Helper = require("spec.support.helper")

describe("KaraBridge inside KOReader", function()
    describe("module loading", function()
        -- The list is written out rather than discovered so that deleting a
        -- module is a deliberate edit here too, and a module that quietly
        -- stops being required still has to keep loading.
        local modules = {
            "karabridge.api.bookmarks",
            "karabridge.api.client",
            "karabridge.api.highlights",
            "karabridge.api.lists",
            "karabridge.api.tags",
            "karabridge.config.config_file",
            "karabridge.config.defaults",
            "karabridge.config.paths",
            "karabridge.config.settings",
            "karabridge.config.validation",
            "karabridge.features.article_download.downloader",
            "karabridge.features.automation",
            "karabridge.features.article_download.library",
            "karabridge.features.article_download.menu",
            "karabridge.features.article_download.sources",
            "karabridge.features.article_sync.annotations",
            "karabridge.features.article_sync.highlight_sync",
            "karabridge.features.article_sync.identity",
            "karabridge.features.article_sync.offsets",
            "karabridge.features.article_sync.reconcile",
            "karabridge.features.article_sync.status",
            "karabridge.features.article_sync.uploader",
            "karabridge.features.book_export.card",
            "karabridge.features.book_export.exporter",
            "karabridge.features.book_export.menu",
            "karabridge.features.connection_test",
            "karabridge.features.link_capture",
            "karabridge.features.queue.manager",
            "karabridge.features.queue.menu",
            "karabridge.features.queue.store",
            "karabridge.features.menu.config_file_menu",
            "karabridge.features.menu.download_folder",
            "karabridge.features.menu.list_picker",
            "karabridge.features.menu.main_menu",
            "karabridge.features.menu.server_settings",
            "karabridge.features.connectivity",
            "karabridge.features.progress",
            "karabridge.features.sync",
            "karabridge.features.update.check",
            "karabridge.features.update.install",
            "karabridge.features.update.menu",
            "karabridge.formats.epub_builder",
            "karabridge.formats.html_cleaner",
            "karabridge.formats.book_card_body",
            "karabridge.formats.markdown_html",
            "karabridge.shared.filesystem",
            "karabridge.shared.hashing",
            "karabridge.shared.json",
            "karabridge.shared.logging",
            "karabridge.shared.metadata",
            "karabridge.shared.notification",
            "karabridge.shared.paths",
            "karabridge.runtime",
            "karabridge.shared.recovery",
            "karabridge.shared.result",
            "karabridge.shared.text",
            "karabridge.shared.url",
            "karabridge.shared.version",
            "karabridge.api.github",
        }

        for _, name in ipairs(modules) do
            it("loads " .. name, function()
                local ok, module = pcall(require, name)
                assert.is_true(ok, name .. ": " .. tostring(module))
                assert.is_table(module)
            end)
        end
    end)

    describe("_meta.lua", function()
        local meta = dofile(Helper.plugin_dir .. "/_meta.lua")

        it("provides what the plugin manager shows", function()
            assert.is_string(meta.fullname)
            assert.is_string(meta.description)
            assert.is_string(meta.version)
        end)

        it("does not set a name, which PluginLoader deprecates", function()
            assert.is_nil(meta.name)
        end)
    end)

    describe("main.lua", function()
        local plugin = dofile(Helper.plugin_dir .. "/main.lua")

        it("returns a widget KOReader can instantiate", function()
            assert.is_table(plugin)
            assert.equals("karabridge", plugin.name)
            assert.is_function(plugin.init)
            assert.is_function(plugin.addToMainMenu)
        end)

        it("is available in both the file manager and the reader", function()
            -- is_doc_only would hide the whole plugin from the file manager,
            -- where downloading articles is most likely to be started.
            assert.is_false(plugin.is_doc_only)
        end)

        it("handles the settings flush event KOReader sends before suspend", function()
            assert.is_function(plugin.onFlushSettings)
        end)
    end)

    describe("the menu", function()
        local MainMenu = require("karabridge.features.menu.main_menu")

        local function fakePlugin()
            local settings = Helper.settings({
                server_url = "https://karakeep.example.org",
                api_token = "ak1_x",
            })
            return {
                settings = settings,
                version = "0.0.0-test",
                path = Helper.plugin_dir,
                getClient = function()
                    return require("karabridge.api.client").new({})
                end,
            }
        end

        it("builds a menu with a title and children", function()
            local menu = MainMenu.build(fakePlugin())

            assert.is_string(menu.text)
            assert.is_table(menu.sub_item_table)
            assert.is_true(#menu.sub_item_table > 0)
        end)

        it("gives every item something TouchMenu can render", function()
            -- An item with neither text nor text_func renders as a blank row.
            local menu = MainMenu.build(fakePlugin())

            for index, item in ipairs(menu.sub_item_table) do
                local has_label = item.text ~= nil or item.text_func ~= nil
                assert.is_true(has_label, "item " .. index .. " has no label")
            end
        end)

        it("evaluates every text_func without error", function()
            local menu = MainMenu.build(fakePlugin())

            for index, item in ipairs(menu.sub_item_table) do
                if item.text_func then
                    local ok, text = pcall(item.text_func)
                    assert.is_true(ok, "item " .. index .. ": " .. tostring(text))
                    assert.is_string(text)
                end
            end
        end)

        it("never shows the API key in a menu label", function()
            local menu = MainMenu.build(fakePlugin())

            for _, item in ipairs(menu.sub_item_table) do
                local text = item.text or (item.text_func and item.text_func()) or ""
                assert.is_nil(text:find("ak1_x", 1, true))
            end
        end)

        it("builds every submenu", function()
            local plugin = fakePlugin()
            local menu = MainMenu.build(plugin)

            for index, item in ipairs(menu.sub_item_table) do
                if item.sub_item_table_func then
                    local ok, children = pcall(item.sub_item_table_func)
                    assert.is_true(ok, "submenu " .. index .. ": " .. tostring(children))
                    assert.is_table(children)
                    assert.is_true(#children > 0)
                end
            end
        end)
    end)

    describe("the exporter provider", function()
        -- ADR-002. exporter.koplugin snapshots the provider registry in its own
        -- init(), and PluginLoader instantiates alphabetically, so
        -- exporter.koplugin runs before karabridge.koplugin. Registering in our
        -- init() would be too late; it happens at module load instead.
        local Provider = require("provider")

        setup(function()
            -- base.lua requires `device`, which probes SDL and reads
            -- G_reader_settings. That global only exists once KOReader's own
            -- bootstrap has run -- at real runtime long before any export, but
            -- it has to be asked for explicitly in a spec.
            require("commonrequire")

            -- Loading main.lua is what registers, exactly as PluginLoader's
            -- dofile does. Nothing is called on the registered table here,
            -- which is the whole point: at that moment `base` may not be
            -- resolvable yet, so the table hydrates on first use instead.
            dofile(Helper.plugin_dir .. "/main.lua")
        end)

        teardown(function()
            Provider:unregister("exporter", "karabridge")
        end)

        it("is registered by loading main.lua, before any init() runs", function()
            local targets = Provider:getProvidersTable("exporter")
            assert.is_not_nil(targets.karabridge, "KaraBridge did not register as an exporter")
        end)

        it("presents the surface exporter.koplugin expects", function()
            local target = Provider:getProvidersTable("exporter").karabridge
            local BookExporter = require("karabridge.features.book_export.exporter")

            assert.equals("karabridge", target.name, "hydration failed: " .. tostring(BookExporter.hydrationError()))
            assert.is_function(target.export)
            assert.is_function(target.isReadyToExport)
            assert.is_function(target.getMenuTable)
            assert.is_true(target.is_remote)
        end)

        it("inherits BaseExporter's behaviour rather than reimplementing it", function()
            local target = Provider:getProvidersTable("exporter").karabridge

            -- getVersion and isEnabled come from base.lua; if the hydration
            -- failed these would be nil.
            assert.matches("^karabridge/", target:getVersion())
            assert.is_function(target.saveSettings)
        end)

        it("reports itself unready before the plugin is initialised", function()
            -- Runtime has no plugin attached in this spec, so KOReader greys
            -- the target out rather than letting an export fail at the end.
            local target = Provider:getProvidersTable("exporter").karabridge
            assert.is_false(target:isReadyToExport())
        end)

        it("builds a menu entry", function()
            local target = Provider:getProvidersTable("exporter").karabridge
            local entry = target:getMenuTable()

            assert.is_table(entry)
            assert.is_string(entry.text)
        end)
    end)

    describe("against the real filesystem", function()
        -- Regression. lfs.dir returns two values -- an iterator and the
        -- directory object it needs as state. Keeping only the first raises
        -- "directory metatable expected, got nil" on the first call. The mock
        -- returned a bare closure, so the unit suite passed and the first real
        -- download crashed.
        local Filesystem = require("karabridge.shared.filesystem")
        local Library = require("karabridge.features.article_download.library")

        local dir = "/tmp/karabridge-integration-fs"

        setup(function()
            Filesystem.setBackend(nil)
            os.execute("rm -rf " .. dir .. " && mkdir -p " .. dir .. "/sub")
            for _, name in ipairs({
                "[kb-id_abc] An Article.epub",
                "[xx-id_xyz] Another Plugin Article.epub",
                "Ordinary Book.epub",
            }) do
                local handle = io.open(dir .. "/" .. name, "w")
                handle:write("x")
                handle:close()
            end
            local nested = io.open(dir .. "/sub/[kb-id_deep] Nested.epub", "w")
            nested:write("x")
            nested:close()
        end)

        teardown(function()
            os.execute("rm -rf " .. dir)
        end)

        it("lists a real directory", function()
            local entries = Filesystem.listDirectory(dir)
            assert.is_true(#entries >= 3, "expected entries, got " .. #entries)
        end)

        it("excludes . and ..", function()
            for _, entry in ipairs(Filesystem.listDirectory(dir)) do
                assert.is_true(entry ~= "." and entry ~= "..")
            end
        end)

        it("indexes only our own articles, including nested ones", function()
            local index = Library.index(dir)

            assert.equals(dir .. "/[kb-id_abc] An Article.epub", index.abc)
            assert.equals(dir .. "/sub/[kb-id_deep] Nested.epub", index.deep)
            assert.is_nil(index.xyz, "another plugin's file must not be claimed")
            assert.equals(2, Library.count(index))
        end)
    end)

    describe("against the real JSON module", function()
        -- Regression, and the reason this block exists at all: KOReader's
        -- `json` exports decode/encode as tables with a __call metamethod. A
        -- `type(x) == "function"` codec check rejects it, and the plugin then
        -- reports every response as malformed -- against a live Karakeep that
        -- was answering 200 with valid JSON. No mock catches this, because a
        -- mock made of plain functions is a shape the real module does not
        -- have.
        local Json = require("karabridge.shared.json")

        setup(function()
            Json.setCodec(nil)
        end)

        it("finds and uses KOReader's json module", function()
            local decoded, err = Json.decode('{"id":"abc","name":"Ada"}')

            assert.is_nil(err)
            assert.is_table(decoded)
            assert.equals("abc", decoded.id)
            assert.equals("Ada", decoded.name)
        end)

        it("strips the null sentinel KOReader's decoder actually produces", function()
            -- Decoded null is a *function* here, which is truthy. This is the
            -- concrete case shared/json.lua:stripNulls exists for.
            local decoded = Json.decode('{"name":"Ada","image":null}')

            assert.is_nil(decoded.image)
            assert.equals("none", decoded.image or "none")
        end)

        it("encodes a request body", function()
            local encoded, err = Json.encode({ type = "text", text = "hello" })

            assert.is_nil(err)
            assert.is_string(encoded)
            assert.equals("hello", Json.decode(encoded).text)
        end)

        it("reports malformed input rather than throwing", function()
            local decoded, err = Json.decode("{not json")

            assert.is_nil(decoded)
            assert.is_string(err)
        end)
    end)

    describe("against the real DataStorage", function()
        local ConfigPaths = require("karabridge.config.paths")

        it("produces absolute config paths", function()
            for _, path in ipairs(ConfigPaths.candidates(nil)) do
                assert.matches("^/", path)
            end
        end)

        it("names a settings file distinct from the other two plugins", function()
            local path = ConfigPaths.settingsFile()
            assert.matches("karabridge%.lua$", path)
        end)
    end)

    describe("against the real DocSettings", function()
        local Metadata = require("karabridge.shared.metadata")
        local DocSettings

        local book = "/tmp/karabridge-integration/book.epub"

        setup(function()
            -- DocSettings reads G_reader_settings, which only exists once
            -- KOReader's own test bootstrap has run. KOReader's specs pull it
            -- in the same way (see spec/unit/pluginloader_spec.lua).
            require("commonrequire")
            DocSettings = require("docsettings")

            os.execute("mkdir -p /tmp/karabridge-integration")
            local handle = io.open(book, "w")
            handle:write("not really an epub")
            handle:close()
        end)

        teardown(function()
            DocSettings:open(book):purge()
            os.execute("rm -rf /tmp/karabridge-integration")
        end)

        it("round-trips through a real .sdr sidecar", function()
            Metadata.write(book, { book_card = { bookmark_id = "b1", content_hash = "abc" } })

            local read = Metadata.read(book)
            assert.equals("b1", read.book_card.bookmark_id)
            assert.equals("abc", read.book_card.content_hash)
            assert.equals(Metadata.SCHEMA_VERSION, read.version)
        end)

        it("survives being closed and reopened", function()
            Metadata.write(book, { article = { bookmark_id = "a1" } })

            -- A fresh DocSettings read, not the cached handle: this is what
            -- happens after a restart, which is the case that matters.
            local reopened = DocSettings:open(book):readSetting("karabridge")
            assert.equals("a1", reopened.article.bookmark_id)
        end)

        it("adopts a bookmark ID left by an older integration", function()
            local doc_settings = DocSettings:open(book)
            doc_settings:delSetting("karabridge")
            doc_settings:saveSetting("karakeep", { bookmark = { id = "legacy1" } })
            doc_settings:flush()

            assert.equals("legacy1", Metadata.getBookCardId(book))
        end)
    end)
    describe("against the real socketutil", function()
        -- socketutil's timeouts are process-global: set_timeout writes
        -- http.TIMEOUT and the values socketutil.tcp -- monkey-patched over
        -- socket.tcp itself -- gives every socket KOReader opens afterwards.
        -- Leaving them set would not break KaraBridge. It would break every
        -- other part of KOReader that opens a connection, which is a far worse
        -- failure because nothing there would point back at this plugin.
        local Client = require("karabridge.api.client")
        local socketutil = require("socketutil")

        local function assertRestored()
            assert.equals(socketutil.DEFAULT_BLOCK_TIMEOUT, socketutil.block_timeout)
            assert.equals(socketutil.DEFAULT_TOTAL_TIMEOUT, socketutil.total_timeout)
        end

        after_each(function()
            socketutil:reset_timeout()
        end)

        it("restores the shared timeouts after a request that cannot connect", function()
            local client = Client.new({
                server_url = "https://karabridge.invalid",
                api_token = "x",
                sleep = function() end,
            })

            assert.equals("unreachable", client:get("/bookmarks"):errorCode())
            assertRestored()
        end)

        it("restores them after an image fetch that raises", function()
            -- The image fetcher sets the same process-global timeouts as the
            -- API client, and for a long time reset them only on the happy
            -- path. Same guarantee, same reason.
            local EpubBuilder = require("karabridge.formats.epub_builder")
            local http = require("socket.http")
            local real_request = http.request

            EpubBuilder.setFetcher(nil)
            http.request = function()
                error("a synthetic failure from deep inside LuaSocket")
            end

            local fetched = EpubBuilder.fetchImages({ { src = "https://karabridge.invalid/a.png" } }, {})

            http.request = real_request

            assert.equals(0, #fetched)
            assertRestored()
        end)

        it("caps how much of one image is kept", function()
            local EpubBuilder = require("karabridge.formats.epub_builder")
            assert.is_true(EpubBuilder.MAX_IMAGE_BYTES > 0)
        end)

        it("restores them even when the HTTP call raises", function()
            local http = require("socket.http")
            local real_request = http.request
            http.request = function()
                error("a synthetic failure from deep inside LuaSocket")
            end

            local client = Client.new({ server_url = "https://karabridge.invalid", api_token = "x" })
            local result = client:get("/bookmarks")

            http.request = real_request

            assert.is_true(result:isErr())
            assertRestored()
        end)
    end)
    describe("carrying the configuration through an update", function()
        -- The step that exists so an update does not delete the user's API
        -- key. It read a Result and handed it to writeFile as if it were a
        -- string, which crashed the install with "string expected, got table"
        -- -- and only for the people it was written to protect. The unit specs
        -- could not see it: their filesystem mock stands in for lfs, not for
        -- io, so readFile and writeFile were never really called.
        local Install = require("karabridge.features.update.install")
        local lfs = require("libs/libkoreader-lfs")

        local root = require("datastorage"):getDataDir() .. "/karabridge-update-test"
        local paths = { live = root .. "/live", staging = root .. "/staging" }

        before_each(function()
            os.execute(string.format("rm -rf %q", root))
            lfs.mkdir(root)
            lfs.mkdir(paths.live)
            lfs.mkdir(paths.staging)
        end)

        after_each(function()
            os.execute(string.format("rm -rf %q", root))
        end)

        local function write(path, content)
            local handle = assert(io.open(path, "w"))
            handle:write(content)
            handle:close()
        end

        local function read(path)
            local handle = io.open(path, "r")
            if not handle then
                return nil
            end
            local content = handle:read("*a")
            handle:close()
            return content
        end

        it("copies a configuration that lives in the plugin folder", function()
            write(paths.live .. "/karabridge.conf", "api_token = secret\nserver_url = https://x\n")

            assert.is_true(Install.carryConfiguration(paths))
            assert.equals(
                "api_token = secret\nserver_url = https://x\n",
                read(paths.staging .. "/karabridge.conf")
            )
        end)

        it("says nothing happened when there is none to carry", function()
            assert.is_false(Install.carryConfiguration(paths))
            assert.is_nil(read(paths.staging .. "/karabridge.conf"))
        end)
    end)
end)
