# Testing

Five layers, cheapest first. Run the first two on every change; the rest before
anything that touches a device.

| # | Layer | Command | Needs | Current |
|---|---|---|---|---|
| 1 | Static checks | `scripts/check.sh` | luac, luacheck, shellcheck, stylua | clean |
| 2 | Unit | `scripts/test-unit.sh` | any Lua 5.1 | 834 passing |
| 3 | KOReader-hosted | `scripts/test-koreader.sh` | a built KOReader | 92 passing |
| 4 | Emulator smoke | `spec/smoke/emulator_checklist.md` | a built KOReader | manual |
| 5 | Karakeep integration | `scripts/test-integration.sh` | a test Karakeep | 21 passing |
| 6 | Real device | manual | a Kobo | done on a Kobo Libra Colour |

There is no KOReader plugin SDK, so these are deliberately combined: KaraBridge
owns layers 1, 2 and 5; layers 3 and 4 borrow KOReader's own infrastructure.

## 1. Static checks

```bash
scripts/check.sh          # report
scripts/check.sh --fix    # let stylua rewrite
```

Four things, each skipped with a note when the tool is absent:

- **`luac -p`** — syntax, every Lua file.
- **`luac -l -p | grep SETGLOBAL`** — accidental globals. An assignment without
  `local` is accepted silently by Lua and then leaks between plugins sharing
  one Lua state. KOReader's own Makefile does the same check.
- **luacheck**, configured by `.luacheckrc`. The only KOReader globals declared
  are `G_reader_settings` and `G_defaults`, both read-only: writing to them
  from a plugin leaks state.
- **shellcheck** on `scripts/*.sh`, **stylua --check** on the Lua.

`./kodev check` inside the KOReader checkout also works, but it lints all of
KOReader as well, which buries our output.

## 2. Unit tests

```bash
scripts/test-unit.sh              # everything
scripts/test-unit.sh config       # only specs matching "config"
KARABRIDGE_LUA=luajit scripts/test-unit.sh
```

No KOReader, no network, no temporary directories except where the point is the
filesystem. The whole suite runs in well under a second.

### Busted, and the fallback

The specs are written in **busted syntax**, because that is what KOReader's
test suite uses and a spec should be movable between the two without editing.

`test-unit.sh` uses busted when it is on `PATH`. Otherwise it falls back to
`spec/support/busted_lite.lua`, a small harness implementing the subset the
pure-Lua specs use: `describe`/`it`/`setup`/`teardown`/`before_each`/
`after_each`/`pending`, and `assert.` with `is_true`, `is_false`, `is_nil`,
`is_not_nil`, `is_table`, `is_string`, `is_number`, `truthy`, `falsy`,
`is_function`, `is_boolean`, `equals`, `same` (deep), `matches`, `has_error`.

Anything outside that list — `spy`, `mock`, `assert.is_not.same` — raises
"busted_lite does not implement …" rather than silently passing. A spec needing
those belongs in layer 3, where the real busted is available.

The busted bundled in KOReader's build **cannot be invoked directly**: it fails
on `pl.utils` because its LuaRocks tree is only complete relative to the
emulator directory. Layer 3 runs it correctly.

### Coverage

Against the coverage list in the project prompt:

| Required | Spec |
|---|---|
| Config file discovery | `config_paths_spec` |
| Config precedence | `settings_spec` |
| Config reload | `settings_spec` |
| Folder picker boundary | `download_folder` via `plugin_loading_spec` |
| Selected folder persistence | `settings_spec` + emulator |
| Selected path display | `plugin_loading_spec` (menu labels) |
| Picker cancellation | by construction; noted in `download_folder.lua` |
| Selected folder validation | `filesystem_spec` |
| Missing folder behaviour | `filesystem_spec` |
| Unwritable folder behaviour | `filesystem_spec` |
| Token masking | `logging_spec`, `settings_spec` |
| URL normalisation | `url_spec` |
| API request construction | `api_client_spec`, `api_resources_spec` |
| Authorization header not logged | `api_client_spec`, `connection_test_spec` |
| API error translation | `api_client_spec` |
| Pagination | `api_client_spec` (`collect`) |
| Bookmark creation | `api_resources_spec` |
| Bookmark update | `api_resources_spec` |
| Bookmark-not-found | `api_resources_spec` |
| Highlight creation | `api_resources_spec` |
| Metadata read/write | `metadata_spec` + `plugin_loading_spec` |
| Metadata schema migration | `metadata_spec` |
| Duplicate prevention | `api_resources_spec` (`existingTexts`) |
| Path traversal prevention | `paths_spec` |
| Content hashing | `hashing_spec` |
| Filenames | `paths_spec` |
| Queue persistence / retry / corruption | `queue_spec` |
| Markdown rendering (articles) | `markdown_html_spec` |
| Chapter grouping (book cards) | `book_export_spec` |
| EPUB filenames, image filenames | `paths_spec`, `html_cleaner_spec`, `epub_builder_spec` |
| Unchanged export detection | `book_export_spec` |

Every row in the brief's coverage list is now covered by a spec.

### How the mocks work

Mocked **only at external boundaries**, through seams the modules expose
deliberately:

```lua
require("karabridge.config.paths").setBackend(mock_datastorage)
require("karabridge.shared.filesystem").setBackend(mock_lfs)
require("karabridge.shared.json").setCodec(mock_json)
require("karabridge.shared.logging").setBackend(mock_logger)
require("karabridge.shared.metadata").setBackend(mock_docsettings)
```

`Helper.install()` does all five and `Helper.uninstall()` undoes them, so one
spec cannot make another pass for the wrong reason.

`spec/mocks/`:

| Mock | Notable |
|---|---|
| `luasettings` | Faithfully writes a default back on `readSetting(k, default)` — the behaviour config seeding has to work around |
| `datastorage` | Three directories; nothing created on disk |
| `docsettings` | Per-document tables, plus a flush counter so "did this persist, and how often" is assertable |
| `filesystem` | In-memory lfs. `readFile`/`writeFile` go through `io.open` and are tested against a real temp directory instead |
| `logger` | Captures every line, so the token-leak assertion has something to search |
| `json` | Decodes `null` to a **function**, exactly as KOReader does — a mock decoding it to nil would make the null-stripping specs vacuous |

`spec/support/helper.lua` sets `package.path` to **exactly**
`plugin_root/?.lua`, matching `PluginLoader:_load`, and deliberately *not*
`?/init.lua`. This is not pedantry: the first draft had `?/init.lua`, the specs
were green, and the emulator refused to load the plugin because
`features/connection_test/init.lua` does not resolve on device.

## 3. KOReader-hosted tests

```bash
scripts/test-koreader.sh
scripts/test-koreader.sh /path/to/koreader
scripts/test-koreader.sh --keep    # leave the copied specs in place
```

For what a mock cannot honestly answer. `spec/integration/plugin_loading_spec.lua`
checks:

- every module resolves under PluginLoader's exact `package.path`;
- `_meta.lua` is valid and does **not** set `name` (deprecated);
- `main.lua` evaluates to something KOReader can instantiate;
- every menu item has a label, every `text_func` evaluates, every submenu
  builds, and no label contains the API key;
- `DataStorage` yields absolute paths;
- sidecar metadata round-trips through the **real** DocSettings, survives a
  reopen, and adopts a legacy sidecar record.

The script copies the spec files into `<emulator>/koreader/spec/front/unit/`,
runs KOReader's own busted the way `base/test-runner/runtests` does, and removes
them again — the KOReader checkout is a reference copy and must not accumulate
our files. Only the spec files are copied; the support tree is reached through
`LUA_PATH`, so there is one copy of it.

**Requires a built KOReader** (`./kodev build`) — the AppImage has no test tree.

A spec that touches DocSettings must `require("commonrequire")` first, because
DocSettings reads `G_reader_settings`, which only exists once KOReader's test
bootstrap has run. KOReader's own `spec/unit/pluginloader_spec.lua` does the
same.

## 4. Emulator smoke tests

Checklist: [`../spec/smoke/emulator_checklist.md`](../spec/smoke/emulator_checklist.md).

```bash
scripts/link-plugin.sh
cd "$KARABRIDGE_KOREADER"/koreader-emulator-*/koreader
./luajit reader.lua 2>&1 | tee /tmp/karabridge-koreader.log
grep -i karabridge /tmp/karabridge-koreader.log
```

With a working X11 display this needs nothing further. Without one:

```bash
xvfb-run -a -s "-screen 0 600x800x24" ./luajit reader.lua
```

For device screen simulations, `./kodev run -s=kobo-clara` from the KOReader
root. Profiles verified in this checkout: `kobo-forma`, `kobo-aura-one`,
`kobo-clara`, `kobo-h2o`, `kindle-paperwhite`, `legacy-paperwhite`, `kindle`,
`hidpi`.

`scripts/link-plugin.sh` symlinks into both the source `plugins/` and any built
emulator tree, so `kodev run` and a directly launched emulator agree on which
copy is loaded. It refuses to replace a real directory — most likely a manually
installed copy with the user's `karabridge.conf` in it.

Two lines to look for on every run:

```
KaraBridge: loaded version 0.0.1, main.lua modified 2026-08-10 11:50:14, from plugins/karabridge.koplugin
```

The path and the modification time are what distinguish a fixed copy from a
stale one still sitting in the plugins directory; the version alone does not.

```
KaraBridge:config.settings: seeded 3 setting(s) from ./karabridge.conf; 0 already set on the device and left alone
```

And two that must **not** appear: any Lua stack trace, and any API token.

## 5. Karakeep integration tests

```bash
KARABRIDGE_TEST_SERVER_URL=https://karakeep.test.example.org \
KARABRIDGE_TEST_API_TOKEN=ak1_... \
KARABRIDGE_TEST_ALLOW_WRITES=1 \
  scripts/test-integration.sh
```

Or put the variables in `spec/integration/.env`, which is gitignored.

**Opt-in by construction.** With no variables set the script prints why it did
nothing and exits 0. Without `KARABRIDGE_TEST_ALLOW_WRITES=1` only read-only
checks run.

Rules:

- A Karakeep instance and an API key created **for testing**.
- Everything created is titled `[KaraBridge Test] …` and cleaned up afterwards.
  Nothing without that prefix is touched.
- The token is never echoed; the script prints its length.
- No credentials in git.

`spec/integration/karakeep_api_spec.lua` covers connection and authentication,
a wrong key, a non-Karakeep address, bookmark listing, pagination, text
bookmark create/update/retrieve/delete, archiving, tag attachment, list
filing, highlight creation, colour mapping, zero offsets, the absence of
server-side deduplication, and that the token never reaches the log.

These run on KOReader's `luajit`, not a plain interpreter: they make real
requests and need luasocket, which KOReader ships and a system lua5.1 usually
does not. The script finds a built emulator automatically.

**This layer earns its keep.** It found that `note` and `text` in
`zNewHighlightSchema` are `z.string().nullable()` — nullable but *not*
optional — so omitting either is a 400. Every highlight KaraBridge had sent
until then happened to carry a note, so no unit spec could have seen it: a mock
codec has no opinion about which keys a server requires.

KOReader tests cannot prove compatibility with a real server; this layer is the
only one that can.

## 6. Real-device tests

Nothing above replaces this layer, and it has repeatedly found what the others
could not: the annotations KOReader holds in memory rather than in the sidecar,
an update that could not unpack on the KOReader most people run, a prompt to
connect Wi-Fi on a device already connected. Each was invisible to a green
suite.

Run on a real device before any release. So far that means a Kobo Libra
Colour; another model may well behave differently:

installation by folder copy · settings file discovery · folder picker · touch
interaction · EPUB import · PDF highlight export · EPUB highlight export · WLAN
interruption mid-sync · queue recovery · storage paths on internal and SD ·
memory use on a large highlight set · a large image-heavy article, timed ·
unavailable server · invalid token · restart persistence.

The timing one is the main performance unknown: building EPUBs in Lua on a Kobo
is the slowest thing this plugin does. Compare with *Embed images* off.

## Reporting a run

Never claim tests passed unless they were executed. Report the command, the
environment, the counts, and anything unresolved. For example:

```
$ scripts/test-unit.sh
  lua5.1 + busted_lite, 26 spec files
  676 passed, 0 failed, 0 pending

$ scripts/test-koreader.sh
  KOReader koreader-emulator-x86_64-linux-gnu-debug, busted 2.3.0
  77 passed, 0 failed

$ scripts/check.sh
  luac 51 files ok · no accidental globals · luacheck 0 warnings
  · shellcheck ok · stylua not installed (skipped)
```

## Adding a spec

1. Put it in `spec/unit/` if it needs no KOReader, `spec/integration/` if it
   does.
2. `local Helper = require("spec.support.helper")` first — it fixes
   `package.path`.
3. `Helper.install()` in `before_each`, `Helper.uninstall()` in `after_each`,
   if the module under test has backends.
4. Prefer the injection seam the module already exposes. If there is none,
   that is usually a sign the module should be split, not that the spec needs a
   way in.
5. **For a fixed bug, write the spec first** and watch it fail. Two of the bugs
   found early on — the `cursor and nil or …` pitfall and
   the `?/init.lua` path — were each caught by exactly one assertion, and
   neither would have been noticed by reading the code again.
