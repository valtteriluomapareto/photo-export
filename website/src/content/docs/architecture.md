---
title: Architecture
description: How Photo Export is built — SwiftUI + Managers pattern.
---

Photo Export follows a small **SwiftUI + Managers** architecture. Views stay relatively thin, stateful workflows live in managers or view models, and the project relies on Apple system frameworks only.

## App entry point

[`photo_exportApp.swift`](https://github.com/valtteriluomapareto/photo-export/blob/main/photo-export/photo_exportApp.swift) creates the shared app state and injects it into the view tree with `@EnvironmentObject`.

## Managers

Most long-lived state lives in manager types under `photo-export/Managers/`.

### PhotoLibraryManager

Handles Photos authorization and asset fetching. Uses `PHCachingImageManager` for thumbnail work.

- Queries assets grouped by year and month
- Provides both thumbnail and full-size image loading
- Manages Photos library authorization flow

### ExportDestinationManager

Manages the chosen export destination folder using security-scoped bookmarks.

- Presents the macOS folder picker
- Persists the selection via security-scoped bookmarks
- Validates folder accessibility on launch

### ExportRecordStore (timeline)

Tracks which assets have been exported per-destination to avoid duplicates and support resume.

- Stores records by `PHAsset.localIdentifier`
- Per-variant state: each record carries a `variants` dictionary keyed by `original` /
  `edited`, so the same asset can track an original export and an edited export
  independently
- Legacy flat records (single `filename` + `status`) decode into a synthesized `.original`
  variant so existing users keep their progress after upgrade
- JSONL-based persistence with compaction
- Reconfigures automatically when the destination changes
- Provides selection-aware month summaries for the thumbnail grid and approximate counts
  for sidebar badges

### CollectionExportRecordStore

Sibling store for collection exports (Favorites + user albums). Lives next to
`ExportRecordStore` on disk under the same per-destination directory but uses its own
files (`collection-records.json` / `collection-records.jsonl`). The two stores never
share a key — a `.timeline` placement is rejected at every collection-store API entry
point — so a corrupt collection store cannot affect timeline progress and vice versa.

- Records are keyed by `(placementId, assetId)`; the placement itself is keyed by
  `kind`/`collectionLocalIdentifier`/`displayPathHash8`, so a renamed or moved album
  resolves to a fresh placement on its next export
- `ExportPlacementResolver` decides the on-disk path under `Collections/Albums/...`,
  including `_2`/`_3` suffix disambiguation when two distinct albums sanitize to the
  same folder name under the same parent
- Same JSONL+snapshot persistence mechanics as the timeline store, including the
  deferred-rename corruption-recovery flow

### ExportManager

Orchestrates the export queue. Depends on the other three managers.

- Enqueue/pause/cancel/resume operations
- Persists the user's version selection (`edited` / `editedWithOriginals`) in
  `UserDefaults` and snapshots it onto each enqueued job
- Sequential export pipeline; each job writes every variant required for the asset under
  the active selection
- `ExportFilenamePolicy` decides the `_orig` companion filename shape; `ResourceSelection`
  picks between original-side and edited-side `PHAssetResource`s
- Atomic writes: per-variant temp file → move to final location, with stale `.tmp`
  cleanup at export start
- Updates per-variant export records after each successful write; a failed edited variant
  does not roll back a completed original variant
- Runs the "Import Existing Backup…" flow
- Awaitable `runExport(context:)` API for AutoSync; an `autoSyncEligibilityCheck`
  closure consulted at enqueue time skips assets whose retry entries are in
  backoff (Auto-Sync runs only)

### AutoSyncManager

Orchestrates Auto Export. Wraps a pure `AutoSyncReducer` with a Combine-based
effect runner so timing-sensitive decisions (debounce, retry backoff, run
dispatch) are testable without wall-clock waits.

- Pure `reduce(event, state, now) -> (state, [effect])` reducer. Tests assert
  effect-list equality without executing them.
- Subscribes to six publishers on `attach(to:)`: destination snapshot,
  scope selection, version selection, import state, export run state,
  PhotoKit persistent changes.
- Sequential per-scope fan-out for the `.autoExport(scopes)` run shape;
  cancellable on disable / destination clear so a long multi-scope chain
  stops at the next await boundary.
- Per-destination persistence under `<App Support>/<bundleId>/AutoSync/`:
  dirty-state JSON, retry-state JSON, last run summary, last durably-
  recorded persistent-change token. Global token at the same parent.
- Read-modify-write paths for retry state use the manager's in-memory
  `@Published currentRetryState` as the source of truth for the currently-
  active destination, so successive mutations (failure recording, manual
  Retry) compose correctly across a multi-scope fan-out.

### PhotoLibraryPersistentChangeAdapter

Adapts PhotoKit's `PHPhotoLibraryChangeObserver` + `fetchPersistentChanges`
into the `Result`-typed event stream AutoSync consumes.

- Establishes a baseline on first launch, then emits one
  `PhotoLibraryPersistentChangeEvent` per `photoLibraryDidChange` callback
  carrying inserted / updated / deleted local identifiers
- Maps the three documented PhotoKit failure modes (token expired, token
  invalid, details unavailable) onto the corresponding
  `PhotoLibraryPersistentChangeFetchError` cases so AutoSync can route each
  to a bounded full-reconciliation fallback
- Subscribes to `PhotoLibraryManager.$authorizationStatus` so the observer
  registers on the first sufficient status, not just at app launch
- Skipped under XCTest / swift-testing so the test process doesn't trip the
  Photos-library permission prompt at DerivedData paths

### DestinationSafetyMonitor

Detects the Phase 0b "non-empty destination with no matching records" state
and surfaces it as `@Published needsSafetyConfirmation`, which
`DestinationSnapshotAdapter` folds into the
`DestinationSnapshot.safety` field as `.unsafeNeedsConfirmation`.

- Closure-based directory scan injection so unit tests can drive the
  monitor without a real `ExportDestinationManager`
- Stale-generation guard discards late-arriving scan results when the user
  has already switched destinations
- Confirmation persists per-destination at
  `AutoSync/destinations/<id>/safetyRecord.json` so previously-confirmed
  destinations never re-prompt

### AppLifecycleCoordinator

Owns destination-change handling and the migration-conflict detection
that surfaces as `.unsafeMigrationConflict`. `gcLegacyState` closure-based
dependency keeps filesystem layout decisions out of the coordinator and
in `PhotoExportApp` where the record-store directory roots are known.

## Supporting Services

- `BackupScanner` scans an existing backup folder and matches files back to Photos assets.
  Its fingerprints split original-side and edited-side resource filenames so each scanned
  file is classified per variant before being merged into the record store.
- `ExportFilenamePolicy` is the shared source of truth for `_orig` companion filename
  rules and used by both the export pipeline and the backup scanner.
- `ResourceSelection` picks the right `PHAssetResource` for a variant and is the shared
  classifier for "original-side" vs "edited-side" resources.
- `FileIOService` centralizes atomic file moves and timestamp handling.

## Views and View Models

The main UI lives under `photo-export/Views/` and `photo-export/ViewModels/`.

| Type                     | Responsibility                                                                                  |
| ------------------------ | ----------------------------------------------------------------------------------------------- |
| `ContentView`            | Top-level router (auth → onboarding → library)                                                  |
| `LibraryRootView`        | `NavigationSplitView` shell with the Timeline / Collections segmented selector                  |
| `TimelineSidebarView`    | Year/month tree                                                                                 |
| `CollectionsSidebarView` | Favorites + user albums and folders, lazy-counted via `cachedCountAssets(in:)`                  |
| `MonthContentView`       | Thumbnail grid for the selected month                                                           |
| `CollectionContentView`  | Thumbnail grid for Favorites or a user album, sharing `MonthViewModel` via a scope-based loader |
| `AssetDetailView`        | Full-size image or video preview                                                                |
| `ExportToolbarView`      | Export destination and queue controls                                                           |
| `RecordStoreAlertHost`   | Surfaces a corruption-recovery alert when either record store transitions to `.failed`          |
| `OnboardingView`         | First-run flow for permissions and destination setup                                            |
| `ImportView`             | Progress and results for importing an existing backup                                           |
| `MonthViewModel`         | Cancellation-aware asset loading for any `PhotoFetchScope` (timeline / favorites / album)       |

## Persistence

The export record store keeps per-destination state under Application Support. A detailed format description lives in [`persistence-store.md`](https://github.com/valtteriluomapareto/photo-export/blob/main/docs/reference/persistence-store.md).

## Design choices worth knowing

- **Logging:** `os.Logger` with subsystem `com.valtteriluoma.photo-export` — visible in Console.app for diagnostics.
- **Concurrency:** UI-facing managers run on the main actor. Export is sequential rather than parallel, by design.
- **Asset identity:** Tracked by `PHAsset.localIdentifier`. Existing files in the destination are never overwritten — re-running an export resumes where it left off.

Contributor-facing conventions (linting rules, formatting, the SwiftUI + Managers code style) live in the [contributor guide](https://github.com/valtteriluomapareto/photo-export/blob/main/CONTRIBUTING.md) and [`AGENTS.md`](https://github.com/valtteriluomapareto/photo-export/blob/main/AGENTS.md).
