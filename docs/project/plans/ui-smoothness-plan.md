# UI Smoothness Improvement Plan

Goal: reduce main-thread stalls and SwiftUI re-render churn so the app stays at 60 fps during launch, scroll, library changes, and active export runs — especially with large libraries (≥100k assets) and active iCloud sync.

This plan is scoped to **UI smoothness only**. Export throughput, parallelization, and feature work are out of scope. Cross-cutting contracts (cancellation seam, actor isolation policy, AutoSync seam) from [`docs/reference/architecture-conventions.md`](../../reference/architecture-conventions.md) must be preserved by every task below.

---

## Background — What Currently Hurts Smoothness

From the threading audit on this branch, the dominant sources of UI stalls are:

1. **High-frequency `@Published` mutations during export runs.** Only `mutationCounter` is debounced; underlying `state` and per-month counters fire `objectWillChange` on every record append, invalidating every observing view.
2. **Image decode on draw.** `PHCachingImageManager` caches encoded bytes; SwiftUI `Image(nsImage:)` decodes on render. Fast grid scroll → repeated main-thread decodes → stutter.
3. **No cell-scoped cancellation for thumbnail requests.** A fast scroll queues thousands of in-flight `PHCachingImageManager` requests that all settle when scrolling stops.
4. **Broad observation surfaces.** `ExportManager` and `PhotoLibraryManager` publish ~10 properties each; any view holding them as `@EnvironmentObject` re-evaluates on any one property changing.
5. **Synchronous main-thread enumeration.** Ordered `PHFetchResult.enumerateObjects` for favorites/album/year fetches runs on `@MainActor` and only commits to the grid when complete.
6. **Main-thread JSON decode at launch.** `JSONLRecordFile.load()` decodes potentially 100+ MB on main; `monthCounters` rebuild is O(records) on main.
7. **Coarse `libraryRevision` cascade.** A burst of iCloud sync events bumps `libraryRevision` repeatedly; observing views re-fetch each time.

Tasks below are ordered by impact ÷ effort.

---

## Tier 1 — Quick Wins (Days, Not Weeks)

### Task 1.1 — Coalesce `@Published` mutations during active runs

**What:** Replace point-debouncing (`mutationCounter` + `asyncAfter(+0.2)`) with a single per-frame drain that batches all record-store mutations. Aim for ≤60 publication events per second per store regardless of append rate.

**Where:**

- `photo-export/Records/ExportRecordStore.swift` — the `objectWillChange` / mutation surface around `recordsById` and `monthCounters` updates
- `photo-export/Records/CollectionExportRecordStore.swift` — same pattern, `placements` / `recordBodies`
- `photo-export/Export/ExportManager.swift` — audit every `@Published` property; debounce or remove any that fires per-job

**Approach:**

1. Introduce a `MainActorCoalescer` helper that schedules `objectWillChange.send()` at most once per frame (use `DispatchSourceTimer` at 16 ms, or a `Task { try await Task.sleep(...) }` rate limiter).
2. Route per-append mutations through the coalescer instead of mutating `@Published` directly.
3. Keep an "immediately publish" escape hatch for state transitions that must reach the UI synchronously (e.g. `isRunning` toggles, completion, failure) — these are rare and load-bearing.

**Definition of done:**

- During a 5,000-asset export, the SwiftUI invalidation count for the year/month sidebar is bounded by `runDurationSeconds × 60`, not by `assetCount`.
- No regressions in `ExportRecordStoreTests` or `CollectionExportRecordStoreTests`.
- The cancellation seam contract is unaffected (mutations still apply synchronously to in-memory state; only `objectWillChange` is debounced).

**Risk:** Tests that read `@Published` immediately after a mutation may now see the new value before SwiftUI has been notified. That's correct behavior, but any test relying on `objectWillChange` ordering needs updating.

---

### Task 1.2 — Off-main thumbnail decode + decoded image cache

**What:** Decode thumbnails to `CGImage` on a utility task and cache the decoded result in an LRU. Cells render `Image(decorative:scale:orientation:)` from the cached `CGImage`, never `Image(nsImage:)` from raw bytes.

**Where:**

- `photo-export/PhotoLibrary/PhotoLibraryManager.swift` — thumbnail request path around L538/L580
- `photo-export/Views/Shared/ThumbnailView.swift` (or wherever the cell renders)
- New file: `photo-export/PhotoLibrary/DecodedThumbnailCache.swift` (`actor` if cross-thread reads exist; otherwise `@MainActor` with explicit off-main fill)

**Approach:**

1. New `DecodedThumbnailCache` keyed by `(localIdentifier, targetSize, contentMode)`, backed by `NSCache` (built-in size-based eviction + memory-pressure handling).
2. Thumbnail request flow becomes: check decoded cache → on miss, `PHCachingImageManager.requestImage` → off-main `CGImage` decode → insert into cache → publish to cell.
3. Memory budget: cap at ~100 MB or 500 entries, whichever first. `NSCache.totalCostLimit` does this.
4. Invalidation: clear on `libraryRevision` bump for *changed* asset IDs only (requires reading `PHChange.changeDetails(for:)` instead of nuking everything — keep this minimal in v1; in v1 it's acceptable to invalidate the whole cache on library change).

**Definition of done:**

- Grid scroll at 1000 px/s shows no decode-related stutter on a profile of a typical Photos library.
- Memory does not grow unbounded on long scrolls.
- The cache survives `libraryRevision` bumps without showing stale thumbnails for changed assets.

**Risk:** `NSCache` eviction is opaque; if it evicts too aggressively the cache becomes useless. Profile under memory pressure before shipping.

---

### Task 1.3 — Cell-scoped thumbnail request cancellation

**What:** Tie each thumbnail request to its cell's lifecycle. When a cell scrolls off-screen, cancel its in-flight `PHCachingImageManager` request.

**Where:**

- `photo-export/Views/Shared/ThumbnailView.swift` (or equivalent)
- `photo-export/PhotoLibrary/PhotoLibraryManager.swift` — expose `cancelThumbnailRequest(id: PHImageRequestID)` if not already

**Approach:**

1. Use `.task(id: asset.localIdentifier)` on the cell so the request is cancelled by Swift Concurrency when the cell is reused.
2. Inside the task, store the `PHImageRequestID` returned by `requestImage` and call `PHImageManager.default().cancelImageRequest(id)` in the cancellation handler (via `withTaskCancellationHandler`).
3. Drive `startCachingImages` / `stopCachingImages` from visible-row range (the grid's `onAppear` / `onDisappear` on cells, batched).

**Definition of done:**

- A fast flick-scroll over 5,000 cells leaves ≤ visible-count + prefetch-window in-flight requests at any time.
- Cancellation is visible in the PhotoKit signpost log (signposts emitted by `PHImageManager`).

**Risk:** Aggressive cancellation can cause flicker if a cell is cancelled and immediately re-requested (scroll bounce). Add a small grace period (e.g. 50 ms) before cancelling.

---

## Tier 2 — Structural Smoothness

### Task 2.1 — Partition observation surfaces

**What:** Split the two largest `ObservableObject`s into smaller focused observables so views subscribe only to the slice they read.

**Where:**

- `photo-export/Export/ExportManager.swift` — currently publishes `isRunning`, `isPaused`, `queueCount`, `versionSelection`, `convertHEICToJPEG`, `livePhotosPairedExport`, `videoLayout`, `activeRunContext`, plus run publishers
- `photo-export/PhotoLibrary/PhotoLibraryManager.swift` — publishes `authorizationStatus`, `isAuthorized`, `libraryRevision`

**Approach:**

1. Carve `ExportManager` into:
   - `ExportRunState` — `isRunning`, `isPaused`, `queueCount`, `activeRunContext`
   - `ExportSettings` — `versionSelection`, `convertHEICToJPEG`, `livePhotosPairedExport`, `videoLayout`
   - `ExportManager` itself keeps the façade API and forwards reads/writes to the right child
2. Inject the children as separate `@EnvironmentObject`s. The toolbar reads settings + run state; the sidebar reads only library state.
3. Same exercise for `PhotoLibraryManager`: pull `libraryRevision` into a tiny `LibraryRevisionPublisher` since it's the most-observed signal.

**Definition of done:**

- A view that only reads `versionSelection` does not re-evaluate when `queueCount` changes.
- AutoSync seam is preserved — `ExportManager+AutoSyncConformance.swift` continues to expose the same façade-level publishers.
- No regression in any UI test.

**Risk:** This is the most invasive Tier 2 task. Touches every view that injects these managers. Roll out incrementally: split one property at a time, behind no flag, and let SwiftUI re-evaluation telemetry confirm the win after each move.

---

### Task 2.2 — Progressive `PHFetchResult` enumeration

**What:** Replace synchronous "enumerate then commit" with "batch-enumerate off-main, commit each batch as it arrives."

**Where:**

- `photo-export/PhotoLibrary/PhotoLibraryManager.swift` — `fetchPHAssets`, `fetchFavoritesPHAssets`, `fetchAlbumPHAssets`, `availableYearsWithCounts`
- `photo-export/ViewModels/MonthViewModel.swift` — receiver side; needs to handle progressive append without grid flicker

**Approach:**

1. Wrap `enumerateObjects(_:)` in an `AsyncStream<[AssetDescriptor]>` that yields batches of 200.
2. The producer runs on a `Task.detached(priority: .userInitiated)`; consumer is `@MainActor` and appends to `MonthViewModel.assets`.
3. The grid's `ForEach` already keys on stable IDs (`PHAsset.localIdentifier`), so appending is diff-friendly. Validate that incremental append doesn't trigger full grid rebuild.
4. Preserve the cancellation contract — if the user's selection changes mid-stream, the producer task is cancelled and the consumer drops queued batches.

**Definition of done:**

- First batch visible in <50 ms after selecting a year/album/favorites scope.
- A 50k-asset month/album shows its first 200 cells immediately and fills progressively without main-thread stalls.
- The existing `MonthViewModel` cancellation contract still holds (see [`docs/reference/architecture-conventions.md`](../../reference/architecture-conventions.md) §Cancellation contract).

**Risk:** Progressive append can cause layout reflow that looks worse than a single-shot commit on small fetches. Gate progressive mode by fetch size (`if estimatedCount > 500`, use streaming; else single commit).

---

### Task 2.3 — Move `JSONLRecordFile.load()` decode off main

**What:** Decode snapshot JSON and rebuild `monthCounters` on the per-store `ioQueue`, then atomic-swap on main.

**Where:**

- `photo-export/Records/JSONLRecordFile.swift` — `load()` ~L100
- `photo-export/Records/ExportRecordStore.swift` — `monthCounters` rebuild ~L840
- `photo-export/Records/CollectionExportRecordStore.swift` — equivalent rebuild

**Approach:**

1. Make `load()` `async`. Internally dispatch the decode to `ioQueue` and `await` its result.
2. Rebuild derived state (`monthCounters`, placements index) on the same off-main hop.
3. Publish the final value to `@Published state` in a single main-actor assignment.
4. Add a launch-time progress indicator (already partly present via `RecordStoreState.loading`); ensure it remains visible until the off-main work is done so the UI shows "loading" instead of an empty sidebar.

**Definition of done:**

- App launch with a 500k-record store shows the loading state immediately and never blocks the main thread for >16 ms on a single tick.
- `RecordStoreState.failed` recovery alert still surfaces correctly (covered by `RecordStoreAlertHost`).
- All `ExportRecordStore` recovery tests pass.

**Risk:** Any caller that today assumed `load()` was synchronous breaks. Search for `store.load(` and `store.configure(` callers; they should already be in `Task { @MainActor in … }` contexts but verify.

---

## Tier 3 — Bigger Refactors (Weeks)

### Task 3.1 — Split authoritative record-store state from observable façade

**What:** A `nonisolated` (or `actor`-backed) store owns the records; a thin `@MainActor` façade publishes only what views read. Generalization of 2.3.

**Why hold this in Tier 3:** Pays off most when Tasks 1.1 + 2.1 + 2.3 are already in. Doing it earlier is premature and AGENTS.md explicitly defends the current shape ("forcing every callsite into `await` for state that is already main-bound, with no thread-safety gain"). The façade pattern is the answer to that critique — common reads stay sync on main from a published snapshot; only bulk writes cross the actor boundary.

**Where:** `photo-export/Records/` — affects both stores plus `JSONLRecordFile` and the `RecordStoreRouter`.

**Approach:** Design a `RecordStoreCore` (off-main, owns records + IO) and a `RecordStoreFacade` (`@MainActor ObservableObject`, owns the published snapshot). Mutations go through the core; the core posts diffs back to the façade via a coalescer (Task 1.1).

**Definition of done:** Drafted in a follow-up issue with its own design doc before any code is written.

**Risk:** Largest refactor in this plan. Don't start until Tier 1 + 2 measurements confirm the remaining stalls are dominated by main-thread store work.

---

### Task 3.2 — Lazy sidebar evaluation

**What:** `TimelineSidebarView` and `CollectionsSidebarView` defer count fetches for collapsed nodes; a burst of `libraryRevision` bumps is coalesced into a single refetch.

**Where:** `photo-export/Views/Timeline/TimelineSidebarView.swift`, `photo-export/Views/Collections/CollectionsSidebarView.swift`, `photo-export/PhotoLibrary/CollectionCountCache.swift`

**Approach:**

1. Today's `.task(id: libraryRevision)` on each count row fires on every library mutation. Replace with `.task(id: libraryRevision)` that itself debounces (e.g. 250 ms) before re-fetching.
2. Only expanded year/album nodes start fetches. Collapsed nodes show a cached count or a placeholder.
3. `CollectionCountCache` already dedups; add a TTL so a rapidly-changing library doesn't refetch every entry on every event.

**Definition of done:** During a heavy iCloud sync (hundreds of `photoLibraryDidChange` callbacks per minute), sidebar count refetches are bounded to ≤4/sec.

**Risk:** Debouncing count refresh means the sidebar lags slightly during active sync. Acceptable for smoothness; flag in the UX review.

---

## Cross-Cutting — Audit Items

These don't have a single "task" but should be checked as part of any UI work:

- **Stable `ForEach` IDs.** Confirm every `ForEach` row key is a stable value-type ID (`PHAsset.localIdentifier`, `ExportRecord.id`, etc.). Any concatenated-string or hash-based ID is a smoothness hazard.
- **Animation discipline during runs.** Audit `withAnimation` and `.animation(...)` usages. Any animation that fires per-record during export should be removed or gated by a "reduce motion during runs" check.
- **`@EnvironmentObject` discipline.** A view that only reads one property from an environment object still invalidates on any change. After Task 2.1, audit views to reduce their injected surface.
- **No `.receive(on:)` on AutoSync mirrors.** Reaffirmed by [`docs/reference/architecture-conventions.md`](../../reference/architecture-conventions.md) §AutoSync seam — keep mirrors synchronous `.sink`. Any task in this plan that adds a Combine pipeline must verify it doesn't break this.

---

## Rollout & Measurement

Each tier should land independently with measurements before moving to the next.

**Measurement harness (to be built once, used for every task):**

1. SwiftUI invalidation counter — wrap target views in a `.onChange` counter or use a debug `_printChanges()` overlay during dev.
2. `os_signpost` around: app launch, year/album selection commit, scroll session, export run start/end.
3. A scripted "smoothness scenario" run in `photo-exportUITests/` — launch, select a 10k-asset month, scroll to bottom, start an export of 200 assets, observe. Captures signpost durations and asserts upper bounds.

**Sequencing recommendation:**

1. Build the measurement harness.
2. Land Task 1.1 (coalescing). Re-measure.
3. Land Tasks 1.2 and 1.3 (thumbnail decode + cancellation). Re-measure.
4. Land Task 2.1 (observation surfaces) one property at a time. Re-measure after each.
5. Land Task 2.2 (progressive fetch). Re-measure.
6. Land Task 2.3 (off-main load). Re-measure.
7. Re-evaluate whether Tier 3 is needed based on remaining stall sources.

---

## Out of Scope

Reaffirming what this plan does **not** cover:

- Parallel export throughput (separate plan; would increase mutation rate and depends on Task 1.1 landing first).
- Storage format changes (SQLite, binary records). The JSONL format is fine; the bottleneck is decode-on-main, addressed by 2.3 / 3.1.
- Replacing the cancellation seam with `Task.checkCancellation`. The generation-based seam is load-bearing.
- Adding `.receive(on:)` to AutoSync mirrors. Explicitly forbidden.
- Making every collaborator an `actor`. AGENTS.md correctly rejects this; the façade pattern in Task 3.1 is the right answer instead.

---

## Open Questions

- Is the existing `_printChanges()`-based invalidation telemetry sufficient, or do we need a structured logger?
- For Task 1.2, do we need an on-disk thumbnail cache layer, or is the in-memory `NSCache` enough for the target library sizes? Decide after Task 1.2 ships and we have profiling data.
- Task 2.1 may want a per-property feature flag to A/B test invalidation counts before fully committing. Worth the scaffolding, or just measure once and commit?
