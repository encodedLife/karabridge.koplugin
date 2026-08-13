--[[--
Deciding what to do with each highlight, on both sides.

This is the whole two-way policy in one pure function. It takes the local
annotations, the remote highlights and the mapping recorded at the last sync,
and returns a list of actions. Nothing here touches a sidecar or a network, so
every branch — including the ones that are hard to reach on a device, like a
conflict — is covered by a spec.

## How "changed" is decided

For each mapped pair, two hashes were recorded at the last successful sync: one
of the local note and colour, one of the remote. Comparing today's values with
those says which side moved.

| Local | Remote | Action | Why |
|---|---|---|---|
| same | same | `none` | nothing happened |
| changed | same | `push` | send the local edit |
| same | changed | `pull` | apply the remote edit locally |
| changed | changed | `conflict` | **neither side is overwritten** |

## Conflicts

The local annotation wins by staying exactly as it is, and the remote value is
left alone too. The conflict is recorded and shown in Diagnostics. This is the
conservative policy the review asks for: whichever side we picked
automatically, the other person's edit would vanish with no way to get it back,
and a note is small enough that resolving it by hand costs almost nothing.

## Remote deletion

**Chosen policy: keep the local annotation and report the difference.**

The alternatives were considered and rejected. Deleting the KOReader annotation
makes Karakeep the system of record for something a user created in KOReader,
and a stray tap in a web UI would silently destroy reading notes. Clearing only
the note is the same problem in miniature. Doing nothing at all and not saying
so leaves the mapping pointing at something that no longer exists.

So the mapping is marked `remote_deleted`, the annotation is untouched, and the
count appears in the summary. A future version can offer to re-create the
remote highlight or drop the local one, as an explicit choice.

## Adoption

A remote highlight with no mapping — because it was pushed before mappings
existed, or created in Karakeep directly — is matched to an unmapped local
annotation by normalised text. **Only when exactly one candidate matches.**
Two identical passages are precisely the case a text match cannot resolve, and
attaching a note to the wrong one is worse than leaving it unattached.

@module karabridge.features.article_sync.reconcile
]]

local Identity = require("karabridge.features.article_sync.identity")
local Text = require("karabridge.shared.text")

local Reconcile = {}

--- The note and colour of a remote highlight, normalised for comparison.
-- @tparam table remote
-- @treturn table `{ note, color }`
function Reconcile.remoteFields(remote)
    return {
        note = type(remote.note) == "string" and remote.note or "",
        color = type(remote.color) == "string" and remote.color or "",
    }
end

--- The note and colour of a local annotation, mapped to Karakeep's palette.
--
-- The colour is compared in Karakeep's four-colour space, not KOReader's:
-- KOReader's `cyan` and `blue` both become `blue` remotely, so comparing raw
-- values would report a change on every single sync.
--
-- @tparam table annotation
-- @treturn table `{ note, color }`
function Reconcile.localFields(annotation)
    local Highlights = require("karabridge.api.highlights")
    return {
        note = type(annotation.note) == "string" and annotation.note or "",
        color = Highlights.mapColor(annotation.color),
    }
end

--- Work out what to do with every highlight on both sides.
--
-- @tparam table opts
--   annotations  array from the sidecar
--   remote       array of Karakeep highlights
--   mapping      fingerprint -> `{ remote_id, local_hash, remote_hash, … }`
-- @treturn table `{ actions = {...}, collisions = {...} }` where each action is
--   `{ kind, fingerprint, index, annotation, remote, remote_id, fields }` and
--   `kind` is "create", "push", "pull", "conflict", "remote_deleted",
--   "adopt" or "orphan".
function Reconcile.plan(opts)
    local annotations = opts.annotations or {}
    local remote_list = opts.remote or {}
    local mapping = opts.mapping or {}

    local actions = {}
    local local_index, collisions = Identity.index(annotations)

    -- Remote highlights by ID, and the set still unaccounted for.
    local remote_by_id, unclaimed_remote = {}, {}
    for _, remote in ipairs(remote_list) do
        if type(remote) == "table" and type(remote.id) == "string" then
            remote_by_id[remote.id] = remote
            unclaimed_remote[remote.id] = true
        end
    end

    -- Pass one: everything with a recorded mapping.
    for fingerprint, entry in pairs(local_index) do
        local record = mapping[fingerprint]
        local fields = Reconcile.localFields(entry.annotation)
        local local_hash = Identity.contentHash(fields)

        if not record or not record.remote_id then
            -- No mapping yet. Adoption is tried in pass three; for now this is
            -- a candidate for creation.
            table.insert(actions, {
                kind = "create",
                fingerprint = fingerprint,
                index = entry.index,
                annotation = entry.annotation,
                fields = fields,
                basis = entry.basis,
            })
        else
            local remote = remote_by_id[record.remote_id]
            unclaimed_remote[record.remote_id] = nil

            if not remote then
                table.insert(actions, {
                    kind = "remote_deleted",
                    fingerprint = fingerprint,
                    index = entry.index,
                    annotation = entry.annotation,
                    remote_id = record.remote_id,
                })
            else
                local remote_fields = Reconcile.remoteFields(remote)
                local remote_hash = Identity.contentHash(remote_fields)

                local local_changed = local_hash ~= record.local_hash
                local remote_changed = remote_hash ~= record.remote_hash

                local kind
                if local_changed and remote_changed then
                    kind = "conflict"
                elseif local_changed then
                    kind = "push"
                elseif remote_changed then
                    kind = "pull"
                else
                    kind = "none"
                end

                if kind ~= "none" then
                    table.insert(actions, {
                        kind = kind,
                        fingerprint = fingerprint,
                        index = entry.index,
                        annotation = entry.annotation,
                        remote = remote,
                        remote_id = record.remote_id,
                        fields = fields,
                        remote_fields = remote_fields,
                    })
                end
            end
        end
    end

    -- Pass two: remote highlights nobody claimed.
    local unmapped_creates = {}
    for _, action in ipairs(actions) do
        if action.kind == "create" then
            table.insert(unmapped_creates, action)
        end
    end

    for id in pairs(unclaimed_remote) do
        local remote = remote_by_id[id]
        local wanted = Text.normaliseWhitespace(remote.text or "")

        -- Adopt only on an unambiguous text match. Two identical passages are
        -- exactly what text cannot resolve, and guessing attaches a note to
        -- the wrong sentence.
        local matches = {}
        if wanted ~= "" then
            for _, candidate in ipairs(unmapped_creates) do
                if Text.normaliseWhitespace(candidate.annotation.text or "") == wanted then
                    table.insert(matches, candidate)
                end
            end
        end

        if #matches == 1 then
            matches[1].kind = "adopt"
            matches[1].remote = remote
            matches[1].remote_id = id
            matches[1].remote_fields = Reconcile.remoteFields(remote)
        else
            table.insert(actions, {
                kind = "orphan",
                remote = remote,
                remote_id = id,
                ambiguous = #matches > 1,
            })
        end
    end

    return { actions = actions, collisions = collisions }
end

--- Count each kind of action, for the summary.
-- @tparam table plan From `Reconcile.plan`.
-- @treturn table
function Reconcile.counts(plan)
    local counts = {
        create = 0,
        push = 0,
        pull = 0,
        conflict = 0,
        remote_deleted = 0,
        adopt = 0,
        orphan = 0,
    }

    for _, action in ipairs(plan.actions or {}) do
        counts[action.kind] = (counts[action.kind] or 0) + 1
    end

    return counts
end

return Reconcile
