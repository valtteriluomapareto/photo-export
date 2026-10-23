# Export Record Persistence Store

This document explains how the app persists export status for Photos assets.

## Overview

The app keeps **two parallel record stores**, one per "shape" of export:

- `ExportRecordStore` (timeline) — keyed by `PHAsset.localIdentifier`. Backs the
  year/month exports under `<root>/YYYY/MM/`.
- `CollectionExportRecordStore` (collections) — keyed by
  `(placementId, assetId)`. Backs Favorites, user-album and shared-album exports under
  `<root>/Collections/Favorites/`, `<root>/Collections/Albums/...` and
  `<root>/Collections/Shared Albums/<album>/`.

The two stores share **no key space**: the collection store rejects `.timeline`
placements at every API entry point. As a result a corrupt collection store cannot
affect timeline progress and vice versa.

Both stores use the same persistence mechanism — an append-only JSON Lines log plus a
compacted snapshot — implemented by the shared `JSONLRecordFile` component.

## Files & Locations

- Directory (sandboxed): `~/Library/Containers/<bundle id>/Data/Library/Application Support/<bundle id>/ExportRecords/<destinationId>/`
  - `destinationId` is the **stable logical destination id** — a per-destination key persisted
    beside the security-scoped bookmark (`ExportDestinationStableId` in `UserDefaults`). Each
    destination gets its own isolated record store. The id is *seeded* from the destination
    fingerprint (SHA-256 of volume UUID + volume-relative path for drives with a volume UUID;
    SHA-256 of the canonical path for drives without one — network shares, exFAT) the first
    time a destination validates, then **reused verbatim** for as long as the stored bookmark
    resolves to the same folder. Reusing the seeded id — rather than recomputing the
    fingerprint every launch — is what keeps a network-share remount (whose path-derived
    fingerprint drifts) from opening an empty record dir and re-exporting everything (issue
    #127). The same id keys the AutoSync per-destination state
    (`AutoSync/destinations/<destinationId>/`), the current-run journal, and the
    safety-confirmation store; the fingerprint is retained only as the identity-confidence
    signal for the AutoSync safety gate. Identity ownership and the keying invariant live in
    [`docs/reference/architecture-conventions.md`](architecture-conventions.md) §Destination
    identity.
- Timeline store files:
  - `export-records.jsonl` — append-only mutation log (one JSON object per line)
  - `export-records.json` — compacted snapshot of the current state (single JSON object mapping `id` → `ExportRecord`)
- Collection store files (sit in the same per-destination directory):
  - `collection-records.jsonl` — append-only log of placement and record mutations
  - `collection-records.json` — compacted snapshot containing `placements` (placement metadata keyed by placement id) and `records` (record bodies nested by `[placementId][assetId]`)

Released-writer compatibility fixtures cover record snapshots/logs and the Auto Export
dirty, retry, summary, per-destination token, current-run, safety and scope stores, plus
the stable destination id. See [historical persistence fixtures](../project/historical-persistence-fixtures.md)
for first-release provenance, isolated defaults transport and the explicit global
PhotoKit-token coverage limitation.

## Record-store value sets

This table is the one list of the enum-like strings the two record stores write. The
data-model sections below refer to it rather than repeating the values.
[`scripts/ci/check-persistence-doc.py`](../../scripts/ci/check-persistence-doc.py) reads
each named Swift type and fails CI when a row and the source disagree, so keep the header
and the backticked, comma-separated value lists in this shape.

| Value set | Persisted as | Values |
| --- | --- | --- |
| `ExportPlacement.Kind` | placement `kind`; the collection store never persists `timeline` | `timeline`, `favorites`, `album`, `sharedAlbum` |
| `ExportVariant` | keys of `variants`, in both stores | `original`, `edited`, `originalPairedVideo`, `editedPairedVideo` |
| `ExportStatus` | variant `status` | `pending`, `inProgress`, `done`, `failed` |
| `ExportVariantReason` | variant `reason`; an open set, unknown codes round-trip | `interrupted`, `editedResourceUnavailable`, `editedUnavailableOriginalBackedUp`, `pairedVideoUnavailable` |
| `ExportRecordMutation.Operation` | timeline log `op` | `upsert`, `delete` |
| `CollectionExportRecordStore.LogOp.OpDiscriminator` | collection log `op` | `upsertPlacement`, `deletePlacement`, `upsertRecord`, `deleteRecord` |

The AutoSync metadata files have their own persisted enums, such as
[`AutoSyncFailureCategory`](../../photo-export/Models/AutoSyncFailureCategory.swift); see
[Auto Export metadata recovery](#auto-export-metadata-recovery). They are not record-store
values and are not listed here.

## Data Model — timeline store

- `ExportRecord` (JSON):
  - `id` (String) — `PHAsset.localIdentifier`
  - `year` (Int), `month` (Int)
  - `relPath` (String) — the export folder of the latest in-progress or done write, e.g. `2025/02/`, or
    `2025/02/videos/` for a standalone video written into the `videos` subfolder. Readers
    locate each file from `year`/`month` plus the variant's `subfolder`, not from `relPath`.
    A failure recorded for an asset that has no record yet creates one with `year` and
    `month` `0` and an empty `relPath`; a later in-progress or done write fills them in.
  - `variants` (Object) — keyed by an `ExportVariant` value
    ([value sets](#record-store-value-sets)), each value an `ExportVariantRecord`
- `ExportVariantRecord` (JSON), the same shape in both stores:
  - `filename` (String?) — final exported filename for that variant; see
    [Variants and file names](#variants-and-file-names).
  - `status` (String) — an `ExportStatus` value
  - `exportDate` (ISO8601 date, optional)
  - `lastError` (String?)
  - `subfolder` (String?) — the path component inside the placement folder where the file
    landed. Today's writer sets `"videos"` for every variant of a standalone video asset
    (`PHAssetMediaType.video`) under `videoLayout = .subfolder`, and omits the key
    otherwise; a Live Photo's paired video stays beside its still. A missing key means
    the bare placement folder, which is what records written before the field existed
    decode to.
  - `reason` (String or explicit null) — stable domain reason, separate from error copy:
    an `ExportVariantReason` code. The set is open; see
    [Stable variant reasons](#stable-variant-reasons).
- `ExportRecordMutation` (JSON Lines):
  - `op` — an `ExportRecordMutation.Operation` value
  - `id` — asset id
  - `record` — present on `upsert`, omitted on `delete`

A timeline log line for a Live Photo whose paired video Photos did not provide, from
[`test-fixtures/persistence/v1.6.5/A/export-records.jsonl`](../../test-fixtures/persistence/v1.6.5/A/export-records.jsonl)
(line 11). It shows the failed case, so the paired video has no `filename`; a done one
records the Photos resource's extension, typically `.MOV`, at the still's stem
(`LIVE.MOV` here). The line is wrapped for reading; keys, values and escapes are as
written. That release predates `reason`, so the field is absent:

```json
{"id":"live","record":{"id":"live","year":2024,"month":4,"relPath":"2024\/04\/",
 "variants":{"original":{"filename":"LIVE.HEIC","status":"done","exportDate":"2023-11-14T22:13:20Z"},
 "originalPairedVideo":{"lastError":"Photos has no exportable paired video resource for this Live Photo","status":"failed","exportDate":"2023-11-14T22:13:20Z"}}},
 "op":"upsert"}
```

### Variants and file names

Both stores use the same variant keys and file-naming rules:

- `original` — the original resource at its natural name, e.g. `IMG_0001.HEIC`, or at the
  `_orig` companion name, e.g. `IMG_0001_orig.HEIC`, when it is paired with an `edited`
  write (including the fallback that backs up the original when the edit is unavailable).
- `edited` — the rendered edit at the natural stem, e.g. `IMG_0001.JPG`. With HEIC-to-JPEG
  conversion on, it is also the JPEG made from an unedited HEIC original, which then
  counts as adjusted for variant selection.
- `originalPairedVideo` and `editedPairedVideo` — the Live Photo motion file paired with
  `original` or `edited`. They appear only when "Export Live Photos as paired image +
  video" is on. The extension comes from Photos' paired-video resource, typically `.MOV`.
  The file lands at its still's stem (`IMG_0001.MOV`), or at the `_orig` stem
  (`IMG_0001_orig.MOV`) for `originalPairedVideo` when the asset also has an `edited`
  write.

A name that is taken gets a ` (1)`, ` (2)`, … collision suffix. When several files of one
asset are written together (an edit with its `_orig` companion, or a still with its paired
video), the exporter picks one stem at which every file's name is free, so the group
shares one stem and its collision suffix rather than being split across stems.

A file written alone can instead be recorded against an existing file at its natural name
or one of its suffixes, when that file has the same bytes and no other record in the store
for that placement names it in that folder (see architecture-conventions § Final file commit boundary).
Its `filename` is then the name as the folder spells it, which can differ from the
resource's name in case or Unicode normalization. Every record with a `filename`, whatever
its status, reserves that name in its folder: no other asset or variant adopts a file there
or writes one there, even after the file is deleted. Import Existing Backup drops a
completed record whose file is missing, which frees its name; failed and in-progress
records keep theirs until they are retried. The index behind that check is built from the
records in memory; nothing new is persisted.

Shared albums record only `original`. Their placement kind maps to the `singleResource`
variant policy (`ExportPlacement.Kind.variantPolicy`, not persisted): Photos exposes one
downscaled resource per shared-album asset, so there is no `edited` variant, no `_orig`
companion and no paired video, whatever the version selection, HEIC-to-JPEG and Live Photo
settings. The other kinds use the `standard` policy, which honors those settings.

## Data Model — collection store

- `Snapshot`:
  - `version` (Int) — schema version (current: `1`)
  - `placements` (Object) — placement metadata keyed by placement id; each value is an
    `ExportPlacement` (see below)
  - `records` (Object) — `{ placementId: { assetId: { variants: { variantName: ExportVariantRecord } } } }`
- `ExportPlacement`:
  - `kind` (String) — an `ExportPlacement.Kind` value
    ([value sets](#record-store-value-sets)). The collection store rejects `timeline` at
    every API entry point; persisted snapshots only ever contain `favorites`, `album` and
    `sharedAlbum`.
  - `id` (String) — placement id. Format: `collections:favorites` for the canonical
    Favorites placement; `collections:album:<collectionIdHash16>:<displayPathHash8>` for
    albums; `collections:shared-album:<collectionIdHash16>:<displayPathHash8>` for shared
    albums. The path-hash component changes when an album is renamed or moved between
    folders, and when a shared album is renamed (shared albums never nest, so they never
    move); the next export then resolves to a fresh placement.
  - `displayName` (String) — human-readable label (e.g. `Trips/Iceland`); a shared
    album's title.
  - `collectionLocalIdentifier` (String?) — `PHAssetCollection.localIdentifier` for
    `album` and `sharedAlbum`. Absent for `favorites`.
  - `relativePath` (String) — path under the export root, frozen when the placement is
    created, e.g. `Collections/Albums/Trips/Iceland/` or `Collections/Shared Albums/Family/`.
    Shared albums never nest. When sanitized sibling names collide, later placements get
    `_2`, `_3`, … suffixes; a shared album collides only with other shared albums.
  - `createdAt` (ISO8601 date) — diagnostic only, not part of identity.
- `LogOp` (JSON Lines): four operations, distinguished by an `op` discriminator (a
  `CollectionExportRecordStore.LogOp.OpDiscriminator` value). Record-level bodies are the
  same `{ variants: { ... } }` shape as the snapshot, under the key `record`.

A collection snapshot trimmed to its shared-album placement and that placement's records,
from [`test-fixtures/persistence/v1.6.5/A/collection-records.json`](../../test-fixtures/persistence/v1.6.5/A/collection-records.json).
The other placements and records are omitted and the JSON is indented; keys, values and
escapes are as written. The fixture's placement id is synthetic: a real one has the
`collections:shared-album:…` form above.

```json
{"placements":{
  "fixture-shared":{"id":"fixture-shared","createdAt":"2023-11-14T22:13:20Z","kind":"sharedAlbum","displayName":"Shared","collectionLocalIdentifier":"fixture-shared-collection","relativePath":"Collections\/Shared Albums\/Shared\/"}},
 "version":1,
 "records":{
  "fixture-shared":{"shared":{"variants":{"original":{"status":"done","filename":"SHARED.JPG","exportDate":"2023-11-14T22:13:20Z"}}}}}}
```

The collection store also enforces a referential constraint when replaying the log: an
`upsertRecord` with no matching placement metadata is skipped (with a log line) so a
truncated log can't freeze an orphan record into the next compaction.

### Legacy schema migration

Records produced before per-variant state decoded as a flat object with `filename`, `status`,
`exportDate`, and `lastError` at the top level. The decoder recognises this shape and
synthesises a single `.original` variant:

- Legacy `.done` becomes `.original` done.
- Legacy `.failed` becomes `.original` failed.
- Legacy `.pending` becomes `.original` pending.
- Legacy `.inProgress` becomes `.original` failed with the message
  `Interrupted before completion`. No in-progress state survives app restart.

Any variant (new schema or migrated legacy) left as `.inProgress` at load time is also
converted to `.failed` with the same interrupted message — this keeps progress tracking
recoverable after crashes and force-quits.

Encoding always emits the current schema. Legacy fields are dropped on the next write or
compaction.

### Stable variant reasons

Completion, edited fallback, counters, and friendly recovery copy use `reason`, never
`lastError`. New writers supply reasons explicitly and always encode the field, including
null for ordinary failures. Starting or succeeding clears an old reason; a new generic
failure also clears it. Restart recovery sets `interrupted`.

When the field is absent, decoding a failed legacy variant maps only the four exact,
frozen historical messages. Explicit null and unknown codes suppress this legacy mapping,
even if the error text matches an old sentinel. Unknown strings round-trip unchanged,
remain ordinary incomplete failures, and appear in saved diagnostic reports. Malformed
non-string codes fail decoding through the existing corruption-recovery path.

Existing files are upgraded only through ordinary writes/compaction. The immutable
[historical fixtures](../project/historical-persistence-fixtures.md) pin pre-reason
snapshot/log completion semantics. Older releases ignore the additive field and may
discard it when rewriting; after a downgrade, their completion rules still depend on text.
Known sentinel retry identities remain the frozen historical strings, and edited
render/conversion failures retain the `Export:9` retry identity.

## Lifecycle

Both stores follow the same lifecycle on their own files: `export-records.json` and
`export-records.jsonl` for the timeline store, `collection-records.json` and
`collection-records.jsonl` for the collection store.

1. On first run, the store creates its directory.
2. On launch and on every destination change, the store loads its snapshot (if present), then applies each log line in order to reconstruct the latest state. The app does this off the main actor: the files are read on the store's IO queue, after any writes still queued for the previous destination, and decoded in a detached task, together with the counters and filename claims installed for that history epoch. The store is `.loading` until the result is installed in one main-actor turn; meanwhile its records read as empty and it accepts no mutations. A load that a newer configure replaced is discarded. The compatibility `configure(for:)` prepares on the IO worker without publishing `.loading`; production configuration and Retry use the asynchronous path. A transition waits for previous maintenance and writes before replacing their owner.
3. On updates, the store:
   - Waits for store-owned maintenance admission, then rechecks destination and history ownership before applying one synchronous, bounded batch to memory
   - Appends a JSON line to its log (`export-records.jsonl` or `collection-records.jsonl`)
   - Requests a checkpoint at idle/terminal boundaries once at least 1,000 operations have accumulated, or sooner when the conservative byte/operation replay estimate approaches one second. Explicit maintenance can checkpoint smaller histories. Admission closes before the history is captured, earlier writes drain, and the IO worker encodes, synchronizes and atomically replaces the snapshot before truncating the log. Admission reopens after physical IO completes, including failure or cancellation. Appends never capture whole-history snapshots.
4. The durable log is replayed at next launch if no successful checkpoint truncated it. Replay cost is calibrated off main, with conservative operation/byte fallbacks; the estimate is an admission policy, not a wall-clock guarantee.

`drainSynchronously()` on the JSONL writer and both record stores blocks its caller
until queued IO finishes and delivers any pending persistence failure. It must never
be called from the writer's IO queue. Finishing the drain does not imply failed writes
succeeded; the existing persistence state still reports those failures.

## Crash Safety

- Mutations are fsynced to the log upon append; after a crash, the log is replayed.
- Snapshot creation writes and synchronizes a temporary file, then replaces the old
  snapshot with a single atomic rename (without first deleting the old snapshot).
  The containing directory is synchronized before the log is truncated. If preparing,
  replacing, or synchronizing the snapshot fails, the log is left intact.
- An interruption before replacement leaves the previous snapshot plus the log; an
  interruption after replacement but before truncation leaves the new snapshot plus
  the log. Replaying the idempotent record mutations reconstructs the same state.
- Explicit snapshot writes run on the same serial IO queue as appends and automatic
  compaction. Leftover temporary snapshots are not used during load; a subsequent
  write replaces them. Neither store's file format changes.

## Querying Status

Completion is decided by `ExportCompletionPolicy.isComplete` against the variants that
`requiredVariants(for:selection:policy:convertHEICToJPEG:livePhotosPaired:)` returns:

- the placement's variant policy (`standard`, or `singleResource` for shared albums, which
  requires only `original`);
- the version selection and the asset's current `hasAdjustments`, where an unedited HEIC
  counts as adjusted while HEIC-to-JPEG conversion is on;
- with Live Photo pairing on, the paired-video variant of each required still.

Every required variant must be `done`, with two exceptions. A paired video that failed with
reason `pairedVideoUnavailable` counts as covered. Under the `edited` selection, an
adjusted asset whose `original` is `done` and whose `edited` failed with reason
`editedUnavailableOriginalBackedUp` counts as exported. Filenames are not inspected.

- `isExported(asset:selection:livePhotosPaired:)` on the timeline store, and
  `isExported(asset:placement:selection:livePhotosPaired:)` on the collection store,
  apply that rule to the asset's record. The pairing flag has no default, so every caller
  states it.
- `exportInfo(assetId:)` (timeline) and `exportInfo(assetId:placement:)` (collections)
  return the record; callers read `variants` directly, including the paired-video keys.
- `monthSummary(assets:selection:livePhotosPaired:)` counts the loaded assets for which
  `isExported` holds. The older `monthSummary(year:month:totalAssets:)` and
  `yearExportedCount(year:)` count `original` `done` records only.
- `sidebarSummary(year:month:totalCount:adjustedCount:selection:livePhotosPaired:)`
  approximates the count for sidebar rows without loaded `AssetDescriptor`s, from
  per-month record counters. It returns nil until `adjustedCount` is known. The exported
  count is `editedDone + min(origOnlyAtStem, uneditedCount) + fallbackCovered` for the
  `edited` selection and `bothDone + min(origOnlyAtStem, uneditedCount)` for
  `editedWithOriginals`. With pairing on, records with an incomplete paired video (not
  `done` and not `pairedVideoUnavailable`) are then subtracted. `origOnlyAtStem` counts
  records whose `original` is `done` at a non-`_orig` filename and whose `edited` is not
  `done`. The `uneditedCount` cap keeps natural-stem `original` records of now-adjusted
  assets from counting past the number of assets that could be original-only.

## Error Handling

- A missing snapshot or log is normal. An unreadable file is an IO failure, never an empty history.
- Invalid JSONL lines are skipped and logged, preserving truncated-final-line recovery. A nonempty log without a final LF is remembered when the load is installed (an unreadable log keeps what the file knew); the next operation prefixes a separating LF and writes its JSON plus final LF in one Data write. This prevents a recovered complete or partial tail from absorbing the next operation. Partial OS writes remain possible; the next load isolates them again. Successful snapshot/reset clears the pending separator; failed persistence still blocks later appends until snapshot recovery.
- Snapshot decoding failure enters `.failed`. Reset Records explicitly moves the corrupt snapshot aside and starts empty; Quit preserves it.
- Log read or append/open/write/synchronize failure enters `.persistenceFailed` and blocks new exports through the affected store. The other store remains independent. The recovery alert offers Retry rather than destructive reset.
- In-memory mutations are provisional until `flush()` successfully acknowledges all preceding queued writes and synchronization. Export jobs await this boundary before work and before completion; import also flushes before reporting success. No extra fsync is performed per UI notification.
- After an append failure, the primitive stops subsequent queued appends and compactions. The store retains its in-memory history, including final filenames from an in-flight export. Retry saves this history with an atomic snapshot before returning to ready. Keep the app open until retry succeeds; unacknowledged progress can be lost on quit. Destination switches retain failed histories in memory until the user returns and retries.
- After a read failure, Retry reloads the original files; it never replaces unreadable history with an empty snapshot. Callbacks belonging to a previous destination cannot change the current store's health.

## Conservative import reconciliation

Only child-path ENOENT/ENOTDIR proves a tracked file missing. Other lookup failures,
nonregular targets and invalid stored locations reject the affected store's whole
prune batch. A readable root is verified again off-main after the candidate probes.
The ownership/revision guard runs before applying the worker's Result, suppressing
obsolete errors as well as obsolete prunes. No schema or additional recovery state is
persisted. Backup scanning propagates recognized-folder/type errors before importing;
optional date/size values remain optional. A later failure does not roll back matched
imports or already-verified changes in the other store.

## Import adopts collection placements

Import Existing Backup also rebuilds collection history from the folders under
`Collections/Favorites/`, `Collections/Albums/` and `Collections/Shared Albums/`, each with
its optional `videos/` subfolder. It writes only the existing `upsertPlacement` and
`upsertRecord` operations, so the format is unchanged and older builds read the result.

- **Folders.** A folder is adopted for a current Favorites, album or shared album only when
  `ExportPlacementResolver` could have given it that folder: the sanitized title under the
  sanitized parent folders, or that title with a sibling-collision suffix. Names compare
  case-folded and NFC. A saved placement for the album's current id decides its folder, and
  folders that saved placements own are not adopted by another album. A renamed or moved
  album's old folder is not adopted; the import reports it, and the next export uses a new
  folder.
- **Evidence.** A new placement needs files in the folder that match the album's assets and
  no equal claim from another album or folder. When the folder is where the resolver puts
  the album today and no other album or folder with matches competes for it, one match is
  enough; otherwise at least half of the folder's files must match. A folder with no matches
  is never adopted and is reported, which covers an album deleted and recreated under the
  same title. Equal claims whose folders hold the same files (same names and known sizes)
  follow the resolver's order; other ties adopt nothing. Files in `videos/` match only
  videos. Shared albums adopt originals only. A same-extension edit exported in Edited mode
  without an `_orig` companion is adopted as the original, as on the timeline, so the edit is
  exported again.
- **Case.** Folder names compare case-folded, and the stored path is the resolver's spelling.
  On a case-insensitive volume a folder spelled in another case is the same folder and is
  adopted. On a case-sensitive volume (the scan reads the volume's setting) folders and
  saved placements match only by exact NFC spelling: a folder spelled differently from the
  resolver's or a saved placement's path is not the one exports use, so it is not adopted and
  is reported, and when both spellings exist the exact one is adopted. Where case is ignored,
  two folders whose names differ only by case can't be told apart and neither is adopted.
- **Placements.** An adopted placement has the id the resolver gives the collection and the
  resolver's spelling of the folder path. It is written before its records in one batch. A
  placement already in the history keeps its metadata and `relativePath`.
- **Records.** Each matched file becomes a `done` variant at its folder and subfolder. A
  variant already `done` is left as it is. A repeated import appends nothing.
- **Failures.** Collection folders are scanned with the timeline. A scan error, a failed
  Photos album list or a failed album read fails the import before either history changes.
  When the collection store is not ready, the timeline is still imported and the report
  says albums were skipped. Both histories are written in one main-actor turn and then
  reconciled as above; a later failure does not roll back that commit.

## Interrupted paired-slot recovery

Original-side paired variants can reuse an existing slot only when their record still
has typed `failed/interrupted` status and the persisted placement path, filename and
subfolder match. A utility-worker probe rejects links, directories, empty files, metadata-inspection failures
and positive known-resource-size mismatches. The regular resolver still computes
the candidate. Recovery uses the same captured-destination final-commit barrier as a
move, including timestamps and durable acknowledgement. It cannot reconstruct proof
already erased by an older collision retry and makes no content-hash or crash-atomicity
guarantee.

Known file-exists errors now use the hard retry category `destinationCollision`.
Existing category raw values and signatures are unchanged; saved `.unknown` entries
are reclassified on their next attempt. This adds a persisted retry enum value:
older builds cannot decode a retry file containing it and use their existing metadata
recovery path on downgrade. Export-record schemas are unchanged.

## Auto Export metadata recovery

The separate `dirtyState.json` and `retryState.json` files keep their existing JSON
formats. Loads return empty only when the file is missing; corruption and IO failures
are distinct errors. Before replacing readable invalid JSON, the writer preserves its
exact bytes in a unique `.corrupt-<UUID>` sibling. The original remains until atomic
replacement succeeds. If reading or preservation fails, replacement is refused.

Unknown dirty state requires full reconciliation of recognized scopes. Retry recovery
merges saved and in-memory raw keys, retaining maximum known attempts and conservative
deadlines based on the latest failure time. It cannot reconstruct exact attempts from
inaccessible or corrupt history. Unknown scope and variant keys survive valid recovery.
Failed removals remain published until persistence succeeds; pending in-memory history
does not survive quitting before a successful save.

`lastRunSummary.json` holds the last Auto Export run's `ExportRunSummary`. Its optional
`stoppedBy` field names the destination-wide failure category (`destinationUnavailable`,
`destinationNoSpace` or `destinationPermission`) when the run stopped itself on one, and is
absent otherwise. A summary saved before the field existed decodes with no stop category,
and older builds ignore the key.

A saved `retryState.json` entry in the `destinationUnavailable` category with no
`nextEligibleAt`, including one an older build recorded for a missing file (`ENOENT`), is
eligible for the next Auto Export run. If that attempt fails with `ENOENT` again, the entry
is replaced by an `unknown` one at attempt 1 with the normal backoff.

## Migrations

- Schema changes are handled by reading both the snapshot and the log using compatible
  decoders. The current decoder handles both the flat legacy record shape and the new
  per-variant shape.
- The next full compaction writes the current schema and drops legacy fields.

## Notes

- Checksums are not stored in MVP; we rely on `localIdentifier` and exported filename/path.
- The store is designed to move to SQLite in the future if needed; JSON files remain importable.
