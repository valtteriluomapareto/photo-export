# Export Record Persistence Store

This document explains how the app persists export status for Photos assets.

## Overview

The app keeps **two parallel record stores**, one per "shape" of export:

- `ExportRecordStore` (timeline) — keyed by `PHAsset.localIdentifier`. Backs the
  year/month exports under `<root>/YYYY/MM/`.
- `CollectionExportRecordStore` (collections) — keyed by
  `(placementId, assetId)`. Backs Favorites and user-album exports under
  `<root>/Collections/Favorites/` and `<root>/Collections/Albums/...`.

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

## Data Model — timeline store

- `ExportRecord` (JSON):
  - `id` (String) — `PHAsset.localIdentifier`
  - `year` (Int), `month` (Int)
  - `relPath` (String) — relative export folder, e.g. `2025/02/`
  - `variants` (Object) — keyed by variant name (`original`, `edited`), each value an
    `ExportVariantRecord`
- `ExportVariantRecord` (JSON):
  - `filename` (String?) — final exported filename for that variant. The `.original`
    variant's filename may be the bare stem (e.g. `IMG_0001.JPG`) or the `_orig` companion
    form (e.g. `IMG_0001_orig.HEIC`) depending on whether it was paired with an `.edited`
    write.
  - `status` (String) — `pending` | `inProgress` | `done` | `failed`
  - `exportDate` (ISO8601 date)
  - `lastError` (String?)
- `ExportRecordMutation` (JSON Lines):
  - `op` — `upsert` | `delete`
  - `id` — asset id
  - `record` — present on `upsert`, omitted on `delete`

## Data Model — collection store

- `Snapshot`:
  - `version` (Int) — schema version (current: `1`)
  - `placements` (Object) — placement metadata keyed by placement id; each value is an
    `ExportPlacement` (see below)
  - `records` (Object) — `{ placementId: { assetId: { variants: { variantName: ExportVariantRecord } } } }`
- `ExportPlacement`:
  - `kind` (String) — `timeline` | `favorites` | `album`. The collection store rejects
    `timeline` at every API entry point; persisted snapshots only ever contain
    `favorites` and `album`.
  - `id` (String) — placement id. Format: `collections:favorites` for the canonical
    Favorites placement; `collections:album:<collectionIdHash16>:<displayPathHash8>` for
    albums (the path-hash component changes when the album is renamed or moved between
    folders, so the next export resolves to a fresh placement).
  - `displayName` (String) — human-readable label (e.g. `Trips/Iceland`).
  - `collectionLocalIdentifier` (String?) — `PHAssetCollection.localIdentifier` for
    `.album`. `nil` for `.favorites`.
  - `relativePath` (String) — path under the export root, e.g. `Collections/Albums/Iceland/`.
  - `createdAt` (ISO8601 date) — diagnostic only, not part of identity.
- `LogOp` (JSON Lines): four operations, distinguished by an `op` discriminator —
  `upsertPlacement`, `deletePlacement`, `upsertRecord`, `deleteRecord`. Record-level
  bodies are the same `{ variants: { ... } }` shape as the snapshot.

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

## Lifecycle

1. On first run, the store creates its directory.
2. On launch, the store loads the snapshot (if present), then applies each log line in order to reconstruct the latest state.
3. On updates, the store:
   - Applies the mutation to in-memory state immediately
   - Appends a JSON line to `export-records.jsonl`
   - Periodically compacts:
     - Writes a full snapshot to a temp file
     - Atomically replaces `export-records.json`
     - Truncates `export-records.jsonl`
4. On quit, any pending compaction can run; otherwise the log is replayed at next launch.

## Crash Safety

- Mutations are fsynced to the log upon append; after a crash, the log is replayed.
- Snapshot creation writes to a temporary file and atomically replaces the old snapshot to avoid corruption.

## Querying Status

- `isExported(assetId:)` returns whether the `.original` variant is `done` — a convenience shim
  for legacy call sites.
- `isExported(asset:selection:)` evaluates completion strictly against
  `requiredVariants(for:selection:)` — i.e. the asset's current `hasAdjustments`. No
  filename inspection: a `.original.done` row at any filename satisfies an unedited
  asset's requirement, and an adjusted asset is only satisfied when `.edited.done` (and
  `.original.done` under `editedWithOriginals`).
- `exportInfo(assetId:)` returns the full record; callers inspect
  `record.variants[.original]` and `record.variants[.edited]` directly.
- `monthSummary(assets:selection:)` computes an asset-based summary for a selected month
  by calling the strict, asset-aware `isExported` on each descriptor.
- `sidebarSummary(year:month:totalCount:adjustedCount:selection:)` computes an approximate
  summary for sidebar rows that do not have loaded `AssetDescriptor`s. The formula is
  `editedDone + min(origOnlyAtStem, uneditedCount)` for the default mode and
  `bothDone + min(origOnlyAtStem, uneditedCount)` for include-originals, where
  `origOnlyAtStem` filters records by `!isOrigCompanion(filename:)`. The
  `adjustedCount`-derived cap prevents natural-stem `.original.done` records belonging to
  currently-adjusted assets from over-contributing past the number of assets that could
  legitimately be original-only.

## Error Handling

- If the log contains an invalid line, it is skipped and logged. The rest of the log is still applied.
- If snapshot loading fails, the store transitions to `RecordStoreState.failed` and
  rejects further writes. The corrupt snapshot is **not** renamed automatically — the
  in-app `RecordStoreAlertHost` surfaces a recovery alert with a Reset action that
  renames the corrupt file aside (`<name>.broken-<ISO8601>`) and starts the store with
  an empty snapshot. Choosing Cancel leaves both the snapshot and the user's exported
  files on disk untouched. Each store presents its alert independently — only the
  failed store's records are reset.

## Migrations

- Schema changes are handled by reading both the snapshot and the log using compatible
  decoders. The current decoder handles both the flat legacy record shape and the new
  per-variant shape.
- The next full compaction writes the current schema and drops legacy fields.

## Notes

- Checksums are not stored in MVP; we rely on `localIdentifier` and exported filename/path.
- The store is designed to move to SQLite in the future if needed; JSON files remain importable.
