# UI Smoothness and Observation Modernization Plan

Status: active roadmap, revised May 2026.

This plan merges the previous UI smoothness and SwiftUI Observation migration
plans into one implementation order. The standalone Observation plan is archived
as a decision record at
[`../archive/observable-migration-plan.md`](../archive/observable-migration-plan.md).
The Auto Export memory-watermark plan is also archived; its issue #112 fixes are
already implemented and the remaining performance follow-up is covered here.

## Goal

Keep the app responsive during launch, navigation, scrolling, library-change
bursts, and export runs on large Photos libraries. The preferred modern Swift
direction is SwiftUI Observation (`@Observable`) for UI-facing state, because the
app targets macOS 15 and benefits from per-property dependency tracking.

This plan is about responsiveness and state observation. It does not cover export
throughput, parallel export execution, storage-format replacement, or new product
features.

## Direction

- Use `@Observable @MainActor final class` as the default for SwiftUI-facing
  mutable state.
- Keep `ObservableObject` + `@Published` only where an existing Combine contract
  needs it, especially the AutoSync seam.
- Keep `actor` for real concurrent state holders, such as `CollectionCountCache`.
- Keep pure helpers as plain `struct` or `enum`; do not add `@MainActor`
  reflexively.
- Preserve the contracts in
  [`../../reference/architecture-conventions.md`](../../reference/architecture-conventions.md):
  generation-based cancellation, actor-isolation policy, and synchronous
  AutoSync mirror behavior.

## Relationship to Archived Plans

The previous UI smoothness plan treated `ObservableObject` as fixed and tried to
compensate with broad coalescing and manual observable partitioning. Observation
changes that tradeoff:

| Previous task | New status |
| --- | --- |
| Broad mutation coalescing | Defer until measured. Use only for hot properties whose direct readers still drop frames. |
| Decoded thumbnail cache | Keep. Orthogonal to Observation. |
| Cell-scoped thumbnail cancellation | Keep. Orthogonal to Observation. |
| Manual partition of `ExportManager` / `PhotoLibraryManager` | Delete as a primary task. `@Observable` is the modern partitioning mechanism. |
| Progressive `PHFetchResult` enumeration | Keep. Orthogonal to Observation. |
| Off-main `JSONLRecordFile.load()` | Keep. Orthogonal to Observation. |
| Record-store core/facade split | Reframe as an IO/main-thread refactor only, not as a workaround for broad `@Published` invalidation. |
| Lazy sidebar evaluation | Keep if measurement shows `libraryRevision` bursts remain costly. |

The memory-watermark fix for Auto Export should not be reimplemented from its
old plan. The current code already drops `phAssetCache` inside
`ExportManager.runBulkEnqueueLoop`, avoids refilling that cache from
`cachedOrFetchPHAsset`, uses index-based `autoreleasepool` loops for album and
favorites fetches, and lowers the timeline fetch batch size to 100. The follow-up
left to this plan is the broader PhotoKit fetch smoothness work, not the issue
#112 memory fix itself.

## Phase 0 - Measurement and Fixtures — landed

Land this before invasive refactors.

1. ✅ `BulkLibraryFixture` (`photo-exportTests/TestHelpers/BulkLibraryFixture.swift`)
   synthesizes 10k–100k-asset libraries with optional large-month piles and
   album/folder trees.
2. ✅ `ObservationCounter` (`photo-exportTests/TestHelpers/ObservationCounter.swift`)
   wraps `withObservationTracking` with a timeout and re-registration. For
   the upcoming Phase 2 work.
3. ✅ `BodyInvalidationCounter` (`photo-export/App/BodyInvalidationCounter.swift`,
   `#if DEBUG`) + `.measureBodyInvalidations("…")` wired into
   `MonthContentView`, `CollectionContentView`, `TimelineSidebarView`,
   `CollectionsSidebarView`.
4. ✅ `AppDiagnostics` (`photo-export/App/AppDiagnostics.swift`) for the
   `AppLaunch` interval and `SelectionChanged` event; `Export.Run` interval
   on `ExportQueueCoordinator.isRunning`. Scroll-session signposts deferred —
   SwiftUI on macOS has no clean per-scroll hook; use Instruments' Core
   Animation track.
5. ✅ Reproduction scenario captured in the section below.

The goal of Phase 0 was not perfect profiling. It was enough repeatable
evidence to decide which later work actually moves the app.

### Reproducing the baseline trace

Phase 0 wires three signposters (all under subsystem
`com.valtteriluoma.photo-export`):

| Category                            | Owner                                                  | Records                              |
| ----------------------------------- | ------------------------------------------------------ | ------------------------------------ |
| `AppLifecycle`                      | `App/AppDiagnostics.swift`                             | `AppLaunch` interval, `SelectionChanged` event |
| `Export.Run`                        | `Export/ExportQueueCoordinator.swift`                  | `ExportRun` interval                 |
| `PhotoLibraryChanges.CatchUp`       | `PhotoLibrary/PhotoLibraryPersistentChangeAdapter.swift` | `CatchUp`, `FetchPersistentChanges`, `EnumerateChanges` intervals |

`BodyInvalidationCounter` (`App/BodyInvalidationCounter.swift`, `#if DEBUG`)
counts SwiftUI body re-evaluations for the four wired views:
`MonthContentView`, `CollectionContentView`, `TimelineSidebarView`,
`CollectionsSidebarView`. Read from a debug REPL with
`po BodyInvalidationCounter.shared.snapshot()`.

To capture a run: cold-start the app → select a ~10k-asset month → trigger
"Export Month" (or stop after ~200 jobs) → record the `AppLaunch` duration,
the `ExportRun` duration, and a body-counter snapshot. Scroll sessions have
no clean SwiftUI lifecycle hook on macOS — use Instruments' Core Animation
track instead.

## Phase 1 - Observation-Independent Smoothness Wins — landed

These tasks can land before the Observation migration. They reduce real work on
the main thread or bound PhotoKit request lifetimes. All seven sub-items are
resolved as of May 2026: 1.1–1.4 shipped as planned, 1.5 was reframed by
measurement (the JSONL reader, not off-main load), and 1.6 / 1.7 were
confirmed not needed by the same measurement plus the new regression tests.

### 1. Stable Grid Identity — already implemented

`AssetDescriptor` is `Identifiable` with `let id: String`, so the existing
`ForEach(viewModel.assets)` calls in `MonthContentView` and
`CollectionContentView` already key on `\.id`. No change is needed before
progressive-fetch work lands; an explicit `id: \.id` would be a textual
no-op.

### 2. Decoded Thumbnail Cache — landed

`DecodedThumbnailCache` (`photo-export/PhotoLibrary/DecodedThumbnailCache.swift`)
owns CGImage storage keyed by `(assetId, quantizedSize, deliveryMode)`,
backed by `NSCache` with `totalCostLimit = 64 MB` + `countLimit = 512`.
Concurrent requests for the same key share one decode, ref-counted so the
shared decode is cancelled only when every waiter has cancelled. `clear()`
discards stored entries and stamps a generation so in-flight decodes that
were started before the call don't land in the cleared cache.

`PhotoLibraryManager` configures the cache's decode closure to extract a
`CGImage` from PhotoKit's NSImage via
`cgImage(forProposedRect:context:hints:)`. `invalidateCache()` clears the
cache alongside `phAssetCache` and the count cache. The cell renders
through `Image(nsImage: NSImage(cgImage:size:))`. `MonthViewModel`'s
`thumbnailsById` dict is gone — replaced by `DecodedThumbnailCache` as the
single source of truth.

Coverage: `photo-exportTests/DecodedThumbnailCacheTests.swift` — concurrent
dedup with identity check, fast/HQ separation, clear-mid-flight, count-limit
eviction, quantization, cancel-only-waiter-cancels-decode,
cancel-one-of-two-waiters-survives.

### 3. Cell-Scoped Thumbnail Cancellation — landed

`PhotoLibraryManager.decodeThumbnail` (and the legacy
`loadThumbnail`/`loadThumbnailHighQuality`) wrap PhotoKit's `requestImage`
with `withTaskCancellationHandler`. The onCancel branch calls
`PHCachingImageManager.cancelImageRequest` with the id captured in an
inline `OSAllocatedUnfairLock<PHImageRequestID?>`. Pre-cancel and post-set
re-checks around the request keep the cancellation race tight.

`ThumbnailView` (`photo-export/Views/Shared/ThumbnailView.swift`) owns its
own `@State` and drives loading via `.task(id: "\(asset.id)#\(retry)")`.
Render order: cached HQ → cached fast → async fast → 150 ms linger →
async HQ. The linger keeps flick-scrolls from firing HQ at all; `failed`
is only set after both legs return nil, so a fresh iCloud asset where fast
3303s but HQ rescues doesn't flash a Retry tile.

`MonthViewModel` (`photo-export/ViewModels/MonthViewModel.swift`) loses
`loadedThumbnailIds`, `failedThumbnailIds`, `highQualityIds`,
`hqUpgradeTask`, `loadAndStoreThumbnail`, `upgradeThumbnailToHighQuality`,
`thumbnailState(for:)`, and `retryThumbnail(for:)`. It keeps the asset
list, the windowed `PHCachingImageManager` preheat lifecycle (issue #109),
and the refresh scope-race guard.

`PhotoLibraryService` API surface is unchanged; `PHImageRequestID` never
crosses the protocol boundary.

### 4. Progressive PhotoKit Fetch Enumeration — landed

`PhotoLibraryService` grows `fetchAssetsProgressive(in:mediaType:batchSize:)`
returning `AsyncThrowingStream<[AssetDescriptor], any Error>`.

`PhotoLibraryManager`'s implementation runs the `PHFetchResult` build and
the stride-based enumeration on a `Task.detached(priority: .userInitiated)`,
so a 37k-asset materialisation no longer blocks the main actor. Each
batch's `PHAsset` array is cached on the main actor in the same hop that
maps it to `[AssetDescriptor]`. Default batch size is 200; `onTermination`
cancels the producer task. Auth-denied or unknown-album fall-throughs
throw or finish cleanly.

`MonthViewModel.loadAssets(for:)` consumes the stream and appends batches
to `@Published assets` as they arrive — the grid renders the first 200
tiles as soon as PhotoKit yields them, instead of waiting for the entire
scope. `isLoading = false` and `selectedAssetId` fire after the first
batch. The windowed `PHCachingImageManager` preheat snapshot (issue #109,
500-asset cap) runs once at end of stream. A `streamTask` reference is
cancelled on scope change so mid-stream batches from the prior scope
cannot bleed into the new one.

`MonthViewModel.refresh(for:)` streams too, but collects into a local
array and commits assets + the windowed cache delta atomically at end —
preserves the in-place refresh contract (no partial-state flashes).

The grid's `.onChange(of: libraryRevision)` → in-place refresh wiring is
unchanged; `.task(id: libraryRevision)` is still avoided.

Coverage: `MonthViewModelTests` gains
`loadAssetsDiscardsLateBatchesAfterScopeSwitch` (uses
`FakePhotoLibraryService.progressiveCheckpointByScopeKey` to gate batches
and observe mid-stream scope changes) and
`refreshCommitsCollectedAssetsAtomically`.

### 5. JSONL Reader — landed (was: Off-Main Record Store Load)

Cold-start measurement on a 184 KB JSONL log showed `configure(for:)` taking
273 ms. The cost wasn't snapshot decode, replay, or counter rebuild — it was
byte-at-a-time `FileHandle.read(upToCount: 1)` in `JSONLRecordFile.swift`'s
line reader (~190k syscalls for the file). One `Data(contentsOf:)` +
`split(separator: 0x0A)` brings the same `configure(for:)` to 13 ms;
`AppLaunch` overall dropped from 507 ms to 239 ms.

`RecordStore.Configure` interval signposts were added in
`App/AppDiagnostics.swift` so launch and destination-switch cost can be
read straight off `log show --signpost` instead of a Time Profiler trace.

The "off-main load" framing this section originally proposed was based
on the wrong bottleneck hypothesis. Off-main scaffolding (`.loading`
state, async configure, mutation-during-loading assertion, the
test-site migration) is deferred — no measured need.

### 6. Debounce `libraryRevision` Bursts — not needed today

Phase 0's `PhotoLibraryChanges.CatchUp` signposts on a cold-start trace
showed PhotoKit already coalesces changes at the observer-callback level:
one `photoLibraryDidChange(_:)` per batched library change, one
downstream `invalidateCache()`, one `libraryRevision` bump. The
50-bump-in-tight-loop scenario the plan worried about does not reflect
real PhotoKit behaviour, so source-side debouncing would solve a
problem that does not exist.

Revisit if a real-world burst pattern surfaces — likely via a future
`PhotoLibraryChanges.CatchUp` trace showing multiple `CatchUp` intervals
within a 250 ms window during a user-visible UI hitch.

### 7. Stale-Frame Sweep on Scope Switch — moot, pinned by test

Confirmed moot at the view-model level by
`loadAssetsClearsAssetsBeforeFirstBatch`
(`photo-exportTests/MonthViewModelTests.swift`): the synchronous prefix of
`MonthViewModel.loadAssets(for:)` blanks `assets` and `selectedAssetId`
before the first await against the progressive stream, so a SwiftUI body
re-evaluation in the click-frame window cannot find the previous scope's
covers attached to the new scope's selection. 1.2's removal of
`thumbnailsById` and 1.3's cell-scoped thumbnail cancellation close the
secondary late-write race the plan also worried about.

If a visual flash ever reproduces in a real-app trace, `.id(scope)` on
the grid container remains the cheap escape hatch — but the view-model
invariant is now a pinned regression gate, so any future change that
moves `assets = []` past an await would surface immediately.

## Phase 2 - Observation Migration

Observation is the main modern Swift direction for UI state in this app. Migrate
from low-risk leaves toward high-risk seams.

### 2.0 Pilot and Recipe — landed

`WhatsNewState` migrated as the leaf pilot — no Combine consumers, no
AutoSync contract, no `$publisher` projections. The migration applied:

- Class is `@Observable @MainActor final class` (drops `ObservableObject`
  and `@Published`).
- App-entry storage flipped from `@StateObject` to `@State`.
- Injection flipped from `.environmentObject(...)` to `.environment(...)`.
- `LibraryRootView` consumer flipped from `@EnvironmentObject` to
  `@Environment(WhatsNewState.self)`.
- `WhatsNewView` swapped `@ObservedObject var state` to plain
  `let state` — no `$`-projected bindings, so no `@Bindable` needed.

Recipe lives at
[`../../reference/observation-migration-recipe.md`](../../reference/observation-migration-recipe.md);
the pre-migration grep checklist there is the load-bearing tool for
picking which type goes next.

### 2.1 AutoSync Bridge Spike

Before migrating `ExportManager`, prove the Combine bridge works.

AutoSync currently depends on a synchronous Combine publisher composed from
`activeRunContext`, `isRunning`, `queueCount`, and `isEnqueueingAll`. Plain
`@Observable` does not provide `$property` publishers, and
`withObservationTracking` is one-shot, so the bridge must be explicit.

Recommended bridge for Combine-observed properties:

```swift
var isRunning: Bool = false {
    didSet {
        guard isRunning != oldValue else { return }
        isRunningSubject.send(isRunning)
    }
}

private let isRunningSubject = CurrentValueSubject<Bool, Never>(false)
```

Rules:

- The `oldValue` guard is load-bearing.
- Do not add `.receive(on:)`, `MainActor.run`, or async hops.
- Preserve emission order and `removeDuplicates` behavior.
- Keep `ExportManager+AutoSyncConformance.swift` as conformance-only.
- Add or update a characterization test for the seven-step manual/bulk/AutoSync
  emission sequence before changing production code.

If the bridge spike fails, keep `ExportManager` as `ObservableObject` and migrate
the rest of the UI-facing state. That is an acceptable final architecture.

### 2.2 Self-Contained Leaves

Candidates:

- `LoginItemController`
- `AppLifecycleCoordinator`
- `ExportDestinationManager`
- `DestinationSafetyMonitor`, after verifying its Combine pipeline is not a
  load-bearing AutoSync-style seam

For each type:

1. Grep for `$property`, `.sink`, and `objectWillChange`.
2. Migrate to `@Observable` only if no Combine consumer needs a bridge.
3. Update environment injection and bindings.
4. Run the focused tests and build.

### 2.3 UI-Local State

Candidates:

- `ExportProgressState`
- `MonthViewModel`, preferably as part of the thumbnail-cache work that removes
  `thumbnailsById`

Goal:

- Per-asset progress changes should invalidate only progress UI and the affected
  row, not broad view trees.
- Month/collection grids should observe the view model directly through
  Observation once thumbnail storage is thinned.

### 2.4 Record Stores

Candidates:

- `ExportRecordStore`
- `CollectionExportRecordStore`

Important limitation:

- Observation tracks dictionary properties as properties, not individual keys.
  A reader of `monthCounters[MonthKey(...)]` still depends on the dictionary as a
  whole unless lower-level registrar work is added. Accept dictionary-level
  granularity for v1; measure before adding per-key registrar plumbing.

After migrating the stores, re-evaluate any coalescing work. A broad coalescer is
probably unnecessary unless a direct reader of a hot property still drops frames.

### 2.5 PhotoLibraryManager

Migrate `authorizationStatus`, `isAuthorized`, and `libraryRevision` after
verifying there are no Combine consumers of those properties.

`libraryRevision` remains a broad semantic signal even under Observation. If
PhotoKit change bursts are still expensive, keep the Phase 1 debounce task.

### 2.6 ExportManager - Optional

`ExportManager` is the highest-risk migration because it owns the AutoSync seam.
Do this only after:

- The bridge spike passes.
- Phases 2.0 through 2.5 have landed.
- Measurement shows `ExportManager`'s coarse `ObservableObject` invalidation is
  still a meaningful part of remaining churn.

If the remaining churn is small, leave `ExportManager` as `ObservableObject` and
document that Combine/AutoSync compatibility is the reason.

## Phase 3 - Measured Fallback Refactors

Do not start these until Phase 0 measurements and Phase 1/2 results show they
are still needed.

### Targeted Mutation Coalescing

Use coalescing only for hot properties whose direct readers cannot keep up, for
example a per-asset progress filename or a mutation counter used in a hot view.

Rules:

- Keep state mutation synchronous; only rate-limit notification/render pressure.
- Expose `flushPending()` for cancellation, pause, resume, and terminal states.
- Use an injectable frame/timer provider for deterministic tests.
- Avoid relying on `MainActor.assumeIsolated` from display-link callbacks.

### Record Store Core Split

If launch/load or per-record mutation work still blocks the main actor after the
off-main load and Observation work, design a separate record-store core.

Rules:

- Keep a main-actor snapshot/facade that answers every synchronous SwiftUI body
  read.
- Move IO and heavy rebuilds off-main.
- Keep generation-based cancellation on `ExportQueueCoordinator`; do not move the
  cancellation seam into the record-store core.
- Draft a separate design doc before implementing.

## Regression Gates

Every implementation PR should add at least one regression test for the property
it improves.

Required gates:

- Thumbnail cache deduplicates concurrent identical requests.
- Thumbnail cancellation cancels or suppresses underlying PhotoKit work.
- Progressive fetch does not apply stale batches after scope changes.
- Record-store `.loading` transitions to `.ready` or `.failed` correctly.
- AutoSync publisher characterization stays unchanged before and after any bridge
  work.
- Existing cancellation seam tests continue to pass after every phase.

## Open Questions

- Whether the in-memory thumbnail cache is enough, or an on-disk cache is needed.
  Decide only after profiling the in-memory cache.
- Whether `ExportProgressState` should remain separate after Observation. Measure
  first; folding it back into `ExportManager` may be reasonable later.
- Whether record-store per-key Observation is worth the complexity. Dictionary
  granularity is the v1 assumption.
- Whether `libraryRevision` debounce should be 100 ms, 250 ms, or UI-side only.
  Confirm AutoSync coupling before source-debouncing.
