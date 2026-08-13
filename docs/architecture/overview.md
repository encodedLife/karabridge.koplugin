# KaraBridge architecture

Companion documents: [configuration](configuration.md), [metadata](metadata.md),
[synchronization](synchronization.md).

## What the plugin is

A two-way bridge between a Karakeep server and KOReader:

```
Karakeep articles and bookmarks
        ↓
    KaraBridge
        ↕
     KOReader
        ↑
Local ebook highlights, notes and reading status
```

It is intended to be the only Karakeep integration a device needs: article
download, reading-status and highlight sync, and local book export in one
plugin, so none of it has to be split across two.

## Layout

```
karabridge.koplugin/          ← the installable plugin, and nothing else
├── _meta.lua
├── main.lua                  ← small by policy
└── karabridge/
    ├── api/                  transport and Karakeep resources
    │   ├── client.lua        URLs, headers, retries, JSON, error translation
    │   ├── bookmarks.lua
    │   ├── highlights.lua
    │   ├── lists.lua
    │   └── tags.lua
    ├── config/
    │   ├── defaults.lua      THE schema: every setting, once
    │   ├── config_file.lua   karabridge.conf parser and template
    │   ├── paths.lua         where the config file is looked for
    │   ├── validation.lua    is this value acceptable
    │   └── settings.lua      the store, seeding and precedence
    ├── features/
    │   ├── article_download/  scope, pagination, the local index, the run
    │   ├── article_sync/      status, highlight matching, the upload run
    │   ├── book_export/       one Karakeep card per book, and the provider
    │   ├── queue/             the versioned store and the handler dispatch
    │   ├── menu/              the menu, split by what each part configures
    │   ├── automation.lua     Wi-Fi sync and the Dispatcher actions
    │   ├── connection_test.lua
    │   ├── link_capture.lua   "Save to Karakeep" on a tapped link
    │   └── sync.lua           queue -> upload -> download -> clean up
    ├── formats/
    │   ├── epub_builder.lua   crengine balancing and zip assembly
    │   ├── html_cleaner.lua   sanitising crawled HTML, collecting images
    │   ├── book_card_body.lua the body and title a new book card starts with
    │   └── markdown_html.lua  the markdown fallback for articles
    ├── runtime.lua            the seam a load-time registration needs
    └── shared/
        ├── result.lua        ok/err with a stable code
        ├── logging.lua       prefixed logging, and secret masking
        ├── json.lua          decode, encode, null-sentinel stripping
        ├── text.lua          pure string helpers
        ├── url.lua           normalisation, validation, query building
        ├── paths.lua         pure path and filename helpers
        ├── filesystem.lua    the disk-touching half
        ├── hashing.lua       FNV-1a, for change detection
        ├── metadata.lua      versioned .sdr sidecar access
        └── notification.lua  toast vs modal
```

Everything outside `karabridge.koplugin/` is development-only:
`spec/`, `scripts/`, `docs/`. Installation is copying that one directory into
`<KOReader>/plugins/`.

### Layer rules

```
main.lua
   ↓
features/          may use api, config, shared. May touch UI.
   ↓
api/               may use shared. Never touches UI.
config/            may use shared. Never touches UI.
   ↓
shared/            may use other shared modules. Never touches UI or network.
```

Enforced by review rather than tooling, but the shape makes violations obvious:
a `require("ui/…")` in `api/` or `shared/` is wrong.

Two hard rules behind that:

- **A module that has to be tested off-device must not require a KOReader
  module at load time.** `socketutil` alone pulls in the device stack, which
  probes SDL and wants a display. Where a dependency is unavoidable it is
  required lazily inside the function that needs it
  (`api/client.lua:_socketRequest`) or injected through a `setBackend` seam.
- **Only `features/` may show anything.** Welding notification calls into an
  HTTP client makes the client untestable and takes the decision "should this
  failure be visible" away from the caller.

## Decision records

Each records the context, what was decided, what else was considered, and what
it costs.

### ADR-001 — `karabridge.conf` seeds; it does not override

**Context.** A config file is what makes the plugin usable at all: typing a
Karakeep API key on an e-reader keyboard is miserable. But a file and a settings
menu editing the same values need a precedence rule.

**Decision.** The file *seeds*. At startup, every key in the file that is not
already set on the device is written to the device store. Anything already set
is left alone. The device store wins from then on. The single exception is the
explicit **Reload it now** action, which applies the file over the store.

**Alternatives.** (a) File always authoritative: rejected — a setting changed
in the menu silently reverts at the next restart, with the menu showing the
user's value until then. (b) File as fallback, never written to
the store: rejected — `originOf()` becomes unanswerable and the diagnostics
dump cannot say where a value came from.

**Consequences.** Editing the file after first run does nothing until reload,
which must be said clearly in the menu's help text and is. Seeding must run
before anything reads a setting with a default, because `LuaSettings` writes
defaults back; `Settings:get` never passes a default to the store, and
`main.lua` seeds first regardless.

**Tests.** `spec/unit/settings_spec.lua`, "seeding from the config file" and
"reloading the config file". Verified end to end in the emulator: first run
seeds 3, second run keeps 3.

### ADR-002 — the exporter provider registers at module load, not in `init()`

**Context.** KOReader's highlight exporter discovers third-party targets
through `frontend/provider.lua`. `exporter.koplugin` snapshots the registry in
`Exporter:init()` (`genExportersTable`, `main.lua:91,124`).

`PluginLoader:loadPlugins()` sorts with `sortProvidersFirst` for the `dofile`
pass, then **re-sorts `enabled_plugins` by path** (`pluginloader.lua:288`).
Instantiation is therefore alphabetical, and `exporter.koplugin` sorts before
`karabridge.koplugin`.

**Decision.** Register the exporter provider at the top level of `main.lua`, so
it happens during `PluginLoader:_load` — strictly before any `Exporter:init()`.

**Alternatives.** (a) Register in `init()`: rejected, it is too late for the
first UI instance of a session and only
appears to work because the registry is a module-level singleton that survives
into the next instantiation. (b) Rename the directory to
`provider-karabridge.koplugin`: rejected — it would make the plugin's own
`sortProvidersFirst` bucket correct but change the plugin's `name`, its settings
key and its menu key, and the prompt fixes the directory name.

**Consequences.** The provider object cannot hold a `ui` reference at
construction, because there is no UI yet. It reads what it needs from a
module-level service registry, refreshed by `init()`.

**Status.** Implemented. `main.lua` calls `BookExporter.register()` at module
load. `require("base")` does not resolve that early — PluginLoader appends every
plugin's directory only after all of them are loaded — so the registered table
hydrates itself into a BaseExporter-derived object on first access.
`spec/integration/plugin_loading_spec.lua` covers registration, hydration and
the inherited surface, and `Exporter.hydrationError()` reports why it failed
rather than the target silently never appearing.

### ADR-003 — `Result` instead of positional error returns

**Context.** Failures can be returned as `(false, "network_error", 503)` or as
`(nil, Error.new("Unauthorized - please check…"))`. The first has no message,
the second no stable code, so callers wanting to branch on *why* something
failed end up matching on English prose.

**Decision.** One `Result` type: `Result.ok(value)` and
`Result.err(code, message, details)`. The code is the contract; the message is
for humans and may be reworded freely; `details` is for the log.

**Alternatives.** Lua's `nil, err` idiom: rejected because `nil` is a legitimate
success value for a DELETE.

**Consequences.** Every API function returns a Result, which is slightly more
verbose at each call site and much less verbose at each error site. Error codes
are listed in `api/client.lua`.

### ADR-004 — the store is injected; so are lfs, DocSettings, DataStorage, JSON and the logger

**Context.** The two reference plugins are largely untestable off-device
because their modules require KOReader at load time.

**Decision.** Every KOReader dependency in `shared/` and `config/` resolves
through a lazy `pcall(require, …)` with a `setBackend()` override. The HTTP
call in `api/client.lua` is a constructor parameter.

**Alternatives.** `package.preload` shims, as the prompt suggests: used in
addition, not instead — a `setBackend` seam is visible in the module's own
source, so the next reader can see the module was designed to be tested rather
than having a test reach into it.

**Consequences.** 311 unit tests run under a plain `lua5.1` in well under a
second, with no KOReader, no network and no temporary `.sdr` directories.

The risk is a mock drifting from the real thing, and it is not theoretical.
The JSON mock exposed `decode` as a plain function; KOReader's `json` exposes
it as a *table with a `__call` metamethod*. The codec check tested for a
function, rejected the real module, and the plugin reported every response as
malformed against a live server answering 200 with valid JSON — while the unit
suite stayed green. That is exactly why the KOReader-hosted suite in
`spec/integration/` re-checks the same behaviour against the real DocSettings,
DataStorage and `json`.

### ADR-005 — one schema table describes every setting

**Context.** A setting easily ends up listed in four places — a schema, a
loader, a flush handler and the menu. Forgetting the flush handler produces a
setting that works until you restart.

**Decision.** `config/defaults.lua` holds type, default, group, description,
bounds and a `secret` flag for every setting. The parser, the validator, the
example-file generator and the diagnostics dump are all derived from it.

**Consequences.** Adding a setting is one table entry.
`spec/unit/config_spec.lua` asserts the generated template mentions every key
and that every default passes validation, so the derivation cannot silently
break.

### ADR-006 — FNV-1a for content hashing, and it is not a digest

**Context.** "Has this book's Markdown changed since I last sent it" needs a
fingerprint. A cryptographic hash needs a C library that is not present on
every device.

**Decision.** FNV-1a, pure Lua, two 32-bit passes rendered as 16 hex
characters. Anchored on the published reference vectors in
`spec/unit/hashing_spec.lua` so a refactor of the wrapping arithmetic cannot
silently break it.

**Consequences.** Not collision-resistant and must never be used for anything
security-relevant. A collision means one export is skipped that should have
run — recoverable by editing the book.

### ADR-007 — no internal event bus

**Context.** Internal messages could be broadcast through
`UIManager:broadcastEvent`, as KOReader's own events are.

**Decision.** Modules call each other directly. Events are used only for
KOReader's own (`onFlushSettings`, `onNetworkConnected`, `onDispatcher…`).

**Consequences.** Control flow is greppable. A future feature that genuinely
needs decoupling can still use KOReader's bus.

### ADR-008 — no `?/init.lua`

**Context.** `PluginLoader:_load` sets `package.path` to `plugin_root/?.lua`
and nothing else. A module at `features/x/init.lua` does not resolve.

**Decision.** A single-file feature is `features/x.lua`. A multi-file feature is
a directory with an explicitly named entry point, e.g.
`features/book_export/exporter.lua`.

**Consequences.** `spec/support/helper.lua` mirrors PluginLoader's path exactly
so a spec cannot pass on a layout the device would reject. This was found the
hard way: the specs were green and the emulator refused to load the plugin.

## Security

- **Tokens.** Built into a header in `Client:buildHeaders` and never passed to
  the logger. `Logging.mask()` reveals at most the last four characters, and
  nothing at all from a short value. `Logging.maskUrl()` strips userinfo.
  `spec/unit/api_client_spec.lua` asserts that after a run of successful and
  failed requests, neither the token nor the string `Bearer` appears in
  anything logged — an assertion that also catches the next person's
  `logger.dbg("request", request)`. Logging a request table wholesale writes
  the key to the log at debug level; that is the bug this guards against.
- **Server URLs** are validated: http/https only, a host required, embedded
  credentials refused. Plain http is permitted — a Karakeep on a home LAN is
  normal — but the connection test says once that the key travels unencrypted.
- **Path traversal.** Article titles and image URLs are remote-controlled.
  `Paths.resolveInside(root, relative)` returns nil rather than a path outside
  the root, and refuses an absolute "relative" path.
- **Filenames** are sanitised for FAT32 and truncated without splitting a UTF-8
  sequence.
- **Retries are capped** at two, so a dead server is reported rather than
  hanging the device.
- **TLS.** KOReader ships its own CA bundle and refuses an unknown issuer; a
  self-signed certificate surfaces as "the server could not be reached".
  KaraBridge does not and will not offer a "skip certificate verification"
  setting.

## Testing

Five layers, cheapest first. Full detail in [`../testing.md`](../testing.md).

| Layer | Command | Needs |
|---|---|---|
| Static checks | `scripts/check.sh` | luac, luacheck, shellcheck, stylua |
| Unit | `scripts/test-unit.sh` | any Lua 5.1 |
| KOReader-hosted | `scripts/test-koreader.sh` | a built KOReader |
| Emulator smoke | `spec/smoke/emulator_checklist.md` | a built KOReader |
| Karakeep integration | `scripts/test-integration.sh` | a test Karakeep |

## Roadmap

What each area covers:

1. **Article download** — `features/article_download/`,
   `formats/{html_cleaner,epub_builder}.lua`. Pagination, filtering, image
   embedding, EPUB assembly, filename and image collision prevention.
2. **Article sync** — `features/article_sync/`. Reading status, archiving,
   highlight push with duplicate prevention.
3. **Local book export** — `features/book_export/`,
   `formats/book_card_body.lua`. One text card per book, created once and then
   left alone -- the body is the user's -- plus real Karakeep highlights, a
   cover, and recreate-if-deleted on a confirmed 404. Registers the exporter
   provider (ADR-002).
4. **Queue** — `features/queue/`. Versioned, with attempt counts, last error
   and corruption recovery.
5. **Automation** — sync on Wi-Fi connect, Dispatcher actions.

All of it is verified in the emulator, against a live Karakeep, and on a Kobo.
Devices other than that Kobo remain untested.
