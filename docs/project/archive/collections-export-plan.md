# Collections Export Plan

Date: 2026-04-30
Status: ✅ Shipped — archived as a decision record. All four phases landed; the `AppFlags.enableCollections` build-time gate was flipped to `true` for Phase 4 and removed in the cleanup commit that followed. Album rename and the `_album.json` membership sidecar remain deliberately deferred (see the "Goals" / "Non-Goals" sections below).

## Implementation Status

Tracked per phase. Each phase lands as one or more commits on the `collections-export` branch.

| Phase | Status | Notes |
|---|---|---|
| 0. Stable destination identity | ✅ Done | volume-UUID-based id; `ExportRecordsDirectoryCoordinator` handles legacy migration |
| 1. Type/queue plumbing + new collection store | ✅ Done | Foundation types, `JSONLRecordFile`, `CollectionExportRecordStore`, corruption recovery, `ExportManager` routing. Behind `enableCollections == false`. |
| 2. PhotoKit collection discovery | ✅ Done | `PhotoCollectionDescriptor` + scope-based fetch/count APIs; `ExportPlacementResolver` with placement-id format and sibling-collision disambiguation. Resolver not yet wired (Phase 3). |
| 3. ExportManager and destination collection-aware | ✅ Done | `urlForRelativeDirectory` + escape protection; `startExportFavorites`/`startExportAlbum` + queue wiring; reuse-source copy path; `CollectionCountCache` actor. Behind `enableCollections == false`. |
| 4. UI + docs | ✅ Done | `LibraryRootView` + Timeline/Collections segmented selector; `CollectionsSidebarView`, `CollectionContentView`, `RecordStoreAlertHost`. `enableCollections` flipped to `true`. Docs updated (README, AGENTS, persistence-store, architecture, features, auto-sync cross-reference). |

The whole feature ships to the App Store only when Phase 4 is ready; phases 1–3 stay behind the feature flag for
internal/dev testers in the meantime (see *Release strategy* in the Summary).

## Summary

Add a second export surface alongside the existing timeline export:

```text
<destination>/
  2026/
    04/
      IMG_0001.HEIC

  Collections/
    Favorites/
      IMG_0001.HEIC
    Albums/
      Album_1/
        IMG_0001.HEIC
      Folder/
        Album_2/
          IMG_0001.HEIC
```

Timeline and collection exports must be independent. Exporting an asset to `2026/04/` must not mark it exported in
`Collections/Favorites/` or `Collections/Albums/<album>/`, and exporting from a collection must not affect timeline
progress. Duplicate physical files are intentional when the same Photos asset appears in multiple export placements.

The architectural change is **a second, sibling record store for collections**, not a rewrite of the existing one.
Independence is a property of disjoint key spaces: timeline records continue to live in the existing
`export-records.json`/`.jsonl` (asset-keyed, unchanged on disk and in API), and a new
`collection-records.json`/`.jsonl` holds collection records keyed by `(placementId, assetId)`. The two stores
never share keys, so a failed favorites export is physically incapable of touching a timeline record for the
same asset. The existing timeline store is untouched on upgrade; the collection store starts empty.

The shared JSONL+snapshot machinery in `ExportRecordStore` is extracted into a reusable component (parameterized
over filenames and codable types) that both stores compose. `ExportManager` queues placement-aware jobs and
routes reads and writes to the right store based on `placement.kind`. The reuse-source copy path queries both
stores in deterministic order (timeline first, then collection) when looking up a prior `.done` record.

Phase 0 (stable destination identity) is a prerequisite: today's bookmark-hash-based `destinationId` can change
on bookmark refresh and silently orphan the record store, which is acceptable pre-collections (recoverable via
`Import Existing Backup`) but not after (collection state is not on-disk-recoverable).

The plan defers two pieces of work to follow-up plans: an interactive album-rename UX (MVP behavior is "rename
in Photos = new placement at the new path; old folder stays") and the `_album.json` membership sidecar
(speculative metadata; nothing in the app reads it). Both can land later without changing the schema.

**Release strategy.** No App Store release until **all four phases are ready**. Phases 1–3 landed in `main`
behind a build-time flag (`AppFlags.enableCollections`) that stayed `false` while the UI and corruption alert
presenter were under construction; only internal/dev testers saw the new code paths during the ramp. Phase 4
flipped the flag to `true` and shipped collections to all users; the flag itself was removed in the cleanup
commit that followed.

## Goals

- Add a top-level two-state UI selector: `Timeline` and `Collections`.
- Keep the current year/month sidebar under `Timeline`.
- Under `Collections`, show:
  - `Favorites`
  - `Albums`
  - one row per user album, preserving folder nesting when available.
- Allow queueing exports from months, years, favorites, and individual albums in one session.
- Write collections under `Collections/Favorites/` and `Collections/Albums/...`.
- Keep timeline and collection export completion state completely independent.
- Preserve the existing edited/originals export-version behavior for every export placement.
- Use APFS file clones to avoid disk-doubling when both timeline and a collection contain the same asset and the
  destination is on APFS; copy on non-APFS filesystems.
- Leave existing timeline export state untouched on upgrade — no migration, no schema rewrite, no re-export.
- Keep PhotoKit types behind protocol/model boundaries so views and the export pipeline remain testable.

## Non-Goals

- Restoring album membership back into Photos automatically. A future "restore to Photos" tool would consult
  the collection store's records on disk, but writing such a tool is out of scope.
- Exporting smart albums beyond `Favorites` in the first pass. ("Recently Added" was considered and dropped:
  Timeline → most-recent-month already serves "back up new stuff" with cleaner semantics — sliding-window smart
  albums force UI compromises like suppressed completion badges and folder names that drift from contents over
  time.)
- Automatically deleting files when an album is removed in Photos.
- Adding a new closed-app background export process.
- Changing the existing timeline folder layout.
- (Superseded.) The collections plan originally scoped auto-sync to timeline only. The auto-sync plan (`auto-sync-background-sync-plan.md`, revised 2026-05-08) now covers Timeline, Favorites, and Albums. Albums auto-sync uses a bounded all-albums reconciliation in MVP rather than targeted per-album work; collection exports triggered manually still keep their existing user-confirmation flows for renames/large writes.
- Unifying the timeline and collection records into a single store. Two sibling stores are intentional: the
  timeline store keeps its current asset-keyed shape and API; the collection store is placement-keyed. A future
  unification, if ever needed, would be a fresh plan with its own migration.
- `Export All` covering collections. `Export All` remains timeline-scoped. A future `Export All Collections` action,
  if added, will be explicit.
- Backfilling collection placement records from existing files via `Import Existing Backup`. Import remains
  timeline-only and ignores `Collections/`.

## Risks and Decisions

This plan's value lives in this section. Each item below changed the design.

- **No migration; two stores side by side.** The existing `ExportRecordStore` keeps its asset-keyed shape, files,
  and API for timeline records. A new `CollectionExportRecordStore` holds favorites + album records keyed by
  `(placementId, assetId)`. Independence is a property of disjoint key spaces, not of a unified schema, so two
  stores satisfy the guarantee with no migration risk. If the collection store's snapshot fails to decode at
  startup, the alert in the Phase 4 UI surfaces it and disables collection export controls; timeline export is
  unaffected. (See *Storage Files* and *Collection Store Format*.)
- **Album rename creates a new placement; the old folder stays.** Renaming an album in Photos changes the
  resolver's `displayPathHash8`, so the next export of that album writes to a fresh placement at the new path.
  The previous placement and its on-disk folder remain. A "merge old folder into new" UX is deferred to a
  follow-up plan; the placement-id format already detects renames and the future plan adds the dialog and file
  move without changing the schema. (See *Album Rename Behavior*.)
- **Manual filesystem edits are not detected.** Records are the source of truth for "what is exported where." If a
  user moves, renames, or deletes folders or files in the destination through Finder, the next export will write to
  the path the records remember, which may surprise the user. `Import Existing Backup` is the only recovery path,
  and it covers timeline only.
- **Duplicate files are mostly free on APFS (best-effort optimization).** When source and destination are on the
  same APFS volume, modern macOS makes `FileManager.copyItem(at:to:)` perform copy-on-write at the filesystem
  layer, so the duplicate uses no extra bytes until either copy is modified. On exFAT/NTFS, duplication is always
  a real copy and a 50k-asset / 100-album library can grow disk use 3–5×. The plan does not depend on cloning
  succeeding — if a macOS regression ever made `copyItem` always copy, exports still work; they just use more
  disk on APFS than expected. Verified at test time via volume free-space delta.
- **`ExportManager` refactor is moderate, not invasive.** ~981 lines today, queue keyed by year/month strings, jobs
  carry year/month inline. The queue and `ExportJob` gain a `placement` field so collection jobs can be enqueued
  alongside timeline jobs, and reads/writes route to the right store based on `placement.kind`. Existing timeline
  call sites that key by `(year, month)` keep their signatures — they are wrapped to construct the synthetic
  timeline placement internally and route to the unchanged timeline store. No persistence-side rewrite of the
  timeline store is required.
- **Album titles can produce path collisions.** Sibling collisions (two albums named the same in the same parent
  folder) are detected and disambiguated with a `_2` / `_3` numeric suffix. We do not detect cross-tree case-fold
  collisions in the MVP — they are vanishingly rare in personal libraries and the cost of building reliable
  cross-tree detection (NFC + case-fold over the whole sanitized tree) outweighs the user-visible value. (See
  *Path Policy*.)
- **Stale album placements accumulate from album deletions only.** Renaming no longer creates a stale placement
  (the rename action moves files and rewrites records). Deleting an album in Photos still leaves the placement
  record behind; disk cost is negligible (a few KB) and the descriptor tree drives sidebar display. Cleanup of
  deleted-album placements is out of scope for the MVP.
- **Storage scaling.** The timeline store's size profile is unchanged from today. The new collection store
  normalizes placements (placement metadata stored once, records reference by id), so its snapshot size is
  dominated by `Σ placements records`, not `placements × assets`. Compaction threshold (currently 1000 mutations)
  is reused per store; profile during Phase 1 and tune if snapshot writes on slow USB targets become noticeable.
  Worst-case a 50k-asset / 100-album library is single-digit MB across both stores.
- **Auto-sync interaction.** Auto-sync (per `auto-sync-background-sync-plan.md`, revised 2026-05-08) covers
  Timeline, Favorites, and Albums. Albums auto-sync runs a bounded all-albums reconciliation rather than
  targeted per-album work; rename detection and other flows requiring user input remain manual-only and surface
  through Export Issues when an automatic run would otherwise need to prompt.
- **Destination identity must be stable before this ships.** Today `destinationId` is a SHA-256 of the bookmark
  data (`ExportDestinationManager.swift:218`). When a bookmark is refreshed (e.g. after the OS regenerates it),
  the hash changes and the entire record store appears to be a fresh empty destination. Pre-collections, the
  user could re-run `Import Existing Backup` to recover. Post-collections, that path is timeline-only — collection
  state cannot be reconstructed from disk. A bookmark refresh would silently orphan the user's collection
  records. The `auto-sync-background-sync-plan.md` already calls this out as a prerequisite for that feature; it
  is now a prerequisite for this one too. **Phase 0 (below) addresses it before the collection store ships.**
- **`ContentView` is too coupled to do this in place.** Sidebar logic moves out before adding the Collections branch.

## PhotoKit API Shape

Use app-owned descriptors at the protocol boundary. `PHAssetCollection`, `PHCollection`, and `PHCollectionList` must
not appear in SwiftUI views or `ExportManager`.

Relevant PhotoKit routes:

- Favorites can be fetched either with a `PHFetchOptions` predicate (`favorite == YES`) or through the smart album
  (`PHAssetCollectionSubtype.smartAlbumFavorites`). Use the predicate for the MVP — the desired output placement is
  fixed and we do not need smart-album metadata.
- User albums are `PHAssetCollection` values with `assetCollectionType == .album`.
- Fetch album contents with `PHAsset.fetchAssets(in:options:)`.
- Fetch top-level folders/albums with `PHCollection.fetchTopLevelUserCollections(with:)`.
- Recurse folders with `PHCollection.fetchCollections(in:options:)`.
- Moments are not used (deprecated/unavailable on macOS).

Fetch options match existing timeline behavior:

- Sort assets by `creationDate` ascending for deterministic output.
- Hidden assets stay excluded by default.
- Source-type behavior unchanged. If shared albums are added later, that decision is explicit.

`PhotoLibraryManager` already conforms to `PHPhotoLibraryChangeObserver` and calls `invalidateCache()` on library
changes. Extend `invalidateCache()` to also clear:

- the cached collection descriptor tree,
- per-placement count and adjusted-count caches.

Cache invalidation also cancels any in-flight count tasks (see *PhotoLibraryService → off-main counting*), so
observers do not return stale results after a Photos library mutation.

Without this, sidebar collection rows go stale until app restart.

## Product Behavior

### Navigation

Add a segmented control at the top of the main UI:

```text
[ Timeline | Collections ]
```

`Timeline` selected:

- Render the current `Photos by Year` sidebar with unchanged behavior.
- Selecting a month shows the existing thumbnail grid and `Export Month` action.
- Existing `Export Year` / `Export All` toolbar behavior stays timeline-scoped.

`Collections` selected:

- Render a `Collections` sidebar:
  - `Favorites`
  - `Albums`
    - `<album rows, nested by folder path where possible>`
- Selecting `Favorites` shows its asset grid and an `Export Favorites` action.
- Selecting an album shows its asset grid and an `Export Album` action.
- Albums that resolve to the same display title under different folders remain distinct in state and on disk.

### Album Rename Behavior

MVP behavior is "rename in Photos = new placement at the new path; the old folder stays on disk." When a user
renames an album in Photos.app, the resolver's `displayPathHash8` segment changes, so the next export of that
album resolves to a fresh placement (different placement id, different `relativePath`). The previous placement
remains in the collection store and its files remain on disk; nothing is moved.

**Rationale.** Users in the field who rename albums get a working export to the new folder without an interactive
prompt. They can move or delete the old folder in Finder if they want; the app does not auto-clean. Building a
rename dialog with pre-flight checks, multi-state copy variants, atomic file move, and a `renamePlacement` log op
is multi-day work that can land in a follow-up plan if user feedback asks for it. The MVP rule is the simplest
correct behavior — no data loss, no surprising file moves, recoverable by the user.

**Cost users will see.** If a user renames an album they have already exported, they end up with two folders on
disk: the old one (frozen at the rename moment) and the new one (continuing to receive exports). The
*Collections > Albums* sidebar is **driven by the PhotoKit descriptor tree**, so it shows only the renamed
album (one row, at the new name). The stale placement record stays in the collection store and the old folder
stays on disk, but neither has a sidebar row — there is no live PhotoKit collection to anchor one. Users
discover the old folder when they next browse the destination in Finder. The release notes for the collections
launch must call this out explicitly so users aren't surprised. Cleanup of stale placements after album
deletion or rename is out of scope for this plan; a future "manage exported folders" UI could surface them.

**What's deferred to a follow-up plan.** A "merge old folder into new" UX with a dialog, file moves, and a
`renamePlacement` log op. The placement-id format already supports detecting renames (the `displayPathHash8`
segment), so the follow-up plan does not need to reshape the schema — it adds the dialog, the move logic, and
the log op without breaking existing records.

### Queueing

The queue may contain timeline-month, timeline-year (which expands to N timeline-month jobs), favorites, and album
jobs. The queue shows one global progress state, but per-row queued counts are keyed by **placement id**, not by
year-month string.

### Destination Layout

Relative directories:

```text
timeline month:      <YYYY>/<MM>/
favorites:           Collections/Favorites/
album:               Collections/Albums/<sanitized folder path>/<sanitized album title>/
```

The destination must reject any `relativePath` that escapes the export root after canonicalization (no `..`, no
absolute paths, no symlink traversal at write time).

Album-membership sidecars (`_album.json`) are **deferred** to a follow-up plan. They were originally proposed
to preserve album membership alongside the exported photos as forward-looking metadata for a hypothetical
restore-to-Photos tool, but nothing in the app reads them and no concrete consumer exists today. The collection
records on disk capture which assets were exported under which placement; that's enough state for any future
sidecar/manifest writer to materialize without changing the on-disk format.

## Path Policy

A small, deliberately boring sanitizer. The goal is "produce a usable path on common filesystems without surprising
the user." Edge cases the policy does not handle (reserved Windows device names, deep tree case-fold collisions,
extreme length) are accepted as out-of-scope: they are vanishingly rare in personal Photos libraries, and the cost
of building reliable detection outweighs the user-visible value.

All album and folder names go through `ExportPathPolicy.sanitizeComponent(_:)` before becoming a path component.

### Per-component rules

1. **Banned characters** — replaced with `_`:
   - path separators: `/` `\`
   - Windows/exFAT bans: `<` `>` `:` `"` `|` `?` `*`
   - control characters: `0x00`–`0x1F`, `0x7F`
2. **Whitespace and dots:** trim leading and trailing whitespace; strip trailing dots; if empty after trimming,
   replace with `_`.
3. **Dot-only components:** after trimming, if the component is exactly `.` or `..`, replace with `_`. (Defense in
   depth; the destination's relative-path validator is the primary guard against `..` traversal.)
4. **Unicode normalization:** NFC.
5. **Empty input:** `""` → `_`.

The policy intentionally does **not**:

- Reject reserved Windows/exFAT names like `AUX`, `CON`, `LPT1`. These are vanishingly rare album names; if a user
  hits one and exports to a Windows-formatted drive, the OS will refuse the directory creation. We surface this
  as a single placement-level failure (not 5,000 per-asset failures): `ExportManager.enqueue` calls
  `urlForRelativeDirectory(_, createIfNeeded: true)` once before enqueuing the placement's jobs; if it throws,
  the enqueue aborts, the placement is marked failed, and a single user-facing error explains which album and
  why. Per-asset failure marking is reserved for genuine per-asset failures (resource fetch, write).
- Cap component length. Common filesystems allow 255 bytes; album titles longer than that are not realistic.
- Detect cross-tree case-fold collisions. Sibling-only collisions (two albums with the same name in the same parent
  folder) are detected (next section); cross-tree case-only collisions are not. The build-up complexity of NFC +
  case-fold over the whole sanitized tree is not justified by the user-visible value. The failure mode (two
  case-only-different albums writing into the same folder on a case-insensitive filesystem) is rare and
  recoverable by the user manually renaming one album in Photos.

### Disambiguation

A *sibling collision* is two distinct collections that, after sanitization, would produce the same full path under
the same parent folder under `Collections/Albums/`. Sibling collisions are detected against existing placement
records and against collections currently in the descriptor tree.

When a new placement collides with an existing placement's `relativePath`, the **new** placement gets a numeric
suffix; the existing placement's `relativePath` is never altered. First claimant keeps the bare path. Stale
placements from deleted albums count as live claimants so a reinstated album does not silently steal a path.

Suffix format:

```text
<sanitized leaf>_2
<sanitized leaf>_3
…
```

Suffix selection: take the smallest integer `n ≥ 2` such that `<leaf>_n` does not collide with any existing
placement. For two newly-discovered colliding albums (neither persisted yet), candidates are sorted
lexicographically by `collectionLocalIdentifier` and the bare path goes to the first; the second gets `_2`.

### Test cases

`ExportPathPolicyTests` covers at least:

1. ASCII passthrough.
2. Forward slash → `_`.
3. Backslash → `_`.
4. Trailing dot stripped (`Family.` → `Family`).
5. Leading/trailing whitespace trimmed.
6. Empty input → `_`.
7. NFC normalization: input `"Cafe\u{0301}"` (NFD: e + combining acute) → output `"Caf\u{00E9}"` (NFC: precomposed).
8. Component `..` → `_`. Component `.` → `_`.
9. Two newly-discovered albums with identical titles under the same folder produce paths `Trip/` and `Trip_2/`,
   ordered by `collectionLocalIdentifier`.
10. New album collides with an existing-recorded placement → new gets `_2`; existing path is unchanged.
11. `Trip_2` is taken → next collision yields `Trip_3`.

## Architecture

### Selection and Scope Models

```swift
enum LibrarySection: String, Codable, Sendable {
  case timeline
  case collections
}

enum LibrarySelection: Hashable, Sendable {
  case timelineMonth(year: Int, month: Int)
  case favorites
  case album(collectionId: String)
}

enum PhotoFetchScope: Hashable, Sendable {
  case timeline(year: Int, month: Int?)
  case favorites
  case album(collectionId: String)
}
```

`LibrarySelection` is UI state. `PhotoFetchScope` is a Photos query. They stay separate so the UI can represent
headers and empty states without implying an exportable query.

### Collection Descriptors

```swift
struct PhotoCollectionDescriptor: Identifiable, Hashable, Sendable {
  enum Kind: String, Codable, Hashable, Sendable {
    case favorites
    case album
    case folder
  }

  let id: String
  let localIdentifier: String?
  let title: String
  let kind: Kind
  let pathComponents: [String]   // unsanitized display hierarchy
  let estimatedAssetCount: Int?
  let children: [PhotoCollectionDescriptor]
}
```

- `Favorites` is a synthetic descriptor with no PhotoKit collection id.
- Album descriptors carry `PHAssetCollection.localIdentifier`.
- Folder descriptors carry `PHCollectionList.localIdentifier` only for tree identity; folders are not directly
  exportable.
- `pathComponents` is the unsanitized display hierarchy. Sanitization happens in `ExportPathPolicy`, not here.

### PhotoLibraryService

Add scope-based APIs alongside the existing timeline-only APIs:

```swift
func fetchAssets(in scope: PhotoFetchScope, mediaType: PHAssetMediaType?) async throws -> [AssetDescriptor]
func countAssets(in scope: PhotoFetchScope) async throws -> Int
func countAdjustedAssets(in scope: PhotoFetchScope) async throws -> Int
func fetchCollectionTree() throws -> [PhotoCollectionDescriptor]
func collectionDescriptor(id: String) -> PhotoCollectionDescriptor?
```

Existing methods become wrappers:

```swift
func fetchAssets(year: Int, month: Int?, mediaType: PHAssetMediaType?) async throws -> [AssetDescriptor] {
  try await fetchAssets(in: .timeline(year: year, month: month), mediaType: mediaType)
}
```

**Off-main counting.** The `PhotoLibraryService` protocol stays `@MainActor`. Two new methods are explicitly
declared `nonisolated`:

```swift
@MainActor protocol PhotoLibraryService {
  // existing main-actor methods unchanged
  nonisolated func countAssets(in scope: PhotoFetchScope) async throws -> Int
  nonisolated func countAdjustedAssets(in scope: PhotoFetchScope) async throws -> Int
}
```

Implementations build a `PHFetchResult` inside `Task.detached` and iterate without crossing any `PHAsset` instance
back to the main actor. Returned values are `Sendable` (`Int`). Fakes mirror the same `nonisolated async`
signatures. All other protocol methods retain their main-actor isolation; existing call sites are unaffected.

A `CollectionCountCache` actor owns per-placement-id `Task<Int, Error>?` handles. It exposes
`count(for: placementId, fetch: () async throws -> Int) async -> Int`, replacing any in-flight task for the same id
(cancelling the prior). Cache invalidation (`invalidateAll()`) cancels every in-flight task rather than stranding
them. Invalidation is called from the existing `PHPhotoLibraryChangeObserver` callback.

If `Task.detached` proves incompatible with PhotoKit threading in measured tests, the fallback is to keep the work
`@MainActor` and yield (`Task.yield()`) every 50 assets. Default to detached; revisit only if Phase 2 measurement
forces it.

`AssetDescriptor` does **not** gain an `isFavorite` field in this plan. Adding it is speculative (no current UI uses
it). Add it when a favorite affordance lands, not before.

### Export Placement

```swift
struct ExportPlacement: Codable, Hashable, Sendable {
  enum Kind: String, Codable, Hashable, Sendable {
    case timeline
    case favorites
    case album
  }

  let kind: Kind
  let id: String                        // stable, used as the placement-section key on disk
  let displayName: String
  let collectionLocalIdentifier: String?

  // Frozen at placement creation. Never recomputed.
  let relativePath: String

  let createdAt: Date                   // diagnostic; set on first persist
}
```

All fields are `let`. There is no mutable `lastDoneAt`: "most recent done" is computed lazily by the collection
store from record `exportDate`s (see *Two Stores: API Surface → Collection store*). This avoids the cross-mutation
atomicity problem (a
`done` write plus a separate `touchPlacementLastDone` log line could land out of sync after a crash) and keeps the
struct safely usable in `Set` / dictionary keys.

There is no stored `pathPolicyVersion`. The path policy is committed-to and frozen for this plan; if it ever
changes, the change will land in a future plan that explicitly handles existing placements. Today, `relativePath`
on every record *is* the placement's recorded path — that's all we need.

**Identity is `id`; conformances are manual.** `ExportPlacement` defines `Hashable` and `Equatable` manually
over `id` only — *not* via Swift's synthesized conformance. Two placements with the same `id` but different
`createdAt` (one freshly constructed, one decoded from disk) must compare equal; synthesized conformance over
all `let` fields would say they differ. The `createdAt` field is diagnostic, not part of identity. Manual
conformance from day one avoids the footgun where a placement passed in for lookup is rejected because its
`createdAt` is `Date()` rather than the persisted timestamp.

**`displayName` rules.** This is the human-readable label used in diagnostic logs (and any future rename
dialog); `relativePath` is sanitized and `id` is opaque, so neither is suitable.

- Timeline: `"<year>/<MM>"` (e.g. `"2025/02"`).
- Favorites: `"Favorites"`.
- Album: the unsanitized full display path joined with `/` (e.g. `"Family/Trip 2024"` for an album titled
  `"Trip 2024"` inside a folder named `"Family"`). Album titles that contain `/` characters are preserved verbatim
  in `displayName` — the U+0000-separated hash in the placement id is what disambiguates structural nesting from
  an in-title slash.

Albums whose titles contain `/` produce ambiguous `displayName` strings (a reader cannot tell whether `A/B`
means "nested folder A containing album B" or "single album with `/` in its title"). This is accepted as a niche
edge case rather than introducing escape syntax — the placement id (which uses U+0000 separators) keeps the
underlying state correct; only the human-readable display is ambiguous in this corner.

### Placement IDs

```text
timeline:    timeline:<YYYY>-<MM>
favorites:   collections:favorites
album:       collections:album:<collectionIdHash16>:<displayPathHash8>
```

`collectionIdHash16` is the first 16 hex characters (64 bits) of `SHA256(collectionLocalIdentifier)`. The raw
`collectionLocalIdentifier` lives on the placement record body for diagnostics and lookups. Hashing isolates the
placement-id format from PhotoKit's opaque id alphabet (which can in principle contain any character).

`displayPathHash8` is the first 8 hex characters of
`SHA256(unsanitized pathComponents joined with U+0000, then U+0000, then unsanitized title)`.

Identity uniqueness is provided by `collectionIdHash16`. The `displayPathHash8` segment is a *rename detector*: it
changes when the album is renamed or moved between folders, so the resolver can spot a rename. Identity itself does
not depend on path.

**Collision handling.** Hash collisions are vanishingly rare at personal-library scale (64-bit at ~4 billion
albums for birthday 50%; 32-bit at ~65,000). The plan's worst-case scaling assumption is ≤1,000 albums per user.
If a hash collision is ever detected at id construction (the candidate id already exists under a *different*
`collectionLocalIdentifier`), the offending hash segment is extended in 8-hex-char increments
(`collectionIdHash16` → `collectionIdHash24` → `…32`, and the same for `displayPathHash`). The format is forward-
compatible.

**Concurrent collision among new placements.** When two newly-discovered albums (no existing record for either)
resolve to the same candidate path, the resolver sorts candidates lexicographically by `collectionLocalIdentifier`
and gives the bare path to the first. The result is independent of PhotoKit traversal order.

### `ExportPlacementResolver`

```swift
struct ExportPlacementResolver {
  func placement(
    for selection: LibrarySelection,
    collections: [PhotoCollectionDescriptor],
    existingPlacements: [ExportPlacement]
  ) throws -> ExportPlacement
}
```

Pure with respect to `(selection, collections, existingPlacements)`. The only code that maps selections to
placements. Uses `ExportPathPolicy` to compute `relativePath` for new placements.

Behavior:

- If an existing placement record matches the resolved `(kind, collectionLocalIdentifier, displayPathHash8)` tuple,
  the resolver returns it unchanged.
- If multiple existing placements match the same triple (which should never happen but defends against record
  corruption or a buggy past write), the resolver picks the placement with the latest `createdAt`, logs a warning,
  and continues.
- If the candidate `relativePath` collides with an existing placement's `relativePath` at the same parent folder,
  the **new** placement gets a numeric suffix (`_2`, `_3`, …); the existing placement is never altered.
- If two *newly-discovered* placements (neither has an existing record) resolve to the same candidate path, the
  resolver sorts candidates lexicographically by `collectionLocalIdentifier` before assigning bare/suffixed paths.

### Reuse-Source Copy Path (APFS clone as optimization)

When a collection export needs `(asset, variant)` and the same `(asset, variant)` already has a `.done` record
under another placement, we copy the existing file rather than refetching from PhotoKit. On APFS, modern macOS
makes `FileManager.copyItem(at:to:)` use copy-on-write at the filesystem layer, so the duplicate is effectively
free. On non-APFS, it's a real copy.

This is an **optimization**, not a correctness pillar. The plan does not depend on cloning succeeding; if a future
macOS regression makes `copyItem` always do a real copy, exports still work — they just use more disk on APFS than
expected.

**Source lookup.** When the writer is about to export `(assetId, variant)` for placement P:

1. Look up *any existing `.done` record* for this `(assetId, variant)` across all placements in the store —
   timeline first, then other collection placements (deterministic order so tests are repeatable). The source can
   be any prior `.done` write; album-first / timeline-second works as well as timeline-first / album-second.
2. If found, the source URL is `<destination root>/<placement.relativePath>/<variant.filename>` from that record.
3. Resolve the *destination* filename independently using the existing `ExportFilenamePolicy` +
   `uniqueFileURL(_:in:)` against P's directory. **The destination filename is not assumed to equal the source
   filename** — collision suffixes (`IMG_0001 (2).HEIC` vs `IMG_0001.HEIC`) can differ between placements
   depending on what each directory already contains.
4. Call `try FileManager.default.copyItem(at: sourceURL, to: destURL)`.
5. On error, narrow the fallback by what failed:
   - **Source-side error** (`NSFileNoSuchFileError`, source unreadable): the prior `.done` record is stale. Fall
     back to PhotoKit re-export. The stale `.done` record is *not* modified by this export — that placement's
     corruption surfaces on its next export run.
   - **Destination-side error** (target permission, `NSFileWriteOutOfSpaceError`, target volume removed): mark the
     variant `.failed` for placement P with the underlying error. **Do not** retry via PhotoKit — it would hit the
     same destination problem and double the work. The variant retries on the next export run.

**Capability detection.** Query `URLResourceKey.volumeSupportsFileCloningKey` on the destination root URL once per
mount and log the result for diagnostics. The flag is informational; `copyItem` works either way.

**Tests:**

- APFS same volume, known-size source (10 MB): post-copy, the volume's
  `URLResourceKey.volumeAvailableCapacityForImportantUsageKey` drops by less than ~64 KB (clone succeeded). Add a
  behavioral check: write to one of the two files, verify the other is unchanged.
- Non-APFS destination: post-copy, free space drops by approximately the source size (real copy ran).
- Source missing (any prior `.done` record's file deleted by user): falls back to PhotoKit re-export; the stale
  `.done` record is unchanged.
- Destination out of space: variant marked `.failed` with the destination error; PhotoKit is not invoked.
- Variant-level decision: timeline has only `.edited`; collection requests both variants. `.edited` is reused from
  the timeline file; `.original` is fetched from PhotoKit. Each variant independently consults the source-lookup.
- Album-first then timeline: timeline export of an asset already in an album reuses from the album record, not
  PhotoKit. Same lookup order ("any prior `.done`"), no special-casing.
- Source filename and destination filename differ (because each directory had different prior collisions): the
  destination record stores the *destination* filename; reads find the right file.

`st_blocks` is **not** a reliable signal for cloning (both files report full blocks after a clone since they
share at the filesystem layer). Use volume free-space delta and behavioral divergence.

If APFS measurement ever shows `copyItem` is doing a real copy (regression or unexpected platform behavior), Phase
3 has the option to drop in `clonefile(2)` as an explicit fallback. The contract surface (`copyItem`) does not
change in that scenario; the implementation gains an explicit pre-step.

State independence is preserved — placement records still record their own `.done` status independently — but
bytes on disk are shared on APFS.

### Export Destination

```swift
protocol ExportDestination {
  func urlForRelativeDirectory(_ relativePath: String, createIfNeeded: Bool) throws -> URL
}
```

`urlForMonth(year:month:createIfNeeded:)` becomes a wrapper around `urlForRelativeDirectory`. The implementation
must reject any relative path that escapes the export root.

**Path validation timing.** Validation runs in `urlForRelativeDirectory` on every write — that is the single
guard. There is no load-time path validation closure on `configure`. A corrupted `relativePath` in a stored
placement surfaces as a loud failure on the first export attempt against that placement, which is acceptable for
this app: collection placements are user-triggered, so the failure is observable immediately. (The previous draft
proposed a `configure(for:validate:)` closure to fail-fast at load; it was dropped because it required threading
the destination root URL through `configure` and complicated handling of disconnected drives, in exchange for
catching corruption ~minutes earlier.)

Rejected inputs (tested in `ExportDestinationTests`):

- absolute paths (leading `/`),
- paths containing `..` segments after canonicalization,
- paths whose canonical resolution lands outside the export root,
- paths whose parent contains a symlink that escapes the root,
- paths where a non-directory exists at one of the intermediate components,
- paths exceeding the platform's max path length.

### Export Jobs and ExportManager

`ExportJob` is placement-scoped:

```swift
struct ExportJob: Equatable {
  let assetLocalIdentifier: String
  let placement: ExportPlacement
  let selection: ExportVersionSelection
}
```

Public `ExportManager` API:

```swift
func startExportMonth(year: Int, month: Int)
func startExportYear(year: Int)             // resolves to N timeline placements internally
func startExportAll()                        // timeline-only; resolves to M timeline placements
func startExportFavorites()
func startExportAlbum(collectionId: String)
func startExport(selection: LibrarySelection)
```

Internally there is **no** single `enqueue(scope:placement:)` for year/all. Year and All resolve to a *list* of
(scope, placement) pairs and call the per-placement enqueue path once per pair:

```swift
private func enqueue(scope: PhotoFetchScope, placement: ExportPlacement, selection: ExportVersionSelection, generation: Int)
```

This is the correctness fix: the previous draft's signature could not represent a year export.

Queue counts: `queuedCountsByYearMonth: [String: Int]` → `queuedCountsByPlacementId: [String: Int]`. Timeline row
helpers ask through a wrapper that resolves the timeline placement id from year/month.

**Routing record mutations to the right store.** With `ExportJob` carrying `placement`, every `markVariant*` and
`removeVariant` call site in `ExportManager` switches on `placement.kind` to choose `exportRecordStore` (for
`.timeline`) or `collectionExportRecordStore` (for `.favorites`/`.album`). Affected call sites today, in
`ExportManager.swift`: 433, 522, 542, 583, 616/618, 657 (verify line numbers before implementing). The
cancellation-cleanup paths (`cancelAndClear` at 223-247 and the run-loop catch at 531-536) follow the same
rule, using the in-flight job's placement.

**In-flight tracking.** Add a third field to track the placement of the job currently in flight:

```swift
private(set) var currentJobAssetId: String?
private(set) var currentJobVariant: ExportVariant?
private(set) var currentJobPlacement: ExportPlacement?   // new
```

Three separate fields (not a tuple) preserve the existing `private(set)` test surface. Reset
`currentJobPlacement` everywhere `currentJobAssetId` is reset (231-232, 375-376, 395-396), and assign it
*before* `currentJobAssetId` at the start-of-job site (388). Widen the catch-block `inFlight` capture (426)
from `(assetId, variant)` to `(assetId, variant, placement)`.

Cancellation remains global (one `currentTask`, one generation counter); per-placement cancel is out of scope.
Cross-store independence is testable: enqueue a timeline job and a collection job, cancel mid-flight, assert
the timeline teardown does not touch the collection store and vice versa.

### Two Stores: API Surface

Independence is enforced by storing timeline and collection records in two physically separate stores with disjoint
key spaces. The existing `ExportRecordStore` retains its current API for timeline records; a new
`CollectionExportRecordStore` carries the placement-keyed API for favorites and albums. `ExportManager` consults
both — routing writes to the appropriate store by `placement.kind`, and querying both during reuse-source lookup —
but the stores themselves remain ignorant of each other.

`ScopedExportRecord` is the in-memory shape callers use to read and upsert collection records. It joins the
on-disk `(placementId, assetId)` key with the variants dictionary and the placement object:

```swift
struct ScopedExportRecord: Sendable, Equatable {
  let placement: ExportPlacement
  let assetId: String
  var variants: [ExportVariant: ExportVariantRecord]   // existing per-variant status/filename/exportDate
}
```

It is not persisted as a single blob — on disk, placement metadata lives in the top-level `placements` map and
the record body is just the variants dict (see *Collection Store Format*).

#### Timeline store (`ExportRecordStore`) — unchanged API

The current asset-keyed API is preserved. Existing call sites
(`monthSummary(year:month:totalAssets:)`, `yearExportedCount(year:)`,
`sidebarSummary(year:month:totalCount:adjustedCount:selection:)`, `recordCount(year:month:variant:status:)`,
`isExported(assetId:)`, etc.) keep their signatures and storage shape. Any "timeline placement" the queue or UI
needs is a synthetic `ExportPlacement` constructed at the boundary — not persisted as a separate metadata entry.
The on-disk files (`export-records.json`, `export-records.jsonl`) and their format are unchanged.

The timeline store has no `placement` parameter on its API and therefore does not assert against non-`.timeline`
placements at the store boundary. Placement-kind policing lives in `ExportManager`'s routing layer (the
`switch placement.kind` at every record-mutation call site) — a `.favorites` placement reaching the timeline
store would only happen via a routing bug in `ExportManager`, not via direct caller error. This is asymmetric
with the collection store (which does assert) but acceptable: the timeline store's API surface is the existing
asset-keyed one and adding a parameter solely to assert against it would force every existing call site to
change.

One small tidiness fix while we're touching the queue layer: **`monthSummary(assets:selection:)`** today derives
`(year, month)` from `assets.first?` and falls back to `Date()` when the array is empty — a latent bug that
hasn't surfaced because the single call site always passes a non-empty array. The signature gains explicit
parameters:

```swift
func monthSummary(year: Int, month: Int, assets: [AssetDescriptor], selection: ExportVersionSelection) -> MonthStatusSummary
```

The single call site (`MonthContentView`) already owns both values.

#### Collection store (`CollectionExportRecordStore`) — new, placement-keyed

```swift
// Placement metadata
func upsertPlacement(_ placement: ExportPlacement)
func deletePlacement(id: String)
func placement(id: String) -> ExportPlacement?
func placements(matching kind: ExportPlacement.Kind) -> [ExportPlacement]

// Record writes (placement must exist)
func upsert(_ record: ScopedExportRecord)
func markVariantInProgress(assetId: String, placement: ExportPlacement, variant: ExportVariant, filename: String?)
func markVariantExported(assetId: String, placement: ExportPlacement, variant: ExportVariant,
                         filename: String, exportedAt: Date)
func markVariantFailed(assetId: String, placement: ExportPlacement, variant: ExportVariant,
                       error: String, at: Date)
func removeVariant(assetId: String, placement: ExportPlacement, variant: ExportVariant)
func remove(assetId: String, placement: ExportPlacement)

// Reads
func exportInfo(assetId: String, placement: ExportPlacement) -> ScopedExportRecord?
func isExported(asset: AssetDescriptor, placement: ExportPlacement, selection: ExportVersionSelection) -> Bool

// Scoped queries
enum CollectionPlacementScope {
  case favorites
  case album(collectionLocalId: String)
  case any                          // favorites + albums
}
func recordCount(in scope: CollectionPlacementScope) -> Int
func summary(for placement: ExportPlacement) -> PlacementSummary
```

The collection store accepts only `.favorites` and `.album` placements; passing a `.timeline` placement is a
programming error and trips an `assertionFailure` (release: silent drop). An invariant test asserts every record's
referenced placement has a non-`.timeline` kind. Symmetrically, `ExportManager` never asks the collection store
about a timeline placement.

`bulkImport` is intentionally **not** part of the collection store. `Import Existing Backup` is timeline-only and
calls into the timeline store's existing import path; the collection store has no equivalent flow because
collection placements are not on-disk-recoverable.

`PlacementSummary` reuses the existing `MonthExportStatus` enum (`notExported` / `partial` / `complete`):

```swift
struct PlacementSummary: Sendable, Equatable {
  let placementId: String
  let exportedCount: Int          // assets with at least one .done variant for this placement
  let totalCount: Int             // distinct assets with any record under this placement
  let status: MonthExportStatus
}
```

**Naming.** `markVariantExported` matches the existing timeline-store method name. The collection store reuses
the same name for symmetry and to match the existing test vocabulary.

**`removeVariant`** (variant-level) is distinct from **`remove`** (whole `(assetId, placement)` record). Cancellation
today removes the in-flight variant only — other variants on the same asset record may still be `.done` and must
survive.

**`markVariantPending`** is intentionally absent: the existing pipeline transitions directly
`inProgress → done | failed` without a persisted `pending` write.

**Load state and mutation guard.** Each store carries a minimal `RecordStoreState` enum
(`.unconfigured | .ready | .failed`). All write entry points check `state == .ready` and no-op
otherwise (with `assertionFailure` in debug; release silently drops the call to avoid crashing on a benign race
during state transitions). Reads return empty results when not `.ready`. UI disables the corresponding export
controls based on each store's state — a failure to load the collection store does **not** disable timeline
export, and vice versa.

**No cross-scope query.** There is intentionally no "is this asset exported anywhere?" API. It invites cross-scope
coupling and makes the independence guarantee leak. The reuse-source copy path consults both stores explicitly,
not via a unified accessor.

### Storage Files

Both stores live under the destination-specific store directory:

```text
ExportRecords/<destinationId>/
  export-records.json            # timeline snapshot (existing format, unchanged)
  export-records.jsonl           # timeline append-only log (existing format, unchanged)
  collection-records.json        # collection snapshot (new)
  collection-records.jsonl       # collection append-only log (new)
```

The two stores are loaded and persisted independently. There is no marker file — neither store needs one because
nothing migrates: timeline files keep their existing format and the collection files start empty on first launch
under the new build.

### Shared `JSONLRecordFile` Component

The current `ExportRecordStore` mixes JSONL+snapshot machinery (atomic writes, log replay, compaction, recovery)
with timeline-specific record shape. Phase 1 extracts the machinery into a small, generic component:

```swift
final class JSONLRecordFile<Snapshot: Codable & Sendable, LogOp: Codable & Sendable> {
  // .tmp + atomic rename + fsync(parent) snapshot writes
  // append-only log with malformed-line skip
  // compaction at N mutations rotating snapshot and log together
}
```

`ExportRecordStore` (timeline) and `CollectionExportRecordStore` (new) each compose one. The timeline store binds
the generic to its existing snapshot type and log op enum; the collection store binds it to the placement-keyed
shape below. The extraction is internal — no public API of either store changes for callers.

The generic owns persistence mechanics (atomic write, append, log iteration, compaction trigger). The composing
store owns record shape, the apply-log-op dispatch, the in-flight recovery pass, the `@Published`
`mutationCounter`, and the `RecordStoreState` machine. `JSONLRecordFile` exposes `append(_ op: LogOp)`,
`writeSnapshot(_ snapshot: Snapshot)`, and a load API returning `(snapshot, [LogOp])`; the composing store
calls `apply(_:)` on each op itself. Each store has its own 200ms `objectWillChange` coalescing timer
(matching today's behavior); the two stores' UI updates can fire ~200ms apart, which is acceptable.

### Collection Store Format

The collection store **normalizes** placement metadata out of records. Placements live once in a top-level
dictionary; records reference placements by id. This gives stale placements a first-class home (rename detection,
collision checking) and avoids delimiter-parsed string keys.

**Snapshot format** (`collection-records.json`):

```json
{
  "version": 1,
  "placements": {
    "collections:favorites": {
      "kind": "favorites",
      "displayName": "Favorites",
      "collectionLocalIdentifier": null,
      "relativePath": "Collections/Favorites/",
      "createdAt": "2026-04-01T10:00:00Z"
    },
    "collections:album:abc123def4567890a:9876fedc": {
      "kind": "album",
      "displayName": "Family/Trip 2024",
      "collectionLocalIdentifier": "ABC-123-…",
      "relativePath": "Collections/Albums/Family/Trip 2024/",
      "createdAt": "2026-04-01T10:00:00Z"
    }
  },
  "records": {
    "collections:album:abc123def4567890a:9876fedc": {
      "ABCDE-F-12345/L0/001": {
        "variants": { "original": { "filename": "IMG_0001.HEIC", "status": "done",
                                    "exportDate": "2026-04-15T12:00:00Z", "lastError": null } }
      }
    },
    "collections:favorites": {}
  }
}
```

The outer `records` dictionary is keyed by placement id; the inner dictionary by `PHAsset.localIdentifier`. No
delimiter parsing — PhotoKit's opaque asset ids are stored verbatim as JSON keys. JSON requires only that keys be
strings, which `localIdentifier` always is.

Top-level `placements` is the canonical placement metadata. Each record carries only `variants`; `assetId` is the
inner-key, `placementId` is the outer-key. `ScopedExportRecord` (in-memory) joins these with the placement object
for callers, but on disk the placement is referenced once.

**Placement Codable.** `ExportPlacement` always encodes `id` inside its JSON body. The dict key in the snapshot
duplicates the value's `id` field; the encoder asserts `key == value.id` and the decoder treats the value's `id`
as authoritative (logging if they differ). This costs ~30 bytes per placement (~3 KB at 100 placements) — much
less than the complexity of two parallel encodings (one with `id`, one without). Standard Codable synthesis
applies; no special encoder. A round-trip test asserts encode-then-decode produces identical placements.

There is no stored `lastDoneAt`; "most recent done" is computed lazily from record `exportDate`s on demand.

A placement entry may exist with no records (e.g. cancelled before first export). Stale placement entries from
deleted albums remain until explicit cleanup; they are intentionally load-bearing for collision detection and
rename history.

JSON dictionary key ordering is undefined (Swift dictionaries are unordered). The collection store's snapshot may
re-encode equivalent state with different key order.

**Log format** (`collection-records.jsonl`), one mutation per line. Placements and records mutate independently:

```json
{ "op": "upsertPlacement", "placementId": "<placementId>", "placement": { ExportPlacementRecord JSON } }
{ "op": "deletePlacement", "placementId": "<placementId>" }
{ "op": "upsertRecord",    "placementId": "<placementId>", "assetId": "<assetId>",
                           "record": { "variants": { ... } } }
{ "op": "deleteRecord",    "placementId": "<placementId>", "assetId": "<assetId>" }
```

Loader applies log entries in order. An `upsertRecord` referencing an unknown `placementId` is logged and
skipped (defends against truncated logs). There is no `bulkImport` op (`Import Existing Backup` is timeline-only
and uses the timeline store's existing path). There is no `renamePlacement` op for the MVP — album rename
behavior is "new placement at the new path" (see *Album Rename Behavior*); a future "merge old folder" UX would
add the op then.

`ExportRecordKey` remains as an in-memory ergonomic tuple `(placementId, assetId)`. It is not persisted.

### Atomic Snapshot Writes

Every snapshot write in either store uses a `.tmp` + atomic rename pattern with explicit fsyncs:

1. Write snapshot bytes to `<name>.tmp`.
2. `fsync(<name>.tmp)`.
3. Rename `<name>.tmp` → `<name>`.
4. `fsync(<parent dir>)` so the rename is durable.

This discipline is centralized in `JSONLRecordFile` so both stores get it from the same code path. The current
`writeSnapshotAndTruncate` (`ExportRecordStore.swift:602-613`) has **two unsynced renames** — the snapshot
rename uses `Data(...).write(to:options: .atomic)` (a `.tmp` + rename without parent-dir fsync) and the log
truncation at line 612 *also* uses `.atomic` write (a *second* `.tmp` + rename without parent-dir fsync). The
extraction must cover both: snapshot rename and log truncation each get the four-step discipline above. Without
the log-truncation fsync, a power loss between the snapshot rename and the log truncation can leave the
snapshot durable on disk while the log still contains pre-snapshot mutations, replaying mutations already in
the snapshot on next load.

`JSONLRecordFile`'s `writeSnapshot(_:)` is the single entry point for both renames.

The loader ignores `.tmp` files. A half-written `.tmp` from a crash mid-write is incomplete and untrustworthy;
the next compaction overwrites it.

## Upgrade Behavior

### No data migration

Existing users get the new build with **no schema migration and no on-disk rewrite**. The timeline store
(`export-records.json` / `.jsonl`) keeps its current asset-keyed shape; its files are untouched. The new collection
store (`collection-records.json` / `.jsonl`) starts empty on the first launch under the new build.

Consequences:

- Existing completed timeline exports continue to show as exported. No re-export. No `Import Existing Backup` re-run.
- File paths on disk for timeline exports are unchanged.
- The collection store has no records on day one; the user creates them by exporting favorites or albums.
- Downgrade to a pre-collections build is **not** safe and is explicitly unsupported. The collection-store files
  on disk would be ignored — that part is benign — but Phase 0 also renames the destination's record directory
  from the legacy bookmark-hash `<oldId>` to the stable-identity `<newId>`. A pre-collections build re-derives
  `<oldId>` from the current bookmark bytes, doesn't find it (it's now under `<newId>`), and presents an empty
  timeline store. The user could recover with `Import Existing Backup`, but the downgrade is destructive to
  recorded state until then. Document this in the release notes. Do not attempt to keep a `<oldId>` symlink
  around — it would silently divide the source of truth across two directories on every subsequent
  re-upgrade/re-downgrade.

The existing `ExportRecordLegacyMigrationTests` (v0 → v1, decode-time inside `ExportRecord.init(from:)`) is left
in place — it is independent of this plan.

### Compaction

Both stores compact at ~1000 mutations to bound log size. Compaction is the standard rotate pattern (snapshot
written via `.tmp` + atomic rename + fsync(parent), then the log is truncated). The timeline store's existing
`writeSnapshotAndTruncate` (`ExportRecordStore.swift:602`) is updated as part of the `JSONLRecordFile`
extraction to add the parent-dir fsync it currently lacks; without it, a power loss between the rename and the log
truncation can leave the snapshot durable but the log un-truncated, replaying mutations already in the snapshot.
The collection store inherits the corrected discipline from the same shared component.

There is intentionally no `.bak` rotation, no `.complete` marker, and no multi-state recovery flow. The timeline
store has operated without these for the life of the project; the collection store starts empty so corruption
during its first months of life is a "lose at most a few albums' worth of records" event recoverable by re-export.

### Recovery on Corruption

Each store loads independently:

- **Snapshot decodes, log overlays cleanly.** State → `.ready`. Done.
- **Log has malformed lines.** Skip them with logging. Snapshot + good lines apply. State → `.ready`.
- **Snapshot fails to decode.** State → `.failed`. The corrupt snapshot is **left in place on disk** — it is not
  renamed yet. A modal alert names the file and the store and offers two actions:
  - **Reset to empty** — explicit destructive action. The corrupt snapshot is renamed to
    `<name>.broken-<ISO8601>` for forensic inspection and an empty snapshot + log are written. State → `.ready`.
  - **Quit** — leaves the corrupt snapshot in place. On next launch the same `.failed` state and the same alert
    appear. State persists across relaunches; there is no silent recovery.

The deferred-rename is the load-bearing detail. If the loader renamed the corrupt snapshot eagerly and the user
quit, the next launch would find no snapshot and would match the documented "snapshot file absent → empty store,
state `.ready`" path — i.e. a silent reset behind the user's back. By keeping the corrupt file in place until the
user picks a destructive action, "Quit" is non-destructive in the literal sense.

If a Reset action partially succeeds — the rename to `<name>.broken-*` lands but the empty-snapshot write fails
(rare I/O error) — the next launch finds no `<name>.json` and falls into the empty-store path with state
`.ready`. The forensic `.broken-*` is left on disk for the user to inspect. The user's previous records are
gone in this corner case, which matches the user's intent ("Reset to empty"); no further recovery is needed.

Failure isolation: a corrupted collection store does **not** disable timeline exports, and a corrupted timeline
store does **not** disable collection exports. UI checks each store's state independently when deciding which
controls to enable.

**In-flight recovery on load.** Both stores run an in-flight cleanup pass on successful load:

- **Timeline store** retains the existing `recoverInProgressVariants()` pass at
  `ExportRecordStore.swift:135-150`. The implementation walks `recordsById`, flips `.inProgress` → `.failed` with
  `ExportVariantRecovery.interruptedMessage`, and mutates the in-memory dictionary only. **It does not persist
  the rewrite.** Stale `.inProgress` log lines are overwritten lazily — the next mutation that lands for the
  same `(asset, variant)` rewrites the on-disk state, and the next compaction folds the corrected status into
  the snapshot. This is existing behavior; the plan does not change it.
- **Collection store** runs a structurally identical in-memory pass against its placement-keyed records: any
  variant in `.inProgress` becomes `.failed` with the recoverable-error message. Like the timeline pass, it
  **does not persist the rewrite eagerly**. The corrected status flows to disk on the next mutation or
  compaction.

Why no eager persistence: writing on every launch that finds a stale `.inProgress` costs a write for state that
the next user action would correct anyway. The lazy model has been correct in production today; the
collection store inherits it.

Tests live in each store's test file.

### `Import Existing Backup`

Unchanged. `BackupScanner` continues to scan `<YYYY>/<MM>/` and writes results into the timeline store via the
existing import path; no signature change is required. `Collections/` directories are ignored. UI copy states
explicitly: "Import scans timeline backups (`YYYY/MM/`) only."

There is no equivalent flow for the collection store — collection placements are not on-disk-recoverable (folder
names are sanitized, not reversibly mapped to PhotoKit collection ids). Users re-export favorites or albums to
rebuild collection state if needed.

### Tests

Storage and recovery tests for the new collection store live in `CollectionExportRecordStoreTests`:

- snapshot + log replay across simulated restart produces correct state,
- malformed log lines are skipped and logged,
- snapshot file absent on first launch → empty store, state `.ready`,
- **snapshot corrupt** → state `.failed`, the corrupt file remains at its original path on disk (no `.broken-*`
  exists yet), timeline store unaffected,
- **Quit-and-relaunch after `.failed`** → store re-loads the same corrupt file, state remains `.failed` (no
  silent recovery),
- **`resetToEmpty()`** → corrupt file is renamed to `<name>.broken-<ISO8601>`, an empty snapshot+log are
  written, state → `.ready`,
- **lazy in-flight cleanup**: pre-stage a record with one variant `.inProgress`; load the store; assert
  in-memory state shows the variant as `.failed` with the recoverable-error message and the on-disk log
  retains the original `.inProgress` line until the next mutation rewrites it,
- store mutations on `.failed` no-op (with `assertionFailure` in debug; release silently drops),
- collection store rejects a `.timeline` placement at the API boundary (assertion in debug, drop in release),
- invariant: every record's referenced placement has `kind ∈ {.favorites, .album}`.

Tests for the timeline store's recovery behavior follow the same shape (`ExportRecordStoreCorruptionTests`),
with deferred-rename / Quit-doesn't-reset / `resetToEmpty` / lazy in-flight cleanup cases.

A new file `CrossStoreIndependenceTests` covers boundary behavior between the two stores:

- a `.failed` collection store does not disable timeline export controls,
- a `.failed` timeline store does not disable collection export controls,
- writes to one store never produce log lines in the other (file-watch assertion),
- cancellation mid-flight on a timeline job does not write to the collection store, and vice versa,
- reuse-source lookup with one store `.failed` falls through cleanly (treated as "no record"; PhotoKit re-export).

`JSONLRecordFileTests` covers the shared persistence behavior:

- atomic snapshot write succeeds; subsequent load returns equivalent state,
- compaction at threshold truncates the log; snapshot reflects all mutations,
- crash mid-compaction (snapshot written, log not yet truncated) produces correct state on next load — no
  duplicate mutations.

Backward-compatibility invariants for timeline (trivially satisfied because nothing migrates):

- existing completed timeline exports show as exported after upgrade,
- existing timeline file paths on disk are unchanged,
- no `Import Existing Backup` prompt appears on upgrade,
- a failure marking on favorites does not mutate timeline store contents (cross-store independence).

## UI Plan

### `ContentView` Split

`ContentView` is too broad for this addition. Sidebar and content branching move out:

```text
Views/
  LibraryRootView.swift          // segmented Timeline/Collections selector and NavigationSplitView composition
  TimelineSidebarView.swift      // current year/month list, extracted from ContentView
  CollectionsSidebarView.swift   // favorites/albums tree
  AssetGridContentView.swift     // generalized MonthContentView
  CollectionRow.swift
  TimelineRows.swift             // existing YearRow/MonthRow moved out of ContentView
```

`ContentView` can remain the environment-object entry point.

### Generalized Asset Grid

Replace `MonthViewModel` with a scope-based view model:

```swift
final class AssetGridViewModel: ObservableObject {
  func loadAssets(in scope: PhotoFetchScope) async
}
```

The grid receives: title, export summary, export button title, fetch scope, export placement.

Asset selection (used for the detail view) carries both asset and placement:

```swift
struct AssetSelection: Hashable {
  let asset: AssetDescriptor
  let placement: ExportPlacement
}
```

`AssetDetailView` (currently asset-scoped — it reads export info by asset id only) takes `AssetSelection` and
queries `exportInfo(assetId:placement:)`. Without this, the detail pane would show timeline export status when
viewing the same asset under a collection.

### Sidebar Counts and Progress

Timeline:

- Preserve current behavior and badges; route through timeline placements internally.

Collections:

- Show asset counts and adjusted counts per row for `Favorites` and `Albums`.
- Show completion badges using placement-scoped queries.
- Compute counts off the main actor; cache by placement id; invalidate on `PHPhotoLibraryChangeObserver` ticks.
- Cancel in-flight count work for rows that scroll out of view (or for the whole sidebar if the user switches to
  Timeline).
- A neutral loading state until counts arrive is acceptable, matching current timeline behavior.

### Toolbar

Existing global controls keep their meaning:

- pause, resume, cancel/clear,
- `Include originals` toggle,
- queue/progress status.

`Export All` stays timeline-only. No automatic "Export All Collections" in the MVP.

## Implementation Phases

Each phase has narrow exit criteria and is independently shippable behind a feature flag (with the caveat that
Phase 1 ships persistence changes for *every* user — see *Feature flag scope*).

### Phase 0: Stable destination identity (prerequisite)

`destinationId` is a SHA-256 hash of the security-scoped bookmark data today, and bookmark data changes when the
OS regenerates a stale bookmark or when the user re-grants access via the open panel. Each change orphans the
record store. Pre-collections, `Import Existing Backup` is a recovery path; post-collections, it isn't (collection
state is not on-disk-recoverable). This phase makes destination identity stable before the collection store ships.

**Identity derivation.** `destinationId = SHA-256(volume UUID || U+0000 || canonical-folder-path)` where:

- *volume UUID* is read from `URLResourceKey.volumeUUIDStringKey` on the destination root. Falls back to
  `URLResourceKey.volumeIdentifierKey` if the platform omits the UUID (rare).
- *canonical-folder-path* is the destination root's URL after `.resolvingSymlinksInPath()`, expressed as a path
  string in the volume's coordinate system.

This survives bookmark refresh on the same drive. It changes when:

- The volume is reformatted (different volume UUID).
- The folder is moved/copied to a different volume.
- The user duplicates the folder via Finder and selects the duplicate.

All three are user-initiated actions that arguably should produce a new logical destination. The records under the
old id remain on disk; selecting the original folder again finds them via the lazy migration below.

**Lazy per-destination migration.** Migration runs **once before either store configures**, in a new
coordinator (`ExportRecordsDirectoryCoordinator`, lives at `Export/ExportRecordsDirectoryCoordinator.swift`)
that owns the `ExportRecords/<newId>/` directory lifecycle. Its public surface is a single synchronous method:

```swift
func prepareDirectory(for newId: String) -> Result<Void, DirectoryPrepareError>
```

`ExportManager` (or `photo_exportApp`'s `.task` / `.onChange` blocks directly) calls `prepareDirectory(for:)`
before either store's `configure(for: newId)`. The two stores then `configure` against the already-resolved
directory in either order; neither store's `configure` performs the legacy rename itself.

This ordering is load-bearing: with two stores both calling `configure(for: newId)`, whichever runs first
would create `ExportRecords/<newId>/` and cause the other store's lazy-migration check to see `<newId>` already
present, leaving the legacy `<oldId>` directory orphaned. Centralizing the migration in a coordinator that runs
exactly once before any store touches the destination directory prevents this.

Coordinator algorithm:

1. If `ExportRecords/<newId>/` already exists, use it. Done.
2. Otherwise, re-derive `<oldId>` from the destination's *current* bookmark bytes using the legacy SHA-256 scheme
   (the pre-Phase-0 derivation, kept around as a one-shot helper).
3. If `ExportRecords/<oldId>/` exists, rename the entire directory to `ExportRecords/<newId>/`. Both
   `export-records.{json,jsonl}` and (if present) `collection-records.{json,jsonl}` ride along inside it. Log
   the migration. Done.
4. If `<newId>` already exists *and* `<oldId>` also exists (which shouldn't happen but defends against bugs), log
   both directories as a conflict and use `<newId>` as-is. The `<oldId>` directory is left untouched for manual
   inspection.
5. If `<oldId>` does not exist, treat the destination as fresh.

After the coordinator returns, `ExportManager` calls `exportRecordStore.configure(for: newId)` and
`collectionExportRecordStore.configure(for: newId)` in either order; both find the directory ready.

The coordinator only touches the *active* destination. Historical destinations that the user never reconnects
under the new build are left at their `<oldId>` directory; reconnecting them later runs the same lazy migration
at that point. There is no app-launch sweep across all `ExportRecords/*` directories.

Tests:

- Bookmark refresh on the same folder produces an unchanged `destinationId`.
- Same folder accessed via two different bookmark grants resolves to one `destinationId`.
- Two different folders on the same volume produce different ids.
- Two folders with the same name on different volumes produce different ids.
- Lazy migration: configure D1; verify legacy `<oldId>` directory is renamed to `<newId>`. Skip configuring D2
  (offline). Months later, configure D2; verify its legacy directory is renamed at *that* moment, not at first
  launch.
- A folder on an unmounted volume: derivation fails; the configure call returns an unconfigured state and waits
  for the drive to mount; no data is touched.
- Conflict case: pre-create both `<newId>` and `<oldId>` directories; verify the loader keeps `<newId>` and logs
  `<oldId>` as a conflict (no merge, no delete).

Exit criteria:

- A bookmark-refresh test that previously orphaned the record store now resolves to the same `destinationId`.
- Lazy migration test passes for both the just-after-upgrade and reconnected-months-later cases.
- Cross-reference in `auto-sync-background-sync-plan.md`: that plan can drop its "stable destinationId" prerequisite.

**Effort:** ~3–5 days.

### Feature flag scope

`AppFlags.enableCollections` gates **UI surface** (the `Timeline` / `Collections` segmented control, the
`Collections` sidebar, the new export actions). It is *not* a kill switch for the storage change.

Concrete semantics:

- **`CollectionExportRecordStore` is constructed and loads on every launch, regardless of the flag.** This keeps
  the persistence layer's lifecycle predictable and lets any future codepath (auto-sync, diagnostics) consult
  the store without flag-gating.
- **The corruption alert UI is gated on the flag.** If the collection store loads cleanly, all good. If it fails
  to decode, the loader sets `state == .failed` as usual but the modal alert is *suppressed when
  `enableCollections == false`* — see *Corruption Alert Presenter* below for the host-view spec. A diagnostic
  log line is always emitted regardless of the flag.
- **Export-side reads guard on store state, not on the flag.** The reuse-source copy lookup queries both stores
  and treats `state != .ready` as "no record" — independent of the flag. This means a flag-off user with a
  `.failed` collection store still gets correct timeline behavior, just no reuse from collection records.
- **Cross-store reads from collection-side code (sidebar counts, etc.) are flag-gated.** They are unreachable
  while the flag is off because the UI surface that triggers them is hidden.

Phase 4 flips the flag to `true`. The flag is removed in a follow-up cleanup once the feature stabilizes; at
that point the conditional `.alert(...)` modifier becomes unconditional and the collection-store alert begins
firing for any user whose collection store is `.failed`.

### Corruption Alert Presenter

The corruption alert is greenfield UI: no existing modal alert system in the app today (`ContentView.swift:121`
uses `.sheet(...)` for the import flow, not an alert).

**What ships in which phase.**

- **Phase 1 (store side, no UI):** Each store exposes `RecordStoreState` as `@Published`. The store has a
  `resetToEmpty()` method that performs the deferred `.broken-<ISO8601>` rename + writes an empty snapshot/log.
  Phase 1 also adds a `canExport: Bool` on `ExportManager` that ANDs both stores' `state == .ready`, and the
  export-start paths (`startExportMonth/Year/All` and the future `startExportFavorites`/`startExportAlbum`)
  short-circuit early-return when `canExport == false`. This prevents the silent-false-success case where a
  `.failed` store would otherwise enqueue work whose `markVariant*` writes silently no-op. Internal/dev
  testers running Phase 1 see the early-return + log line; the Phase 4 alert presenter is what surfaces it to
  users. No alert UI yet.
- **Phase 4 (UI):** Add a top-level `RecordStoreAlertHost` view that watches both stores' states. When either
  transitions to `.failed`, the host presents an alert with two buttons: "Reset to empty" (invokes the store's
  `resetToEmpty()`) and "Quit" (`NSApplication.shared.terminate(nil)`). Title and body name the failed store
  and file path. Both stores' alerts are gated on `AppFlags.enableCollections` for the duration of the flag's
  lifetime — collection users see both, pre-flag users see neither (preserving today's silent-failure behavior).
  When the flag is removed in the follow-up cleanup, both alerts become unconditional.

Phase 4 also rebuilds the `.failed` → `resetToEmpty()` → `.ready` flow for the timeline store. Two stores in
`.failed` simultaneously surface as a single alert listing both with separate Reset buttons; Quit terminates
regardless. SwiftUI's native `.alert(...)` does not handle three buttons cleanly, so the implementation will
use a small custom modal view.

Estimate: ~1 day of UI work in Phase 4. Phase 1 contains only the `@Published` state + `resetToEmpty()` method
on each store — that's part of the per-store recovery work and not a separate line item.

### Phase 1: type/queue plumbing + new collection store (no migration)

Goal: introduce placement-aware queueing and the second store without changing the user-visible surface or
disturbing the timeline store's on-disk format.

- Add `LibrarySelection`, `PhotoFetchScope`, `ExportPlacement`, `ExportRecordKey`, `ScopedExportRecord`,
  `CollectionPlacementScope`.
- Add `ExportPathPolicy` and `ExportPlacementResolver` (timeline-only resolver paths in this phase; collection
  paths defined but unreachable until Phase 2).
- Extract the JSONL+snapshot machinery from `ExportRecordStore` into `JSONLRecordFile<Snapshot, LogOp>`. Both the
  existing timeline store and the new collection store compose it. No on-disk format change for timeline.
- Add the parent-dir fsync to `JSONLRecordFile`'s atomic-write path. The current `writeSnapshotAndTruncate`
  (`ExportRecordStore.swift:602`) skips it; the extraction is the natural place to fix it. Compaction also
  inherits the corrected discipline.
- Add `CollectionExportRecordStore`. Empty on first launch. Its API is the placement-keyed surface defined in
  *Two Stores: API Surface*. Asserts that any placement passed in has `kind ∈ {.favorites, .album}`.
- `ExportRecordStore` (timeline) keeps its current public API. `ExportManager`'s timeline call sites are
  unchanged except for the one signature noted below.
- Update `ExportJob` to carry an `ExportPlacement`. Update `ExportManager` queue counts to `[placementId: Int]`.
  Year and All enumerate timeline placements internally; per-placement enqueue routes to the timeline store.
- Add `currentJobPlacement: ExportPlacement?` to `ExportManager`. Route every `markVariant*` and `removeVariant`
  call site by `placement.kind` to the correct store. Reset `currentJobPlacement` everywhere
  `currentJobAssetId` is reset; assign it before `currentJobAssetId` at the start-of-job site. (See *Routing
  record mutations to the right store* and *In-flight tracking* in *Export Jobs and ExportManager*.)
- Update the `destinationId`-change wiring in `photo_exportApp.swift:39-45` to: (1) run the
  `ExportRecordsDirectoryCoordinator` legacy migration for `newId` first; (2) then call `configure(for: newId)`
  on **both** `exportRecordStore` and `collectionExportRecordStore`. Today the `.onChange` handler only
  reconfigures the timeline store; the new ordering ensures the legacy `<oldId>` → `<newId>` directory rename
  happens once before either store creates `<newId>`, avoiding orphaning timeline records when the collection
  store would otherwise create `<newId>` first.
- Wrap every existing year/month-shaped read API (`monthSummary(year:month:totalAssets:)`,
  `yearExportedCount(year:)`, `sidebarSummary(...)`, etc.) so callers do not need to learn placements. Internally
  the wrappers construct the synthetic timeline placement and route to the timeline store.
- Change one timeline read-API signature: `monthSummary(assets:selection:)` →
  `monthSummary(year:month:assets:selection:)`. Update `MonthContentView`'s single call site. (Independent of
  storage shape; the existing `Date()` fallback is unsafe under placement-aware queueing.)
- Add `RecordStoreState` and the `.ready`-guard on every write entry point of *each* store. Each store's UI
  control set is gated independently.
- Implement the per-store corruption-recovery loader path described in *Recovery on Corruption*: on snapshot
  decode failure, leave the corrupt file in place (deferred rename), set state → `.failed`. Both stores wired so
  the collection store's failure leaves the timeline store's state untouched and vice versa. Add a
  `resetToEmpty()` method on each store that performs the deferred `.broken-<ISO8601>` rename + writes an empty
  snapshot/log; this is the API the Phase 4 alert UI will call.
- Add `@Published RecordStoreState` on each store so Phase 4's alert host can observe.
- Add `var canExport: Bool { exportRecordStore.state == .ready && collectionExportRecordStore.state == .ready }`
  on `ExportManager`, and short-circuit `startExportMonth/Year/All` and the (future) collection start methods
  with an early return + log line when `canExport == false`. This prevents the silent-false-success case in dev
  where a `.failed` store would otherwise enqueue work whose `markVariant*` writes silently no-op.
- Implement collection-store in-flight recovery: a `recoverInProgressVariants()`-equivalent pass that converts
  `.inProgress` variants to `.failed` with the recoverable-error message during load. **In-memory only**, mirroring
  the timeline store's existing behavior (no eager persistence; lazy correction on next mutation/compaction).
- Update `FakeExportDestination` and add `FakeCollectionExportRecordStore`. Existing timeline tests need only
  trivial changes (the wrapper APIs preserve their signatures).
- Add `JSONLRecordFileTests`, `CollectionExportRecordStoreTests`, `ExportPathPolicyTests`. Recovery coverage:
  corrupt-snapshot → file remains until `resetToEmpty()`; Quit-and-relaunch → still `.failed`.
- Add `enum AppFlags { static var enableCollections = false }` in `photo-export/AppFlags.swift`. Phase 4 flips it
  to `true`. Removed in a follow-up cleanup once the feature stabilizes.

Explicitly *not* in this phase:

- Any migration of timeline records (the timeline store is untouched on disk).
- The corruption alert UI (lives in Phase 4 alongside the rest of the Collections UI; Phase 1 only wires the
  store-side `@Published` state and the `resetToEmpty()` action).
- The album-rename dialog and `renamePlacement` log op (deferred to a follow-up plan; MVP behavior is "new
  placement at the new path; old folder stays").
- The `_album.json` sidecar writer (deferred to a follow-up plan).
- Load-time path validation closure on `configure` (on-write validation is the single guard).

Exit criteria:

- All existing functional tests pass with no change to timeline store on-disk format.
- Existing timeline file paths unchanged on disk.
- Collection store loads empty on first launch and writes its first snapshot only when something is upserted.
- `AppFlags.enableCollections == false`; user-visible surface is timeline-only.
- **Cross-store independence**: a forced corruption of one store leaves the other's `.ready` state and exports
  unaffected. Verified by `CrossStoreIndependenceTests`.
- **Deferred-rename recovery**: forced snapshot corruption produces `.failed` with the corrupt file *still
  present* at its original path. Quit + relaunch reproduces `.failed`; no silent reset. `resetToEmpty()` is the
  only path that performs the rename. Verified in each store's corruption test file.
- **In-flight cleanup (lazy)**: pre-staging an `.inProgress` variant on each store and loading it leaves the
  in-memory state showing `.failed` while the on-disk log retains the original `.inProgress` line — i.e. the
  recovery did not write to disk.
- **`destinationId` change reconfigures both stores**: changing the export destination at runtime invokes the
  `ExportRecordsDirectoryCoordinator` once, then `configure(for:)` on both stores.

### Phase 2: PhotoKit collection discovery

- Add `PhotoCollectionDescriptor` and `fetchCollectionTree()`.
- Implement `fetchAssets(in:)`, `countAssets(in:)`, `countAdjustedAssets(in:)` for `.favorites` and `.album`
  scopes. Counts in this phase are uncached; callers re-fetch on every access.
- Wire collection-tree invalidation into the existing `PHPhotoLibraryChangeObserver` callback.
- Add collection fixtures to `FakePhotoLibraryService`.
- Activate the collection paths in `ExportPlacementResolver` and add resolver tests.

Exit criteria:

- PhotoKit isolated; no `PHAssetCollection` leaks past `PhotoLibraryManager`.
- Collection-tree mapping tests pass.
- Resolver produces correct placement and `relativePath` for nested folders, sibling collisions, and the two
  collection kinds (`favorites`, `album`).

### Phase 3: ExportManager and destination collection-aware

- Add `urlForRelativeDirectory` to `ExportDestination` and back `urlForMonth` with it.
- Add destination escape-protection tests (absolute paths, `..`, symlinked parent escaping root, intermediate file,
  path length).
- Add `startExportFavorites()` and `startExportAlbum(collectionId:)`.
- Wire collection scopes through the queue and record store.
- Implement the **reuse-source copy path** (see *Reuse-Source Copy Path*): when any prior `.done` record (timeline
  or collection) points at an existing source file, copy it to the destination via `FileManager.copyItem` (auto-
  clones on APFS as a free optimization); fall back to PhotoKit re-export only on source-side errors. Destination-
  side errors fail the variant directly.
- Add `CollectionCountCache` actor with per-id `Task` handles, cancellation, and `PHPhotoLibraryChangeObserver`
  invalidation. (Phase 2 counts were uncached; this phase introduces the cache.)

Exit criteria:

- Timeline export still writes exactly to `YYYY/MM/`.
- Favorites export writes to `Collections/Favorites/`; Album to `Collections/Albums/...`.
- On APFS, a collection export of an asset already exported elsewhere (timeline *or* another collection) results
  in a CoW clone via `FileManager.copyItem` (verified by free-space delta on a known-size source file). On
  non-APFS, the same export produces a real copy.
- Cross-scope failure isolation: a failure marking on favorites does not mutate timeline state for the same asset;
  in-flight cleanup on Album A does not mutate Album B records. (Queue cancellation remains global; per-placement
  cancel is out of scope for this plan.)
- Renaming an album in Photos.app produces a fresh placement at the new path on the next export of that album;
  the old folder remains on disk untouched, and its placement record stays in the collection store.

### Phase 4: UI and docs

- Extract timeline sidebar rows from `ContentView`.
- Add the top `Timeline` / `Collections` segmented selector.
- Add `CollectionsSidebarView` with rows for Favorites and Albums.
- Generalize `MonthViewModel` / `MonthContentView` into scope-based asset grid pieces.
- Add export actions for favorites and albums.
- Empty states: no favorites; no albums; selected album unavailable; limited Photos access may hide some assets.
- Build the corruption alert presenter (`RecordStoreAlertHost`) per *Corruption Alert Presenter*. Wire it to
  observe both stores' `@Published RecordStoreState`. Both stores' alerts are flag-gated for the duration of
  `AppFlags.enableCollections`. Buttons: "Reset to empty" (calls `store.resetToEmpty()`) and "Quit".
- Flip the `enableCollections` feature flag on.
- Update docs in the same PR: `README.md`, `docs/reference/persistence-store.md` (two-store layout, collection
  store schema, recovery rules), `AGENTS.md` (placement vocabulary, cross-store independence invariant), the
  manual testing guide (collections export, independence, rename behavior), the website/Starlight pages under
  `website/src/content/docs/` (user-facing feature pages and any architecture references), and a cross-reference
  in `auto-sync-background-sync-plan.md` (auto-sync remains timeline-scoped). Release notes call out the
  post-rename "old folder stays on disk; sidebar shows new album only" behavior.

Exit criteria:

- Current timeline workflow remains familiar.
- Collection browsing and export are available without a separate window.
- Sidebar remains responsive on a 100-album fixture.
- Forced corruption of either store under flag-on surfaces the modal; Reset succeeds; Quit terminates.
- User-facing docs match shipped behavior; persistence reference describes both stores.

## Testing Plan

### Unit Tests

Path policy (`ExportPathPolicyTests`) — the cases listed in *Path Policy → Test cases*.

Placement resolver:

- timeline selection → correct placement id and relative path,
- favorites → `collections:favorites`, `Collections/Favorites/`,
- album with nested folder → correct unsanitized hash and sanitized path,
- two albums with identical title under same folder → distinct placement ids and paths,
- folder rename produces a new placement id,
- album title rename produces a new placement id,
- new placement collides with existing placement → new gets the `_2` suffix; existing path is unchanged ("first
  claimant wins"),
- three newly-discovered colliding albums lex-sorted by `collectionLocalIdentifier` produce `Trip/`, `Trip_2/`,
  `Trip_3/` deterministically,
- a new placement collides with an existing `_2`-suffixed placement → resolver picks `_3`,
- two placements with identical `collectionLocalIdentifier` but different display paths get different placement ids
  (the `displayPathHash8` segment changes on rename; the next export goes to the new placement),
- title-with-slash vs nested folder produce different placement ids: an album titled `"Family/Trip"` at root has a
  different `displayPathHash8` than an album titled `"Trip"` inside a folder named `"Family"` (confirms the U+0000
  separator),
- two newly-discovered colliding albums in shuffled descriptor order produce identical placement-id assignments
  (the lexicographic sort tiebreaker is honored),
- multiple existing placements that match the same `(kind, collectionLocalIdentifier, displayPathHash8)` triple →
  resolver picks the most-recently-created and logs a warning rather than crashing,
- placement Codable round-trip: encoding then decoding a `placements` map preserves `id` (read from the dict key on
  decode, omitted from the value on encode) and all other fields exactly.

PhotoLibraryService fakes:

- favorites fetch returns only favorite assets,
- album fetch returns only that album's assets,
- folder tree descriptors preserve nesting,
- duplicate album titles produce distinct descriptors.

Timeline store (`ExportRecordStoreTests`) — existing behavior, unchanged signatures:

- existing test suite passes against the wrapped year/month-shaped read APIs,
- `markVariantInProgress` / `markVariantExported` / `markVariantFailed` / `removeVariant` continue to work via
  the existing `(year, month, relPath)` signatures,
- `bulkImportRecords` (timeline-only) still satisfies timeline completion.

Collection store (`CollectionExportRecordStoreTests`) — placement-keyed:

- placement-scoped `isExported` does not leak across `(favorites, album)` placements,
- failure on placement A does not mutate placement B for the same asset,
- delete on placement A does not affect placement B,
- two albums containing the same asset are independent,
- a `.timeline` placement passed to the collection store trips an assertion in debug; in release the call
  silently drops without touching state.

Cross-store independence (`CrossStoreIndependenceTests`) — full list in *Upgrade Behavior → Tests*. Highlights:

- a write to one store never produces a log line in the other,
- timeline completion does not satisfy any collection placement, and vice versa.

Export manager:

- month export writes timeline placement,
- year export enqueues N month placements and only timeline ids,
- export-all enqueues only timeline placements,
- favorites export writes favorites placement,
- album export writes album placement,
- queued counts are placement-scoped,
- duplicate asset in timeline and album writes two files,
- `Include originals` behavior unchanged for collection placements,
- variant-level clone: timeline has only `.edited` for asset X with `Include originals = false`; album export of
  the same asset with `Include originals = true` clones `.edited` from the timeline file and PhotoKit-fetches
  `.original` separately,
- destination filename mismatch is OK: timeline filename `IMG_0001 (2).HEIC` (collision-suffixed in `2025/02/`)
  cloned to `IMG_0001.HEIC` in `Collections/Albums/Trip/` (no collision there); the destination record stores the
  destination filename,
- on APFS, `FileManager.copyItem` produces a CoW clone (verified via volume free-space delta below ~64 KB for a
  10 MB source file, plus a write-then-divergence behavioral test); on non-APFS, `copyItem` produces a real copy
  with full free-space delta,
- album-first source: an album-then-timeline export of the same asset reuses from the album record (not PhotoKit),
  confirming the source-lookup is "any prior `.done`" not "timeline only,"
- destination out of space during reuse-copy: variant marked `.failed` with the destination error; PhotoKit is
  not invoked,
- source missing during reuse-copy (prior `.done` file deleted by user): falls back to PhotoKit re-export; the
  stale `.done` record is left unchanged,
- store load error → `ExportManager` disables export buttons and surfaces the alert; UI test asserts the buttons
  are actually disabled, not just that the alert appears,
- failure cleanup on album A does not mutate timeline state for the same asset,
- failure marking on favorites does not touch timeline state for the same asset.

Storage, recovery, and cross-store independence — full lists in *Upgrade Behavior → Tests*
(`ExportRecordStoreCorruptionTests`, `CollectionExportRecordStoreTests`, `JSONLRecordFileTests`,
`CrossStoreIndependenceTests`).

### Manual Tests

- Fresh destination, export one timeline month.
- Export Favorites containing an already-exported timeline asset; on APFS, verify the new file is a clone
  (free-space delta below ~64 KB on a 10 MB source); on exFAT, verify a real copy.
- Export an album containing the same asset; verify a copy under `Collections/Albums/<album>/`.
- Restart app; verify all placements show completed independently.
- Rename an album in Photos.app; trigger another export of that album; verify the export writes to the new
  folder under `Collections/Albums/<new-name>/`, the old folder remains untouched on disk, and the sidebar
  shows both as separate rows.
- Create duplicate album titles in different folders; verify folders do not collide on disk and both rows show
  correct counts.
- Upgrade from a pre-collections record store; verify existing timeline progress remains, no re-export is needed,
  and `collection-records.json` is created on first collection export (not before).
- Corruption recovery: manually corrupt `collection-records.json` (truncate to invalid JSON); launch the app;
  verify a per-store alert appears and **the corrupt file is still at `collection-records.json` on disk** (no
  `*.broken-*` exists yet); verify timeline exports remain enabled; quit and relaunch — the same alert appears
  and the file is still in place; choose Reset to empty and verify the corrupt file is renamed to
  `collection-records.json.broken-<ISO8601>` and an empty collection store is initialized; verify timeline state
  is intact throughout.
- Limited Photos access: verify only visible albums/assets appear and copy does not promise full-library collections.
- 100-album fixture: verify sidebar remains responsive while counts load.

## Effort Estimate

Honest sizing. Phase 1 carries the persistence work and the routing diff; Phase 3 carries the user-visible
export work; Phase 4 carries the UI plus the corruption-alert presenter plus docs.

- **Phase 0** (stable destination identity, directory-migration coordinator): ~3–5 days. Includes the centralized
  `ExportRecordsDirectoryCoordinator` that runs the legacy `<oldId>` → `<newId>` rename before either store
  configures.
- **Phase 1** (type/queue plumbing + new collection store, no migration): ~1.5–2 weeks. Extract `JSONLRecordFile`
  from `ExportRecordStore` (one refactor PR), build `CollectionExportRecordStore` against it, thread
  `ExportPlacement` through `ExportJob` and the queue, route every `markVariant*` call site by
  `placement.kind`, add `currentJobPlacement` tracking with reset discipline, add `@Published
  RecordStoreState` and `resetToEmpty()` on each store (no UI yet), wrap existing year/month read APIs so
  timeline call sites don't change.
- **Phase 2** (PhotoKit collection discovery, path policy): ~1 week.
- **Phase 3** (ExportManager collection-aware, count caching, reuse-source copy path): ~1 week. Smaller than the
  prior estimate because the album-rename dialog and `_album.json` sidecar are deferred.
- **Phase 4** (UI + docs): ~1.5–2 weeks. Includes the corruption alert presenter (`RecordStoreAlertHost`),
  flag-flip, and docs in the same PR.

Total: ~5–6 weeks. Phase 1 risk is moderate (placement plumbing across `ExportManager` + new store) but
contained — no migration, no on-disk format change for the timeline store. Phase 4 is the largest user-visible
piece. Per the *Release strategy* note, no App Store release until Phase 4 is ready; phases 1–3 land behind
`enableCollections == false` for internal/dev testers. Time later phases against Phase 1's actuals before
committing to a release date.

## Open Questions

- Should shared albums be included in `Albums` in the MVP, or only regular user-library albums?
- Should collection export support a future metadata manifest so album membership can be reconstructed without
  relying on duplicated folder copies? (Probably yes, but out of scope here.)
