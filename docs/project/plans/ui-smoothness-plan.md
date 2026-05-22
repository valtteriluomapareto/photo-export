# UI Smoothness Improvement Plan

Goal: reduce main-thread stalls and SwiftUI re-render churn so the app stays at 60 fps during launch, scroll, library changes, and active export runs — especially with large libraries (≥100k assets) and active iCloud sync.

This plan is scoped to **UI smoothness only**. Export throughput, parallelization, and feature work are out of scope. Cross-cutting contracts (cancellation seam, actor isolation policy, AutoSync seam) from [`docs/reference/architecture-conventions.md`](../../reference/architecture-conventions.md) must be preserved by every task below.

> **Status:** Draft reviewed in two passes against the current implementation (May 2026). Findings from both passes are integrated inline. Key preconditions: Task 1.3 keeps the `PhotoLibraryService` protocol unchanged but reworks the internal loader implementation (no `PHImageRequestID` in the public API); Task 2.2 requires a `ForEach` stable-ID fix in `MonthContentView` / `CollectionContentView`; Task 2.3 requires a new `RecordStoreState.loading` enum case. Tier 1 sequencing was tightened in the second pass: **Tasks 1.2 and 1.3 are sequential, not parallel** — both modify the same `loadThumbnail` / `loadThumbnailHighQuality` implementations. Tier 1 also gained test-seam specifications: an injected `MainActorTimerProvider` for the coalescer (Task 1.1), an injected `DecodeFunction` for the thumbnail cache (Task 1.2), and `FakePhotoLibraryService` spy callbacks for the cancellation tests (Task 1.3).

---

## Background — What Currently Hurts Smoothness

From the threading audit on this branch (verified file:line references throughout), the dominant sources of UI stalls are:

1. **High-frequency `@Published` mutations during export runs.** `mutationCounter` is point-debounced via `DispatchQueue.main.asyncAfter(+0.2)` (`ExportRecordStore.swift` L857–865; `CollectionExportRecordStore.swift` L155). The underlying `state` (L96) and `monthCounters` (L91) writes inside `apply(_:)` (~L763) still fire `objectWillChange` synchronously per record append. Additionally, `ExportProgressState` (held by `ExportManager` ~L75) is a separate `@Published` object whose `currentAssetFilename`, `renderActivity`, and `currentJobPlacement` are mutated per-asset and are read by `ExportProgressBar` and timeline `MonthRow`.
2. **Image decode on draw.** `PHCachingImageManager.requestImage` (`PhotoLibraryManager.swift` L525–554, L580–595) returns `NSImage` and `ThumbnailView.swift` L22 renders `Image(nsImage: image)` — decode happens on render. No decoded-image cache exists today; the only cache is `PhotoLibraryManager.phAssetCache` (~L58) for fetch-result reuse.
3. **No cell-scoped cancellation for thumbnail requests.** `ThumbnailView` has no `.task(id:)` or `withTaskCancellationHandler`, and `PhotoLibraryManager.loadThumbnail` / `loadThumbnailHighQuality` **discard the returned `PHImageRequestID`** (L538, L580). There is no public cancellation API on the thumbnail path. The full-image render path *does* do this correctly (see `ProductionMediaRenderer.swift` L150–209).
4. **Broad observation surfaces.** `ExportManager` exposes **12** `@Published` properties (`isRunning` L68, `queueCount` L69, `isPaused` L70, `versionSelection` L91, `convertHEICToJPEG` L112, `livePhotosPairedExport` L141, `videoLayout` L164, `isImporting` L174, `importStage` L175, `importResult` L176, `activeRunContext` L185, `isEnqueueingAll` L448). `PhotoLibraryManager` exposes 3 (`authorizationStatus` L19, `isAuthorized` L20, `libraryRevision` L28). Any view holding either as `@EnvironmentObject` re-evaluates on any property changing.
5. **Synchronous main-thread enumeration.** `PhotoLibraryManager.swift` has 11 `PHFetchResult.enumerateObjects` calls; the UI-blocking ones for ordered grid fetches are `fetchFavoritesPHAssets` (L801) and `fetchAlbumPHAssets` (L819). `availableYearsWithCounts` (L452–481) does its own synchronous fetch + per-year counting on main.
6. **Main-thread JSON decode at launch.** `JSONLRecordFile.load()` (L100–147) decodes the snapshot JSON synchronously on main at L108 and replays the log at L124–136. Callers (`ExportRecordStore.configure(for:)` L175) follow up with `rebuildCountersFromRecords()` (~L840), an O(records) walk on main.
7. **Coarse `libraryRevision` cascade.** `PhotoLibraryManager.invalidateCache()` (L731–735) does `libraryRevision &+= 1` with no deduplication. Triggered from `photoLibraryDidChange` (L1152–1156) via `Task { @MainActor in ... }`. Multiple iCloud sync events in quick succession cascade through every observing view.

Tasks below are ordered by impact ÷ effort.

---

## Tier 1 — Quick Wins (Days, Not Weeks)

### Task 1.1 — Coalesce `@Published` mutations during active runs

**What:** Replace point-debouncing (`mutationCounter` + `asyncAfter(+0.2)`) with a single per-frame drain that batches all record-store mutations. Aim for ≤60 publication events per second per store regardless of append rate. Extend the same treatment to `ExportProgressState`.

**Where:**

- `photo-export/Records/ExportRecordStore.swift` — `apply(_:)` (~L763) is the call site that mutates `state` / `monthCounters`; `scheduleCoalescedNotify` (L857–865) is today's point-debouncer. Coalesce per-frame instead of per-200ms.
- `photo-export/Records/CollectionExportRecordStore.swift` — `placements` / `recordBodies` mutations (~L196, L247) plus the existing `notifyWorkItem` at L155.
- `photo-export/Models/ExportProgressState.swift` — `currentAssetFilename`, `renderActivity`, `currentJobPlacement`, `totalJobsCompleted` all fire per-asset; coalesce or split (see Task 2.1 for the structural split option).
- `photo-export/Export/ExportManager.swift` — of the 12 `@Published` properties, only `queueCount` (L69) and `isEnqueueingAll` (L448) are realistic per-job mutation sources during normal runs; the rest are user-toggle or once-per-run state transitions and **must remain immediate**.

**Approach:**

1. Introduce a **single shared `MainActorCoalescer`** (one instance per app, owned by `ExportManager.init` and passed to both record stores plus `ExportProgressState`). A per-store coalescer would let `ExportProgressState` (read by `ExportProgressBar`) and `ExportRecordStore.mutationCounter` (read by sidebar) publish in different frame windows, producing visible cross-store incoherence (bar shows job N+1 while sidebar reflects N). One coalescer per app → one batched notification per frame across all stores, while each store still fires its own `objectWillChange` so observers stay decoupled.
2. **Frame primitive:** use `CVDisplayLink` (the macOS display-sync primitive). `DispatchSourceTimer` at 16 ms fires on wall-clock intervals decoupled from vsync — a flush 2 ms before vsync wastes a full frame. `CVDisplayLink`'s callback fires *at* vsync, so a coalesced batch always reaches SwiftUI before the next render pass. The callback hops to `@MainActor` via `Task { @MainActor in ... }` or `MainActor.assumeIsolated` (the latter is safe because the display-link callback is delivered to a main-thread context on macOS for typical configurations — verify when implementing).
3. Route per-append mutations through the coalescer instead of mutating `@Published` directly. Mutations to underlying state apply *synchronously* (so reads see the latest value); only the `objectWillChange` signal is rate-limited. This intentionally deviates from SwiftUI's "willChange→write→read in the same frame" expectation: views read the old value during frame N and see the willChange + new value at frame N+1. This is a known, acceptable trade-off for coalesced publishing.
4. **Expose `flushPending()` on the coalescer** and call it from every cancellation / pause / resume / `cancelAndClear` path. Without flush, a pending coalesced send can land *after* the cancel state mutates, briefly showing a stale intermediate.
5. Keep an "immediately publish" escape hatch for state transitions that must reach the UI synchronously. Explicit immediate-publish list: `isRunning`, `isPaused`, `activeRunContext` (run start/end), `state` transitions to `.failed`, completion of `isImporting`. Test that toggling any of these inside a coalesced burst still flushes immediately.

**Test seam:** The coalescer must accept its frame source as a protocol so tests can drive it deterministically:

```swift
protocol MainActorTimerProvider {
    func scheduleNextFrame(_ work: @escaping @MainActor () -> Void)
}
// Production: CVDisplayLinkTimerProvider
// Tests: ManualFrameTimerProvider with fireNextFrame() / advance(by:)
```

Today's `DispatchQueue.main.asyncAfter` debouncer in the stores is **not** unit-testable except by real-time sleep (see `ExportRecordStoreTests` L170 which sleeps 600 ms). The new seam removes that flakiness.

**Definition of done:**

- New `MainActorCoalescerTests` asserts: 5,000 synchronous `scheduleChange()` calls trigger ≤2 `objectWillChange.send()` invocations (one per frame window with `ManualFrameTimerProvider`).
- New test asserts `flushPending()` synchronously fires any pending notification before returning (critical for cancel paths).
- A new regression test asserts: after Task 1.1 lands, `mutationCounter` increments are bounded to one per frame window over a 5,000-record synthetic append burst.
- `ExportProgressState` no longer fires `objectWillChange` more than once per frame during a sustained run.
- No regressions in `ExportRecordStoreTests` or `CollectionExportRecordStoreTests` (note: the existing `testMutationCounterCoalescedNotifications` at ~L170 will need to be rewritten against the new seam).
- The cancellation seam contract is unaffected (mutations still apply synchronously to in-memory state; only `objectWillChange` is debounced).

> **Note on Definition of Done measurement.** "SwiftUI invalidation count" and "`objectWillChange` count" are *not* the same metric — SwiftUI's diff layer can skip body re-evaluation even when `objectWillChange` fires, depending on which `@Published` properties the view reads. The coalescer can be tested against the latter directly; the former requires the in-app invalidation counter (see Rollout & Measurement §1) and is profiling-only, not a CI gate.

**Risk:** Tests that read `@Published` immediately after a mutation may now see the new value before SwiftUI has been notified. That's correct behavior, but any test relying on `objectWillChange` ordering needs updating.

---

### Task 1.2 — Off-main thumbnail decode + decoded image cache

**What:** Cache the bitmap that `PHCachingImageManager` already returns and hand SwiftUI a stable `CGImage` reference so it doesn't re-decode on every render pass.

**Decode primitive — what's actually being cached.** `PHCachingImageManager.requestImage` already returns a *decoded* `NSImage` bitmap; the stutter comes from `Image(nsImage:)` re-rendering work AppKit does eagerly per draw, not from a missing first-decode. So the cache stores `CGImage` (the stable backing bitmap), wrapped at render time. Do **not** introduce `CGImageSourceCreateThumbnailAtIndex` — PhotoKit already did the source decode.

**Render API on macOS.** SwiftUI on macOS has **no `Image(cgImage:)` initializer** (that's iOS only). The macOS render path is `Image(nsImage: NSImage(cgImage: cachedCGImage, size: .zero))`. `NSImage(cgImage:)` is a thin wrapper (no second decode) — it just holds the `CGImage` reference. Cells call this each render but the per-call work is cheap.

**Where:**

- `photo-export/PhotoLibrary/PhotoLibraryManager.swift` — `loadThumbnail` (L525–554) `deliveryMode: .fastFormat`; `loadThumbnailHighQuality` (~L561) `deliveryMode: .highQualityFormat`. Both call sites integrate the cache.
- `photo-export/Views/Shared/ThumbnailView.swift` — render path (L22 today renders `Image(nsImage:)`).
- `photo-export/ViewModels/MonthViewModel.swift` — **delete `thumbnailsById`** outright. Keeping it alongside the cache means each scope decodes thumbnails into its own dict (100k assets × N scopes = N× redundant work). The view-model becomes a thin scope-cancellation owner; the cell reads from the cache directly.
- New file: `photo-export/PhotoLibrary/DecodedThumbnailCache.swift`. `@MainActor`-owned with explicit off-main fill via `Task.detached`.

**Approach:**

1. New `DecodedThumbnailCache` keyed by `CacheKey(localIdentifier, quantizedTargetSize, contentMode, deliveryMode)`. **`targetSize` is quantized** to the nearest 8 pt — a 200×200 cell and a 201×201 cell (possible from layout rounding on Retina) must not produce separate cache entries. Without quantization, scroll fragments the cache. `PHImageContentMode` and `PHImageRequestOptionsDeliveryMode` are both `Hashable`; verify when implementing.
2. **Dedup concurrent requests for the same key** by storing pending entries as `Task<CGImage?, Never>` — second callers `await` the in-flight task instead of triggering a duplicate PhotoKit request and decode.
3. Request flow: check cache (hit → return stored `CGImage` or `await` in-flight Task) → on miss, `PHCachingImageManager.requestImage` → wrap returned `NSImage` to `CGImage` via `NSImage.cgImage(forProposedRect:context:hints:)` on a `Task.detached(priority: .userInitiated)` → store and publish.
4. HQ upgrade semantics: HQ and fast-format entries coexist (different `deliveryMode` axis). Cell render preference: HQ if present, else fast-format.
5. Memory budget: cap at ~100 MB or 500 entries via `NSCache.totalCostLimit` / `countLimit`. Cost = `width * height * 4` per decoded `CGImage`. Accept `NSCache` for v1; if profiling shows pathological eviction, v2 swaps in a hand-rolled LRU (no SwiftPM deps means it'd be written from scratch — defer until proven needed).
6. Invalidation in v1: clear the entire cache on `libraryRevision` bump (matches `phAssetCache` lifecycle in `PhotoLibraryManager` ~L58). The cache is owned by `PhotoLibraryManager` and invalidated from `invalidateCache()` (L731–735).
7. Move `startCachingImages` / `stopCachingImages` from `MonthViewModel.loadAssets` (~L82) into the grid view's `.onAppear` / `.onDisappear`. The current call site fires on every scope-load, including refreshes from `libraryRevision`; viewport-bound is the correct lifecycle.

**Test seams:**

```swift
final class DecodedThumbnailCache {
    typealias DecodeFunction = (NSImage) async -> CGImage?
    init(decode: @escaping DecodeFunction = Self.productionDecode) { … }
}
```

Tests inject a trivial decode (`{ _ in makeTinyCGImage() }`) and assert cache semantics without touching PhotoKit. Recipe for a 1×1 `CGImage` test fixture:

```swift
func makeTinyCGImage() -> CGImage {
    let space = CGColorSpaceCreateDeviceRGB()
    let ctx = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8,
                        bytesPerRow: 4, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    return ctx.makeImage()!
}
```

**Definition of done:**

- New `DecodedThumbnailCacheTests`:
  - `testCacheDedupsConcurrentRequestsForSameKey` — two `async let` requests for the same key invoke the decode closure exactly once.
  - `testCachePreservesBothDeliveryModes` — fast and HQ entries for the same `localIdentifier` coexist.
  - `testCacheInvalidatesOnClear` — `clear()` drops all entries.
  - `testCacheRespectsCountLimitUnderInsertPressure` — 5,000 inserts do not exceed `countLimit`.
  - `testCacheKeyQuantization` — 200×200 and 201×201 sizes hit the same cache key.
- `MonthViewModel.thumbnailsById` deleted; cell reads the cache directly.
- Grid scroll at 1000 px/s shows no decode-related stutter (profiling-only; not a CI gate).
- Memory does not grow unbounded on long scrolls (`NSCache` eviction observed in Instruments).

**Risk:** `NSCache` eviction is opaque. Ship with the count-limit regression test; profile under memory pressure before declaring done. Deleting `thumbnailsById` touches `MonthViewModel` tests — confirm none of them peek at the dict.

---

### Task 1.3 — Cell-scoped thumbnail request cancellation

**What:** Tie each thumbnail request to its cell's lifecycle. When a cell scrolls off-screen, cancel its in-flight `PHCachingImageManager` request.

**Precondition — API gap to close first:** Today's thumbnail call sites *discard* the `PHImageRequestID` returned by `requestImage` (`PhotoLibraryManager.swift` L538, L580) and the manager has **no public cancellation API for thumbnails**. The full-image path already does this correctly — see `ProductionMediaRenderer.swift` L150–209 (captures `PHImageRequestID`, wraps in `withTaskCancellationHandler`, calls `PHImageManager.default().cancelImageRequest(id)` on cancellation). **Use that as the template.**

**Loader signature stays the same.** Do **not** add `cancelThumbnailRequest(id:)` to the `PhotoLibraryService` protocol — that leaks PhotoKit's `PHImageRequestID` to callers and forces every test fake to model a low-level cancellation ID. Keep `loadThumbnail(for:) async -> NSImage?` as the public shape; cancellation is internal to the implementation and is triggered by cancelling the *caller's `Task`* (which a SwiftUI `.task(id:)` does automatically when the cell is reused). This also means `Protocols/PhotoLibraryService.swift` doesn't need updating — only the production implementation changes.

**Where:**

- `photo-export/PhotoLibrary/PhotoLibraryManager.swift` — refactor `loadThumbnail` (L525–554) and `loadThumbnailHighQuality` (~L561) to wrap the existing PhotoKit call in `withTaskCancellationHandler`, capturing the returned `PHImageRequestID` in a `RequestIDBox` and calling `cancelImageRequest(id)` in `onCancel`.
- `photo-export/Views/Shared/ThumbnailView.swift` — add `.task(id: asset.localIdentifier)` driving the load. SwiftUI cancels this task automatically on cell reuse.
- `photo-export/ViewModels/MonthViewModel.swift` — `hqUpgradeTask` (~L30, L189) already cancels on scope change. **Keep the HQ upgrade view-model-driven** (option (a) below); do not move it per-cell.
- `photo-export/Protocols/PhotoLibraryService.swift` — **no protocol change.** `FakePhotoLibraryService` does need to model `Task` cancellation in its async stubs so the test seam is honest about what cancellation gives the caller.

**Approach:**

1. Refactor `loadThumbnail` / `loadThumbnailHighQuality` to `withTaskCancellationHandler` internally. Public signature unchanged.
2. Use `.task(id: asset.localIdentifier)` on `ThumbnailView` so the request is cancelled when the cell is reused.
3. Move `startCachingImages` / `stopCachingImages` from `MonthViewModel.loadAssets()` (~L82) into the grid view's `.onAppear` / `.onDisappear` (also touched by Task 1.2). PhotoKit's internal LRU is adequate for v1 — per-cell prefetch tracking is a v2 concern only if profiling shows it's needed.
4. Keep HQ upgrade view-model-driven (option (a)). Reasoning: fast-format requests are lightweight and frequent (cell-cancellation is a win); HQ upgrades are heavy and ordered (per-cell cancellation would race the sequence and produce visible flicker). Cell-cancellation owns only the fast-format path.
5. **Grace period for scroll bounce:** wrap the load with a 50 ms `Task.sleep` before issuing the PhotoKit request. If the cell is cancelled during that window (e.g. a scroll bounce), no PhotoKit work happens. If it survives, the work proceeds. The grace period is *pre-request*, not post-cancel, which keeps it cheap and naturally testable.

**Test seam:**

- `FakePhotoLibraryService` gains:
  - `onLoadThumbnail: (assetId: String) -> Void` and `onCancelThumbnail: (assetId: String) -> Void` callbacks for spy assertions.
  - A `loadThumbnailDelay: TimeInterval?` knob so tests can model a slow PhotoKit response and exercise cancellation during the response window.
- The grace-period sleep needs an injected clock (reuse the `MainActorTimerProvider` seam from Task 1.1, or a separate `GracePeriodClock` protocol) so tests don't need real-time sleeps.

**Definition of done:**

- `loadThumbnail`/`loadThumbnailHighQuality` no longer discard the `PHImageRequestID`; both wrap in `withTaskCancellationHandler` following the `ProductionMediaRenderer` template.
- `ThumbnailView` uses `.task(id: asset.localIdentifier)`.
- New `PhotoLibraryManagerCancellationTests`:
  - `testLoadThumbnailCancelsPhotoKitRequestWhenTaskIsCancelled` — start a load, cancel the wrapping Task, assert `cancelImageRequest` was called for the captured ID (using a fake `PHImageManager`-shim or the spy callback on `FakePhotoLibraryService`).
  - `testGracePeriodSuppressesRequestWhenCancelledWithinWindow` — start a load, cancel within 30 ms (well under the 50 ms grace), assert no PhotoKit `requestImage` ever fired.
- Integration-level test (using `FakePhotoLibraryService` spy and a synthetic 5,000-asset scroll simulation): in-flight thumbnail count stays bounded by `(visible + prefetch_window)` throughout a fast scroll.
- No HQ upgrade behavior change visible to users (existing `MonthViewModel` HQ tests still pass).

**Risk:** The grace period delays first-paint by 50 ms even for cells that aren't bounced. For steady-state scrolling that's invisible; for the first cells on a cold load it's not. Profile to confirm 50 ms is the right number; consider a smaller (20 ms) value if first-paint feels sluggish. The internal-only cancellation approach means observability of cancellation events depends on the test spy or PhotoKit signposts — there's no app-visible cancellation event surface.

---

## Tier 2 — Structural Smoothness

### Task 2.1 — Partition observation surfaces

**What:** Split the two largest `ObservableObject`s into smaller focused observables so views subscribe only to the slice they read.

**Where:**

- `photo-export/Export/ExportManager.swift` — currently publishes 12 `@Published` properties (enumerated in Background §4)
- `photo-export/PhotoLibrary/PhotoLibraryManager.swift` — publishes `authorizationStatus` (L19), `isAuthorized` (L20), `libraryRevision` (L28)
- `photo-export/Export/ExportManager+AutoSyncConformance.swift` — pure declaration file (5 conformances at L10–17). The split must preserve these — façade publishers can route through child objects without breaking the conformance contract.
- View consumers verified to inject these as `@EnvironmentObject`: `LibraryRootView`, `TimelineSidebarView`, `CollectionsSidebarView`, `ExportToolbarView`, `MonthContentView`, `CollectionContentView`, `AssetDetailView`, `YearContentView` (~20+ refactor sites)

**Approach:**

1. Carve `ExportManager` into:
   - `ExportRunState` — `isRunning`, `queueCount`, `isPaused`, `activeRunContext`, `isEnqueueingAll`, `isImporting`, `importStage`, `importResult`
   - `ExportSettings` — `versionSelection`, `convertHEICToJPEG`, `livePhotosPairedExport`, `videoLayout`
   - `ExportManager` keeps the façade API; AutoSync conformance and `start*` entry points stay on the façade.
2. **Decide between two implementation shapes** (open question to resolve before coding):
   - **a) Separate `ObservableObject`s** injected as their own `@EnvironmentObject`s. Strongest decoupling, largest refactor.
   - **b) Façade-with-publishers** — keep one `ExportManager`, but back each property with its own `CurrentValueSubject` and let views observe via dedicated `@Published` mirrors of subgroups. Smaller diff, weaker decoupling.
   - Recommendation: try (b) on `versionSelection` first as a benchmark; if the invalidation-count drop is sufficient, prefer (b) for the rest.
3. Handle existing `didSet` side effects. Several `ExportManager.@Published` properties have `didSet` observers that persist to `UserDefaults` or call `clearEmptyRunMessage()`. If the property moves to a child object, the side effect either (a) moves with it, or (b) the façade forwards via a subscription. Decide per-property.
4. Same exercise for `PhotoLibraryManager`: pull `libraryRevision` into a tiny `LibraryRevisionPublisher` since it's the most-observed signal.

**Definition of done:**

- A view that only reads `versionSelection` does not re-evaluate when `queueCount` changes (verified by the invalidation-count harness).
- AutoSync seam is preserved — `ExportManager+AutoSyncConformance.swift` continues to expose the same façade-level publishers, and AutoSync tests pass.
- All `didSet`-driven side effects (UserDefaults persistence, derived state clears) still fire on the same triggers.
- No regression in any UI test.

**Risk:** This is the most invasive Tier 2 task. Touches ~20+ view files. Roll out incrementally: split one property at a time and measure after each move. The façade-with-publishers shape (option 2b above) materially de-risks this.

---

### Task 2.2 — Progressive `PHFetchResult` enumeration

**What:** Replace synchronous "enumerate then commit" with "batch-enumerate off-main, commit each batch as it arrives."

**Precondition — `ForEach` stable-ID fix:** `MonthContentView.swift:101` currently uses `ForEach(viewModel.assets) { asset in ... }` with **no explicit `id`**, which falls back to positional identity. Progressive append would cause every existing cell to be re-evaluated on each batch arrival. **Fix to `ForEach(viewModel.assets, id: \.id)` before any progressive work lands.** The plan's earlier claim that stable IDs were already in use was wrong — only the sidebar `ForEach` usages are stable today.

**Where:**

- `photo-export/PhotoLibrary/PhotoLibraryManager.swift` — `fetchFavoritesPHAssets` (L801–803), `fetchAlbumPHAssets` (L819), `availableYearsWithCounts` (L452–481). The grid-feeding paths are the priority; year counts can stay synchronous or move to `Task.detached` separately.
- `photo-export/ViewModels/MonthViewModel.swift` — `loadAssets` (~L79–80) currently stores the full asset list wholesale. `refresh(for:)` (~L149–200) already does incremental diff for library-change updates and is the right template for the progressive consumer.
- `photo-export/Views/Timeline/MonthContentView.swift:101` (and the equivalent `CollectionContentView`) — fix `ForEach` ID.

**Approach:**

1. Wrap `enumerateObjects(_:)` in an `AsyncStream<[AssetDescriptor]>` that yields batches of 200 (size tunable; profile with 50k+ asset months to balance first-batch latency vs. layout reflow).
2. The producer runs on a `Task.detached(priority: .userInitiated)`; consumer is `@MainActor` and appends to `MonthViewModel.assets`. `PHFetchResult.count` is O(1) per PhotoKit documentation and is the gate value for "streaming vs. single-shot."
3. Cancellation: when the producer task is cancelled (selection change), the `AsyncStream` is closed; the consumer's `for await` loop exits and any queued batches are discarded by Swift Concurrency.
4. Preserve the existing `.onChange(libraryRevision)` → `refresh(for:)` pattern (AGENTS.md §94 — abandoned `.task(id:)` for grids); progressive fetch is a new code path on initial load and re-fetch, not a replacement for the in-place diff during library mutations.

**Definition of done:**

- `ForEach(..., id: \.id)` fix landed in both `MonthContentView` and `CollectionContentView`.
- First batch visible in <50 ms after selecting a year/album/favorites scope of any size.
- A 50k-asset month/album shows its first 200 cells immediately and fills progressively without main-thread stalls.
- Cancellation: switching scope mid-fetch does not produce a flash of stale-scope cells; no orphaned batches reach the new scope's `assets` array.
- The existing `MonthViewModel` cancellation contract still holds (see [`docs/reference/architecture-conventions.md`](../../reference/architecture-conventions.md) §Cancellation contract).

**Risk:** Progressive append can cause layout reflow that looks worse than a single-shot commit on small fetches. Gate progressive mode by fetch size (`if count > 500`, use streaming; else single commit). Without the `ForEach` ID fix, this task is actively harmful.

---

### Task 2.3 — Move `JSONLRecordFile.load()` decode off main

**What:** Decode snapshot JSON and rebuild `monthCounters` on the per-store `ioQueue`, then atomic-swap on main.

**Precondition — `RecordStoreState.loading` case:** The plan previously claimed `.loading` existed. **It does not.** `Records/RecordStoreState.swift` defines only `.unconfigured`, `.ready`, `.failed`. The first step of this task is to add `.loading` to the enum and define the state-machine transitions: `.unconfigured` → `.loading` (when `configure(for:)` starts) → `.ready` (on snapshot+log replay success) or `.failed` (on corruption). Update `RecordStoreAlertHost` and any view that switches on `RecordStoreState` to handle the new case.

**Define mutation behavior during `.loading`:** Decide and document one of:
- **(a)** Mutations are rejected with a sentinel error while loading.
- **(b)** Mutations are queued and replayed after `.loading` → `.ready` transitions.
- **(c)** Mutations are forbidden by construction — no caller path can hit `apply(_:)` before `.ready`.

Recommendation: **(c)**, because today's `configure(for:)` is synchronous and callers naturally wait. Verify no `Task` boundary lets a mutation slip in before `.ready`; add an assertion in `apply(_:)` for `state == .ready` to catch regressions.

**Where:**

- `photo-export/Records/RecordStoreState.swift` — add `.loading` case.
- `photo-export/Records/JSONLRecordFile.swift` — `load()` (L100–147) currently returns `LoadResult` synchronously; refactor to async.
- `photo-export/Records/ExportRecordStore.swift` — `configure(for:)` (~L175) calls `file.load()` and then `rebuildCountersFromRecords()` (~L840) on main; both move off-main.
- `photo-export/Records/CollectionExportRecordStore.swift` — equivalent path.
- `photo-export/Records/RecordStoreRouter.swift` — `findReuseSource()` (~L149–165) reads `recordsById` synchronously and assumes `.ready`. During `.loading`, it must return `nil` (caller falls back to fresh fetch); document this acceptable transient state.
- Callers of `configure(for:)` — search `store.configure(` and `store.load(` in production code; confirm they're already in `Task` / `async` contexts or wrap them.

**Approach:**

1. Add `.loading` to `RecordStoreState` and handle it in every switch on the enum.
2. Make `load()` `async`. Internally dispatch decode + replay to `ioQueue`; rebuild `monthCounters` / placements on the same off-main hop.
3. Publish the final value to `@Published state` in a single main-actor assignment. The store transitions `.unconfigured` → `.loading` synchronously *before* the off-main work starts, so the UI sees the loading state immediately.
4. `mutationCountSinceCompact` semantics: the counter lives inside `JSONLRecordFile` and is touched only from inside `ioQueue.async` blocks today — unchanged by moving `load()` off-main.
5. `RecordStoreRouter.findReuseSource()` during `.loading`: return `nil` (treat as "no record yet"). Variants enqueued mid-load will be fetched fresh instead of reusing an existing source; subsequent re-exports will find the source after load completes.

**Definition of done:**

- App launch with a 500k-record store shows the `.loading` state immediately and never blocks the main thread for >16 ms on a single tick.
- `RecordStoreState.failed` recovery alert still surfaces correctly (covered by `RecordStoreAlertHost`).
- All `ExportRecordStore` recovery tests pass; new test exercises `.loading` → `.ready` transition and confirms `RecordStoreRouter.findReuseSource()` returns `nil` during `.loading`.

**Risk:** Any caller that today assumed `load()` was synchronous breaks. The `state == .ready` assertion in `apply(_:)` catches violations cheaply. The reuse-source `nil` window is a minor efficiency loss, not a correctness issue.

---

## Tier 3 — Bigger Refactors (Weeks)

### Task 3.1 — Split authoritative record-store state from observable façade

**What:** A `nonisolated` (or `actor`-backed) store owns the records; a thin `@MainActor` façade publishes only what views read. Generalization of 2.3.

**Why hold this in Tier 3:** Pays off most when Tasks 1.1 + 2.1 + 2.3 are already in. AGENTS.md's defense ("forcing every callsite into `await` for state that is already main-bound, with no thread-safety gain") remains evidence-backed even after those tasks land — synchronous `@MainActor` record-store reads from SwiftUI body are pervasive:

  - `MonthContentView.swift:106` — `exportRecordStore.isExported(...)` inside `body`
  - `MonthContentView.swift:166` — `exportRecordStore.monthSummary(...)` inside `body`
  - `CollectionContentView.swift:225, 257` — collection-store equivalents

If `ExportRecordStore` became an `actor` today (without the façade), every one of these breaks because SwiftUI `body` is not `async`. The façade pattern resolves this: the façade stays `@MainActor ObservableObject` and exposes a snapshot that answers all sync read queries; the core does mutations and IO off-main.

**Where:** `photo-export/Records/` — affects both stores plus `JSONLRecordFile` and the `RecordStoreRouter`.

**Approach:** Design a `RecordStoreCore` (off-main, owns records + IO) and a `RecordStoreFacade` (`@MainActor ObservableObject`, owns the published snapshot). Mutations go through the core; the core posts diffs back to the façade.

**Snapshot shape requirements** (must support every read currently called from SwiftUI body):

1. Per-asset completion lookup: `isExported(assetId:variantSelection:) -> Bool`.
2. Per-month summary: `monthSummary(forYear:month:) -> MonthSummary` (the existing `monthCounters` dict shape is a candidate).
3. Per-placement completion: collection-store equivalent indexed by `(placementId, assetId)`.
4. The snapshot is itself the `@Published` value; views observe it normally (no `.task(id:)` on a version number).

**Diff protocol from core → façade:**

- Per-frame batched (uses the Task 1.1 coalescer infrastructure on the *façade side*, not inside the core).
- Core emits `RecordStoreDelta` values; façade applies them to the snapshot atomically on main.
- Startup: core emits one large "initial snapshot" delta; façade transitions `.loading` → `.ready` on apply.

**Cancellation-seam interaction:** The `generation` / `isCurrent(gen)` seam stays where it is today (`ExportQueueCoordinator`, `@MainActor`, synchronous). Records moving off-main does **not** push generation tracking off-main; export tasks check `isCurrent(gen)` on main between awaits, then read from the façade's snapshot.

**Definition of done:** Drafted in a follow-up issue with its own design doc before any code is written. The design doc must enumerate every synchronous record-store read in the view tree (the grep above is a starting point) and confirm the snapshot satisfies each.

**Risk:** Largest refactor in this plan. Don't start until Tier 1 + 2 measurements confirm the remaining stalls are dominated by main-thread store work.

---

### Task 3.2 — Lazy sidebar evaluation

**What:** Coalesce a burst of `libraryRevision` bumps into a single refetch across both sidebars. Defer count fetches for collapsed nodes in the Collections sidebar.

**Current behavior — corrections to the original plan:**

- **Timeline sidebar** does *not* use per-row `.task(id: libraryRevision)`. Instead, `TimelineSidebarView.swift:139` calls `TimelineSidebarCounts.loadCounts(forYears:...)` once on appear, which fans out parallel year × month fetches into a published dict (read at L55–56). Month rows are pure readers of that dict, not fetchers. This is **already closer to the desired shape**; the work here is debouncing the `libraryRevision`-triggered refetch and (optionally) deferring collapsed-year months.
- **Collections sidebar** *does* use per-row `.task(id: descriptor.id + "|\(photoLibraryManager.libraryRevision)")` (`CollectionsSidebarView.swift:189, 200, 233`). Per-row firing on every `libraryRevision` bump is the actual problem here.
- `CollectionCountCache` (an `actor`) already invalidates wholesale on `libraryRevision` (~L63). **Adding a TTL conflicts with wholesale invalidation** — drop the TTL idea; the right move is debouncing the *bump*, not adding a second invalidation policy on top.

**Where:** `photo-export/Views/Timeline/TimelineSidebarView.swift`, `photo-export/Views/Collections/CollectionsSidebarView.swift`, `photo-export/PhotoLibrary/CollectionCountCache.swift`, `photo-export/PhotoLibrary/PhotoLibraryManager.swift` (`invalidateCache()` L731–735 and the `Task { @MainActor in ... }` site at L1153).

**Approach:**

1. Coalesce `libraryRevision` at the *source*: in `PhotoLibraryManager.invalidateCache()`, debounce the `&+= 1` bump by 250 ms (drop intervening callbacks). This benefits every observer at once instead of every observer hand-rolling a debouncer.
2. Collections sidebar: keep per-row `.task` but the `id` now changes ≤4 Hz instead of per-`photoLibraryDidChange` callback.
3. Collections sidebar — optional v2: defer per-row fetch for collapsed disclosure groups. Today all rows fetch on appear regardless of disclosure state; gating by `isExpanded` requires propagating disclosure state into each row. Defer this unless v1 (debouncing only) doesn't hit the target.
4. Verify AutoSync coupling: AutoSync observes library changes via `PhotoLibraryChangeProviding` (`PhotoLibraryPersistentChangeAdapter`), **not** via `libraryRevision`. Debouncing `libraryRevision` for UI purposes is independent of AutoSync's wake-up path. Confirm in code before shipping.

**Definition of done:**

- During a heavy iCloud sync (hundreds of `photoLibraryDidChange` callbacks per minute), `libraryRevision` bumps are bounded to ≤4/sec.
- Sidebar count refetches are bounded by the bump rate.
- AutoSync still wakes promptly on library changes (verified by its own integration test).

**Risk:** Debouncing `libraryRevision` means *every* view observing it sees the slower bump rate. The grid (`MonthContentView` `.onChange(libraryRevision)` → `refresh()`) becomes slightly less responsive to library mutations. Profile this: 250 ms is likely fine for a user-facing photo library, but a smaller debounce (100 ms) may also work.

---

## Cross-Cutting — Audit Items

Audit pass results (May 2026) included inline; remaining items flagged.

- **Stable `ForEach` IDs.** Sidebars audited and clean: `TimelineSidebarView` uses `id: \.self` on `Int` years/months; `CollectionsSidebarView` uses `id: \.id` on `PhotoCollectionDescriptor` (String IDs). **Hazard found in grids:** `MonthContentView.swift:101` (and the equivalent `CollectionContentView` `ForEach`) has no explicit `id` and falls back to positional identity. **Tracked as a Task 2.2 precondition.**
- **Animation discipline during runs.** Five `.animation(...)` / `withAnimation` usages found: `ExportProgressBar.swift` (3, animating progress UI — safe), `FolderTileView.swift` and `MonthTileView.swift` (hover state — safe). No animation fires per-record or per-export-state change. **No action required.**
- **`@EnvironmentObject` discipline.** Both sidebars inject `exportManager` even though direct reads of it are minimal — the injection is consumed by child row views. After Task 2.1, re-audit and inject only the slice each view actually reads. **No standalone work required ahead of Task 2.1.**
- **No `.receive(on:)` on AutoSync mirrors.** Repository-wide grep found one `.receive(on:)`, in `Destination/DestinationSafetyMonitor.swift` — not on an AutoSync mirror path. **Clean.** Any task in this plan that adds a Combine pipeline must verify it doesn't introduce a violation.

---

## Rollout & Measurement

Each tier should land independently with measurements before moving to the next.

**Measurement harness (to be built once, used for every task):**

1. **SwiftUI invalidation counter.** No existing invalidation telemetry in the codebase. Two options: (a) wrap target views in a `.onChange` counter that increments a debug `@Observable` counter; (b) use SwiftUI's `_printChanges()` debug API. `_printChanges()` is **not currently used anywhere** in the repo — validate it on the target macOS version before relying on it. Recommendation: ship (a) since it's deterministic and assertable in tests.
2. **`os_signpost` intervals.** **Existing harness to extend, not greenfield:** `PhotoLibrary/PhotoLibraryPersistentChangeAdapter.swift` L104–108 already defines `private static let signposter = OSSignposter(...)` and wraps catch-up operations in signpost intervals at L473–480. Add new intervals around app launch (in `App/photo_exportApp.swift` / `AppLifecycleCoordinator`), year/album selection commit (in the selection-handler path), scroll session (cell appear/disappear), and export run start/end (in `ExportManager.start*` entry points).
3. **Scripted smoothness scenario.** `photo-exportUITests/` exists but **is skipped by default in the shared scheme** (AGENTS.md L32). Options: (a) explicitly enable the scenario in a non-default CI job; (b) build the measurement scenario as a `@MainActor` integration test using `FakePhotoLibraryService` with a synthetic 100k-asset fixture. Recommendation: (b) — UI tests need real Photos library data which can't be CI-injected, while the fake can synthesize any size.
4. **Test-data generation.** No mechanism exists today to populate Photos library with bulk test assets. `FakePhotoLibraryService` has a canned `assetsByYearMonth` dictionary populated by individual tests; add a fixture helper that bulk-generates a 100k-descriptor configuration so the harness has representative load.

**Regression-gate tests:** Each task should add at least one regression test that asserts the smoothness property it establishes (e.g. Task 1.1 asserts ≤60 `objectWillChange` signals/sec during a 5k-record append burst). Without these, future regressions go undetected because smoothness is not visible to existing tests.

**Sequencing recommendation:**

1. Build the measurement harness *and* the bulk-fixture helper.
2. Land Task 1.1 (coalescing) — independent of other tasks. Re-measure.
3. Land Task 1.2 (decoded thumbnail cache) — adds the cache *and* deletes `MonthViewModel.thumbnailsById`. Re-measure.
4. Land Task 1.3 (cell-scoped cancellation) — must follow 1.2, **not in parallel**. Both modify the same `loadThumbnail` / `loadThumbnailHighQuality` functions in `PhotoLibraryManager`; landing them in parallel produces a merge conflict in the most-modified part of the file. The cache lands first because cancellation is more useful when it cancels into a populated cache; the API gets refactored once to wrap both the cache lookup and the `withTaskCancellationHandler`.
5. Land Task 2.1 (observation surfaces) one property at a time. Re-measure after each.
6. Land Task 2.2 (progressive fetch) — landing the `ForEach` ID precondition fix first as a standalone PR. Re-measure.
7. Land Task 2.3 (off-main load) — landing the `RecordStoreState.loading` enum case first. Re-measure.
8. Re-evaluate whether Tier 3 is needed based on remaining stall sources.

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

- For the measurement harness: pick (a) `.onChange` counter vs. (b) `_printChanges()` — the latter has zero existing usage so its behavior on macOS 15+ needs validation. Recommendation in §Rollout is (a); confirm before building.
- For Task 1.2, do we need an on-disk thumbnail cache layer, or is the in-memory `NSCache` enough for the target library sizes? Decide after Task 1.2 ships and we have profiling data. No on-disk caching exists today (verified — no `URLCache`/`~/Library/Caches` references).
- For Task 2.1, the two implementation shapes (separate `ObservableObject`s vs. façade-with-publishers) have different effort profiles. The codebase has no existing feature-flag pattern (only `AutoSyncManager.isEnabled` as a runtime toggle), so A/B testing would require new scaffolding. Recommendation: prototype the façade-with-publishers shape on `versionSelection` first and decide from measurement, not flags.
- CI integration of the measurement harness: should signpost-based assertions run in CI, or only in developer profiling sessions? Capturing Instruments traces in CI requires non-containerized runners. Decide before §Regression-gate tests in Rollout become CI-blocking.
- For Task 3.2's `libraryRevision` source-debounce: confirm AutoSync's wake-up actually comes from `PhotoLibraryChangeProviding` and not via observing `libraryRevision`. If any AutoSync code path depends on the unsuppressed counter, source-debouncing breaks it and the debounce has to move to the UI side instead.
