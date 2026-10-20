# Architecture Conventions

## Do you need this doc?

**You need to read this if your change touches any of the following:** `ExportManager` or any of its collaborators (`ExportQueueCoordinator`, `VariantExporter`, `ImportCoordinator`); the AutoSync seam (`ExportManager+AutoSyncConformance.swift` or `exportRunStatePublisher` consumers); the record stores or `RecordStoreRouter`; `ExportPlacement.Kind` or `ExportVariant`; the cancellation contract (`generation`, `isCurrent`, `throwIfCancelledOrStale`); or you're extracting a new collaborator.

**You can skip this if your change is** a typo, a copy tweak, a website edit, a view-only change that doesn't touch the export pipeline, or a new test that doesn't modify the system under test.

The patterns and contracts below were established by the May 2026 architecture refactor (PR #68; Phases 0–6 + partial 7). The original design rationale lives in [`docs/project/archive/software-architecture-improvement-plan.md`](../project/archive/software-architecture-improvement-plan.md). For the friendly high-level type map, see [`website/src/content/docs/architecture.md`](../../website/src/content/docs/architecture.md). This doc covers the *contracts* — what the types must follow.

## The architecture in one paragraph

`ExportManager` is the façade. It owns the export-run lifecycle, the AutoSync-observable `@Published` properties, and `UserDefaults`-backed user choices (`versionSelection`). Real work is delegated to extracted collaborators: `ExportQueueCoordinator` runs the drain loop, owns queue state, and owns the Phase-0 cancellation seam (`generation`, `isCurrent`, `throwIfCancelledOrStale`, `bumpGeneration`); `VariantExporter` writes each variant; `ImportCoordinator` runs the Import Existing Backup flow; `ExportDestinationResolver` allocates filenames; `ExportJobPlanner` plans jobs; `RecordStoreRouter` dispatches record reads/writes by placement kind; `ExportCompletionPolicy` decides what counts as "done". `VariantExporter` and `ImportCoordinator` hold a direct weak reference to `ExportQueueCoordinator` for the seam; each collaborator also holds a narrow `Host` protocol back to the manager for the remaining UI-state mutations.

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
- `cancelAutoSyncRun()` (same path; only while an AutoSync-sourced run is active). `AutoSyncManager.setEnabled(false)` calls it after the reducer is disabled, so turning Auto Export off stops the automatic run in progress; manual exports keep running.
- `cancelImport()` (on `ImportCoordinator`, via the injected `queueCoordinator` reference)
- Destination or history-save failure teardown from `performExport` (through the same manager teardown helper)

**Which method does NOT bump generation**:

- `clearPending()` — drops queued jobs only. In-flight work that started before `clearPending` keeps its `gen` and finishes normally. If you need to cancel mid-flight, call `cancelAndClear` instead.

**Collaborator seam**: `VariantExporter` and `ImportCoordinator` hold a direct (weak) reference to `ExportQueueCoordinator` for the cancellation helpers; their `Host` protocols no longer carry `isCurrent`, `throwIfCancelledOrStale`, `generation`, or `bumpGeneration` (issue #67 item 2 landed in May 2026). The coordinator's own dispatch loop reads its own `generation` / `isCurrent` directly. New collaborators that need the seam should inject `ExportQueueCoordinator` the same way, not route through `Host`.

### Preview content ownership

Thumbnail and detail tasks use asset ID plus the existing
`PhotoLibraryManager.thumbnailContentRevision(for:)` value, not broad `libraryRevision`.
Known content edits invalidate only affected IDs; unknown changes and bounded-tracking overflow
use the existing global fallback. Placement/history changes do not change preview identity.
The detail loader checks its captured revision predicate before installing a request and before
publishing success or error, in addition to UUID and Task cancellation guards. This rejects a
superseded response even before SwiftUI starts the replacement task. Same-asset replacement
retains the displayed image while loading; other selected IDs hide prior content immediately.
A current failure clears retained bytes to expose the existing error message. Grid descriptor
refresh remains owned by `MonthViewModel` and its parent selection binding. The model emits a
payloadless selection update synchronously after each owned visible batch or successful complete
snapshot. Grids derive the current descriptor from the live binding inside `onReceive`; they do
not queue binding writes through `onChange`/task identities. A completed snapshot proves absence
(first survivor or empty clears); unfinished enumeration preserves a choice still awaiting its
batch. Failed or obsolete refreshes do not emit a selection update.

### Import outcome ownership

`ImportCoordinator` owns transient `isImporting`, `importStage` and `importError`; the manager
mirrors them with synchronous sinks. Writable `importResult` remains a Host callback. A private
operation UUID owns UI outcomes separately from the queue generation: destination teardown may
invalidate the generation without cancelling the task. Progress/results/errors require current
UUID and generation; deferred stale cleanup may settle only its own UUID. Cancel invalidates UUID
before clearing state. Publish error/report/stage before setting activity false, and perform no
old-operation state writes after that publication. Scope release still waits for physical work.
Cancelling the import reaches the detached backup scan, which stops before its next directory
entry, file entry or `videos/` check.
Retry preserves timeline-only compatibility when the collection store is unconfigured, but waits
for recovery if either history store has failed. Scanner matching error propagation is unchanged.

### Final file commit boundary

Every byte-producing attempt (PhotoKit resource, render, HEIC conversion or reuse)
owns a short hidden UUID stage adjacent to its final destination. HEIC source bytes
use a side-file derived from that attempt's stage. Physical producers may outlive
Task cancellation: cleanup removes only their own stages, producer errors recheck
generation before reaching outcome recording, and HEIC materialization rechecks before
starting conversion. Callers also recheck after exporter awaits and before failure/fallback
mutations. The legacy fixed `.tmp` sweep remains for older builds; unique crash leftovers
are not automatically scavenged. Staging paths never determine final filenames.

The final move never replaces an existing file. `FileIOService.moveItemAtomically` refuses an
existing destination with `Export` code 2 ("Destination already exists"), which classifies as a
destination collision with the `Export:2` error signature (persisted in retry state for Auto
Export runs); the variant fails and the existing bytes stay. The check precedes
`FileManager.moveItem`, so a file created between the two steps is not covered by it (#326).

`VariantExporter` checks generation immediately before admitting the final atomic move.
After admission, a short-lived task owns the physical move, timestamps, record acknowledgement,
and staging cleanup. A successful move is acknowledged to its captured logical destination even
if the run becomes stale. `RecordStoreRouter` captures that store's existing JSONL owner; each
store parks its latest snapshot only when switching away, merges the completed variant, and
retains write failures through the existing non-destructive persistence recovery path. A corrupt
load keeps its alert and bytes intact; only the known completion delta is deferred until a valid
load or explicit reset. Collection acknowledgements restore missing placement metadata without
replacing newer metadata. No persisted schema changes or crash-atomicity guarantee is implied.

Queue teardown remains synchronous and does not discard this task. Replacement jobs await its
barrier before their initial record flush, history reads, or filename allocation, then recheck
generation and persistence health. Commit-owned staging cleanup finishes before the barrier is
released. Ordinary generation checks resume immediately afterwards, before additional variants,
fallback bookkeeping, or UI changes. Security-scoped access remains held by the original export
until the complete bounded commit finishes.

### 2. Actor isolation policy

Reuse-source filesystem copies run on an explicit utility Dispatch worker through the
Sendable filesystem seam. Cancellation waits for physical IO to finish before releasing
security-scoped access, then rejects stale success/errors before fallback or commit.
Each reuse attempt owns a short hidden adjacent staging file through fallback and the
existing no-overwrite move; late cleanup cannot remove a replacement attempt's temp.
Normal/error/cancel exits attempt to remove their stage. A process crash, unavailable
volume, or removal failure can leave a hidden unique stage; automatic scavenging is not
implemented. Legacy fixed
`.tmp` cleanup remains immediate. Queue identifier and render-activity cleanup must check
the owning generation before changing UI state.

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
- Await detached work through `runDetached(priority:operation:)` (`Helpers/RunDetached.swift`), not `Task.detached { … }.value`. Awaiting `.value` never cancels the detached task, so its own cancellation checks never fire. The helper forwards the caller's cancellation and still waits for the operation to finish.

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

Both objects are `@MainActor` and `@Published`'s `willSet` is synchronous, so the AutoSync `CombineLatest4` observes consistent state. The synchrony pin is [`ExportQueueStateSnapshotTests.teardownQueue_synchronouslyClearsManagerMirrors`](../../photo-exportTests/ExportQueueStateSnapshotTests.swift) — if you make a mirror async (`.receive(on:)`, `MainActor.run`, etc.) that test fails.

### AutoSync dirty-work acknowledgement

`AutoSyncReducer` captures a `RunDirtyBoundary` (run context, stable destination ID, and scopes changed since start). The fan-out sends `exportRunStarted` before each scope's `await runExport`; synchronous `exportRunStateChanged` observations capture manual runs and never reset an existing boundary for the same run ID. Keep the boundary across the idle publication: the completion summary arrives afterward.

Every export-relevant Photos event invalidates the affected scopes, including repeated changes to the same asset, changes while full reconciliation is already pending, and collection-only changes for album scopes. Successful completion acknowledges only covered, selected scopes that have not changed since the matching run began. Unknown, failed, or destination-mismatched completions cannot clear pending work. The boundary is transient: the existing persisted dirty state remains authoritative after restart, so no persistence migration or counter is needed.

### AutoSync destination ownership

Each AutoSync fan-out captures the stable destination ID and a transient task identity.
Completion events carry the originating destination and are accepted only for the current
matching run boundary. Every destination identity change cancels the old fan-out and invalidates
its boundary. Returning to the same destination does not revive an abandoned run.

Task-handle and diagnostic-journal cleanup must verify ownership before clearing state.
An old task exiting after a replacement starts must leave the replacement's handle and journal intact.
These guards are transient; persisted run-summary, retry, and dirty-state formats stay unchanged.

### AutoSync retry lifecycle

Retry eligibility is per destination, placement, asset, and variant. Enqueue checks only missing variants; execution checks again immediately before each variant attempt, including an edited export's original fallback. Manual runs bypass automatic backoff. Keep the full required-variant set for filename pairing and completion policy even when only one variant is eligible.

The reducer schedules the earliest automatically retryable entry in enabled scopes. Firing consumes the exact entry in transient state so a removed asset or deselected variant cannot cause a zero-delay loop. Changed failures and settings can make work eligible again. A due retry waits for manual work, imports, and the entire current automatic fan-out; switching destinations or disabling Auto Export cancels its ownership.

Matched completion prunes only sparse retry tuples that `AutoSyncExportRunning.isRetryVariantDone` confirms in a healthy, fully flushed record store. Legacy manual runs use their idle transition as a cleanup opportunity; cancellation can also publish idle, so unacknowledged writes must keep retry entries intact. The JSONL layer tracks submitted and flushed revisions in memory so an append during an async flush cannot be mistaken for an acknowledged write. A completed summary alone cannot prove that every failed variant was selected or saved. Existing retry JSON and record formats remain unchanged, and unknown scope or variant keys are preserved.

### AutoSync dirty-state persistence acknowledgement

The effect runner saves a destination's dirty snapshot before writing its advisory
`lastDurablyRecordedToken`. A failed dirty save blocks that destination's token writes
across later events, including events that produce no export work. Only a successful
dirty-state save for the same stable destination releases the block. Other destinations
continue independently; existing export and debounce effects still run.

While persistence is blocked, the reducer's latest snapshot remains authoritative in
memory, including an empty snapshot after valid completion. Returning to that destination
must not replace it with older disk state. A later existing save recovers persistence;
there is no additional retry timer or deferred-token queue.

This guarantee applies to per-destination acknowledgement, not PhotoKit fetching. The
PhotoKit adapter independently saves the global fetch cursor before emitting a change.
Per-destination tokens are currently loaded but do not drive fetching. Unsaved snapshots
and the failure block do not survive process exit; an enabled, eligible app launch uses
the existing full-scope reconciliation. Persisted file formats remain unchanged.

Dirty/retry metadata loads throw on corrupt or inaccessible files; only missing files
are empty. Uncertain dirty loads retain known reducer state and mark all recognized
scopes for full reconciliation, blocked from acknowledgement until that snapshot saves.
Every metadata save preflights the source. Readable invalid bytes are copied to a unique
sibling before atomic replacement; an unreadable source or failed preservation prevents
replacement. The source stays present if the recovery write fails.

Retry recovery uses the existing reducer cache. Restored raw scope/asset/variant keys
are unioned with known memory, including unknown keys. For the same category/signature,
retain maximum known attempts, earliest first failure, latest last failure, and the
latest known/computed deadline. Different failures prefer the latest timestamp, with
memory winning ties. Deadlines use failure time, never recovery time, so merging is
idempotent. Exact inaccessible-interval counts are not reconstructed. Retry removals
are published only after saving; unavailable baselines defer cleanup. Recovery retries
on existing run starts, reconnection, and retry mutation, without a new timer or journal.

### Record reconciliation ownership

Both record stores snapshot reconciliation candidates on MainActor, await file checks
through `ReconciliationFileChecking` in a detached worker, then apply one synchronous
prune batch. The production checker follows valid file links, returns missing only for
child-path ENOENT/ENOTDIR, and throws for other lookup/type errors. Invalid location
metadata rejects the batch. Timeline paths still use year/month plus each variant's
persisted subfolder, preserving mixed-layout history. A detached readable-root check
runs after the file probes, immediately before returning the proposed batch.

Each store owns a private immediate reconciliation revision, separate from its
coalesced `mutationCounter`. Configuration (including nil and same-ID reloads), accepted
record/placement mutations, reset and a new reconciliation invalidate older probes.
Task cancellation stops new probes and the root check; a probe in flight finishes first.
After all physical probes finish, the store checks caller ownership, Task cancellation,
readiness and the captured revision before **any** deletion or error propagation.
Workers return a Result so a stale thrown probe cannot surface an obsolete import error.
A still-owned error rejects the entire affected store's prune batch. Reconciliation's own appends
advance the revision but must not interrupt the rest of that synchronous batch.

`ImportCoordinator` supplies its captured queue-generation predicate to both stores;
checking only after the awaited store call is too late to protect persisted history.
An invalid snapshot returns zero without changes. The whole batch is discarded even
when an unrelated record changed; a later import can reconcile again. No ownership
metadata is persisted. Physical probes finish before the import releases scoped access.
Scanner enumeration/type errors within recognized backup paths throw before bulk import
or reconciliation; genuinely absent optional videos folders are accepted. A later failure
can follow successful matched imports or reconciliation of the other store: there is no
rollback across stores or import stages.

## Host protocol pattern

> The cancellation-seam methods (`isCurrent` / `throwIfCancelledOrStale` / `generation` / `bumpGeneration`) are no longer on any Host protocol — that move landed in issue #67 item 2. Collaborators that need the seam inject `ExportQueueCoordinator` directly. The remaining Host methods are UI-state mirrors and dependency forwarders, all stable.

When you extract a new collaborator from `ExportManager`, expose what you need from the manager via a narrow `@MainActor` `Host` protocol declared on the collaborator. The `@MainActor` annotation on the protocol itself is load-bearing — a non-MainActor Host would force `await` at every call site and break the mirror-sinks synchrony.

Example from [`ExportQueueCoordinator.swift`](../../photo-export/Export/ExportQueueCoordinator.swift):

```swift
@MainActor
final class ExportQueueCoordinator: ObservableObject {
  @MainActor
  protocol Host: AnyObject {
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

Every fire-and-forget export entry point on `ExportManager` uses `canStartExport(in:logTag:)` for import/store admission and `prepareExport(selectionOverride:bulk:)` for shared synchronous preparation. Keep entry-specific exclusive-bulk and empty-input checks between them; rejected starts must preserve their existing message and counter behavior.

```text
func startExportX(...) {
  // 1. canStartExport: import conflict, then the correct timeline/collection store.
  // 2. Entry-specific exclusive-bulk and empty-input checks, in their existing order.
  // 3. prepareExport: capture settings, clear messages, publish the optional bulk flag,
  //    reset counters only when truly idle, then capture generation synchronously.
  let (settings, gen) = prepareExport(...)
  // 4. Track the preparation task; pass settings intact to enqueueX(... generation:).
  //    Re-check isCurrent(gen) after every await. Process the queue on success.
  //    On throw, single-scope starts call handleScanFailure: record the preparation
  //    failure, log, and resolve an active run as .failed when nothing is queued.
}
```

Favorites is the only single-scope start AutoSync runs through `runExport`; the shared failure rule keeps the others safe if one is ever routed there.

`ExportSettingsSnapshot` owns the capture policy for selection, Live Photo paired-video export, and video layout. Add future click-time settings to that value and its capture initializer, then consume them where needed; start methods, enqueue helpers and planners transport the same value. `ExportJob` stores it once, with computed compatibility accessors. Only the manager-reading initializer is `@MainActor`; scalar construction and the value itself remain pure. A run-context selection override must never mutate the toolbar selection. HEIC-to-JPEG conversion deliberately remains live at planning/write time and is excluded from this snapshot.

Preparation has no awaits. Capture settings before publishing messages or the bulk flag, and capture generation before dispatching any asynchronous work. The idle check is `!isRunning && !isProcessing && pendingJobs.isEmpty`: paused pending work accumulates counters. Never move preparation ahead of entry-specific rejection checks or combine timeline and collection readiness.

Bulk dispatchers (`startExportAll`, `startExportTimelineSelection`, `startExportCollectionsSelection`, plus the shared `enqueueBulkAlbumExport` driver behind `startExportAllAlbums` / `startExportAllSharedAlbums` / `startExportFolder` / `startExportAlbums`) follow the same shape but loop over multiple `enqueueX(...)` calls and set `isEnqueueingAll = true` for the duration. The four outer-Task scaffoldings share a private helper, `runBulkExportTask(...)`, which owns the `Task { [weak self] in }` wrapping, the `isEnqueueingAll = false` teardown only for the owning generation, the success finalize, and the partial-failure recovery on throw. The inner per-item loop shares `runBulkEnqueueLoop(...)` so multi-bucket dispatchers (years + months for timeline; favorites + albums + shared for collections) can chain passes while accumulating into a single `BulkExportTotals`.

## Manual export feedback

Manual terminal feedback lives on `ExportProgressState.manualSummary`, not on the
AutoSync run publications. Legacy actions keep their nil `activeRunContext` and do not
emit new `completedRunsPublisher` values. Capture manual ownership before run-context
finalization, and wait for all current-generation preparation handles as well as queue
drain before publishing the outcome. A temporarily empty queue can still have a month
or album scan outstanding. Private feedback totals survive that interval independently
of the legacy queue counters.

Manual failure counts are placement jobs: compare failure signals around each serialized,
owned export and credit the job only after its post-export persistence flush. Multiple
variant failures count once there; `ExportRunSummary.failedCount` retains its existing
per-variant meaning. Latch scan/authorization/cleared-work reasons across appended actions.
Persistence teardown snapshots a stopped outcome before clearing ownership. Cancellation,
supersession and destination interruption clear feedback. Dismissal and success expiry
retire the terminal row without resetting coordinator counters or revealing old N/N UI.

Destination no-space/permission failures return their original private job-stop signal
after one failure record. The post-job history flush precedes teardown; a flush failure
uses the existing persistence recovery message. Renderer/converter wrapping preserves
these hard destination errors after checking generation; source-side reuse copy failures
retain their PhotoKit fallback. Native AVFoundation disk-full uses the same category.
Stop summaries snapshot totals before teardown and account for the current job once,
since the coordinator's normal completion increment is suppressed by the generation
change. Completion publication/awaiter resumption follows teardown. Manual feedback
counts failed jobs; awaitable summaries retain per-variant failure details. The pending
queue is cleared and preparations invalidated; unattempted history remains eligible for
a fresh explicit run. Auto Export keeps its existing source visibility and scope fan-out
stop on a failed result.

## Destination identity

Every per-destination store — both record stores (`ExportRecords/<id>/`), the AutoSync state
(`AutoSync/destinations/<id>/`), the current-run journal, and the safety-confirmation store — is
keyed on a single **stable logical destination id**. This is a load-bearing contract: it is the
root-cause fix for #127 (a network-share remount re-exporting everything).

- **Owner.** `ExportDestinationManager` owns the id. It is persisted in `UserDefaults`
  (`ExportDestinationStableId`) beside the security-scoped bookmark, **seeded** once from the
  destination fingerprint the first time a destination validates, then **reused verbatim** for
  as long as the stored bookmark resolves to the same folder. It is refreshed only when the user
  explicitly selects a *different* folder (decided by **bookmark/file-identity equivalence**, not
  path — the path is the drift-prone signal). `clearSelection()` drops it.
- **Unclear picks.** When the stored bookmark can't be compared with a pick, the user answers
  (`AmbiguousFolderPrompt`). "Same Folder" keeps the id and then calls
  `onAmbiguousSameFolderChosen` synchronously, which runs Import Existing Backup with
  `requiringPreviousBackup`: if the history has completed files and none of them are in the
  folder, nothing is imported or pruned, and `previousBackupMissing` holds exports
  (`isImportingPublisher` stays true, manual starts are refused) until the user re-picks with
  `selectFolderKeepingHistory()` — which applies `.sameDestination`, because the stored bookmark
  now points at the rejected folder — or starts a new history, or the destination changes. The
  import starts in the same main-actor turn as the identity publish, so AutoSync waits for it,
  and the debounce it cancels keeps its reason (photos-change reasons excepted; the resume hook's
  dirty-state check covers those).
- **One atomic identity value.** The manager publishes `@Published identity: DestinationIdentity`
  (stable id + advisory fingerprint) as **one** value — not two `@Published` fields. The old
  `destinationFingerprint` + `destinationId` pair-write is **retired**: it had a mid-emission gap
  where a subscriber could read a new fingerprint with the stale id, and the documented "read
  `fingerprint?.id`" workaround inverted the moment the stable id diverged from the fingerprint
  id. Do not reintroduce a second `@Published` identity field; thread `DestinationIdentity`
  through instead. `destinationId` remains a read-through of `identity.stableId`.
- **Unavailable invariant.** While the destination is unavailable (`fingerprint == nil` /
  `isAvailable == false`), the *published active* stable id is `nil` even though the *persisted*
  id is kept privately for reuse. Publishing the persisted id while unavailable would make
  `AppLifecycleCoordinator.apply` see an unchanged id on unplug and skip
  `interruptForDestinationUnavailable`.
- **The fingerprint is advisory.** `DestinationFingerprint` survives, but only as the
  identity-*confidence* signal for the AutoSync safety gate (`identityConfidence`). It is **not**
  the keying id and may drift across a network-share remount while the stable id holds. The
  snapshot `Equatable` deliberately still carries the (drifting) fingerprint so a metadata refresh
  flows through to subscribers; **stable-id equality**, not struct equality, is the
  "same destination, don't re-key" line of defense (`DestinationIdentitySnapshot.id` /
  `DestinationSnapshot.id` / the `removeDuplicates` filters in `AppLifecycleCoordinator.attach`
  and `DestinationSafetyMonitor.attach`).
- **Lint guard.** Keying per-destination state on `fingerprint?.id` is forbidden outside the
  fingerprint module and enforced by [`scripts/ci/check-fingerprint-id-keying.sh`](../../scripts/ci/check-fingerprint-id-keying.sh)
  (run in CI after the regression-gate check). A behavioral test can only cover the paths it
  exercises; this grep proves the *absence* of a future consumer that re-derives the key from the
  fingerprint. The lone legitimate `fingerprint.id` read (turning a freshly computed fingerprint
  into the *seed* for a brand-new stable id) is tagged `// keying-id-ok`.

## Regression gates

These tests are wired so they fire when a load-bearing invariant breaks. Do not "fix" them by re-recording — audit first.

The gates are listed once, in [`scripts/ci/regression-gates.txt`](../../scripts/ci/regression-gates.txt). Its rows are suite gates (`struct Suite`), method gates (`func Suite.method`) and suite pins. A pin is a suite listed only because it holds method gates; it must exist, but it is not an additional behavioral gate.

CI checks the list twice:

- **Before the build,** [`scripts/ci/check-regression-gates.sh`](../../scripts/ci/check-regression-gates.sh) checks that every listed suite and method is still declared, and that this table and the gate lists in `AGENTS.md` and `CONTRIBUTING.md` name every listed gate. A rename fails with a clear "MISSING SYMBOL" message, and a doc missing a gate with "DOC DRIFT".
- **After the unit tests pass,** [`scripts/ci/check-regression-gates-ran.py`](../../scripts/ci/check-regression-gates-ran.py) reads the result bundle and checks that every gate ran and that each of its test cases and argument cases reports Passed. Skipped, failed, expected-failure, unknown or missing results fail the gate, and a suite gate also needs at least one test case.

If you rename, move, add or remove one of these tests, update the list file, this table, and the gate lists in `AGENTS.md` and `CONTRIBUTING.md` in the same PR. A gate that returns early without recording an issue still reports Passed; no result-bundle check can catch that, so write gate preconditions with `#require` rather than `guard … return`.

| Test | Fires when… | What to do |
| --- | --- | --- |
| [`AutoSyncSeamCharacterizationTests`](../../photo-exportTests/AutoSyncSeamCharacterizationTests.swift) | The emission sequence on `exportRunStatePublisher`, `isImportingPublisher`, or `completedRunsPublisher` changes | Audit. Re-record snapshots only after confirming the new sequence is what AutoSync should see. |
| `AutoSyncSeamCharacterizationTests.autoSyncRunYieldsCanonicalSequence` | An AutoSync run no longer publishes `[idle, autoSyncActive, idle]`, or its completed-run summary changes | Audit. `isAutoSyncActive` must follow the active run's source. |
| `AutoSyncSeamCharacterizationTests.manualExportSupersedingAutoSyncYieldsCanonicalSequence` | A manual export superseding an AutoSync run no longer publishes `[idle, autoSyncActive, idle, manualActive, idle]`, or the superseded run's summary changes | Audit. The superseded AutoSync run must end `.superseded` / `.supersededByManualRun`, and no state may be manual and AutoSync at once. |
| [`ExportQueueStateSnapshotTests.teardownQueue_synchronouslyClearsManagerMirrors`](../../photo-exportTests/ExportQueueStateSnapshotTests.swift) | A coordinator → manager mirror becomes async (`.receive(on:)`, `.async`, etc.) | Re-add the synchronous sink. The AutoSync `CombineLatest4` depends on synchrony for consistent reads. |
| `ExportQueueStateSnapshotTests.pauseResumeCancelStateSnapshot_canonicalTransitions` | Pause/resume/cancel transitions on `isRunning`/`queueCount`/`isPaused` change | Audit; this is the toolbar's contract. |
| [`ScreenshotPhotoLibraryServiceOverridesTests`](../../photo-exportTests/ScreenshotPhotoLibraryServiceOverridesTests.swift) | A `PhotoLibraryService` method on `ScreenshotPhotoLibraryService` returns production-PhotoKit-shaped empties instead of curated synthetic data | The tests pin every method's curated output. The "newly-added method silently inherits production" hole that prompted this gate's original wording is closed structurally — `ScreenshotPhotoLibraryService` is a peer conformance (no inheritance) since issue #67 item 1, so a new protocol method fails to compile until it has a real implementation. |
| [`ImportIdempotencyTests`](../../photo-exportTests/ImportIdempotencyTests.swift) | The import flow loses idempotency on retry | Audit. Two consecutive `startImport()` runs over the same backup tree must not double-write records. |
| `ExportManagerRunExportTests.autoSyncRunFilterAlreadyExportedBeforeRetryCheck` | The `isExported` predicate runs *after* the retry-gate (instead of before) | Restore the order. `isExported` must run first so already-done assets are not blocked by the retry-gate. |
| `AmbiguousSameFolderTests.sameFolderForUnclearPickHoldsAutoExportUntilHistoryCheckEnds` | An AutoSync run starts while the history check after "Same Folder" is still running, or no run follows it | The check must start in the same main-actor turn as the identity publish (`onAmbiguousSameFolderChosen`), and a debounce an import cancels must keep its reason for the resume hook. |
| [`CollectionBackupImportTests.importAdoptsAlbumHistorySoExportsWriteNothing`](../../photo-exportTests/CollectionBackupImportTests.swift) | Exporting an album, shared album or Favorites (manually or from Auto Export) after Import Existing Backup writes, copies or moves a file that was already in its folder | Audit the collection scan and folder matching (`BackupScanner+Collections`, `CollectionBackupPlanner`). Adopted placements must keep the id `ExportPlacementResolver` gives the collection. |
| `CollectionBackupImportTests.exportWipeImportRoundTripRestoresPlacements` | Importing a backup no longer restores the album placements an export created (same id and `relativePath`), including nested albums, a `_2` sibling, a lossy sanitized title, Favorites and a shared album | Keep folder names coming from `ExportPlacementResolver`; do not add naming rules to the import. |

## Extension recipes

### Adding a new `start*` entry point

1. Add the public method on `ExportManager` following the canonical shape above.
2. If it routes through an existing `enqueueX(...)` helper, you are done — record-store dispatch, dedup, queue handoff are already correct.
3. If it needs a new `enqueueX(...)` helper, write that private method too. It should be `async throws`, take `settings: ExportSettingsSnapshot` (passed intact) and `generation: Int`, call `try throwIfCancelledOrStale(gen)` after the PhotoKit fetch, and end with `queueCoordinator.enqueue(jobs)` (NOT a direct `pendingJobs.append`).
4. Add a unit test that asserts the generation guard fires when the run is cancelled mid-await.

### Adding a new export placement kind

`ExportPlacement.Kind` is a closed enum — the compiler will guide you to every switch that needs to handle the new case. Touch points:

1. **`ExportPlacement.Kind`** ([Models](../../photo-export/Models/ExportPlacement.swift)) — add the case. The `variantPolicy` switch on `Kind` itself (same file) also needs to handle the new case — required-variants policy lives there.
2. **`RecordStoreRouter`** ([Records](../../photo-export/Records/RecordStoreRouter.swift)) — audit every placement-kind switch, including reads, flushes, writes, captured final commits and cleanup. Closed-enum switches are compiler-enforced, but comparisons are not: explicitly audit `findReuseSource`'s `currentPlacement.kind != .timeline` check. If the new kind has its own retry scope, extend `AutoSyncRetryScopeKey`, its library-scope mapping, and every affected router scope switch/query too. Preserve captured final-commit ownership rather than routing late acknowledgments through mutable current state.
3. **`ExportCompletionPolicy`** ([Records](../../photo-export/Records/ExportCompletionPolicy.swift)) — handle the new kind in `requiredVariants`, edited-fallback, and asset-complete checks.
4. **`ExportPlacementResolver`** and any **`startExport*` entry point** that constructs an `ExportPlacement` for this kind from a `LibrarySelection`. If the new kind also needs a UI route, add corresponding cases to `LibrarySelection` and `PhotoFetchScope`.

The `placement.kind` switch is *not* duplicated across `ExportManager` anymore — Phase 1 centralized it into `RecordStoreRouter`. If you find yourself writing `switch placement.kind` outside the router or the policy, you are probably bypassing a seam.

### Adding a new variant

`ExportVariant` is a closed enum. Adding a case forces compile errors at every switch that handles variants — work through them:

1. **`ExportVariant`** — add the case.
2. **`VariantExporter`** ([Export](../../photo-export/Export/VariantExporter.swift)) — handle it in the per-variant write switch.
3. **`ResourceSelection.selectEditedProducer`** ([Export](../../photo-export/Export/ResourceSelection.swift)) — decide how the new variant selects bytes. The function returns an `EditedProducer` enum (`.resource | .render | .convertHEIC | .none`); extend that enum if the new variant needs an additional byte source. New media kinds change `ResourceSelection`, not the call sites.
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
3. ~~**Remaining Phase 7 folder moves**~~ — landed (issue #67 item 3, May 2026): `Destination/`, `Export/`, and `App/` exist; `Managers/` has been removed. The folder descriptions are a role map with key examples, not an exhaustive file inventory. `photo-export/ContentView.swift` remains at the source root with `AuthorizationView`, `YearRow` and `MonthRow`; feature views are grouped under `Views/`.

A second wave of follow-ups landed with item 4 (AutoSync seam test growth) and item 5 (`start*` bulk-loop helper consolidation). Item 6 (CI regression-gate symbol guard) is also done.

## Where to ask

If a contract above conflicts with the code (e.g. you find a `@Published` on the manager that should be a mirror, or a `Host` method that has become permanent and should be documented as such), open a PR — these rules are living. The plan doc that originated them is archived at [`docs/project/archive/software-architecture-improvement-plan.md`](../project/archive/software-architecture-improvement-plan.md) for historical context.
