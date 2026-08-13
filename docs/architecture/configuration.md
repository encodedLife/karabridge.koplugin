# Configuration

How KaraBridge is configured, where the values come from, and which one wins.

Implemented by `karabridge/config/`: `defaults.lua`, `config_file.lua`,
`paths.lua`, `validation.lua`, `settings.lua`.

## The three sources

| # | Source | Authority |
|---|---|---|
| 1 | Schema defaults, `config/defaults.lua` | lowest |
| 2 | `karabridge.conf` | seeds, once |
| 3 | The device store, `settings/karabridge.lua` | highest |

### Stated exactly

**The file seeds. It does not override.**

At startup `Settings:seedFromConfigFile()` runs. For every key in the file:

- not set on the device → written to the device store, counted as **seeded**;
- already set on the device → left alone, counted as **kept**.

The file is not consulted again for the rest of the session. Whatever the menu
saves wins from that point on.

**The one exception** is the menu action **Settings file → Reload it now**,
which calls `Settings:reloadConfigFile()` and applies every value in the file
over the device store. That is an override, and it is the only one, because the
user asked for it by name.

The log line after startup says which happened:

```
KaraBridge:config.settings: seeded 3 setting(s) from ./karabridge.conf;
    0 already set on the device and left alone
```

### Why not "the file always wins"

Because a setting changed in the menu would silently revert at the next
restart, with the menu continuing to show the user's value until then. The
file-always-wins design looks tidier and is worse in exactly that way.

### Why the file is written into the store rather than kept as a fallback

So that `Settings:originOf(key)` can answer `"file"`, `"device"` or
`"default"`, and the diagnostics dump can say where every value came from. A
pure fallback chain cannot distinguish "the file said 30" from "nobody said
anything and 30 is the default".

### The ordering trap

`LuaSettings:readSetting(key, default)` **writes the default back into the
store**. If anything reads a setting with a default before seeding runs, every
key then looks set and there is no gap left to seed. Ordering `init()`
carefully works around it; closing it properly is better.

KaraBridge closes it from both ends:

- `Settings:get` never passes a default to the store. It checks
  `store:has(key)` and falls back to the schema itself.
- `main.lua` still calls `seedFromConfigFile()` before anything else, so a
  future accidental `readSetting(key, default)` does not reopen the hole.

Covered by `spec/unit/settings_spec.lua`, "does not write a default back when
reading it".

## Where the file is looked for

`config/paths.lua`, in order. First match wins; the rest are not read.

| # | Path | Why here |
|---|---|---|
| 1 | `$KARABRIDGE_CONF` | Development and integration testing only. Lets a spec point at a fixture without touching the user's data directory. Environment variables are not a thing on a Kobo, so this costs nothing on device. |
| 2 | `<data dir>/karabridge.conf` | The primary location. On a Kobo the data directory **is** on the mounted storage partition (`.adds/koreader`), so this is the file a user reaches by plugging the device into a computer — the entire point of supporting a config file. It also survives replacing the plugin folder. |
| 3 | `<settings dir>/karabridge.conf` | Next to KOReader's own settings, for people who keep configuration together. |
| 4 | `<plugin dir>/karabridge.conf` | The folder just copied onto the device, the obvious place to look. Last, because a plugin update overwrites it. |

Only one file is ever used. Merging several would make "which value am I
actually running with" impossible to answer from the menu.

**Settings file → Where KaraBridge looks** shows the list with a tick against
the one in use, and any problems found in it. That menu item exists so that
"why is my file being ignored" does not need a support round trip.

`Settings file → Create an example file` always writes to the **data
directory**, regardless of where a file was found, because the point of the
action is a file the user can reach from a computer.

## Format

```ini
# Comments start with # or ;
; both work, and both need a line of their own

server_url = https://karakeep.example.org
; ":" separates as well as "="
api_token:  ak1_example

filter_tags = read-later, ebook

; quotes around the whole value preserve edge whitespace
archive_tag = " read on kobo "

; true / yes / on / 1, and false / no / off / 0
download_images = true
prefer_archive  = off

articles_per_sync = 30
```

- **There are no trailing comments.** `#` and `;` start a comment only at the
  beginning of a line. `api_token = x  # mine` makes the token `x  # mine`,
  which then fails with an unhelpful 401. A value beginning with `#` or `;` is
  reported as a likely mistake, but never rewritten: a `#` is legitimate inside
  a URL fragment, and guessing where a comment starts would corrupt it.
- One setting per line, value to end of line — a URL needs no quoting.
- Surrounding quotes are stripped, which is the only way to give a value
  meaningful leading or trailing space.
- CRLF is handled, because the file is usually edited on a computer.
- **Unknown keys are reported, not ignored.** A typo in a config file is
  otherwise completely invisible: the setting simply never takes effect and
  there is nothing to see. The problem appears in the log at warning level and
  in the "Where KaraBridge looks" screen.
- One bad line does not discard the rest of the file.
- Keys the plugin manages itself (`last_auto_sync`) are refused with an
  explanatory message rather than reported as unknown.

The example file is **generated from the schema** by `ConfigFile.template()`,
so a new setting appears in it the moment it is added and cannot be forgotten.
Only `server_url` and `api_token` are left uncommented: those two are what the
file exists for, and a user who uncomments nothing else still gets a working
setup rather than a file that overrides two dozen menu choices they never made.
`spec/unit/config_spec.lua` asserts both properties.

## Validation

`config/validation.lua` is pure and is used by both the file parser and the
settings menu, so a value rejected in one place is rejected in the other.

- **Types** — a number setting given text is refused, not coerced.
- **Bounds** — `articles_per_sync` is 1..200, `auto_sync_interval` 5..720, and
  so on, taken from the schema.
- **Enumerations** — `book_card_template` is **deprecated and ignored** since
  0.7: a book card's body is no longer generated from its highlights. The key
  is still parsed and still validated, so an existing `karabridge.conf` keeps
  loading. Its value must be `grouped_by_chapter` or
  `flat`.
- **Server URL** — http or https, a host required, embedded credentials
  refused ("put the API key in the API key field"). An **empty** address is
  accepted: that is "not configured yet", the normal state on first run, and
  not something to complain about.

Whether a folder is *writable* is deliberately **not** here: it depends on the
state of the device, not on the value. That check lives in
`shared/filesystem.lua`.

`Validation.checkReadiness()` answers which capabilities the current
configuration supports — `connect`, `download`, `export_books` — plus a list of
what is missing, so the menu can grey out exactly the actions that will not
work instead of refusing everything the moment one field is blank.

## The download folder

Centralised in `features/menu/download_folder.lua`: the picker, the
persistence and the validation, because three things have to hold together.

**The picker** is KOReader's `ui/downloadmgr`, a wrapper over `PathChooser` and
what KOReader offers for choosing a folder:

```lua
require("ui/downloadmgr"):new({
    title = "Choose the KaraBridge download folder",
    onConfirm = function(path) … end,
}):chooseDir(current_folder)
```

**Cancellation** needs no code. `chooseDir` calls `onConfirm` only on
confirmation; dismissing the chooser calls nothing. There is deliberately no
cancel callback to get wrong.

**Typing a path** is offered as well, never instead. On a Kobo the picker is
the only way to discover where the storage is actually mounted; manual entry is
for a folder the picker cannot reach because it is not mounted at the moment,
and for the emulator.

**Validation runs at selection time** — `Filesystem.checkWritableDirectory`
creates the folder if missing and writes a `.karabridge-write-test` probe. It
also runs before each download, because a folder can become unwritable in
between (an unmounted SD card).

Without the probe, an unwritable folder surfaces only as every single article
failing to build, one confusing line at a time, from deep inside the zip
writer. Under Flatpak an unreachable folder is the *likely* default rather than
an edge case, so the error message names that possibility and gives the
`flatpak info --show-permissions` command.

**A folder that fails the probe is still saved.** It is the folder the user
meant; an SD card not yet mounted is a transient condition, and discarding
their choice to punish it helps nobody. The problem is reported and the setting
kept.

**The selected path is shown in full** in the menu label — on a device with
both internal storage and an SD card, the leading part is the only thing that
distinguishes them, and that is precisely what a user needs to check.

## Secrets

- `api_token` is the only setting marked `secret` in the schema.
- The menu shows `Logging.mask()` of it — six asterisks and the last four
  characters, or `(set, N chars)` when the value is too short for even that to
  be safe.
- The token field uses `text_type = "password"`. An e-reader is frequently read
  in public and the key is long enough that shoulder-surfing it is realistic.
- `Settings:describe()`, behind **Diagnostics → Current settings**, masks the
  token and strips userinfo from the server address, so the whole screen can be
  photographed and sent to someone.
- `karabridge.conf` is in `.gitignore`.
- The generated example file says, in the header, that it contains an API key
  in plain text and that the device should have its own key so it can be
  revoked alone.

## The settings store

`settings/karabridge.lua`, a KOReader `LuaSettings` file.

The name is deliberately its own. Another Karakeep integration may be installed
at the same time, and sharing a settings file would corrupt the other plugin's
settings. `spec/unit/config_paths_spec.lua` asserts the name.

Flushed on `onFlushSettings`, which KOReader sends before suspend and exit, and
immediately after any menu change that matters.

## Adding a setting

One table entry in `config/defaults.lua`:

```lua
my_setting = {
    type = "boolean",
    default = false,
    group = "sync",
    description = "One line, shown as help text and as a comment in the example file.",
},
```

That is the whole change. The parser accepts it, the validator checks it, the
example file documents it, and the diagnostics dump reports it. Add a menu item
if the user should be able to change it on the device.
