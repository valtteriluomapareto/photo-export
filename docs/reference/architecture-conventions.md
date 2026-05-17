# Architecture Conventions

This document is the living reference for the patterns and contracts established by the architecture refactor (Phases 0–7, shipped May 2026). Read it before:

- Adding a new export entry point (`start*` method or a `runExport(...)` call site).
- Adding a new export placement kind, variant, or record store.
- Extracting a new collaborator out of `ExportManager`.
- Adding a new `@Published` property that AutoSync (or the toolbar) observes.
- Changing the cancellation seam or actor isolation of any collaborator.

The original design rationale lives in [`docs/project/archive/software-architecture-improvement-plan.md`](../project/archive/software-architecture-improvement-plan.md). This file extracts the load-bearing rules from that plan so they survive after the plan is archived.

For the high-level type map (what each collaborator does), see [`website/src/content/docs/architecture.md`](../../website/src/content/docs/architecture.md) — that page is the friendly entry point. This document covers the *contracts* the types must follow.

## The architecture in one paragraph

`ExportManager` is the façade. It owns the export-run lifecycle, the cancellation seam (`generation`), the AutoSync-observable `@Published` properties, and `UserDefaults`-backed user choices (`versionSelection`). Real work is delegated to extracted collaborators: `ExportQueueCoordinator` runs the drain loop and owns queue state; `VariantExporter` writes each variant; `ImportCoordinator` runs the Import Existing Backup flow; `ExportDestinationResolver` allocates filenames; `ExportJobPlanner` plans jobs; `RecordStoreRouter` dispatches record reads/writes by placement kind; `ExportCompletionPolicy` decides what counts as "done". Each `@MainActor` collaborator holds a `Host` protocol that points back to the manager for the cancellation seam and a few UI-state mutations the manager still owns.

## Cross-cutting contracts

These three contracts bind every collaborator. Break one and you break either the AutoSync seam, cancellation safety, or the threading model.

### 1. Cancellation contract

**Storage**: `var generation: Int` lives on `ExportManager` (see [`ExportManager.swift`](../../photo-export/Managers/ExportManager.swift) — search for `private(set) var generation`).

**Helpers** (both `internal` on `ExportManager`):

```swift
func isCurrent(_ gen: Int) -> Bool
func throwIfCancelledOrStale(_ gen: Int) throws
```

**Rule**: every async task that mutates state captures `let gen = generation` *synchronously* before the first `await`, then uses `[weak self]` + `guard self.isCurrent(gen) else { return }` at every checkpoint. Throwing paths use `try throwIfCancelledOrStale(gen)`.

**Which methods bump generation** (and so cancel anything running under the old gen):

- `cancelAndClear()`
- `interruptForDestinationUnavailable()`
- `supersedeForManualRun()`
- `cancelImport()`

**Which method does NOT bump generation**:

- `clearPending()` — drops queued jobs only. In-flight work that started before `clearPending` keeps its `gen` and finishes normally. If you need to cancel mid-flight, call `cancelAndClear` instead.

**Collaborator seam**: each extracted collaborator's `Host` protocol exposes `isCurrent(_:)` (and for `ImportCoordinator`, `bumpGeneration()`) as callbacks back to the manager. This is a deferred follow-up — the storage was planned to move into `ExportQueueCoordinator` in Phase 5 but the Host-protocol shape proved load-bearing and the move is tracked in [issue #67](https://github.com/valtteriluomapareto/photo-export/issues/67).

### 2. Actor isolation policy

| Type kind | Isolation | Examples |
| --- | --- | --- |
| Stateful collaborator with `@Published` state | `@MainActor final class` | `ExportManager`, `ExportQueueCoordinator`, `VariantExporter`, `ImportCoordinator`, `RecordStoreRouter`, `PhotoLibraryManager`, `JSONLRecordFile` |
| Pure helper / policy (value-typed, no I/O state) | plain `struct` or `enum`, `Sendable` where it crosses tasks | `ExportJobPlanner`, `ExportCompletionPolicy`, `ExportDestinationResolver`, `ExportFilenamePolicy`, `ExportPathPolicy`, `ExportPlacementResolver`, `ResourceSelection` |
| Concurrent state holder | `actor` | `CollectionCountCache` |
| Heavy work that must hop off MainActor | `nonisolated async` on protocol seam | `PhotoLibraryService`, `MediaRenderer`, `AssetResourceWriter`, `FileSystemService` |

Rules:

- Do **not** add `@MainActor` to pure helpers reflexively. If a type holds no state and crosses task boundaries, make it `Sendable` and leave the isolation off.
- Do **not** promote a collaborator to `actor` to "fix" concurrency unless you have a measurement showing main-actor contention. `@MainActor` is the established pattern because `@Published` + SwiftUI binding works there without `await` ceremony.
- Each `@MainActor final class` collaborator should carry a one-line comment at its top declaring its isolation. (Stops future contributors from silently making it `nonisolated`.)

### 3. AutoSync seam preservation

**Invariant**: `ExportManager+AutoSyncConformance.swift` stays untouched. AutoSync reads the manager via the conformance file's declared properties; if you need a new bit of state AutoSync should see, add it to the manager (or sink it from a coordinator onto the manager — see below), then expose it through the conformance.

**Publisher surface**:

```swift
var exportRunStatePublisher: AnyPublisher<ExportRunState, Never> {
  Publishers.CombineLatest3($activeRunContext, $isRunning, $queueCount)
    .map { ExportRunState(activeRunContext: $0, isRunning: $1, queueCount: $2) }
    .eraseToAnyPublisher()
}
```

The `CombineLatest3` over `($activeRunContext, $isRunning, $queueCount)` is the AutoSync contract. Adding new state to the triple is a deliberate, audited change — re-record the [`AutoSyncSeamCharacterizationTests`](../../photo-exportTests/AutoSyncSeamCharacterizationTests.swift) snapshots only after verifying the new emission sequence is correct.

**Mirror pattern** (when state lives on a coordinator but AutoSync needs to see it via the manager):

```swift
// On the coordinator:
@Published private(set) var isRunning: Bool = false
@Published private(set) var queueCount: Int = 0

// On ExportManager.init, after collaborators are wired up:
queueCoordinator.$isRunning
  .sink { [weak self] in self?.isRunning = $0 }
  .store(in: &cancellables)
queueCoordinator.$queueCount
  .sink { [weak self] in self?.queueCount = $0 }
  .store(in: &cancellables)
```

Both objects are `@MainActor` and `@Published`'s `willSet` is synchronous, so the AutoSync `CombineLatest3` observes consistent state. The synchrony pin is [`ExportQueueStateSnapshotTests.teardownQueue_synchronouslyClearsManagerMirrors`](../../photo-exportTests/ExportQueueStateSnapshotTests.swift) — if you make a mirror async, that test fails.

## Host protocol pattern

When you extract a new collaborator from `ExportManager`, expose what you need from the manager via a narrow `Host` protocol declared on the collaborator. Example from [`ExportQueueCoordinator.swift`](../../photo-export/Managers/ExportQueueCoordinator.swift):

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

On `ExportManager`, the collaborator is stored as an implicitly-unwrapped optional (IUO) and assigned after `super.init` / `self` is available:

```swift
private(set) var queueCoordinator: ExportQueueCoordinator!

init(...) {
  // ...store dependencies...
  super.init()
  queueCoordinator = ExportQueueCoordinator(host: self)
  // ...wire sinks, etc.
}
```

The conformance is in a small extension file ([`ExportManager+AutoSyncConformance.swift`](../../photo-export/Managers/ExportManager+AutoSyncConformance.swift)) — empty declaration, just makes the manager conform to the Host protocols.

Rules:

- Keep the Host protocol *narrow* — only the seam the collaborator actually needs. Adding methods later is cheap; pruning surface area later is hard.
- `weak var host: Host?` (avoid retain cycles).
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
- **Do not write through to coordinator-owned state from `ExportManager` directly.** Mutating `queueCoordinator.pendingJobs` from outside the coordinator breaks the Host-protocol invariant. Go through a method the coordinator publishes.
- **Do not add new `@Published` properties to `ExportManager` for state that conceptually lives on a coordinator.** Add the `@Published` to the coordinator and sink it onto the manager via the mirror pattern.

## Canonical `start*` entry-point shape

Every fire-and-forget export entry point on `ExportManager` follows this shape. Use it as a template when adding a new one. Source: [`ExportManager.swift`](../../photo-export/Managers/ExportManager.swift) `startExportMonth` (the simplest of the family).

```swift
func startExportMonth(year: Int, month: Int) {
  // 1. Block-on-conflict guards (synchronous, return early).
  guard !isImporting else {
    logger.warning("startExportMonth ignored: import in progress")
    return
  }
  guard canExportTimeline else {
    logger.error("startExportMonth ignored: timeline store state=...")
    return
  }

  // 2. Snapshot user-mutable state synchronously.
  let selection = versionSelection

  // 3. Clear any prior UI messages.
  clearEmptyRunMessage()
  clearQueueWarningMessage()

  // 4. Reset progress counters ONLY when the queue is truly idle.
  //    "Paused with pending jobs" satisfies !isRunning && !isProcessing but is NOT idle —
  //    resetting there detaches done/total from pendingJobs.count.
  if !isRunning && !isProcessing && pendingJobs.isEmpty { resetProgressCounters() }

  // 5. Capture generation synchronously before the first await.
  let gen = generation

  // 6. Fire-and-forget Task that re-checks isCurrent at every hop.
  Task { [weak self] in
    guard let self, self.isCurrent(gen) else { return }
    do {
      let outcome = try await enqueueMonth(
        year: year, month: month, selection: selection, generation: gen)
      guard self.isCurrent(gen) else { return }
      switch outcome {
      case .enqueued, .unauthorized:
        break
      case .alreadyComplete:
        setEmptyRunMessage("This month is already exported.")
      }
      processQueueIfNeeded()
    } catch {
      logger.error("Failed to enqueue month export: ...")
    }
  }
}
```

Bulk dispatchers (`startExportAll`, `startExportTimelineSelection`, `startExportCollectionsSelection`) follow the same shape but loop over multiple `enqueueX(...)` calls and set `isEnqueueingAll = true` for the duration; the post-merge consolidation of the bulk-loop body is tracked in [issue #67](https://github.com/valtteriluomapareto/photo-export/issues/67) item 5.

## Regression gates

These tests are wired so they fire when a load-bearing invariant breaks. Do not "fix" them by re-recording — audit first.

| Test | Fires when… | What to do |
| --- | --- | --- |
| [`AutoSyncSeamCharacterizationTests`](../../photo-exportTests/AutoSyncSeamCharacterizationTests.swift) | The emission sequence on `exportRunStatePublisher`, `isImportingPublisher`, or `completedRunsPublisher` changes | Audit. Re-record snapshots only after confirming the new sequence is what AutoSync should see. |
| [`ExportQueueStateSnapshotTests.teardownQueue_synchronouslyClearsManagerMirrors`](../../photo-exportTests/ExportQueueStateSnapshotTests.swift) | A coordinator → manager mirror becomes async (`.receive(on:)`, `.async`, etc.) | Re-add the synchronous sink. The AutoSync `CombineLatest3` depends on synchrony for consistent reads. |
| `ExportQueueStateSnapshotTests.pauseResumeCancelStateSnapshot_canonicalTransitions` | Pause/resume/cancel transitions on `isRunning`/`queueCount`/`isPaused` change | Audit; this is the toolbar's contract. |
| [`ScreenshotPhotoLibraryServiceOverridesTests`](../../photo-exportTests/ScreenshotPhotoLibraryServiceOverridesTests.swift) | A `PhotoLibraryService` method is added without a matching `ScreenshotPhotoLibraryService` override | Add the override on the screenshot service AND a new test in this file in the same PR. The structural fix (drop inheritance entirely) is a deferred follow-up. |
| [`ImportIdempotencyTests`](../../photo-exportTests/ImportIdempotencyTests.swift) | The import flow loses idempotency on retry | Audit. Two consecutive `bulkImport(records:)` calls must not double-write. |
| `ExportManagerRunExportTests.autoSyncRunFilterAlreadyExportedBeforeRetryCheck` | The `isExported` predicate runs *after* the retry-gate (instead of before) | Restore the order. `isExported` must run first so already-done assets are not blocked by the retry-gate. |

## Extension recipes

### Adding a new `start*` entry point

1. Add the public method on `ExportManager` following the canonical shape above.
2. If it routes through an existing `enqueueX(...)` helper, you are done — record-store dispatch, dedup, queue handoff are already correct.
3. If it needs a new `enqueueX(...)` helper, write that private method too. It should be `async throws`, take `selection: ExportVersionSelection` and `generation: Int`, call `try throwIfCancelledOrStale(gen)` after the PhotoKit fetch, and end with `queueCoordinator.enqueue(jobs)` (NOT a direct `pendingJobs.append`).
4. Add a unit test that asserts the generation guard fires when the run is cancelled mid-await.

### Adding a new export placement kind

Touch points:

1. **`ExportPlacement.Kind`** ([Models](../../photo-export/Models/ExportPlacement.swift)) — add the case.
2. **`RecordStoreRouter`** ([Records](../../photo-export/Records/RecordStoreRouter.swift)) — extend each placement-kind `switch` (reads, writes, cancellation cleanup, reuse-source probe). All four switches must handle the new case; the closed enum will force you to.
3. **`ExportCompletionPolicy`** ([Records](../../photo-export/Records/ExportCompletionPolicy.swift)) — handle the new kind in `requiredVariants`, edited-fallback, and asset-complete checks.
4. **One resolver call site** (the place that constructs an `ExportPlacement` for this kind from a `LibrarySelection`). Typically `ExportPlacementResolver` or directly inside a `startExport*` entry point.

The `placement.kind` switch is *not* duplicated across `ExportManager` anymore — Phase 1 centralised it into `RecordStoreRouter`. If you find yourself writing `switch placement.kind` outside the router or the policy, you are probably bypassing a seam.

### Adding a new variant

`ExportVariant` is a closed enum. Adding a case forces compile errors at every switch that handles variants — work through them:

1. **`ExportVariant`** — add the case.
2. **`VariantExporter`** ([Managers](../../photo-export/Managers/VariantExporter.swift)) — handle it in the per-variant write switch.
3. **`ResourceSelection`** ([Managers](../../photo-export/Managers/ResourceSelection.swift)) — decide how the new variant selects bytes (`.resource | .render | .none` enum). New media kinds change `ResourceSelection`, not the call sites.
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

The refactor shipped with three deliberate deferrals tracked in [issue #67](https://github.com/valtteriluomapareto/photo-export/issues/67):

1. **PhotoLibrary composition refactor** — drop `ScreenshotPhotoLibraryService: PhotoLibraryManager` inheritance. Today protected by the 20-test override gate.
2. **Generation-counter ownership transfer** — move `var generation: Int` storage from `ExportManager` into `ExportQueueCoordinator` and delete the Host-protocol getters.
3. **Remaining Phase 7 folder moves** — `Destination/`, `Export/`, `App/` not yet created. New code should land in its eventual feature folder anyway (e.g., a new destination type goes alongside `ExportDestinationManager` — the future `Destination/` parent matters less than the conventions in this doc).

A second wave of follow-ups (items 4–5 in the same issue) covers AutoSync seam test growth and bulk-loop helper consolidation. Pick any up off the issue if you want to land one as an independent PR.

## Where to ask

If a contract above conflicts with the code (e.g. you find a `@Published` on the manager that should be a mirror, or a `Host` method that has become permanent and should be documented as such), open a PR — these rules are living. The plan doc that originated them is archived at [`docs/project/archive/software-architecture-improvement-plan.md`](../project/archive/software-architecture-improvement-plan.md) for historical context.
