# Import Existing Backup — Collections Plan (issue #106)

Date: 2026-05-21
Status: Proposed (not started). Targets `main`. Sequences naturally on top of PR #105
(videos-subfolder layout) — see "Sequencing vs PR #105" below for the gating decisions.

## Summary

`BackupScanner.scanBackupFolder(at:)` walks the `YYYY/MM/` timeline tree only. Files under
`Collections/Favorites/`, `Collections/Albums/<…folders…>/<Title>/`, and
`Collections/Shared Albums/<Title>/` are invisible to **Import Existing Backup** today.
Users who exported to collections and then re-installed see all timeline records restored
but every collection asset treated as unexported on the next run — duplicate writes follow
(with `_2`/`_3` collision suffixes or overwrites, depending on the destination resolver
path).

This plan extends the scanner to descend the three collection roots, adds a placement-
reconstruction pass that resolves each on-disk folder back to its `(kind,
collectionLocalIdentifier, displayPathHash8)` placement, lands `bulkImportRecords` on
`CollectionExportRecordStore`, and wires both into the existing `ImportCoordinator` flow.
The matching classifier (`matchSingleFile`) is unchanged — same `_orig` / paired-video /
edited-extension rules — but the per-asset fetch becomes scoped to the placement instead of
year-month.

Two follow-on dependencies, both off the critical path:

- **Videos subfolder descent** (PR #105) inside album folders comes free once #105 lands —
  this plan calls the helper but does not block on it.
- **Cleanup of deleted-album placements** is out of scope; stale collection-store
  placements remain on disk and the import simply ignores them when reconciling.

## Implementation Status

| Sub-phase | Status | Notes |
|---|---|---|
| A. Collection-root scanner | Not started | `BackupScanner.scanCollections(at:)` walking three roots into a `[CollectionScanGroup]`. |
| B. Placement reconstruction | Not started | New `BackupCollectionPlacementMatcher` joins scan groups to PhotoKit collections + existing placements. |
| C. Per-placement matching | Not started | Extend the existing per-month classifier loop to also run per-placement against asset-scoped fingerprints. |
| D. Bulk import for collection store | Not started | `CollectionExportRecordStore.bulkImportRecords(placements:records:)`. |
| E. ImportCoordinator wiring | Not started | New stage + report fields; reconcile order unchanged. |
| F. Tests | Not started | Scanner unit tests, matcher unit tests, idempotency + reconcile integration. |
| G. UX + docs | Not started | Update ImportView caption, README, website Import page. |

## Goals

- Restore collection records (favorites + user albums + shared albums) from disk truth on
  Import Existing Backup, with the same idempotency and reconcile properties the timeline
  side already has.
- Reuse `matchSingleFile` and its surrounding classifier rules unchanged — the matcher is
  scope-agnostic; only the candidate-asset set changes per scope.
- Keep the disjoint-key-space invariant between the two stores intact: timeline-side bulk
  import writes only to `ExportRecordStore`, collection-side bulk import writes only to
  `CollectionExportRecordStore`. No cross-store routing in the import path.
- Preserve placement identity across import: an album that gets re-imported and then
  re-exported must land at the *same* `relativePath` the existing files already occupy,
  not at a freshly-suffixed sibling.

## Non-Goals

- Cleanup or compaction of stale `CollectionExportRecordStore` placements for deleted
  albums. Stays out of scope (same line drawn by the existing collection-store reconcile —
  it prunes records, not placements).
- Recovering the on-disk folder for an album whose PhotoKit identifier no longer exists
  ("orphan folder"). The import logs and skips the folder; the user can delete it or
  rename a current album to match if they want a manual reconciliation.
- Videos-subfolder descent inside album folders is mechanically supported by this plan but
  becomes correct only once PR #105 lands. With #105 unmerged, a user who reads
  `Collections/Albums/Trip/videos/IMG.MOV` from a hypothetical future export would land
  in the `unmatched` bucket — but no such file can exist yet because #105 hasn't shipped.
- Cross-extension `.original` vs `.edited` heuristics for collection placements differ in
  no way from the timeline side. If the user's classification preferences change, that's
  a global change, not a collection-side one.

## Sequencing vs PR #105

PR #105 introduces `ExportPlacementPathPolicy.relativePath(placement:subfolder:)` and the
per-variant `subfolder: String?` field on `ExportVariantRecord`. This plan touches neither
file directly. Two viable orderings:

**Option A — merge #105 first (recommended).** This plan's collection-root scanner
descends an extra `videos/` directory if present, mirroring what #105 added on the
timeline side. The path helper exists for both. `bulkImportRecords` writes
`subfolder: nil` for every imported record (collection videos-subfolder exports cannot
exist yet) and the timeline-side change in #105 is unaffected.

**Option B — land this plan first.** Drop the `videos/` descent. The scanner walks one
level under each collection folder, exactly as the timeline side does today (no `videos/`
descent on the timeline side either, on current `main`). When #105 lands, a small
follow-up adds the same `videos/` descent to both the timeline branch and the collection
branch in one diff.

Either ordering keeps the merge mechanically clean. The plan below is written assuming
Option A (descent included). If Option B is chosen, delete `BackupCollectionScanner`'s
`videos/` recursion and the corresponding test case; the rest is untouched.

## Architectural Decisions

### 1. Three collection roots, one shared scanner method

`Collections/Favorites/`, `Collections/Albums/<…>/<Title>/`, and
`Collections/Shared Albums/<Title>/` each have different nesting rules:

- Favorites: exactly one level — files sit directly under `Collections/Favorites/`.
  There is no parent folder; the placement id is fixed (`collections:favorites`).
- Albums: zero or more `<folder>/` segments under `Collections/Albums/`, then exactly one
  `<Title>/` leaf containing files. Top-level albums sit immediately under `Albums/`.
- Shared Albums: exactly one `<Title>/` leaf under `Collections/Shared Albums/`. Shared
  albums never nest (Photos does not allow it; `ExportPlacementResolver` already encodes
  this invariant).

Modeling: one scanner enumerator (`BackupCollectionScanner.scanCollections(at:)`) emits a
typed `CollectionScanGroup` per leaf folder, carrying its kind and its on-disk
`pathComponents + title`. The matcher then handles the kind-specific lookups against
PhotoKit and the existing placement set.

```swift
struct CollectionScanGroup {
  enum Kind { case favorites, album, sharedAlbum }
  let kind: Kind
  /// For `.album`: the parent folder path (sanitized, may be empty for top-level).
  /// For `.favorites` and `.sharedAlbum`: always empty.
  let parentPathComponents: [String]
  /// For `.favorites`: empty (the placement is keyed by kind alone).
  /// For `.album` and `.sharedAlbum`: the sanitized leaf folder name as it appears on disk.
  let leafName: String
  /// On-disk URL of the leaf folder containing files.
  let folderURL: URL
  let files: [BackupScanner.ScannedFile]
}
```

Files inside leaf folders re-use `BackupScanner.ScannedFile` unchanged — same
collision-suffix logic, same `_orig` parsing rules. The `year`/`month` fields on
`ScannedFile` lose their meaning for collection groups; they're stamped as `0/0` (or the
file's modification date is honoured if present) and the matcher does not key on them.

### 2. Placement reconstruction is a join over three sets

Each `CollectionScanGroup` resolves to an existing `ExportPlacement` via this join:

1. **Existing placements** in `CollectionExportRecordStore.placements`. The collection
   store already persists every placement with its `relativePath` and
   `collectionLocalIdentifier`. A scanner-group leaf path of `Collections/Albums/Trip/`
   that matches an existing placement's `relativePath` (case-sensitive, byte-for-byte) is
   reused as-is. No new placement is created.
2. **PhotoKit collections** (the result of `fetchCollectionTree()`). When no existing
   placement matches the scanner leaf path, the matcher searches the PhotoKit tree for an
   album/shared album whose `(parentPathComponents, title)` sanitizes to the leaf path.
   If found, it constructs a fresh placement via `ExportPlacementResolver` and writes it
   alongside the records.
3. **Orphan folders**: scanner leaf paths that match neither (1) nor (2) — typically an
   album that was deleted from Photos after the backup was written. The matcher emits one
   log line per orphan folder and skips it; every file under that folder lands in the
   import report's `unmatched` bucket. We do not create a "phantom" placement for it;
   without a PhotoKit identifier the placement would be unreusable.

Why this order: existing placements are authoritative because they encode the user's
prior collision-suffix decisions (e.g. `Trip_2` was assigned to a specific
`collectionLocalIdentifier`, not just any album titled "Trip"). Re-running the resolver
without that anchor would re-derive collision suffixes from scratch and could shuffle
which on-disk folder maps to which album when more than one collision is involved.

### 3. Collision-suffix detection on disk: name doesn't decide kind

A leaf folder named `Trip_2` could be either (a) a renamed-to-include-`_2` album, or (b)
a sibling-collision suffix for one of two distinct albums titled "Trip". The matcher
cannot decide between these from the folder name alone, and must not try.

The resolver in production never strips the `_2` suffix — it treats every leaf as the
literal folder name and lets `displayPathHash8` (computed from PhotoKit's *current* title)
disambiguate. Import follows the same rule:

- If an existing placement has `relativePath` ending in `Trip_2/` and a
  `collectionLocalIdentifier` whose current title in PhotoKit is "Trip_2", the placement
  is reused; the title-with-underscore is the user's literal album name.
- If an existing placement has `relativePath` ending in `Trip_2/` and the current
  PhotoKit title is "Trip", the placement is reused as the collision-suffixed variant —
  the user did not rename, the resolver assigned the suffix when this album was first
  exported, and the import must respect that historical assignment.
- If no existing placement matches the leaf path *and* the PhotoKit tree has an album
  whose sanitized title is "Trip_2", a fresh placement is created at `Trip_2/` with no
  suffix. (User literally named the album with an underscore.)
- If no existing placement matches the leaf path *and* the PhotoKit tree only has an
  album titled "Trip" (no `Trip_2`), the matcher leaves the folder unmatched. It does
  *not* attempt to retroactively assign the album the `_2` suffix — doing so would force
  every other "Trip" sibling's mapping to shift, which is exactly the bug the user
  hit. A `manual` follow-up could lift this restriction once the matcher knows the full
  sibling set; for now, an orphan folder is a safer failure mode than a wrong-album
  match.

This rule is the load-bearing invariant: **a scanner leaf path that has no existing
placement match must resolve via title-sanitization equality to PhotoKit, or it is an
orphan**. The resolver is the only authority on suffix assignment.

**Post-resolver path-equality guard.** When the matcher constructs a fresh placement via
`ExportPlacementResolver.placement(for:collections:existingPlacements:)`, the resolver
consults the *full* current sibling set to assign a leaf suffix and may legitimately
return a placement whose `relativePath` last segment **disagrees with the scanner's
on-disk leaf name**. Example: the on-disk folder is `Trip_2/`, PhotoKit has an album
"Trip" whose existing placement already claims `Trip/`, and no existing placement
matches `Trip_2/`. The resolver, asked to place "Trip", will return `Trip/` (its
current claim) — not `Trip_2/`. Without a guard, the matcher would write records under
the resolver's `Trip/` placement while the files are at `Trip_2/` on disk; the next
reconcile pass then prunes every just-imported record. **Mitigation:** after the
resolver returns, compare the placement's leaf segment to `group.leafName`. On
disagreement, demote to `orphan(reason: .resolverDisagreesWithOnDiskLeaf)` and log
both names. The user can rename either side and re-run import; a wrong-folder write
is a much worse outcome than an orphan.

**Sanitization non-injectivity tie-break.** `ExportPathPolicy.sanitizeComponent` is
lossy: two distinct PhotoKit titles ("Trip:" and "Trip_") sanitize to the same on-disk
leaf "Trip_". When no existing placement matches the leaf and *more than one* PhotoKit
album's sanitized title equals the leaf, the matcher must not pick arbitrarily — it
emits `orphan(reason: .ambiguousPhotoKitMatch(candidateIds:))` and logs all
candidates. (Auto-tie-break by edit-distance to the raw title is appealing but
quietly favors one rename history over another; orphaning is more honest.) The case
is rare — banned scalars in album titles are exceptional — but the failure mode of
picking the wrong album silently is severe enough to gate.

### 4. Per-placement matching, scoped fingerprints

`BackupScanner.matchFiles` today fetches assets per `(year, month)` because the timeline
scope is naturally month-bucketed. For collection groups the equivalent scope is
"assets in this placement's collection" — which the existing
`PhotoLibraryService.fetchAssets(in scope: PhotoFetchScope, mediaType:)` already
exposes via `.favorites` / `.album(localId)` / `.sharedAlbum(localId)`.

Implementation:

- Introduce a new top-level `matchCollectionFiles(_:photoLibraryService:placements:progress:)`
  on `BackupScanner` that mirrors the existing `matchFiles` shape but iterates
  per-placement instead of per-year-month, and skips the adjacent-month pre-fetch (no
  time-zone boundary equivalent for collections).
- Build fingerprints **once per asset** using the existing
  `buildFingerprints(for:using:)`. An asset can legitimately appear in multiple
  collection placements (e.g. Favorites + an Album). The matcher dedupes by
  `localIdentifier` across all placement scopes before calling `buildFingerprints`, so
  the resource fetch cost stays O(distinct assets) not O(distinct assets × placements).
- Per-placement, narrow candidates to assets whose fingerprint is in the placement's
  member set, then call `matchSingleFile` unchanged.

Single-resource variant policy: shared-album placements get
`ExportPlacement.Kind.variantPolicy == .singleResource`, which collapses
`requiredVariants` to `[.original]`. The classifier still ranks candidates against the
full fingerprint list; the difference shows up later, in
`CollectionExportRecordStore.isExported`, where shared-album records evaluate against
the single-resource policy. The import path does not need a separate branch — every
matched file becomes a single-variant record exactly as it does for the favorites/albums
case.

### 5. `bulkImportRecords` on the collection store

Mirrors the timeline-store API but with the collection-store's nested
`(placementId, assetId)` shape. Signature:

```swift
extension CollectionExportRecordStore {
  /// Bulk-imports placement metadata and per-asset records discovered by
  /// Import Existing Backup. Idempotent: an existing `.done` variant for a
  /// given `(placementId, assetId, variant)` is preserved; weaker statuses
  /// may be replaced by an imported `.done`. Placements are upserted with
  /// `.upsertPlacement` before their records to satisfy the orphan-record
  /// guard in `apply(.upsertRecord)`.
  func bulkImportRecords(
    placements: [ExportPlacement],
    records: [(placement: ExportPlacement, assetId: String, variant: ExportVariant, filename: String, exportedAt: Date)]
  )
}
```

Implementation notes:

- Refuses `.timeline` placements via the same `accept(_:)` gate the other entry points
  use. Three-layer defense remains intact.
- Writes one `upsertPlacement` per unique placement first, then one `upsertRecord` per
  `(placement, asset)` group. Multiple variants for the same `(placement, asset)` merge
  into a single `RecordBody` and emit one `upsertRecord` — same merge rule the existing
  timeline-side bulk API uses.
- Early-return when `state != .ready` (same belt-and-braces no-op pattern). The
  `ImportCoordinator` already gates on the collection store equivalent.
- Returns `Void` to match `bulkImportRecords` on the timeline store. Per-record skip
  counts are logged but not surfaced in the report (the existing import-report shape
  doesn't carry that detail; not worth widening).

### 6. ImportCoordinator wiring — minimal surface, three deltas

The existing flow is: scan → match → bulk-write timeline → reconcile both → done. The
collection-side extension folds in alongside, not in a separate task:

1. **Scan step**: after `BackupScanner.scanBackupFolder`, call the new
   `BackupCollectionScanner.scanCollections` (or one combined `scanAll` helper if the
   shared file enumeration is worth factoring). The combined result is one
   `[ScannedFile]` for timeline plus one `[CollectionScanGroup]` for collections.
2. **Match step**: keep the existing `BackupScanner.matchFiles` for timeline files, add a
   call to `BackupScanner.matchCollectionFiles` for the collection groups. Both passes
   contribute to a single user-visible stage `.matchingAssets(matched: Int, total: Int)`
   where `matched` and `total` sum across timeline + collection files. Internally the
   coordinator can keep `.matchingCollectionAssets` as a *telemetry-only* substage if
   useful for logs, but `ImportView.stageLabel` switches both onto the same
   "Matching assets…" phrase — surfacing two distinct phrases for what the user sees
   as one operation violates Progressive Disclosure (HIG, *Information design*).
3. **Bulk-write step**: existing `host.exportRecordStore.bulkImportRecords(timelineRecords)`
   stays. Add `host.collectionExportRecordStore.bulkImportRecords(placements:records:)`
   alongside.
4. **Reconcile step**: unchanged. The collection store's `reconcileAgainstFilesystem`
   already exists and runs after bulkImport, mirroring the timeline side.

Cancellation seam: same `queueCoordinator?.isCurrent(importGen)` checks after every
`await` — re-thread one for the new match step and one for the new bulk-write step. The
existing checks already guard the reconcile pass.

`ImportReport` widens by three counters so the user can see collection-side outcomes
separately:

```swift
struct ImportReport: Equatable {
  let matchedCount: Int          // timeline + collection
  let collectionMatchedCount: Int // NEW. subset of matchedCount, for the UI breakdown
  let ambiguousCount: Int        // timeline + collection
  let unmatchedCount: Int        // timeline + collection
  let totalScanned: Int          // timeline + collection
  let prunedVariants: Int        // unchanged: sum across both stores
  let prunedRecords: Int         // unchanged: sum across both stores
}
```

Open: whether to break out collection ambiguous/unmatched too. The simplest cut surfaces
only the matched breakdown ("X matched in timeline, Y in collections") since ambiguous
and unmatched files are equally diagnostic regardless of which side they came from. The
ImportView already shows `unmatchedCount` as a single row; keep it that way.

### 7. Gate ordering and `state == .ready` checks

`ImportCoordinator.startImport` today gates on `exportRecordStore.state == .ready`. The
collection store needs the same guard. In production the collection store reaches
`.ready` via `configure(for: nonNilId)` (the `.absent` snapshot branch sets `.ready`
even with no snapshot file present), so first-time-destination imports proceed normally;
only `.failed` or `.unconfigured` are pathological at the gate.

Add the symmetric gate:

```swift
guard host.collectionExportRecordStore.state == .ready else {
  logger.error(
    "Cannot import: collection record store state=\(...); refusing import"
  )
  return
}
```

**Refuse the whole import on non-`.ready`.** A `.failed` collection store means we
cannot persist *any* collection records this session; a partial timeline-only import
would lie by omission ("0 album exports recognized") with no signal that the import
ran with a broken substrate. Refusing keeps the user's mental model coherent — import
either worked or it didn't — and the failure is idempotent: the user can re-run after
the store recovers via the corruption-recovery alert (`RecordStoreAlertHost`) which
calls `resetToEmpty()`.

`.unconfigured` should not be reachable through the normal flow (the existing
`selectedFolderURL` gate above already ensures both stores have been configured), but
the symmetric `state == .ready` check guards a future code path that might invoke
import from a different surface (e.g. AutoSync recovery, scripted reset) without
re-checking the store state.

## Implementation

### Phase A — Collection-root scanner

**New file:** `photo-export/Export/BackupCollectionScanner.swift`

Lives next to `BackupScanner.swift` in `Export/`. Plain `struct` per the actor-isolation
policy (pure helper, no shared state). One static method:

```swift
struct BackupCollectionScanner {
  static func scanCollections(at rootURL: URL) -> [CollectionScanGroup]
}
```

Walks three subtrees:

- `<root>/Collections/Favorites/` — flat. One group with `kind = .favorites`,
  `parentPathComponents = []`, `leafName = "Favorites"` (informational; the placement id
  is fixed). Files in subdirectories of `Favorites/` are ignored — the favorites
  placement is single-level by construction. Exception: under Option A above, also
  descend `Favorites/videos/` and merge its files into the same group with
  `subfolder = "videos"` stamped on each `ScannedFile`. (Requires a new optional
  `subfolder: String?` field on `BackupScanner.ScannedFile`; defaults to `nil` so all
  existing timeline-side callers stay correct.)
- `<root>/Collections/Albums/` — recursive. The deepest directory whose path under
  `Albums/` is non-empty is a candidate leaf. The tree is "folders contain albums OR
  other folders"; an album is recognised as a leaf when its contained entries are
  files (not subdirectories) — *modulo* a single `videos/` subdirectory under Option A.
  Each leaf produces one `CollectionScanGroup`.
- `<root>/Collections/Shared Albums/` — single-level (analog of Favorites but per-album).
  One group per child folder under `Shared Albums/`. Sub-recursion is rejected; PhotoKit
  doesn't allow nested shared albums and we should not invent one.

`BackupScanner.ScannedFile` gains an optional `subfolder: String?` (default `nil`) and a
factory helper for "build from a URL, year/month inferred from `videos/` parent or
defaulted to 0". The timeline-side enumerator does not yet stamp `subfolder` (that's PR
#105); on `main` today it stays `nil` for every timeline file. The collection scanner is
the only producer that stamps non-`nil` values pre-#105, and only when descending
`videos/`.

Test fixture pattern: build a temporary directory tree, assert against the emitted
groups. Mirrors the existing `BackupScannerTests`.

### Phase B — Placement reconstruction matcher

**New file:** `photo-export/Export/BackupCollectionPlacementMatcher.swift`

```swift
struct BackupCollectionPlacementMatcher {
  enum MatchResult {
    case existing(ExportPlacement)        // Reused from CollectionExportRecordStore
    case fresh(ExportPlacement)           // Newly constructed via the resolver
    case orphan(reason: OrphanReason)     // Folder has no PhotoKit equivalent
  }

  enum OrphanReason: Equatable {
    case noPhotoKitCollection
    case sharedAlbumNestedUnderFolder           // disk shape impossible per PhotoKit rules
    case resolverDisagreesWithOnDiskLeaf(       // resolver returned a different leaf
      onDisk: String, resolved: String)
    case ambiguousPhotoKitMatch(                // multiple PhotoKit albums sanitize-equal
      candidateIds: [String])
  }

  static func match(
    group: CollectionScanGroup,
    photoCollections: [PhotoCollectionDescriptor],
    existingPlacements: [ExportPlacement]
  ) -> MatchResult
}
```

Logic:

1. For `.favorites`: return the existing placement with `kind == .favorites` if present,
   else `ExportPlacement.favorites()`.
2. For `.album`: rebuild the on-disk `relativePath` from `parentPathComponents + leafName`
   and look up an existing placement whose `relativePath` is byte-equal under
   `Collections/Albums/`. On match: return that placement. On miss: search
   `photoCollections` for an album whose sanitized `(pathComponents, title)` equals the
   leaf path. On miss again: orphan.
3. For `.sharedAlbum`: same as `.album` under `Collections/Shared Albums/`. The
   `sharedAlbumNestedUnderFolder` variant fires only if a future PhotoKit shape change
   makes the scanner emit a nested shared-album group; today the scanner refuses to.
4. When a fresh placement is needed, call `ExportPlacementResolver.placement(for:
   collections:existingPlacements:)` with the synthesized `LibrarySelection.album(...)`
   or `.sharedAlbum(...)`. The placement's id matches what a future export will compute
   (id is the hash of `(collectionId, displayPathHash8)`). **Then enforce the
   post-resolver path-equality guard from §3:** compare the resolver's `relativePath`
   last segment to `group.leafName`. On disagreement, demote to
   `.orphan(.resolverDisagreesWithOnDiskLeaf(onDisk:resolved:))` — do not write the
   placement.
5. When a fresh placement is needed AND more than one PhotoKit album has a sanitized
   `(pathComponents, title)` equal to the leaf path (sanitization non-injectivity per
   §3), demote to `.orphan(.ambiguousPhotoKitMatch(candidateIds:))` without consulting
   the resolver.

A unit-test fixture (with a hand-built `[ExportPlacement]` and a hand-built
`[PhotoCollectionDescriptor]`) exercises each branch — including the `Trip_2`
disambiguation cases, the path-equality guard (resolver returns `Trip/` but on-disk is
`Trip_2/`), and the sanitization tie (two PhotoKit titles both sanitize to one leaf).

### Phase C — Per-placement matching extension

**Edit:** `photo-export/Export/BackupScanner.swift`

Add a parallel matcher entry point:

```swift
extension BackupScanner {
  /// Matches collection-scan files to PhotoKit assets, scoped per placement.
  /// Reuses `matchSingleFile` and its fingerprint logic unchanged.
  static func matchCollectionFiles(
    _ groups: [CollectionScanGroup],
    placements: [PlacementResolution],
    photoLibraryService: any PhotoLibraryService,
    progress: @MainActor (ImportStage) -> Void
  ) async throws -> CollectionMatchResult

  struct PlacementResolution {
    let group: CollectionScanGroup
    let placement: ExportPlacement
  }

  struct CollectionMatchResult {
    var matched: [MatchedCollectionFile] = []
    var ambiguous: [ScannedFile] = []
    var unmatched: [ScannedFile] = []
  }

  struct MatchedCollectionFile {
    let file: ScannedFile
    let placement: ExportPlacement
    let asset: AssetDescriptor
    let variant: ExportVariant
  }
}
```

Internal flow per placement:

1. Fetch assets via `photoLibraryService.fetchAssets(in: scope, mediaType: nil)` where
   `scope` is `.favorites` / `.album(id)` / `.sharedAlbum(id)`. Result is cached by
   placement id for the duration of the import.
2. Build the asset fingerprint list (`buildFingerprints`) once across the union of
   placement scopes — see §4 — and slice per placement.
3. For each file in the group, call `matchSingleFile` with `combinedFingerprints` set
   to that placement's slice. The `stemsWithOrigSibling` set is computed per-placement
   from the files in that group (mirroring the per-month behaviour today).
4. `narrow` is unchanged: same date/size/dimensions discriminators apply.

Progress stage broadcast: `.matchingCollectionAssets(matched:total:)` — separate from the
timeline `.matchingAssets` so the UI can show two distinct progress phrases.

### Phase D — Bulk import on the collection store

**Edit:** `photo-export/Records/CollectionExportRecordStore.swift`

Add the `bulkImportRecords` method described in §5. Place it under a new
`// MARK: - Bulk import (for backup import)` section between the existing reconcile and
read sections, mirroring the structure of the timeline store.

Idempotency: existing `.done` for `(placement, asset, variant)` wins over an incoming
`.done`. A weaker existing status (`.failed`, `.inProgress`) is replaced by an incoming
`.done`. This matches `ExportRecordStore.bulkImportRecords` exactly.

### Phase E — ImportCoordinator wiring

**Edit:** `photo-export/Export/ImportCoordinator.swift`

Threads the new scan + match + bulk-write steps into `startImport` as described in §6.
Cancellation guards re-thread for the two new awaits.

**Edit:** `photo-export/Export/ExportManager.swift`

`ImportReport` gains the `collectionMatchedCount` field. `setImportResult` is unchanged.

### Phase F — Tests

**New file:** `photo-exportTests/Helpers/CollectionImportFixtures.swift`

The load-bearing test plumbing. Without it, the rest of Phase F devolves into ad-hoc
disk-walking helpers per test file. Two extension points:

```swift
struct CollectionImportFixture {
  let rootDir: URL
  let placement: ExportPlacement
  let scannedFiles: [BackupScanner.ScannedFile]   // year/month = 0 by convention
  let scanGroup: CollectionScanGroup
}

extension CollectionImportFixture {
  /// Plants `files` under `<root>/<placement.relativePath>/` and emits a fixture whose
  /// `scannedFiles + scanGroup` align — the matcher can be invoked directly without
  /// going through the disk-walking scanner.
  static func build(
    kind: CollectionScanGroup.Kind,
    parentPathComponents: [String] = [],
    leafName: String,
    files: [(filename: String, modDate: Date?, fileSize: UInt64?)],
    descendVideos: Bool = false,                  // Option A toggle
    collectionLocalIdentifier: String = "album-\(UUID().uuidString)"
  ) throws -> CollectionImportFixture
}

extension FakePhotoLibraryService {
  /// New field paralleling assetsByYearMonth, keyed by PhotoFetchScope's stable
  /// identifier. Without this, matchCollectionFiles cannot be tested in isolation —
  /// every test would either depend on the real PhotoLibraryManager or hand-roll
  /// the scope shim.
  var assetsByPlacementScope: [String: [AssetDescriptor]] { get set }
}
```

The `FakePhotoLibraryService.assetsByPlacementScope` shim is the load-bearing change
the rest of the test work depends on. Land this fixture file first.

**New file:** `photo-exportTests/BackupCollectionScannerTests.swift`

- Empty `Collections/` → empty group list.
- Favorites with two files → one group, both files in it.
- Albums with a nested folder structure → one group per leaf, parent path correctly
  decomposed.
- *Folder-of-folders* shape (PhotoKit user folder named "Trip" containing album named
  "Trip" rendering as `Collections/Albums/Trip/Trip/`): inner `Trip/` is the leaf, outer
  is the parent path component. Pin explicitly.
- Shared Albums with two albums → two groups, both with empty `parentPathComponents`.
- Mixed: timeline `2026/03/IMG.JPG` plus a Favorites file → timeline scanner sees the
  former, collection scanner sees the latter, neither sees the other.
- `videos/` descent (Option A) — happy path + corners:
  - An album folder with `IMG.JPG` and `videos/IMG.MOV` → one group, `.MOV` carries
    `subfolder == "videos"`.
  - `videos/` containing a `.JPG` (non-video) → still descended; file matched normally
    per its extension. The scanner does not enforce media-type inside `videos/`; that's
    the matcher's job.
  - Empty `videos/` → no spurious group, no error.
  - `videos/` at wrong nesting depth (`Collections/Albums/videos/Trip/IMG.MOV`) → not
    descended; `videos/` becomes a regular leaf-folder candidate (and surfaces as an
    orphan downstream because no PhotoKit album is named "videos").
  - Nested `videos/videos/` → only the outermost `videos/` is descended; the inner
    becomes a regular file.

**New file:** `photo-exportTests/BackupCollectionPlacementMatcherTests.swift`

The `Trip_2` matrix (expanded per the tester's review). Each row is a separate test:

| On-disk leaf | Existing placement | PhotoKit titles | Expected |
|---|---|---|---|
| `Favorites/` | `collections:favorites` exists | n/a | `.existing` reused |
| `Favorites/` | none | n/a | `.fresh` favorites placement |
| `Trip/` | placement at `Trip/` for collectionA | "Trip" (collectionA) | `.existing` reused |
| `Trip_2/` | placement at `Trip_2/` for collectionA, PhotoKit title "Trip_2" | "Trip_2" (collectionA) | `.existing` reused, literal name |
| `Trip_2/` | placement at `Trip_2/` for collectionB, PhotoKit title "Trip" | "Trip" (collectionA), "Trip" (collectionB) | `.existing` reused, historical suffix |
| `Trip_2/` | none | "Trip_2" (collectionA) | `.fresh` with bare path |
| `Trip_2/` | none | "Trip" (only) | `.orphan(.noPhotoKitCollection)` |
| `Trip/`, `Trip_2/`, `Trip_3/` all on disk | placement at `Trip/` for collectionA | "Trip" only in PhotoKit | `Trip/` → `.existing`; `Trip_2/`, `Trip_3/` → orphan |
| `Trip_2/` on disk; existing placement at `Trip_2/` for collectionDeleted (no longer in PhotoKit) | as stated | "Trip" (collectionA) | `.existing` reused — historical assignment is authoritative even when the album has been deleted (see Regression Risks) |
| `Trip/` (resolver would suffix to `Trip_2` because `Trip` already claimed by collectionA's existing placement) | placement at `Trip/` for collectionA | "Trip" (collectionA), "Trip" (collectionB) | match for collectionB demotes to `.orphan(.resolverDisagreesWithOnDiskLeaf)` |
| `Trip_/` on disk; PhotoKit has both "Trip:" and "Trip_" (sanitize-tie) | none | as stated | `.orphan(.ambiguousPhotoKitMatch(candidateIds:))` |
| Shared album under nested folder (synthetic input) | n/a | n/a | `.orphan(.sharedAlbumNestedUnderFolder)` |

Title-input edge cases (separate cluster):
- Leading/trailing whitespace in PhotoKit title → sanitized leaf compares normally.
- PhotoKit title arriving as NFD on one launch and NFC on another → same
  `displayPathHash8`, same placement id, no churn (regression guard for
  `precomposedStringWithCanonicalMapping` in `ExportPlacementResolver`).

**Extend:** `photo-exportTests/BackupScannerMatchingTests.swift` and
`BackupScannerVariantTests.swift`

Realistic parametric scope: re-running every existing case via `matchCollectionFiles`
needs (a) the fixture-builder above and (b) a `FakePhotoLibraryService.assetsByPlacementScope`
shim that's already part of the fixture file. With both in place, the asset-level
assertions (`asset.id`, `variant`, ambiguous/unmatched buckets) carry over directly;
year/month-specific cases (adjacent-month rollover) don't apply and are skipped for
the collection-side runs.

**Don't claim it's "one helper away"** — it's the helper plus the
`assetsByPlacementScope` shim plus a per-test stub of placement resolution. Realistic
effort: ~1 day of mechanical re-derivation per existing test file.

**New file:** `photo-exportTests/CollectionExportRecordStoreBulkImportTests.swift`

- Empty store → records land, placements upserted, `.upsertPlacement` precedes
  `.upsertRecord` (assert log order via `.flushForTesting`).
- Existing `.done` for a variant → preserved, not overwritten by incoming `.done`.
- `.failed` for a variant → replaced by incoming `.done`.
- *Existing `.inProgress`-then-recovered-to-`.failed` variant* → replaced by incoming
  `.done` (closes the `recoverInProgressVariants` overlap).
- `.timeline` placement in input → refused, logged, no-op. (Mirrors
  `CollectionExportRecordStoreTests.upsertPlacementRejectsTimeline`; keep this version
  scoped to the `bulkImportRecords` entry point specifically.)
- Store in `.failed` state → early return.

**Coordinator-level cross-store invariant test** (new test inside
`ExportManagerImportTests.swift`):

The timeline store's `bulkImportRecords` does **not** have a kind gate (it can't —
`ExportRecord` doesn't carry a placement kind). The disjoint-key-space invariant on the
import path therefore lives entirely in `ImportCoordinator`. Add a test that wires a
deliberately-mis-split input (a `.album` `MatchedCollectionFile` planted into the
timeline-bound list) and asserts the coordinator splits them correctly before either
bulk API runs. This pins the *routing* invariant rather than relying on per-store gates
that can't exist.

**Extend:** `photo-exportTests/ImportIdempotencyTests.swift`

- Re-run import on a destination that already has collection records → no churn.
- *Re-import after the user added a new export between imports*: bulk-import → real
  export of one album asset → bulk-import again. The second bulk-import must not
  regress the freshly-written `.done`, must not duplicate the placement, must not flip
  variant filenames.
- *Re-import after UI-driven `deletePlacement`/`removeVariant`*: bulk-import →
  programmatically delete a placement → bulk-import again. Pin whether the scanner
  resurrects the placement (yes — the on-disk folder is still authoritative for the
  import path; the user's UI delete is overridden, which matches the existing timeline
  reconcile contract).
- *NFC/NFD drift between launches*: bulk-import with title in NFD → bulk-import again
  with title in NFC → no churn.

**Extend:** `photo-exportTests/ImportReconcileTests.swift`

- Delete a file in `Collections/Albums/Trip/` between two imports → reconcile prunes
  exactly that variant; sibling variants of the same asset under the same placement
  are left alone.
- Collection-only import (no timeline files present) → completes successfully, report
  shows 0 timeline-matched + N collection-matched.
- *Multi-placement asset*: asset A is in both Favorites and album "Trip", on-disk
  copies under both placement folders → both records land under their respective
  placement ids, neither dedupes the other away.

**Extend:** `photo-exportTests/ExportManagerImportTests.swift`

- Cancel mid-`matchCollectionFiles`: the new `await` point's `isCurrent(importGen)`
  check must abort cleanly. Assert no collection-store mutation lands and
  `importStage` resets to `nil`.
- Cancel mid-`bulkImportRecords(placements:records:)` collection-side: same shape as
  the existing mid-bulk-import timeline test.
- Collection store in `.failed` state → import refuses with logged error, both stores
  untouched.

### Phase G — UX + docs

User-facing language. The HIG principles applied below are *Progressive Disclosure*
(reveal information progressively, only when needed) and *Be honest about errors*
(actionable messages that name the situation, not the internal cause).

- **Progress stages (`ImportView.stageLabel`).** Replace developer verbs with consumer
  language:
  - `"Rebuilding local state…"` → `"Saving import results…"`
  - `"Pruning records for missing files…"` → `"Cleaning up records for deleted files…"`
  - `"Matching assets…"` keeps its phrasing but now spans both timeline + collection
    passes (single user-visible label per §6).
- **ImportView result sheet** (`ImportView.swift:77-121`):
  - Keep the existing rows (Files scanned / Matched to Photos library / Ambiguous /
    No matching asset found / Records pruned).
  - When `collectionMatchedCount > 0`, append a sub-line under the matched row:
    `"including N in albums"`. Conditional rendering — never shown when the user has
    no collection records, avoiding noise on the timeline-only path.
  - When `unmatchedCount > 0` AND any orphan folders were detected, append a single
    italic disclosure line below the unmatched row:
    *"Some folders no longer match an album in Photos. They were skipped."* Detail
    belongs in the diagnostic report; the sheet just names the situation so the user
    knows it's not corruption.
  - Rename the "Records pruned (file missing)" row label to "Cleaned up for deleted
    files".
- **Final caption** (`ImportView.swift:115-117`): when `collectionMatchedCount > 0`,
  swap "previously exported files" → "previously exported files, including N in
  albums."
- **`.failed` collection-store refusal copy** (per §7): the user-facing surface here
  is whatever path delivers the import-refused message — today this is a log-only
  outcome via `logger.error` and `setImportResult(nil)`. Phase G adds a result sheet
  for this case showing: *"Couldn't read album records. Try again in a moment."*
  Implement as a third `ImportReport.failureReason: String?` field or a sibling
  `importFailureMessage: String?` on `ExportManager`; whichever lands first in the
  diff. The sheet's existing two-button shape (Close / Export Remaining) collapses to
  a single Close button for the failure case.
- **README** under "Track exported assets per destination": no change needed — the line
  already reads as covering both kinds.
- **Website** (`website/src/content/docs/`): update the Import Existing Backup page to
  mention collections explicitly. Map of pages is in `docs/README.md`.
- **What's New** in-app entry for the next release:
  *"Import Existing Backup now adopts album and shared-album exports too — no more
  re-exporting the same albums after a reinstall."* Leads with the user benefit.

## Open Questions

- **Folder-of-folders ambiguity.** A user might have nested user folders in PhotoKit that
  collide with album titles on disk — e.g. a folder named "Trip" containing an album
  named "Trip" would render as `Collections/Albums/Trip/Trip/`. The matcher's "leaf
  whose entries are files" rule handles this correctly (the inner `Trip/` is the leaf),
  but the test fixture should cover it explicitly.
- **Empty albums on disk.** A folder under `Collections/Albums/` with zero files is
  arguably a stale folder from a deleted album, but could also be a freshly-created
  album the user dragged into the folder hierarchy with no contents yet. The scanner
  emits a group with `files == []`. **Decision: skip empty groups entirely** — do not
  call the resolver, do not write a placement, do not contribute to the matched
  count. Rationale: writing a placement for an empty folder produces a stale entry
  that the existing `reconcileAgainstFilesystem` cannot prune (reconcile prunes
  records, never placements — see `CollectionExportRecordStore.swift:408-493`), and the
  store has no cleanup mechanism for deleted-album placements (acknowledged
  out-of-scope above). A fresh placement on next real export costs one resolver call;
  the cost of a permanent stale-placement entry is unbounded.
- **Report breakdown granularity.** §6 keeps the report mostly summed. If user feedback
  later wants a per-collection-kind matched count (favorites N, albums M, shared L), the
  fields are easy to add — but doing it now is premature surface.
- **Performance ceiling.** A library with 200 user albums + 5 shared albums means ~205
  collection scopes plus the existing 12 months × N years. Asset fingerprints are
  built once per asset (de-duped across scopes per §4) so the dominant cost is one
  `fetchAssets(in:)` per scope. Each call is a `PHAsset.fetchAssets(in:options:)`
  enumeration; rough estimate is sub-second per scope on a personal-scale library, so
  no special batching is needed. If users with much larger album counts hit this, add
  a `BackupCollectionScanner.parallelism` parameter as a follow-up.

## Regression Risks

- **Disjoint-key-space invariant — coordinator-bound, not store-bound on the timeline
  side.** Every new collection-side write must go through `CollectionExportRecordStore`.
  The collection store's three-layer `.timeline` refusal (snapshot decode, `apply`
  log-replay, `accept` API gate) catches any future drift on that side. *But* the
  timeline store's `bulkImportRecords` does **not** have a symmetric kind gate, because
  `ExportRecord` does not carry a placement kind field — there's nothing in the type
  system to assert against. The invariant on the import path therefore lives entirely
  in `ImportCoordinator`'s input-splitting code, and the regression-gate test belongs
  at the coordinator level (see Phase F's "Coordinator-level cross-store invariant
  test").
- **Resolver-disagrees-with-on-disk-leaf**: a fresh placement constructed via
  `ExportPlacementResolver.placement(for:...)` can return a `relativePath` whose last
  segment disagrees with `group.leafName` — e.g. the resolver sees `Trip/` is already
  claimed and would suffix the new placement to `Trip_2/`, but the on-disk folder is
  literally `Trip_2/` (already claimed by something else). Without the §3 / Phase B
  guard the import would write records under the wrong path and the same import's
  reconcile would prune them all. Guard is part of the matcher; regression test is in
  the `Trip_2` matrix above.
- **Placement identity drift**: an album imported as a fresh placement (no existing
  match) gets an id computed from `(collectionId, displayPathHash8)`. If a future
  PhotoKit launch returns the album's title in a different Unicode normalization form,
  the next export would compute a different `displayPathHash8` and create a *new*
  placement at a different on-disk path. The existing resolver's NFC normalization in
  `displayPathHash8` already mitigates this; the Phase F idempotency test (NFD on
  launch 1, NFC on launch 2 → no churn) pins it end-to-end rather than just at the
  hash level.
- **Stale placements as historical authority.** When an existing placement's
  `collectionLocalIdentifier` no longer resolves to any PhotoKit album, the matcher
  still reuses the placement (the `Trip_2` matrix's "collectionDeleted" row in
  Phase F). This is load-bearing: the placement encodes the user's prior
  suffix-assignment decision, and discarding it would force a different on-disk
  folder for a re-created album with the same title. The cost is that the import
  preserves placements for albums the user has truly deleted; cleanup of those is a
  separate plan.
- **AutoSync seam**: this plan does not modify `ExportManager`'s AutoSync conformance
  surface. `ImportReport` is not observed by AutoSync. Coordinator → manager mirrors
  are unchanged.
- **Cancellation contract**: every new `await` in `ImportCoordinator.startImport` gets
  a `queueCoordinator?.isCurrent(importGen)` check immediately after, matching the
  existing pattern. `clearPending` semantics are not touched. Phase F adds mid-step
  cancellation tests for both new awaits.

## Out of Scope (future plans)

- Cleanup / compaction of stale collection-store placements (an album was deleted, its
  placement is still in the store, its on-disk folder is also gone). Same problem the
  timeline side does not have; would need its own plan.
- A "manual reconcile" UI: a user-driven path that lets them pick an orphan on-disk
  folder and bind it to a current album. Out of scope; the user can rename either the
  folder or the album and re-run import.
- Bringing collection-side exports under the same per-variant `subfolder` accounting as
  timeline. PR #105 is the producer; this plan is the consumer. Once #105 lands and
  collection-side exports start writing `videos/` subfolders, the scanner already
  descends them and the matcher already records them — no further work needed.
