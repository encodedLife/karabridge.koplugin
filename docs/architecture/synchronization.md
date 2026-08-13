# Synchronisation

The intended design of the four synchronisation flows.

**Status.** All four flows are implemented and verified against a
live Karakeep instance. This document was written as a design before any of it
was code, which is why it reads as one; it has been kept accurate rather than
rewritten, so the reasoning behind each decision stays attached to it.

## The two directions

```
Karakeep ──── A: article download ────▶ KOReader
Karakeep ◀─── B: article sync ───────── KOReader
Karakeep ◀─── C: local book export ──── KOReader
Karakeep ◀─── D: offline link capture ─ KOReader
```

## A. Article download

**Trigger.** Menu, Dispatcher action, or Wi-Fi connect when
`auto_sync_on_wifi`.

**Flow.**

1. Check the download folder is writable. **Up front**, before anything else:
   otherwise an unwritable folder surfaces as every article failing to build,
   one confusing line at a time, from inside the zip writer.
2. Index the local articles by bookmark ID, from the `[kb-id_…]` filename.
3. **Upload first** (flow B), so an article archived now drops out of the list
   about to be fetched and is not re-downloaded.
4. Fetch bookmarks for the configured scope, following the cursor.
5. Record the full set of remote IDs *before* downloading anything, so
   cancelling half way through does not make the rest look deleted.
6. For each bookmark not already local: resolve content, build the EPUB, write
   it, record `article` metadata.
7. Remove local files that are gone remotely — **only** if the walk was
   complete and not cancelled.

**Scope.** `all`, a single list, or a single tag. Only the unfiltered
`/bookmarks` endpoint accepts an `archived` filter; list and tag results must be
filtered client-side. See `../research/karakeep-analysis.md`.

**Content source order**, best first, from a link bookmark:

1. `content.htmlContent` — the normal source, hydrated by `includeContent=true`.
2. `content.contentAssetId` — the same content out of line; a safety net for
   when Karakeep's own read of that asset fails and returns null.
3. `precrawledArchiveAssetId`, then `fullPageArchiveAssetId` — whole pages
   including navigation and banners. A **fallback**, not a preference: Karakeep
   already runs a precrawled archive through the same readability extraction,
   so its text has reached `htmlContent` by the time we see the bookmark.
   `prefer_archive` moves them to the front for the pages where extraction went
   wrong.
4. `GET /bookmarks/:id/content` — markdown, so formatting and images are lost
   in the conversion back to HTML. Always last.

**Filenames.** `[kb-id_<id>] <title>.epub`. The ID survives a round trip
through the filesystem. The prefix is our own, because mistaking another
plugin's file for ours would mean archiving or deleting a file we do not own.

**Collisions.** Two articles with the same title get different filenames
because the ID is in the name. Images are numbered per article and written
inside the article's own EPUB, so cross-article collision is impossible; within
an article, a repeated `src` reuses the first path.

**Interruption.** Wrapped in `ui/trapper` so progress shows and the user can
cancel. Cancelling sets a flag that suppresses step 7.

### Deletion safety

The rule, worth restating because getting it wrong loses a user's reading:

> A local file is removed only when the sync saw the **whole** scope, was not
> cancelled, and the file has **no sidecar** — meaning it was never opened.

A capped or cancelled sync cannot distinguish "archived elsewhere" from "did
not fit in this run". `Client:collect` returns `complete = false` when it
stopped at a limit or a page cap, precisely so callers cannot get this wrong by
accident; `spec/unit/api_client_spec.lua` covers it.

## B. Article synchronisation

**Trigger.** Before every download, from the menu, and on Wi-Fi connect while a
document is open (upload only, so a sync cannot interrupt reading).

For each local article, by bookmark ID:

1. **Highlights**, if `sync_article_highlights` and the file has a sidecar.
   Pushed for anything opened, not just finished articles, so notes are not
   lost if the user never marks it read.
2. **Finished?** — from `summary.status` (`complete` / `abandoned`) and
   `percent_finished`, gated by `archive_finished`, `archive_abandoned` and
   `archive_after_read`.
3. If finished: `PATCH /bookmarks/:id { archived = true }`, then `archive_tag`
   if set, then delete the local copy if `delete_local_after_archive`.

### Highlight matching

KOReader records a highlight as a crengine XPointer into the EPUB *we*
generated. Karakeep wants character offsets into *its* rendered content. The
two share only the highlighted text.

So matching is by whitespace-normalised text, and is best-effort:

- A passage appearing more than once resolves to its first occurrence.
- An exact match failing is retried on a distinctive middle slice, which covers
  KOReader having captured a partial word at either end.
- A passage that cannot be found at all is still sent with offsets `0, 0`. The
  schema requires numbers and has no nullable variant, and an unanchored
  highlight that displays its text and note is worth more than no highlight.
  The count of unpositioned highlights is reported, not hidden.

### Duplicate prevention

Karakeep does **not** deduplicate; posting the same text twice creates two
highlights.

Before pushing, fetch the existing set and index by normalised text. **If the
existing set cannot be read, skip the push entirely** rather than risk
duplicates. Failing closed is right here: a highlight pushed next sync is a
delay, a duplicated highlight is manual cleanup.

`api/highlights.lua:existingTexts` returns exactly that index, and propagates
the failure so the caller can make that decision.

### No queue for article status

Deliberate: "finished" and "highlighted" already live durably in the `.sdr` sidecar, which the sync reconciles against
the server on every run. A failed upload is retried next time. A separate queue
would be a second source of truth that could drift from what is on disk.

What *is* reported rather than only logged: how many uploads failed, so the
user knows something is outstanding.

## C. Local book export

```
1 local book
  = 1 editable Karakeep text bookmark
  + real Karakeep highlights attached to that bookmark
```

The bookmark and its highlights are **independent**, and that is the whole
design. Highlights are highlight objects: searchable, listed in Karakeep's
Highlights view, synchronised in both directions. The body is the user's
workspace — notes, a summary, questions, links to other books.

KaraBridge writes the body **only when it creates the card**, with a small
template of empty headings. After that it never sends `text`, `title`, `note`
or `summary` for that bookmark again.

### What this replaced, and why

Until 0.7 the body *was* the highlights: KaraBridge rendered them into Markdown,
hashed the result, and rewrote the card whenever the hash moved. That made the
card a generated artefact. Anything the user typed into it survived exactly
until the next highlight — at which point the export replaced the whole body,
silently.

A hash cannot fix this. It only decides *when* to overwrite, not *whether*.

**Trigger.** KOReader's highlight exporter, with KaraBridge registered as a
target through `frontend/provider.lua`. Registration happens at module load —
see ADR-002 in [`overview.md`](overview.md).

**Flow**, per book:

1. Read `book_card` metadata from the sidecar; adopt an ID from the recovery
   journal or from a legacy `karakeep` record if that is all there is.
2. A file with `article.bookmark_id` is a downloaded Karakeep article and
   already *is* a bookmark. Leave it entirely to article sync.
3. **No stored ID** → `POST /bookmarks` with `type = "text"` and the neutral
   body; store the ID; apply `book_tag` and `book_list`.
4. **Stored ID** → `GET /bookmarks/:id?includeContent=false`.
   - **200** → the card is there. Write nothing to it. Sync highlights, sync
     the cover.
   - **404** → it was deleted. Create a replacement, exactly as in step 3.
   - **anything else** → report it and stop for this book. A timeout or a 500
     is not evidence of deletion, and creating a second card would duplicate
     the book and orphan every highlight on the first.

`includeContent=false` is deliberate. The body is not needed for anything, and
downloading it would only invite something to start comparing against it again.
Nor is the highlights endpoint used as the existence probe: a book with no
annotations has no highlights to ask about, and its card can still have been
deleted.

**Highlights** go through the same `HighlightSync.run` the articles use — the
same identity, the same reconciliation, the same conflict rules. There is no
book-specific reconciliation logic. The one difference is the offset mode.

### Detached offsets

An article's highlight can point at the passage, because the article body
contains it. A book's cannot: the card body is the user's own text and
deliberately does not contain the passage.

So book cards sync with `offset_mode = "detached"`:

- the card body is never fetched;
- nothing is searched for inside it;
- offsets are sent as `0, 0`;
- this is **not** counted as an unresolved offset, because nothing failed to
  resolve — there was nothing to resolve.

Everything else is unchanged: text, note, colour, stable identity, and the
remote ID used for every later update and pull.

The consequence, stated plainly: a book highlight is a real Karakeep highlight
object, but it is not visually anchored in the card body. Karakeep's Highlights
view shows it in full. A correct synchronisation is worth more than an underline
pointing at the wrong words.

Downloaded articles are untouched by this: they keep the real offset
calculation, in UTF-16 code units over the DOM text, and the existing
article-content loading.

### Migration

Non-destructive, and deliberately so. A card created by an earlier version still
holds generated Markdown with the highlights duplicated in it. KaraBridge does
not delete, replace or tidy that. It simply stops regenerating it; new and
changed highlights arrive through the highlight API only. Removing the old text
is the user's decision.

`book_card.content_hash` may still be present in a sidecar. It decides nothing
now, and it is not stripped — `Metadata.update` merges, so not writing the key
leaves it where it is.

**Failure** goes on the queue (D), because unlike article status there is no
sidecar state that would reproduce the intent on the next run.

## D. Queue

For operations with no durable local state to reconstruct them from. Principally
bookmarking a link tapped while offline.

```lua
{
    version = 1,
    entries = {
        ["<dedup key>"] = {
            action     = "create_link" | "create_card" | "update_card",
            payload    = { … },
            attempts   = 0,
            last_error = nil,
            created_at = 1700000000,
            updated_at = 1700000000,
        },
    },
}
```

Stored at `<data dir>/karabridge/queue.lua` via `LuaSettings`, flushed on
`onFlushSettings`.

Against the prompt's requirements:

| Requirement | How |
|---|---|
| Survives restart | LuaSettings on disk, flushed on the KOReader event |
| Stores failed operations | One entry per operation |
| Attempt count | `attempts`, incremented on each failure |
| Last error | `last_error`, the `Result` code and message |
| Safe retries | Retried only when online; capped attempts, then parked |
| No duplicates | Keyed by a dedup key — the URL for a link, the file path for a card |
| Distinguishes action types | `action`, dispatched by a registered handler |
| Versioned | `version` on the envelope |
| Recovers from a corrupt entry | An entry that fails to validate is moved to a `quarantine` table with its error, and the rest of the queue processes normally |

Two things worth doing differently from the obvious version:

- **An envelope**, so the entries and the bookkeeping never share a namespace.
  Its `_length` lives inside the entries table and every iteration has to skip
  it by name.
- **Quarantine rather than removal.** A corrupt entry that is silently dropped
  is silent data loss; one that is retried forever blocks the queue. Parking it
  where the diagnostics menu can show it is neither.

## Idempotency

Every flow can be run twice with no additional effect:

| Flow | What makes it idempotent |
|---|---|
| Article download | Skips a bookmark already present locally, by ID |
| Archiving | `PATCH { archived = true }` on an already-archived bookmark is a no-op |
| Highlight push | Existing set fetched and matched by normalised text |
| Book card | Stored ID → update, not create; equal hash → skip entirely |
| Queue | Entry removed only on success; dedup key prevents a second entry |

## Errors the user sees

`Result` codes are translated once, at the feature boundary, into a sentence
that says what to change:

| Code | Message |
|---|---|
| `not_configured` | Enter the server address and API key first. |
| `unauthorized` | Karakeep rejected the API key. Check it under Settings → API Keys. |
| `not_karakeep` | No Karakeep API answered at that address. Enter the base address, without /api/v1. |
| `unreachable` | The server could not be reached. Check the address and the network. |
| `rate_limited` | Karakeep is rate limiting this device. Try again in a minute. |
| `server_error` | The Karakeep server reported an internal error. |
| `malformed` | Something answered at that address, but it was not Karakeep. |

An automatic sync reports through a corner toast; one the user asked for
reports through a modal. `shared/notification.lua` makes that decision once
rather than at each call site.
