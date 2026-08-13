# Two-way highlight synchronisation

What happens to a highlight in each direction, and why each policy was chosen.

Implemented by `karabridge/features/article_sync/`:
`reconcile.lua` decides, `highlight_sync.lua` carries it out,
`annotations.lua` writes to KOReader, `offsets.lua` works out positions.
Identity is [`highlight-identity.md`](highlight-identity.md).

## What it replaced

Until this, KaraBridge only sent. It created remote highlights, **discarded the
returned IDs**, and deduplicated by text. Three consequences:

- nothing could ever be *updated*, only created;
- a note edited in Karakeep had no way back to KOReader;
- the same sentence highlighted twice was silently treated as one.

## The decision table

For each mapped pair, two hashes were recorded at the last successful sync —
one of the local note and colour, one of the remote. Comparing today's values
with those says which side moved. Neither system offers a per-highlight
modification time, so this is the only way to answer the question.

| Local | Remote | Action | Effect |
|---|---|---|---|
| same | same | `none` | nothing |
| changed | same | `push` | `PATCH /highlights/:id` |
| same | changed | `pull` | the local annotation's note and colour are updated |
| changed | changed | `conflict` | **neither side is touched** |
| — | absent | `remote_deleted` | the local annotation is kept |
| unmapped | unmapped | `create` | `POST /highlights`, ID recorded |
| unmapped | unclaimed, one text match | `adopt` | recorded, nothing sent |
| unmapped | unclaimed, no or several matches | `orphan` | reported |

`reconcile.lua` is pure and returns this list, so every branch — including
conflicts and deletions, which are awkward to produce on a device — is covered
by a spec.

## Policies, and why

### Conflict: neither side wins

The local annotation stays exactly as it is; the remote value is left alone;
the conflict is recorded in the mapping and reported in the summary.

The alternative is to pick a side automatically, and there is no side to pick.
Whichever loses, that edit disappears with no way to recover it — the previous
value is not stored anywhere. A note is short enough that resolving it by hand
costs almost nothing, and a plugin that silently discards typed text is a
plugin nobody should trust with their reading.

A future version can offer interactive resolution. It cannot un-discard a note.

### Remote deletion: keep the local annotation

Four options were considered:

1. delete the local annotation,
2. clear only its note,
3. mark the mapping and report,
4. do nothing at all.

**Chosen: 3.** The mapping records `remote_deleted`, the annotation is
untouched, and the count appears in the summary.

Options 1 and 2 make Karakeep the system of record for something the user
created in KOReader. A stray tap in a web UI would then destroy reading notes
on a device that is not even switched on. Option 4 leaves the mapping pointing
at something that no longer exists and says nothing, so the two sides drift
invisibly.

### Writes to KOReader are as narrow as possible

`annotations.lua` changes the `note` and the `color` of an annotation that
already exists. It never adds one, never removes one, and never touches `pos0`,
`pos1`, `text`, `datetime` or `drawer`.

A remote edit is a note someone typed. It is not authority over where a
highlight sits in a book or whether it exists.

The index is re-checked against the annotation's text before writing: a sidecar
can be rewritten by KOReader between the read and the write, and an index that
has shifted would edit the wrong passage. A mismatch is skipped and logged.

### The chapter suffix

Karakeep has no chapter field, so the chapter is folded into the note as
`(Chapter One)` on the way out, and stripped on the way back. Without the strip
every round trip would append it again.

## Offsets

Karakeep's `startOffset`/`endOffset` are **UTF-16 code units over concatenated
DOM text nodes**, established by reading
`packages/shared-react/components/BookmarkHtmlHighlighter.tsx:307-332`:

```js
offset += walker.currentNode.textContent?.length ?? 0;
```

Two things follow, and the first implementation had both wrong:

- **Not bytes.** `ä` is two UTF-8 bytes and one UTF-16 unit; `😀` is four bytes
  and *two* units. Any non-ASCII before a highlight shifted it.
- **No separator between elements.** `<p>one</p><p>two</p>` is `onetwo`.
  `HtmlCleaner.toText` turns every tag into a space, which is right for
  matching and wrong for counting, so everything after the first block boundary
  shifted further.

`offsets.lua` builds the DOM text the way the browser does, matches against a
whitespace-normalised view of it, maps back, and converts to UTF-16 units.
Matching has three attempts, weakest last: exact on collapsed whitespace, then
with whitespace removed entirely (a passage spanning a block boundary is
`onetwo` on the server and `one two` on the device), then a distinctive middle
slice.

### The honest limitation

An offset is a guess about a DOM this plugin never sees. Karakeep may re-crawl;
the extraction that produced `htmlContent` is not guaranteed to match what the
reader renders; and for a **text** bookmark the content is markdown, so offsets
are against the source rather than the rendered HTML and can be a character or
two out.

So **note synchronisation deliberately does not depend on offsets.** It uses
the stored highlight ID. A wrong offset misplaces an underline in Karakeep's
web reader; it does not lose a note or attach one to the wrong passage.

## Failure handling

- **The remote set cannot be read** → the whole article is skipped. Without it
  there is no way to tell a new highlight from one already sent, and duplicates
  are the one outcome only a human can undo. Counted as `skipped`.
- **A create or update fails** → counted as `failed` and reported. The mapping
  is not written for that highlight, so the next sync retries.
- **The mapping cannot be saved** → `mapping_saved = false`, reported to the
  user. The remote side has already moved; the next sync re-derives what it can
  and adopts the rest by text.
- **Writing the annotations fails** → the pulled count becomes a failed count.
  Nothing is reported as brought back that was not.

The summary vocabulary distinguishes `created`, `pushed`, `pulled`, `adopted`,
`conflicts`, `remote_deleted`, `orphans`, `unresolved`, `skipped` and `failed`.
"Nothing new to send" appears only when genuinely nothing happened — a failure
anywhere adds a line, which is the specific complaint the review raised.

## Local books

A downloaded article is a Karakeep bookmark, so its highlights have something to
hang from. A local EPUB is not, and for a long time that difference leaked all
the way to the user: an article's highlights appeared in Karakeep's
**Highlights** view, a book's did not. A book produced one text card whose body
happened to contain the passages as Markdown blockquotes, and nothing else.

Nothing about the model required that. A Karakeep highlight needs a
`bookmarkId`, and the card *is* a bookmark -- it just has to exist first. So
`Card:export` runs the same `HighlightSync.run` against the card once it exists:

```lua
-- features/book_export/card.lua
return Result.ok({
    action = ...,
    bookmark_id = bookmark_id,
    highlights = self:syncHighlights(file_path, bookmark_id),
    cover = self:cover(file_path, bookmark_id),
})
```

Reusing the driver rather than writing a second one is the whole point: stable
per-annotation identity, no duplicates on a repeated export, and a note edited
in Karakeep finding its way back are all properties of `HighlightSync`, not of
the article path. Writing book export its own highlight code would have meant
reimplementing -- and eventually mis-implementing -- every one of them.

**The card body is not part of this.** Since 0.7 the highlights are the only
representation: the body is the user's editable workspace and KaraBridge writes
it exactly once, at creation. The passage text is no longer duplicated into it,
so a highlight change never causes a bookmark update. See
[`synchronization.md`](synchronization.md) for the export flow.

**Highlights sync on every export**, including one where the card already
existed and nothing was written to it. A note edited in Karakeep changes nothing
locally, so if the highlight pass were conditional on the card being written
that edit would never come back.

### Detached offsets

An article's highlight can point at its passage, because the article body
contains it. A book's cannot: the card body is the user's text and deliberately
does not contain the passage.

So book cards pass `offset_mode = "detached"`:

```lua
HighlightSync.run({
    apis = ...,
    bookmark_id = bookmark_id,
    file_path = file_path,
    offset_mode = "detached",
})
```

which means: never fetch the body, never search inside it, send `0, 0`, and do
**not** count that as an unresolved offset -- nothing failed to resolve, there
was nothing to resolve. Counting it would make a perfectly healthy book export
look broken.

Text, note, colour, identity and the stored remote ID behave exactly as for an
article, which is what every later update and pull depends on.

The consequence, stated plainly rather than buried: a book highlight is a real
Karakeep highlight object, but it is **not visually anchored** in the card body.
Karakeep's Highlights view shows it in full. A correct synchronisation is worth
more than an underline pointing at the wrong words.

Articles are untouched: `locate` mode still computes real offsets in UTF-16 code
units over the DOM text, and still loads the article content to do it.

## A mapping belongs to one bookmark

The mapping is a set of remote highlight IDs, and a Karakeep highlight belongs
to exactly one bookmark. Point the same mapping at a different bookmark and
every ID in it is void.

That is not hypothetical, and the failure it caused is instructive. Delete a
book's card in Karakeep and export again: the card is recreated under a new ID,
and its highlights died with the old one. The mapping still named them, so
`Reconcile.plan` produced `remote_deleted` for every single highlight — the
policy for *the user removed this in Karakeep on purpose*, which is deliberately
never undone. The new card stayed empty, on that export and every one after it.

The mapping was right about the IDs being gone and wrong about what that meant.
So `Metadata` now stores `highlights_bookmark_id` alongside it, and
`HighlightSync.run` starts from an empty mapping when the bookmark it is given
is not the one the mapping was built against:

```lua
local owner = Metadata.highlightMapOwner(file_path)
local mapping_voided = owner ~= nil and owner ~= bookmark_id
if mapping_voided then
    mapping = {}
end
```

A missing owner is trusted rather than treated as a mismatch: mappings written
before this field existed were built against whatever bookmark the caller is
passing now, and voiding them would duplicate every highlight once, for every
user, on upgrade.

The distinction this preserves is the one that matters. A highlight missing
from a bookmark that *still exists* was removed on purpose and is still left
alone. A highlight missing because the bookmark itself was replaced is simply
not the same highlight.

## Does the card still exist?

`Card:export` skips a book whose content hash has not moved, which is what makes
a second export nearly free. But the skip used to be complete: no request at
all. A card deleted in Karakeep while the book stayed untouched therefore went
unnoticed for good — the hash matched on every future export, so nothing ever
asked.

The update path handles this by recreating on a 404, but it only
runs when the content *has* changed, which is precisely not this case.

The fix costs nothing, because the question was already being asked. The
highlight pass fetches the card's highlights, and for a deleted card that comes
back `not_found`. `HighlightSync.run` reports it as `remote_missing`, and the
skip branch treats it as "recreate":

```lua
local counts = self:syncHighlights(file_path, card.bookmark_id)
if not (counts and counts.remote_missing) then
    return Result.ok({ action = "skipped", ... })
end
-- otherwise fall through and create a new card
```

One residual gap, stated rather than hidden: a book with no annotations at all
short-circuits before that fetch, so a deleted card would still go unnoticed.
KOReader only offers to export books that have notes, so this is not reachable
through the UI.

## Settings

| Setting | Default | Effect |
|---|---|---|
| `sync_article_highlights` | on | Send local highlights at all |
| `pull_remote_notes` | on | Bring remote note edits back into KOReader |

Turning `pull_remote_notes` off makes the flow push-only again, which is the
right choice for someone who treats KOReader as the sole source of truth.

## Verified

Against a live Karakeep instance, with the fixture in
`spec/fixtures/ebooks/`. The full transcript is in
[`../testing/epub-roundtrip.md`](../testing/epub-roundtrip.md).

Book-card highlights were verified separately against the same instance on
2026-08-02: a first export created the card and two highlights with the correct
colours, notes and chapters; a second created nothing; a note edited in
Karakeep came back onto the right annotation with the card itself reported as
`skipped`; the card and its highlights were then deleted.

Re-run on the same day after deleting the card in Karakeep by hand -- which is
how both defects above were found. It now reports `recreated`, gives a new card
ID, and attaches both highlights to it.
