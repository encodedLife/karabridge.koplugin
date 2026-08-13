# KaraBridge

A KOReader plugin that bridges [Karakeep](https://karakeep.app) and KOReader in
both directions.

```
Karakeep articles and bookmarks
        ↓
    KaraBridge
        ↕
     KOReader
        ↑
Local ebook highlights, notes and reading status
```

One plugin for both halves:

- **Articles come down** as EPUBs, with images embedded, filtered to a Karakeep
  list or to tags if you want.
- **What you do with them goes back up** — reading progress, highlights, notes —
  and an article can archive itself in Karakeep once you have finished it.
- **Highlights synchronise both ways.** A note edited in Karakeep returns to the
  matching KOReader annotation, and the same sentence highlighted twice stays
  two distinct highlights.
- **Your own EPUB and PDF books** become one editable Karakeep card each, with
  every marked passage attached as a real Karakeep highlight and the cover
  uploaded alongside.
- **It updates itself** from a GitHub release, so a new version does not need a
  USB cable.

It is written to be careful with the things that are easy to lose: your
annotations, your notes, and anything you have written in Karakeep by hand. What
it will *not* do is spelled out under [Known limitations](#known-limitations).

> **Version 0.0.1** — the first public release.

## Install

Once, over USB. After that the plugin updates itself — see
[Keeping it up to date](#keeping-it-up-to-date).

**1. Get the zip.** From the
[latest release](../../releases/latest),
or:

```bash
gh release download --pattern '*.zip'
```

**2. Unpack it into KOReader's `plugins/` directory.** The zip already contains
`karabridge.koplugin/`, so unpack *into* `plugins/`, not into a subfolder of it.

| Device | Path |
|---|---|
| Kobo | `.adds/koreader/plugins/` |
| Kindle | `koreader/plugins/` |
| Desktop | `~/.config/koreader/plugins/` |

On a Kobo, `.adds` is hidden — turn on "show hidden files" in your file manager.
Replacing an existing `karabridge.koplugin/` is fine.

**3. Write `karabridge.conf`.** Put it **next to** `plugins/`, not inside the
plugin folder — then no update can ever touch it:

```
.adds/koreader/karabridge.conf      <- here
.adds/koreader/plugins/karabridge.koplugin/
```

```ini
server_url = https://karakeep.example.org
api_token  = ak1_...

download_folder = /mnt/onboard/Articles

# update_token is only needed for a private repository
update_repo  = encodedLife/karabridge.koplugin
update_token = github_pat_...
```

Only `server_url` and `api_token` are required. Give the device its own Karakeep
key so it can be revoked on its own.

**4. Eject and restart KOReader.** KaraBridge appears under **Tools →
KaraBridge**, and its last row shows the running version.

**5. Check it.** *Test the connection* should report the server. If something is
wrong, *Diagnostics → Current settings* shows what was actually read, with the
key masked.

`spec/`, `scripts/` and `docs/` are development-only and are not in the release
zip.

For development, symlink instead so the emulator runs the working copy:

```bash
scripts/link-plugin.sh /path/to/koreader   # symlink the plugin into a KOReader
scripts/link-plugin.sh --unlink            # remove the symlinks again
```

## Configure

Two settings are required: the Karakeep server address and an API key.

### From the device

**Tools → KaraBridge → Server**, then **Test the connection**.

### From a text file

Typing an API key on an e-reader keyboard is miserable, so it can go in a file
called `karabridge.conf` instead.

#### Where it goes

Searched in this order, **first match wins**:

| | Path | |
|---|---|---|
| 1 | `$KARABRIDGE_CONF` | development only |
| 2 | `<KOReader dir>/karabridge.conf` | **the normal place** |
| 3 | `<KOReader dir>/settings/karabridge.conf` | |
| 4 | `<plugin dir>/karabridge.conf` | works, but an update has to rescue it |

Concretely, on the devices people actually use:

```
Kobo      .adds/koreader/karabridge.conf
Kindle    koreader/karabridge.conf
Desktop   ~/.config/koreader/karabridge.conf
```

So on a Kobo it sits **beside** `plugins/`, not inside it:

```
.adds/koreader/karabridge.conf            <- here
.adds/koreader/plugins/karabridge.koplugin/
```

Both work. Only the first is outside what an update replaces — the installer
does carry a config out of the plugin folder, but there is no reason to depend
on that.

**Settings file → Where KaraBridge looks** shows the list with a tick against
the one in use, and reports any problems in it. **Settings file → Create an
example file** writes a fully commented template to the normal place.

#### What it looks like

Only the first two lines are required. Everything else has a working default.

```ini
# --- Karakeep server ---
server_url = https://karakeep.example.org
api_token  = ak1_example

# --- Downloading articles ---
download_folder   = /mnt/onboard/karabridge
articles_per_sync = 30
download_images   = true

# --- What to sync ---
filter_list = KOReader
filter_tags = read-later, ebook

# --- Exporting your own books ---
book_tag  = koreader
book_list = KOReader Books

# --- Updating the plugin ---
# update_token is only needed for a private repository
update_repo  = encodedLife/karabridge.koplugin
update_token = github_pat_...
```

**Comments need a line of their own.** `#` and `;` start a comment only at the
beginning of a line — there are no trailing comments, so

```ini
update_token =        # only for a private repository
```

sets the token to `# only for a private repository`, and the next update fails
with an unhelpful 401. KaraBridge reports a value that begins with `#` or `;`
as a likely mistake under **Settings file → Where KaraBridge looks**, but it
does not silently rewrite it: a `#` is legitimate inside a URL.

**Quotes are optional.** `api_token = ak1_x` and `api_token = "ak1_x"` are the
same thing; a matching pair of single or double quotes around the whole value is
stripped. Anything else is part of the value, spaces included, so do not pad the
right-hand side.

`=` and `:` both separate a key from its value.

#### Every setting

| Key | Default | What it does |
|---|---|---|
| `server_url` | — | Karakeep address, without `/api/v1`. **Required.** |
| `api_token` | — | Karakeep API key. **Required.** Give the device its own. |
| `download_enabled` | `true` | Download Karakeep articles onto the device. |
| `download_folder` | — | Where downloaded articles are kept. |
| `articles_per_sync` | `30` | Newest unread articles fetched in one sync. |
| `download_images` | `true` | Embed article images in the generated EPUB. |
| `max_images` | `20` | Cap on images per article. |
| `prefer_archive` | `false` | Use the saved page archive, not the extracted article. |
| `max_archive_mb` | `4` | Refuse a page archive larger than this. |
| `filter_list` | all | Only sync bookmarks in this Karakeep list. Pick it from the menu. |
| `filter_list_id` | — | Resolved list ID. Set from the menu, not by hand. |
| `filter_tags` | all | Comma-separated tags to sync. |
| `include_archived` | `false` | Include bookmarks already archived. |
| `sync_read_status` | `true` | Send reading status back. |
| `sync_article_highlights` | `true` | Send article highlights back. |
| `pull_remote_notes` | `true` | Bring notes edited in Karakeep back into KOReader. |
| `archive_after_read` | `false` | Archive once 100% read. |
| `archive_finished` | `true` | Archive when marked finished. |
| `archive_abandoned` | `false` | Archive when marked abandoned. |
| `archive_tag` | — | Tag to add when archiving. |
| `delete_local_after_archive` | `true` | Delete the local copy once archived. |
| `export_local_books` | `true` | Offer KaraBridge to KOReader's highlight exporter. |
| `book_tag` | — | Tag put on a new book card. |
| `book_list` | — | Karakeep list a new book card goes into. Pick it from the menu. |
| `book_list_id` | — | Resolved list ID. Set from the menu, not by hand. |
| `upload_book_cover` | `true` | Upload the book's cover to its card. |
| `book_card_template` | — | **Deprecated and ignored.** Still accepted. |
| `auto_sync_on_wifi` | `false` | Sync when Wi-Fi connects. Never turns the radio on. |
| `auto_sync_interval` | `30` | Shortest gap between automatic syncs, in minutes. |
| `update_repo` | — | GitHub repository, as `owner/name`. Empty turns updates off. |
| `update_token` | — | Token for a private repository. Empty means anonymous. |
| `update_check_on_sync` | `false` | Check for a new version while syncing. Never installs. |

### Precedence, in one sentence

**The file seeds settings the first time; the menu wins from then on; editing
the file later does nothing until you choose "Reload it now".**

That last part catches people out: change `karabridge.conf` on a computer, plug
the device back in, and nothing happens until **Settings file → Reload it now**.

Full reasoning in
[`docs/architecture/configuration.md`](docs/architecture/configuration.md).

## Download folder

**Download folder → Choose a folder…** opens KOReader's native folder picker.
The chosen path is shown in full in the menu and persists across restarts.
Typing a path by hand is also offered, for a folder the picker cannot reach.

KaraBridge checks the folder is writable when you pick it and again before each
download. If it is not, the setting is still saved — an unmounted SD card is a
transient problem, not a reason to discard your choice — and the message
explains what is wrong, including Flatpak sandbox permissions.

## Exporting your own books

Your own EPUB and PDF files become one Karakeep card per book.

A local book is represented by **one editable Karakeep text bookmark**.
KaraBridge writes the bookmark body only when it creates the card.
Book highlights are synchronised separately, as real Karakeep highlights.
Later exports never regenerate or overwrite the card body.

The card body is a workspace: notes, a summary, questions, links to other
books. Write whatever you like in it. KaraBridge fills it once, when the card
is created, with a small template of empty headings, and after that it never
touches the text, the title, the note or the summary again.

The highlights are not copies inside that text. Each marked passage is a real
Karakeep highlight attached to the card, so a book shows up in Karakeep's
**Highlights** view exactly as a saved article does, and notes travel in both
directions.

Book cards can go into a Karakeep list: **KaraBridge → Export book highlights →
List for new book cards**. Fetch the lists once, then tick one. A card is filed
when it is created and never again — move it elsewhere in Karakeep and it stays
where you put it, because a card is found by its bookmark ID, not by where it
sits.

**Turn it on first:** **KaraBridge → Export book highlights**. KOReader keeps
every export target switched off until you tick it, and it lives in a different
menu — so an export can otherwise do nothing at all with no message. That row
sets both switches and tells you where the export action is.

Then, with a book open: **Tools → Export highlights → Export all notes in
current book.**

Exporting again reuses the same card. It checks that the card still exists,
synchronises the highlights and the cover, and leaves the body alone. A card
deleted in Karakeep is recreated — but only on a confirmed 404, never after a
timeout or a server error, because guessing there would duplicate the book.

One honest limitation: a book highlight is a real Karakeep highlight object,
but it is not anchored to a position in the card body — the passage is
deliberately not in that text. Karakeep's Highlights view shows it in full;
there is simply no underline in the card. Correct synchronisation is worth more
than an underline pointing at the wrong words.


## Keeping it up to date

**KaraBridge → Version → Check for updates.** If there is a newer release,
*Install* fetches it, replaces the plugin and offers to restart KOReader. No
cable.

Point it at a repository in `karabridge.conf`:

```ini
# Leave update_token empty for a public repository.
# update_check_on_sync only checks; it never installs.
update_repo   = encodedLife/karabridge.koplugin
update_token  =
update_check_on_sync = false
```

Whether the repository is public or private is not a setting — **the token
decides.** Empty means anonymous, which is all a public repository needs. Set,
and requests are authenticated, which a private repository requires and a public
one merely benefits from (5000 requests an hour instead of 60). Use a
fine-grained token with `Contents: read` on that one repository, and give it an
expiry.

Two things worth knowing before you rely on it:

- **The token sits in plain text on the device**, like the Karakeep key. Whoever
  holds the device holds it.
- **There is no signature check.** The trust boundary is TLS and the GitHub
  account. Anyone who takes over that account can put code on your reader — true
  of any plugin updater, and better said than implied.

Checking can be automatic; **installing never is**. It always asks first, keeps
your settings and `karabridge.conf`, and restores the previous version if the
replacement fails halfway.

Releases are built with `scripts/release.sh`, which runs the checks and the
tests, refuses to package a `karabridge.conf`, and verifies the zip has the
shape the updater expects.

## Known limitations

- **Highlight positions are best-effort.** Offsets are computed the way
  Karakeep's reader computes them — UTF-16 code units over concatenated DOM
  text — but they describe a page this plugin never sees, so they can be off if
  Karakeep re-crawls. Note synchronisation does not depend on them: it uses the
  stored highlight ID, so a wrong offset misplaces an underline in the web
  reader and nothing more.
- **A note changed on both sides is not merged.** Neither side is overwritten;
  the conflict is reported in Diagnostics and left for you.
- **A highlight deleted in Karakeep does not delete your annotation.** The
  difference is reported instead. Karakeep is not the system of record for
  something you created in KOReader.
- **Karakeep accepts four highlight colours** — yellow, red, green, blue.
  KOReader's others are mapped to the nearest.
- **Self-signed certificates are refused.** KOReader ships its own CA bundle
  and will not accept an unknown issuer; it surfaces as "the server could not
  be reached". KaraBridge does not offer a way to skip certificate
  verification.
- **Plain http is allowed but the API key travels unencrypted.** The connection
  test says so once.
- **Content hashing is FNV-1a**, for change detection only. It is not a
  cryptographic digest and is not used as one.
- **`karabridge.conf` holds the API key in plain text.** Give the device its
  own Karakeep key so it can be revoked on its own.
- **Device coverage is narrow.** Developed against the KOReader emulator and a
  live Karakeep, and used on a Kobo. Other devices differ in storage paths,
  memory and touch behaviour, and building an image-heavy article's EPUB in Lua
  is the main performance unknown.

## Coexistence

KaraBridge can be installed alongside another Karakeep integration — its
directory, settings file, menu key, sidecar key and filename prefix are all its
own.

- **A book whose sidecar already holds a bookmark ID** is picked up
  automatically: KaraBridge adopts that ID and uses the existing card instead of
  creating a duplicate. It does not rewrite the card's title or body — whatever
  is there stays.
- **Downloads carrying another plugin's filename prefix** are left alone.
  KaraBridge claims only its own `[kb-id_…]` files, so it neither syncs nor —
  importantly — deletes anything it did not create.

The rules are in
[`docs/architecture/metadata.md`](docs/architecture/metadata.md).

## Development

```bash
scripts/check.sh             # syntax, globals, luacheck, shellcheck, stylua
scripts/test-unit.sh         # plain Lua 5.1, no KOReader, under a second
scripts/test-koreader.sh     # inside a built KOReader
scripts/test-integration.sh  # against a real Karakeep; opt-in
scripts/release.sh           # build a release zip, verify it installs
```

`scripts/test-koreader.sh`, `scripts/link-plugin.sh` and the release script's
install check all need a KOReader checkout. Point `KARABRIDGE_KOREADER` at one,
or pass the path as an argument.

[`docs/testing.md`](docs/testing.md) explains the layers and what each one can
and cannot prove — including where a passing unit suite is structurally unable
to catch something.
[`spec/smoke/emulator_checklist.md`](spec/smoke/emulator_checklist.md) is the
manual pass.

The architecture, and the reasoning behind each decision that could reasonably
have gone the other way:
[`docs/architecture/overview.md`](docs/architecture/overview.md).

## Licence and attribution

KaraBridge is **AGPL-3.0**, the same licence as KOReader, which it is built
against, and Karakeep, which it interoperates with. See [`LICENSE`](LICENSE).

No code has been copied from either. The modules here were written from an
understanding of the published behaviour of Karakeep's HTTP API and KOReader's
plugin interfaces; where a decision follows from something in those, the module
comment says which file or schema it was checked against.

KOReader and Karakeep are the work of their own authors and are not affiliated
with this project.
