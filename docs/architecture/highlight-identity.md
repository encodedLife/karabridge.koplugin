# Highlight identity

How KaraBridge decides that a KOReader annotation and a Karakeep highlight are
the same thing.

Implemented by `karabridge/features/article_sync/identity.lua`; the mapping is
stored by `karabridge/shared/metadata.lua`.

## The problem

Two-way synchronisation needs a stable answer to "which local annotation does
this remote highlight belong to". Neither side offers one for free.

**KOReader annotations have no UUID.** They are entries in a Lua array in the
`.sdr` sidecar. The array index changes whenever an annotation is added or
removed, so the index is not an identity.

**Text is not an identity either.** The same sentence can be highlighted twice
in one document — the review brief asks for exactly this case — and a note
attached to the wrong occurrence is worse than a note left unattached.

**Karakeep's highlight ID is stable**, and is what the mapping stores. The work
is on the local side.

## What an annotation carries

```lua
{
    drawer   = "lighten",                 -- highlight style; absent on a page bookmark
    text     = "the highlighted passage",
    note     = "the user's note",
    color    = "cyan",
    chapter  = "Chapter One",
    datetime = "2026-08-02 16:01:00",
    pos0     = "/body/DocFragment[1]/body/p[2]/text().0",   -- EPUB: crengine XPointer
    pos1     = "/body/DocFragment[1]/body/p[2]/text().31",  -- PDF: { page, x, y }
}
```

## The fingerprint

A hash over the strongest available basis, reported alongside the value so a
caller knows how much to trust it.

| Basis | Built from | When |
|---|---|---|
| `position` | `pos0`, `pos1`, text | Both positions present — the normal case |
| `datetime` | `datetime`, text | No position; rare, but PDFs and imports produce it |
| `text` | text | Neither; the weakest, and the only one that can collide |

Position first, because that is the only thing that distinguishes two identical
passages. `renderPosition` reduces a PDF position table to its page: the
coordinates are floats that can be re-derived slightly differently, and within
one page the datetime and the text do the rest.

### What is deliberately excluded

**The note and the colour.** Those are the fields synchronisation *changes*. A
fingerprint that moved when the note was edited would lose the mapping at
exactly the moment it is needed — the first pull would look like a new
annotation and create a duplicate highlight.

This is covered by two specs that would fail loudly if someone added `note` to
the hash: "is stable when the note changes" and "is stable when the colour
changes".

### Collisions

Two annotations with no position, the same `datetime` and the same text produce
the same fingerprint. `Identity.index` reports those rather than silently
keeping one: a colliding pair cannot be told apart later either, and a mapping
built on one would eventually attach a note to the wrong passage.

## The stored mapping

Sidecar schema **version 2** adds `highlights`, keyed by fingerprint:

```lua
karabridge = {
    version = 2,
    article = { bookmark_id = "…", remote_modified_at = "…", … },
    highlights = {
        ["8f2c1a9e4b7d0356"] = {
            remote_id   = "aaaaaaaaaaaaaaaaaaaaaaa3",
            local_hash  = "…",   -- note+colour as they were at the last sync
            remote_hash = "…",   -- the remote's note+colour at the last sync
            basis       = "position",
            synced_at   = 1785680000,
            adopted     = true,  -- matched by text rather than created here
            conflict    = { at, local_note, remote_note },  -- when both changed
            remote_deleted = true,                          -- when it vanished
        },
    },
}
```

The two hashes are what make "which side changed" answerable without asking
either system for a modification time — Karakeep exposes none per highlight,
and KOReader exposes none at all. See
[`highlight-sync.md`](highlight-sync.md) for how they are used.

`basis` is recorded so a future problem is diagnosable: a mapping built on
`text` is one to be suspicious of.

## Migration

**v1 → v2** adds an empty `highlights` table and nothing else. It is additive,
so nothing already recorded is lost, and a device that has been offline through
several versions migrates in one step.

Highlights pushed by v1 were created and their remote IDs discarded, so there
is nothing to migrate them *from*. They are picked up by adoption instead.

## Adoption

A remote highlight with no mapping — pushed by an older version, or created
directly in Karakeep's web UI — is matched to an unmapped local annotation by
normalised text.

**Only when exactly one local annotation matches.** Two identical passages are
precisely what text cannot resolve; guessing would attach the note to the wrong
sentence. An ambiguous match is reported as an orphan and left alone, and the
local annotations are then created as new highlights, which is the honest
outcome: the user ends up with a visible duplicate they can resolve, rather
than an invisible mis-attachment.

## When the mapping is missing or damaged

| Situation | Behaviour |
|---|---|
| No `highlights` table | Treated as empty; everything is a create or an adoption |
| A record with no `remote_id` | Treated as unmapped; create or adopt |
| A record pointing at a deleted highlight | `remote_deleted`, local annotation kept |
| The sidecar cannot be written | Reported as `mapping_saved = false`; the remote side already moved, so the next sync re-derives what it can |
| Two annotations with the same fingerprint | Reported as a collision; one is mapped, the other treated as unmapped |

None of these delete or overwrite a user annotation. That is the invariant the
whole design is arranged around.

## Limitations

- **An XPointer is stable for a file, not across files.** Re-downloading an
  article produces a new EPUB whose XPointers may differ, which invalidates
  every position-based fingerprint for it. This is one reason the sync refuses
  to replace an article the user has opened — see
  [`synchronization.md`](synchronization.md).
- **A `text`-basis fingerprint is weak** and collides for repeated passages.
  It is reached only when an annotation has neither a position nor a datetime,
  which KOReader does not normally produce.
- **Adoption is one-shot per sync.** A highlight created in Karakeep's web UI
  with text that matches nothing locally stays an orphan for ever. Creating a
  KOReader annotation from a remote highlight would mean inventing a position,
  which is not something this plugin should guess at.
