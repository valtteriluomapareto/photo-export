# Architecture Conventions

## Do you need this doc?

**You need to read this if your change touches any of the following:** `ExportManager` or any of its collaborators (`ExportQueueCoordinator`, `VariantExporter`, `ImportCoordinator`); the AutoSync seam (`ExportManager+AutoSyncConformance.swift` or `exportRunStatePublisher` consumers); the record stores or `RecordStoreRouter`; `ExportPlacement.Kind` or `ExportVariant`; the cancellation contract (`generation`, `isCurrent`, `throwIfCancelledOrStale`); or you're extracting a new collaborator.

**You can skip this if your change is** a typo, a copy tweak, a website edit, a view-only change that doesn't touch the export pipeline, or a new test that doesn't modify the system under test.

The patterns and contracts below were established by the May 2026 architecture refactor (PR #68; Phases 0–6 + partial 7). The original design rationale lives in [`docs/project/archive/software-architecture-improvement-plan.md`](../project/archive/software-architecture-improvement-plan.md). For the friendly high-level type map, see [`website/src/content/docs/architecture.md`](../../website/src/content/docs/architecture.md). This doc covers the *contracts* — what the types must follow.

## The architecture in one paragraph

`ExportManager` is the façade. It owns the export-run lifecycle, the cancellation seam (`generation`), the AutoSync-observable `@Published` properties, and `UserDefaults`-backed user choices (`versionSelection`). Real work is delegated to extracted collaborators: `ExportQueueCoordinator` runs the drain loop and owns queue state; `VariantExporter` writes each variant; `ImportCoordinator` runs the Import Existing Backup flow; `ExportDestinationResolver` allocates filenames; `ExportJobPlanner` plans jobs; `RecordStoreRouter` dispatches record reads/writes by placement kind; `ExportCompletionPolicy` decides what counts as "done". Each `@MainActor` collaborator holds a `Host` protocol that points back to the manager for the cancellation seam and a few UI-state mutations the manager still owns.

## Cross-cutting contracts

These three contracts bind every collaborator. Break one and you break either the AutoSync seam, cancellation safety, or the threading model.

### 1. Cancellation contract

**Storage**: `var generation: Int` lives on `ExportQueueCoordinator` (see [`ExportQueueCoordinator.swift`](../../photo-export/Export/ExportQueueCoordinator.swift) — search for `private(set) var generation`). `ExportManager` exposes a computed `var generation: Int { queueCoordinator.generation }` forwarder for test reads and in-module convenience.

**Helpers** (all on `ExportQueueCoordinator`; `ExportManager` exposes thin forwarders for the dispatcher call sites):

```swift
func isCurrent(_ gen: Int) -> Bool
func throwIfCancelledOrStale(_ gen: Int) throws
func bumpGeneration()
```

**Rule**: every async task that mutates state captures `let gen = generation` *synchronously* before the first `await`, then uses `[weak self]` + `guard self.isCurrent(gen) else { return }` at every checkpoint. Throwing paths use `try throwIfCancelledOrStale(gen)`.

**Which methods bump generation** (and so cancel anything running under the old gen):

- `cancelAndClear()` (on `ExportManager`, via `queueCoordinator.bumpGeneration()`)
- `interruptForDestinationUnavailable()` (same path)
- `supersedeForManualRun()` (same path)
- `cancelImport()` (on `ImportCoordinator`, via the injected `queueCoordinator` reference)

**Which method does NOT bump generation**:

- `clearPending()` — drops queued jobs only. In-flight work that started before `clearPending` keeps its `gen` and finishes normally. If you need to cancel mid-flight, call `cancelAndClear` instead.

**Collaborator seam**: `VariantExporter` and `ImportCoordinator` hold a direct (weak) reference to `ExportQueueCoordinator` for the cancellation helpers; their `Host` protocols no longer carry `isCurrent`, `throwIfCancelledOrStale`, `generation`, or `bumpGeneration` (issue #67 item 2 landed in May 2026). The coordinator's own dispatch loop reads its own `generation` / `isCurrent` directly. New collaborators that need the seam should inject `ExportQueueCoordinator` the same way, not route through `Host`.

### 2. Actor isolation policy

| Type kind | Isolation | Examples |
| --- | --- | --- |
| `ObservableObject` with `@Published` state observed by SwiftUI | `@MainActor final class` | `ExportManager`, `ExportQueueCoordinator`, `ImportCoordinator`, `ExportDestinationManager`, `ExportRecordStore`, `CollectionExportRecordStore` |
| Main-actor collaborator without `@Published` (mutates shared state from MainActor only) | `@MainActor final class` | `VariantExporter`, `RecordStoreRouter`, `JSONLRecordFile` |
| Main-actor composition wrapper — final, conforms to `PhotoLibraryService`, optionally wraps an injected service for curated screenshot content | `@MainActor final class` | `PhotoLibraryManager` (wraps `overrideService`), `ScreenshotPhotoLibraryService` (peer, no inheritance) |
| Pure helper / policy (value-typed, no I/O state) | plain `struct` or `enum`, `Sendable` where it crosses tasks | `ExportJobPlanner`, `ExportCompletionPolicy`, `ExportDestinationResolver`, `ExportFilenamePolicy`, `ExportPathPolicy`, `ExportPlacementResolver`, `ResourceSelection`, `BackupScanner`, `FileIOService`, `ProductionAssetResourceWriter`, `ProductionMediaRenderer` |
| Concurrent state holder | `actor` | `CollectionCountCache` |
| Heavy work that must hop off MainActor | `nonisolated async` selectively on protocol-conforming methods | `PhotoLibraryService` (selectively `nonisolated` count methods), `MediaRenderer`, `AssetResourceWriter`, `FileSystemService` |

Rules:

- Do **not** add `@MainActor` to pure helpers reflexively. If a type holds no state and crosses task boundaries, make it `Sendable` and leave the isolation off.
- Do **not** promote a collaborator to `actor` to "fix" concurrency unless you have a measurement showing main-actor contention. `@MainActor` is the established pattern because `@Published` + SwiftUI binding works there without `await` ceremony.
- Each `@MainActor final class` collaborator should carry a one-line comment at its top declaring its isolation. (Stops future contributors from silently making it `nonisolated`.)

### 3. AutoSync seam preservation

**Invariant**: `ExportManager+AutoSyncConformance.swift` is a thin wire-up file — only `extension ExportManager: …Host {}` conformances and explanatory docstrings, no implementation bodies. The file gains new conformances when collaborators are extracted (Phases 3a/4b/5 each added one), but it should never carry method bodies. AutoSync reads the manager via the conformance file's declared protocols; if you need a new bit of state AutoSync should see, add it to the manager (or sink it from a coordinator onto the manager — see below), then expose it through the conformance.

**Publisher surface** (real shape from `ExportManager.swift`):

```swift
var exportRunStatePublisher: AnyPublisher<ExportRunState, Never> {
  Publishers.CombineLatest4($activeRunContext, $isRunning, $queueCount, $isEnqueueingAll)
    .map { context, isRunning, queueCount, isEnqueueingAll in
      let manualFireAndForget =
        context == nil && (isRunning || queueCount > 0 || isEnqueueingAll)
      return ExportRunState(
        activeContext: context,
        isManualActive: context?.source == .manual || manualFireAndForget,
        isAutoSyncActive: context?.source == .autoSync
      )
    }
    .removeDuplicates()
    .eraseToAnyPublisher()
}
```

The `CombineLatest4` over `($activeRunContext, $isRunning, $queueCount, $isEnqueueingAll)` is the AutoSync contract. The `manualFireAndForget` branch makes toolbar exports (which never set `activeRunContext`) register as `isManualActive` — without it, AutoSync would attempt to start a background run while the toolbar queue was busy. `isEnqueueingAll` participates so the bulk-enqueue window (after the dispatcher flips it true but before the first job lands in `pendingJobs`) is observable as busy too (issue #67 item 4a). Adding new state to the quadruple is a deliberate, audited change — re-record the [`AutoSyncSeamCharacterizationTests`](../../photo-exportTests/AutoSyncSeamCharacterizationTests.swift) snapshots only after verifying the new emission sequence is correct.

**Mirror pattern** (when state lives on a coordinator but AutoSync needs to see it via the manager):

```swift
// On the coordinator:
@Published private(set) var isRunning: Bool = false
@Published private(set) var queueCount: Int = 0

// On ExportManager.init, after collaborators are wired up. Each coordinator
// has its own cancellable set (`queueCancellables`, `importCancellables`) so
// a coordinator can be torn down or rewired independently.
queueCoordinator.$isRunning
  .sink { [weak self] in self?.isRunning = $0 }
  .store(in: &queueCancellables)
queueCoordinator.$queueCount
  .sink { [weak self] in self?.queueCount = $0 }
  .store(in: &queueCancellables)
```

Both objects are `@MainActor` and `@Published`'s `willSet` is synchronous, so the AutoSync `CombineLatest3` observes consistent state. The synchrony pin is [`ExportQueueStateSnapshotTests.teardownQueue_synchronouslyClearsManagerMirrors`](../../photo-exportTests/ExportQueueStateSnapshotTests.swift) — if you make a mirror async (`.receive(on:)`, `MainActor.run`, etc.) that test fails.

## Host protocol pattern

> The cancellation-seam methods (`isCurrent` / `throwIfCancelledOrStale` / `generation` / `bumpGeneration`) are no longer on any Host protocol — that move landed in issue #67 item 2. Collaborators that need the seam inject `ExportQueueCoordinator` directly. The remaining Host methods are UI-state mirrors and dependency forwarders, all stable.

When you extract a new collaborator from `ExportManager`, expose what you need from the manager via a narrow `@MainActor` `Host` protocol declared on the collaborator. The `@MainActor` annotation on the protocol itself is load-bearing — a non-MainActor Host would force `await` at every call site and break the mirror-sinks synchrony.

Example from [`ExportQueueCoordinator.swift`](../../photo-export/Export/ExportQueueCoordinator.swift):

```swift
@MainActor
final class ExportQueueCoordinator: ObservableObject {
  @MainActor
  protocol Host: AnyObject {
    var generation: Int { get }
    func isCurrent(_ gen: Int) -> Bool
    var isEnqueueingAll: Bool { get }
    func performExport(job: ExportManager.ExportJob, generation: Int) async
    func didDrainQueue()
    func setCurrentJob(_ job: ExportManager.ExportJob)
    func clearCurrentJobIdentifiers()
  }

  private weak var host: Host?

  init(host: Host) {
    self.host = host
  }
}
```

On `ExportManager` (which is `final class ExportManager: ObservableObject` — no superclass), the collaborator is stored as an implicitly-unwrapped optional (IUO) and assigned after all stored properties are initialized so `self` is available to pass as `host`:

```swift
private(set) var queueCoordinator: ExportQueueCoordinator!

init(...) {
  // ...assign all stored dependencies first...
  self.photoLibraryManager = photoLibraryManager  // etc.

  // Now self is available — wire the collaborators.
  queueCoordinator = ExportQueueCoordinator(host: self)
  // ...wire sinks into queueCancellables / importCancellables, etc.
}
```

The manager owns the coordinator strongly (IUO storage, not `weak`); only the back-reference from coordinator to manager is `weak`. Construction order matters — collaborators that read each other's state must be wired before sinks fire. The conformance is in a small extension file ([`ExportManager+AutoSyncConformance.swift`](../../photo-export/Export/ExportManager+AutoSyncConformance.swift)) holding only `extension ExportManager: …Host {}` lines — every method the protocol requires is already on `ExportManager` directly, so the conformances have empty bodies.

Rules:

- Keep the Host protocol *narrow* — only the seam the collaborator actually needs. Adding methods later is cheap; pruning surface area later is hard.
- `@MainActor protocol Host: AnyObject` on the protocol itself; `private weak var host: Host?` on the collaborator (avoid retain cycles).
- Document each Host method's intent in the protocol's docstring. The collaborator's class doc lists which methods are temporary (will move when a deferred follow-up lands) versus permanent.
- The collaborator's `@Published` state is *its own* — do not duplicate it on the manager. Use the mirror pattern (above) if AutoSync or views need the same property name on the manager.

## Forwarder pattern

`ExportManager` retains a stable public surface by forwarding to coordinators when sensible. Examples (search `ExportManager.swift` for the literal `{ queueCoordinator.` to find them):

```swift
var pendingJobs: [ExportJob] { queueCoordinator.pendingJobs }
var isProcessing: Bool { queueCoordinator.isProcessing }
func processQueueIfNeeded() { queueCoordinator.processQueueIfNeeded() }
private func resetProgressCounters() { queueCoordinator.resetProgressCounters() }
```

Rules:

- **Read-only forwarders are fine.** They let existing call sites (and future features written against the old `ExportManager` API) keep working without rewrites. The sidebar multi-select feature merged from `main` integrated cleanly thanks to these forwarders.
- **Avoid writing through to coordinator-owned state from `ExportManager` directly** unless the coordinator deliberately exposes a setter. Mutating `queueCoordinator.pendingJobs` from outside the coordinator breaks the Host-protocol invariant; go through a method the coordinator publishes.
- **Avoid adding new `@Published` properties to `ExportManager` for state that conceptually lives on a coordinator.** Add the `@Published` to the coordinator and sink it onto the manager via the mirror pattern. (Exception: state that AutoSync observes via `exportRunStatePublisher` may need to live on the manager so the publisher composes — see §AutoSync seam preservation.)

## Canonical `start*` entry-point shape

Every fire-and-forget export entry point on `ExportManager` follows the same skeleton. Source of truth: `startExportMonth` in [`ExportManager.swift`](../../photo-export/Export/ExportManager.swift) — copy that method as a starting point rather than rewriting from this skeleton.

```text
func startExportX(...) {
  // 1. Block-on-conflict guards (synchronous, return early on each).
  //    Typical conflicts: import in progress; store not in .ready;
  //    bulk-enqueue already in flight (`isEnqueueingAll`).

  // 2. Snapshot user-mutable state synchronously.
  //    `let selection = versionSelection` — picker flips after this point
  //    must not change the run.

  // 3. Clear any prior UI messages (empty-run, queue-warning).

  // 4. Reset progress counters ONLY when the queue is truly idle.
  //    Idle = `!isRunning && !isProcessing && pendingJobs.isEmpty`.
  //    "Paused with pending jobs" satisfies the first two but is NOT idle —
  //    resetting there detaches done/total from pendingJobs.count.

  // 5. Capture generation synchronously before the first await.
  //    `let gen = generation`

  // 6. Fire-and-forget Task with [weak self] re-checking isCurrent(gen)
  //    after every await. Route the actual enqueueing through an existing
  //    `enqueueX(... generation:)` helper (so record-store dispatch + dedup
  //    are shared with the single-select paths). Call `processQueueIfNeeded()`
  //    on success; log + bail on throw.
}
```

Bulk dispatchers (`startExportAll`, `startExportTimelineSelection`, `startExportCollectionsSelection`, plus the shared `enqueueBulkAlbumExport` driver behind `startExportAllAlbums` / `startExportAllSharedAlbums` / `startExportFolder` / `startExportAlbums`) follow the same shape but loop over multiple `enqueueX(...)` calls and set `isEnqueueingAll = true` for the duration. The four outer-Task scaffoldings share a private helper, `runBulkExportTask(...)`, which owns the `Task { [weak self] in }` wrapping, the `isEnqueueingAll = false` teardown on every exit path, the success finalize, and the partial-failure recovery on throw. The inner per-item loop shares `runBulkEnqueueLoop(...)` so multi-bucket dispatchers (years + months for timeline; favorites + albums + shared for collections) can chain passes while accumulating into a single `BulkExportTotals`.

## Regression gates

These tests are wired so they fire when a load-bearing invariant breaks. Do not "fix" them by re-recording — audit first.

| Test | Fires when… | What to do |
| --- | --- | --- |
| [`AutoSyncSeamCharacterizationTests`](../../photo-exportTests/AutoSyncSeamCharacterizationTests.swift) | The emission sequence on `exportRunStatePublisher`, `isImportingPublisher`, or `completedRunsPublisher` changes | Audit. Re-record snapshots only after confirming the new sequence is what AutoSync should see. |
| [`ExportQueueStateSnapshotTests.teardownQueue_synchronouslyClearsManagerMirrors`](../../photo-exportTests/ExportQueueStateSnapshotTests.swift) | A coordinator → manager mirror becomes async (`.receive(on:)`, `.async`, etc.) | Re-add the synchronous sink. The AutoSync `CombineLatest3` depends on synchrony for consistent reads. |
| `ExportQueueStateSnapshotTests.pauseResumeCancelStateSnapshot_canonicalTransitions` | Pause/resume/cancel transitions on `isRunning`/`queueCount`/`isPaused` change | Audit; this is the toolbar's contract. |
| [`ScreenshotPhotoLibraryServiceOverridesTests`](../../photo-exportTests/ScreenshotPhotoLibraryServiceOverridesTests.swift) | A `PhotoLibraryService` method on `ScreenshotPhotoLibraryService` returns production-PhotoKit-shaped empties instead of curated synthetic data | The tests pin every method's curated output. The "newly-added method silently inherits production" hole that prompted this gate's original wording is closed structurally — `ScreenshotPhotoLibraryService` is a peer conformance (no inheritance) since issue #67 item 1, so a new protocol method fails to compile until it has a real implementation. |
| [`ImportIdempotencyTests`](../../photo-exportTests/ImportIdempotencyTests.swift) | The import flow loses idempotency on retry | Audit. Two consecutive `startImport()` runs over the same backup tree must not double-write records. |
| `ExportManagerRunExportTests.autoSyncRunFilterAlreadyExportedBeforeRetryCheck` | The `isExported` predicate runs *after* the retry-gate (instead of before) | Restore the order. `isExported` must run first so already-done assets are not blocked by the retry-gate. |

## Extension recipes

### Adding a new `start*` entry point

1. Add the public method on `ExportManager` following the canonical shape above.
2. If it routes through an existing `enqueueX(...)` helper, you are done — record-store dispatch, dedup, queue handoff are already correct.
3. If it needs a new `enqueueX(...)` helper, write that private method too. It should be `async throws`, take `selection: ExportVersionSelection` and `generation: Int`, call `try throwIfCancelledOrStale(gen)` after the PhotoKit fetch, and end with `queueCoordinator.enqueue(jobs)` (NOT a direct `pendingJobs.append`).
4. Add a unit test that asserts the generation guard fires when the run is cancelled mid-await.

### Adding a new export placement kind

`ExportPlacement.Kind` is a closed enum — the compiler will guide you to every switch that needs to handle the new case. Touch points:

1. **`ExportPlacement.Kind`** ([Models](../../photo-export/Models/ExportPlacement.swift)) — add the case. The `variantPolicy` switch on `Kind` itself (same file) also needs to handle the new case — required-variants policy lives there.
2. **`RecordStoreRouter`** ([Records](../../photo-export/Records/RecordStoreRouter.swift)) — every `switch placement.kind` in the router must handle the new case (today there are six: `variants`, `markVariantInProgress`, `markVariantExported`, `markVariantFailed`, `removeInProgressVariant`, plus the reuse-source probe). The closed enum will force you to update each one.
3. **`ExportCompletionPolicy`** ([Records](../../photo-export/Records/ExportCompletionPolicy.swift)) — handle the new kind in `requiredVariants`, edited-fallback, and asset-complete checks.
4. **`ExportPlacementResolver`** and any **`startExport*` entry point** that constructs an `ExportPlacement` for this kind from a `LibrarySelection`. If the new kind also needs a UI route, add corresponding cases to `LibrarySelection` and `PhotoFetchScope`.

The `placement.kind` switch is *not* duplicated across `ExportManager` anymore — Phase 1 centralized it into `RecordStoreRouter`. If you find yourself writing `switch placement.kind` outside the router or the policy, you are probably bypassing a seam.

### Adding a new variant

`ExportVariant` is a closed enum. Adding a case forces compile errors at every switch that handles variants — work through them:

1. **`ExportVariant`** — add the case.
2. **`VariantExporter`** ([Export](../../photo-export/Export/VariantExporter.swift)) — handle it in the per-variant write switch.
3. **`ResourceSelection.selectEditedProducer`** ([Export](../../photo-export/Export/ResourceSelection.swift)) — decide how the new variant selects bytes. The function returns an `EditedProducer` enum (`.resource | .render | .none`); extend that enum if the new variant needs a third byte source. New media kinds change `ResourceSelection`, not the call sites.
4. **`ExportFilenamePolicy`** — decide the suffix shape (`_orig`, plain, etc.).
5. **`ExportCompletionPolicy`** — add the variant to `requiredVariants` where applicable.

### Extracting a new collaborator from `ExportManager`

1. Identify the seam — what *state and methods* on the manager does the new collaborator need? Write that as a `protocol Host: AnyObject` on the new class.
2. Move the relevant `@Published` state to the new class. Keep the type the same on `ExportManager` as a mirror (sink in init).
3. Construct the collaborator post-init with `host: self`. Store it as an IUO (`var coordinator: NewCoordinator!`).
4. Move the methods. Replace each call site on `ExportManager` with a forwarder (`func foo() { coordinator.foo() }`) so existing tests and callers keep working.
5. Verify the AutoSync seam: run [`AutoSyncSeamCharacterizationTests`](../../photo-exportTests/AutoSyncSeamCharacterizationTests.swift). If the emission sequence changes, the mirror sinks are wrong (likely async, or in the wrong order).
6. Verify the synchrony pin: run [`ExportQueueStateSnapshotTests.teardownQueue_synchronouslyClearsManagerMirrors`](../../photo-exportTests/ExportQueueStateSnapshotTests.swift) if the new collaborator owns any queue-adjacent state.

### Adding a new `@Published` property AutoSync should observe

1. Add the `@Published` to the right *owner* — the collaborator if conceptually theirs; `ExportManager` if conceptually the manager's.
2. If the owner is a collaborator: add a same-named `@Published` on `ExportManager` and `.sink` from the coordinator's publisher in `init`.
3. If the new property changes `ExportRunState`'s shape: add it to the `CombineLatest` (you may need to bump to `CombineLatest4`). Re-record `AutoSyncSeamCharacterizationTests` after verifying the new emission sequence is correct.
4. Mention the new field in `ExportManager+AutoSyncConformance.swift` if AutoSync needs to read it directly (not via the publisher).

## Deferred follow-ups

The refactor shipped with three deliberate deferrals tracked in [issue #67](https://github.com/valtteriluomapareto/photo-export/issues/67); items 2, 4, 5, and 6 landed since:

1. ~~**PhotoLibrary composition refactor**~~ — landed (issue #67 item 1, May 2026): `PhotoLibraryManager` is `final`, holds an optional `overrideService`, and forwards every `PhotoLibraryService` method to it when set. `ScreenshotPhotoLibraryService` is a standalone conformance — no inheritance — so newly-added protocol methods are caught at compile time. The override-gate test stays as a behavioral pin against curated-content regressions.
2. ~~**Generation-counter ownership transfer**~~ — landed: `var generation: Int` now lives on `ExportQueueCoordinator`; `VariantExporter` and `ImportCoordinator` hold a direct reference for the seam.
3. ~~**Remaining Phase 7 folder moves**~~ — landed (issue #67 item 3, May 2026): `Destination/`, `Export/`, and `App/` exist; `Managers/` has been removed. The non-test source layout now matches the architecture-doc descriptions one-to-one.

A second wave of follow-ups landed with item 4 (AutoSync seam test growth) and item 5 (`start*` bulk-loop helper consolidation). Item 6 (CI regression-gate symbol guard) is also done.

## Where to ask

If a contract above conflicts with the code (e.g. you find a `@Published` on the manager that should be a mirror, or a `Host` method that has become permanent and should be documented as such), open a PR — these rules are living. The plan doc that originated them is archived at [`docs/project/archive/software-architecture-improvement-plan.md`](../project/archive/software-architecture-improvement-plan.md) for historical context.
