# Local metadata

What KaraBridge remembers about a file, where it keeps it, and how the schema
changes over time.

Implemented by `karabridge/shared/metadata.lua`.

## Where

KOReader's per-document sidecar (`.sdr`), under the key `karabridge`, reached
through `DocSettings`.

Not a database of our own, because the sidecar:

- travels with the file when the user moves or renames it,
- survives a plugin reinstall,
- is already kept consistent by KOReader,
- is human-readable Lua, so a stuck record can be inspected and fixed by hand.

The pattern is not new. What is added here is a version field and a migration
path — a schema without one can only ever be extended,
never corrected.

The key is `karabridge`, distinct from the legacy `karakeep` key, so another
Karakeep integration can be installed at once and neither corrupts the other's
records.

## Schema, version 1

```lua
{
    version = 1,

    -- Set for files KaraBridge downloaded from Karakeep.
    article = {
        bookmark_id      = "abc123",
        source_url       = "https://example.org/article",
        content_hash     = "811c9dc5e40c292c",
        downloaded_at    = 1700000000,
        status_synced_at = 1700000500,
    },

    -- Set for the user's own books exported as a Karakeep text card.
    book_card = {
        bookmark_id   = "xyz789",
        content_hash  = "bf9cf968811c9dc5",
        exported_at   = 1700000000,
        imported_from = "legacy",  -- only on an adopted record
    },
}
```

`article` and `book_card` are independent. An article downloaded from Karakeep
syncs through its own bookmark; a local book gets a text card. A single file
never legitimately has both, but nothing forbids it: refusing to record
something is a worse failure than recording something redundant.

### The fields, and why each is there

| Field | Why |
|---|---|
| `article.bookmark_id` | Ties the file back to Karakeep. Also derivable from the `[kb-id_…]` filename, but the sidecar survives a rename and the filename does not. |
| `article.source_url` | Shown in diagnostics; lets a user find the original when the card is gone. |
| `article.content_hash` | Detects that Karakeep re-crawled the article, so the local copy can be refreshed. |
| `article.downloaded_at` | Age, for a future "clean up old articles". |
| `article.status_synced_at` | Which reading status was last pushed, so an unchanged status is not re-sent. |
| `book_card.bookmark_id` | **The one that matters.** Without it, every export creates a new card instead of updating the existing one. |
| `book_card.content_hash` | **Legacy, inert.** It used to skip an export that would change nothing, back when the card body was generated from the highlights. Nothing writes it any more and nothing reads it. Existing sidecars keep theirs: `Metadata.update` merges, so not writing the key preserves it, and deleting a field to tidy up is not worth the risk. |
| `book_card.exported_at` | Shown in diagnostics. |
| `book_card.imported_from` | Marks a record adopted from another plugin, so a later problem is diagnosable. |

## Content hashing

`shared/hashing.lua`, FNV-1a over the generated Markdown. See ADR-006 in
[`overview.md`](overview.md): this is change detection, not a digest, and must
never be used for anything security-relevant.

`Hashing.hashParts({...})` joins with `\0` before hashing, so `{"ab","c"}` and
`{"a","bc"}` do not collide — without the separator two different highlight
sets could look unchanged.

## Migration

`Metadata.migrate(raw, legacy_karakeep)` is pure and is the whole reason the
schema is versioned: every migration is a branch there with a spec beside it,
rather than defensive `or` chains scattered across the features that read the
metadata.

`Metadata.read()` calls it and, when something changed, writes the result back
and flushes — so the migration happens once per file rather than on every read.
`spec/unit/metadata_spec.lua` asserts the flush count.

### Version 0 → 1

Metadata written before the version field existed. The shape is already
current, so stamping the version is the whole migration.

### Adopting a legacy record

A file exported by an older integration has, under the `karakeep` key:

```lua
{ bookmark = { id = "old1", createdAt = "…", modifiedAt = "…" },
  last_updated = "2024-01-01 12:00:00" }
```

When KaraBridge finds no metadata of its own but a legacy record with a
bookmark ID, it adopts the ID:

```lua
{ version = 1,
  book_card = { bookmark_id = "old1", imported_from = "legacy" } }
```

Without this, a user switching over would get a **second** card for every book
that already has one — exactly the duplicate the stored ID exists to prevent.

Deliberately **no `content_hash`** on an adopted record -- and none on any new
record either. Historically the reason was that we cannot know what was last
sent, so the next export must actually run rather than be skipped as
unchanged.

The legacy `karakeep` key is **left in place**. Both plugins may be installed
during the migration, and corrupting the other one's records would be a poor
way to win the user over. `spec/unit/metadata_spec.lua` asserts it survives.

### When there is no sidecar record at all

An integration that keeps the bookmark ID in the filename rather than the
sidecar leaves nothing to adopt. Such files are left alone: KaraBridge claims
only its own `[kb-id_…]` prefix, so it never archives or deletes a file it did
not create.

### Adding version 2

1. Add a branch to `Metadata.migrate` for `version == 1`.
2. Bump `Metadata.SCHEMA_VERSION`.
3. Add a spec that migrates a realistic version-1 record and checks the result.
4. Keep the version-1 spec: it must still pass, because a device that has been
   offline for a year will present a version-1 record.

Migration must never be destructive. If a field is being removed, leave it in
place; unknown fields are ignored on read.

## Robustness

- `Metadata.read` returns nil rather than throwing for a missing file, a
  missing sidecar, or a sidecar with no KaraBridge data.
- `Metadata.write` refuses a non-table payload rather than corrupting the
  sidecar, and returns false.
- `version` is always stamped by `write`, overriding anything a caller passed —
  so a caller cannot accidentally write a record claiming to be a version it
  is not.
- `Metadata.update(path, section, values)` merges into one section and leaves
  the other alone, so two features writing different sections cannot clobber
  each other.
- Raising when an ID is missing throws out of an export loop and abandons the
  remaining books. KaraBridge returns false and lets the caller count the
  failure.

## Verification

- `spec/unit/metadata_spec.lua` — 20 specs against a mock DocSettings:
  migration branches, merge semantics, version stamping, flush counting.
- `spec/integration/plugin_loading_spec.lua`, "against the real DocSettings" —
  a real `.sdr` round trip, survival across a reopen, and legacy adoption,
  running inside KOReader.


## The open document

A `.sdr` file is a serialisation of state KOReader holds in memory, and while a
book is open it lags behind. `ReaderAnnotation:onReadSettings` takes the
`annotations` array out of the sidecar and keeps it; every highlight made
afterwards goes into that array, and only `onSaveSettings` — on close, or an
autosave — puts it back.

Two consequences, both of which bit.

**Reading the file gives you the past.** `clip.lua:418` builds a book's export
from `ui.annotation.annotations`, so a passage marked this session is in the
card. KaraBridge's highlight sync read the sidecar, so the same passage was
invisible to it, and no Karakeep highlight was created until the book had been
closed and exported again.

**Writing the file is worse than useless.** `DocSettings:flush` serialises its
own instance's table wholesale:

```lua
local ser_data = dump(data, nil, true)
```

So a key written through a second instance — which is what `DocSettings:open`
always returns — is erased the moment KOReader flushes the instance it has held
since the book was opened. A note pulled from Karakeep vanished on close, and so
did the card's bookmark ID, which would have produced a duplicate card.

`Metadata.liveDocument(file_path)` is the answer, fed by `Runtime.openDocument`.
When the file is the one KOReader has open it hands back KOReader's own
`doc_settings` and annotation array, and every read and write goes through
those. When it is not, nothing changes.

The write verification still re-reads from disk rather than from the instance it
just wrote, because the question that matters is whether the bytes landed, not
whether the table has the value.
