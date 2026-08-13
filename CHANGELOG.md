# Changelog

Notable changes to KaraBridge. Format loosely follows
[Keep a Changelog](https://keepachangelog.com/); versions follow
[Semantic Versioning](https://semver.org/).

## [0.0.1] — 2026-08-10

The first release.

### Articles, from Karakeep to the device

- Downloads unread Karakeep articles as EPUBs, with images embedded, and can use
  the saved page archive instead of the extracted article.
- Scope can be narrowed to one Karakeep list, to tags, or both. The list is
  chosen from the menu.
- Filenames carry the bookmark ID, `[kb-id_<id>] Title.epub`, so it survives a
  round trip through the filesystem. Only files with that prefix are ever
  claimed, so nothing another plugin downloaded is touched.

### And back again

- Reading status and progress return to Karakeep; an article can be archived
  when finished, abandoned or fully read, and optionally tagged as it goes.
- **Highlights synchronise in both directions.** Each KOReader annotation is a
  real Karakeep highlight, matched by a stable per-annotation identity rather
  than by its text — so the same sentence highlighted twice stays two
  highlights, a note edited in Karakeep comes back to the right annotation, and
  a repeated sync creates nothing.
- Offsets are computed in UTF-16 code units over the article's DOM text, which
  is how Karakeep's own reader counts them.
- Where both sides changed a note, neither is overwritten and the conflict is
  reported.

### Your own books

    1 local book
      = 1 editable Karakeep text bookmark
      + real Karakeep highlights attached to that bookmark

- The card body is **yours**. KaraBridge writes it once, when it creates the
  card, and never sends `text`, `title`, `note` or `summary` for it again — so
  notes and summaries you write there survive every later export.
- Every marked passage is a real Karakeep highlight on the card, not a copy
  inside its text, so a book appears in Karakeep's Highlights view as an article
  does.
- The book's cover is uploaded and attached to the card.
- A card deleted in Karakeep is recreated, but only on a confirmed 404 — never
  after a timeout or a server error, where guessing would duplicate the book.

### Getting there and staying there

- `karabridge.conf` seeds the settings, so an API key can be typed on a computer
  instead of an e-reader keyboard. The menu wins from then on.
- Failed operations, and links tapped while offline, go on a versioned queue
  with attempt counts and a last error.
- Optional sync when Wi-Fi connects. It never turns the radio on by itself.
- Updates from a GitHub release, checked and installed from the menu, public or
  private repository. The installer verifies the archive before touching the
  working copy and restores it if the swap fails.
- The API key is never logged. A spec asserts that after a run of successful and
  failed requests, neither the token nor the word `Bearer` appears in anything
  logged.

### Reviewed before release

An external review of the code before release found four things, all of which
held up when checked, and two of which were places where the plugin failed a
standard it sets for itself elsewhere. All four are fixed here.

**A signed download URL could reach the log.** The API client logged the full
URL. For Karakeep that is harmless, but a private release asset is fetched from a
storage URL whose entire authorisation sits in its query string — so a debug log
could hand a reader time-limited access to it. The Karakeep token has been kept
out of the log since the beginning; a credential in a query parameter is the same
thing wearing a different hat. `Url.forLog` now drops everything after `?` or
`#`, keeping the path so the line stays useful.

**The updater trusted the paths inside the archive.** `destination .. "/" ..
entry.path` walks out of the destination given `../../`, and an absolute path
ignores it altogether. The realistic risk was small — the archive comes from a
release in a repository the user configured, and whoever controls that controls
the plugin's code anyway — but "you would have to be compromised already" is a
poor reason to write a file wherever a stranger asks. Entries that climb out, are
absolute, or contain a backslash are now refused, as are archives with more than
one top-level directory, both at the gate and again at the line that writes.

**The image fetcher left KOReader's global socket timeouts set if the request
raised**, and had no size limit. `api/client.lua` had been fixed for exactly this
and the same reasoning was never carried across: `socketutil`'s timeouts are
process-global, so leaving them set does not break KaraBridge — it breaks every
other part of KOReader that opens a connection. The request is now wrapped with
the reset beyond it, and a single image is capped at 8 MB, enforced in the sink so
an oversized one is abandoned partway rather than downloaded in full first.

**The HTML sanitiser only matched quoted attributes.** `onclick="…"` was removed;
`onclick=alert(1)` went straight through, because the quoted patterns have no
closing quote to anchor on. Unquoted event handlers and `javascript:` hrefs are
now handled too. Defence in depth rather than an open door — the generated EPUB
is rendered by crengine, which does not execute JavaScript.
