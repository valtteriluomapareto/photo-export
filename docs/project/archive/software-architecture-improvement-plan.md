# Software Architecture Improvement Plan

Date: 2026-05-15
Revised: 2026-05-15 (added Cross-Cutting Contracts, Phase 0, and folded in multi-reviewer feedback: tightened Phase 0 spec, rescoped RecordStoreRouter, swapped Phase 2/3, split Phases 2/4/7)
Archived: 2026-05-17. Status: shipped. Phases 0–5 done; Phases 6 and 7 delivered in partial scope (composition-refactor + remaining folder moves deferred to follow-ups tracked in [issue #67](https://github.com/valtteriluomapareto/photo-export/issues/67)).

> **Reader note**: this plan is preserved as a decision record. The **living** reference for the contracts and patterns this plan established is [`docs/reference/architecture-conventions.md`](../../reference/architecture-conventions.md) — read that file when developing new features. This plan is useful for understanding *why* the contracts have the shape they do.

## Progress

Snapshot as of 2026-05-15. Update this table each time a phase lands.

| Phase | State | Landed | Notes |
|---|---|---|---|
| Phase 0: Characterization | Done | PR #53 | Generation `isCurrent(_:)` seam, AutoSync emission-sequence regression test, cancel-during-render tempfile cleanup test, Swift 6 Sendable audit ([`phase-0-sendable-audit.md`](phase-0-sendable-audit.md)) |
| Phase 1: Stabilize Export Boundaries | Done | PR #54 (lands with this commit) | `ExportCompletionPolicy` consolidates `satisfiesEditedFallback` + `shouldRunEditedFallback`; `RecordStoreRouter` owns every record-store `switch placement.kind` (reads, writes, cleanup, reuse-source). `ExportManager.swift` shrank 2,543 → 2,401 lines. |
| Phase 2: Destination Resolution | Done | PR #55 | `ExportDestinationResolver` (`Sendable struct`) owns URL + filename allocation, paired-stem allocation, `_orig` companion naming, collision suffixing, inherited group stem. Byte-identical to the pre-extraction inline code. |
| Phase 3a: VariantExporter skeleton + static-resource | Done | PR #56 | `VariantExporter` (`@MainActor final class`) owns the static-resource write path, reuse-source copy, atomic move, timestamps. Rendered media stayed in ExportManager via temporary `Host.renderToTempURL` bridge. |
| Phase 3b: Rendered-media path | Done | PR #57 | `MediaRenderer` becomes a direct `VariantExporter` dependency; `Host.renderToTempURL` bridge deleted. ExportManager still constructs the renderer for the `renderActivity` callback. |
| Phase 4a: `ExportJobPlanner` (pure) | Done | PR #58 | Pure `enum` with two static methods turning assets + predicates into `[ExportJob]`. Predicate-order discipline (isExported before retry-gate) preserved. |
| Phase 4b: `ExportQueueCoordinator` | Done | PR #60 | Queue state (`pendingJobs`, `isProcessing`, `currentTask`, queued counters), drain loop, pause/resume/cancel, and queue published mirrors all move into the coordinator. ExportManager mirrors via sinks for AutoSync compatibility. Generation stays on the manager. |
| Phase 5: `ImportCoordinator` | Done | PR #61 | Import flow (~190 lines: scanner → matcher → bulkImport → reconcile) moves into coordinator. `importResult` stays writable on the manager via Host callback. Generation transfer deferred to a follow-up. |
| Phase 6: PhotoLibrary composition | Done (partial) | PR #62 | Override regression-gate test (20 tests covering every `PhotoLibraryService` method) pins the property "Screenshot mode cannot accidentally fall through to production PhotoKit." Full composition refactor (extract `ProductionPhotoLibraryService` peer, drop inheritance, mark `PhotoLibraryManager` `final`) deferred to a follow-up. |
| Phase 7a–g: File reorganization | Done (partial) | this PR | Moved into `Records/`, `AutoSync/` (with `Stores/` subgroup), `PhotoLibrary/`, and feature-grouped `Views/`. `Destination/`, `Export/`, and `App/` folder moves deferred to keep blast radius bounded. Xcode 15 synchronized groups made the moves Xcode-config-free. |

## Summary

The repository has a solid baseline architecture: SwiftUI views are mostly presentation-oriented, Photos and filesystem seams are protocolized, persistence is centralized through `JSONLRecordFile`, and pure policy helpers already exist for several export rules.

The main architectural risk is responsibility concentration. `ExportManager` has become the coordination point for queueing, planning, destination resolution, variant writing, record-store routing, retry behavior, import reconciliation, and cancellation. That makes individual changes harder to reason about and increases the chance that a feature change breaks unrelated export paths.

This plan keeps product behavior and existing data formats stable while extracting clearer boundaries around export orchestration, record completion policy, PhotoKit access, and feature-owned views.

## Current Assessment

### Strong Foundations

- `Protocols/` provides useful test seams for Photos, resources, filesystems, and destinations.
- `Managers/` already contains several pure policy helpers such as `ExportFilenamePolicy`, `ExportPathPolicy`, `ExportPlacementResolver`, and `ResourceSelection`.
- `JSONLRecordFile` centralizes the JSONL-plus-snapshot persistence mechanics shared by both record stores.
- Keeping timeline records and collection records in separate stores is still a reasonable design because their key shapes are different.
- `AutoSyncReducer` is a good example of isolating decision logic from stateful app services.
- The SwiftUI shell has clear top-level routing through `ContentView` and `LibraryRootView`.

### Pressure Points

- `ExportManager` owns too many lifecycle stages: queue planning, queue execution, asset export, variant selection, file placement, reuse detection, record mutation, cancellation, import, and cleanup.
- Record-store completion rules are spread across stores and export code. The app needs one named place for "what counts as exported" for a placement and variant set.
- Record-store routing currently depends on repeated `switch placement.kind` blocks. The rule is small, but duplication makes future placements more error-prone.
- Screenshot mode appears to be implemented through service specialization/subclassing. Composition through an injected `PhotoLibraryService` would be easier to audit and harder to partially override.
- Some views remain grouped by UI layer instead of feature area. That is workable today, but timeline, collection, folder, and export views are now distinct enough to deserve local folders.
- Stale phase comments and historical naming can make the code look less settled than it is.

## Target Folder Shape

This is the intended end state for code with active behavior. It does not require a single large move; extraction should happen incrementally.

```text
photo-export/
  App/
    PhotoExportApp.swift
    AppContainer.swift
    ScreenshotMode.swift
    Commands.swift

  Export/
    ExportManager.swift
    ExportQueueCoordinator.swift
    ExportJobPlanner.swift
    ExportRunCoordinator.swift
    VariantExporter.swift
    ExportDestinationResolver.swift
    ExportReuseSourceFinder.swift
    RecordStoreRouter.swift
    ImportCoordinator.swift

  Records/
    ExportRecordStore.swift
    CollectionExportRecordStore.swift
    JSONLRecordFile.swift
    RecordReconciler.swift
    ExportCompletionPolicy.swift

  PhotoLibrary/
    PhotoLibraryManager.swift
    ProductionPhotoLibraryService.swift
    ScreenshotPhotoLibraryService.swift
    PhotoLibraryCollections.swift
    PhotoLibraryThumbnails.swift

  AutoSync/
    AutoSyncManager.swift
    AutoSyncReducer.swift
    AutoSyncEnvironment.swift
    Stores/

  Destination/
    ExportDestinationManager.swift
    DestinationSafetyMonitor.swift
    DestinationFingerprint.swift

  Views/
    Timeline/
    Collections/
    Export/
    Settings/
    Shared/

  Models/
  Protocols/
  Helpers/
```

## Boundary Principles

- Keep existing observable facades stable while extracting internals.
- Extract pure policy before moving stateful objects.
- Preserve the two-record-store design. This plan is not a schema unification or migration.
- Keep PhotoKit behind `PhotoLibraryService` and model boundaries.
- Keep filesystem mutation behind the existing destination, writer, renderer, and file-service seams.
- Prefer small file moves after behavior extraction, so diffs stay reviewable.

## Cross-Cutting Contracts

These three contracts bind every extracted collaborator. Locking them in before Phase 2 prevents downstream phases from each re-litigating the same questions.

### Generation / cancellation ownership (status: deferred follow-up)

**Plan target**: `ExportQueueCoordinator` owns `var generation: Int` and exposes:

- `isCurrent(_ gen: Int) -> Bool`
- `throwIfCancelledOrStale(_ gen: Int) throws`
- `bumpGeneration() -> Int`

**Current state (post-Phase-5)**: `generation` storage stayed on `ExportManager`. Each of the three extracted collaborators (`VariantExporter`, `ExportQueueCoordinator`, `ImportCoordinator`) holds a `Host` protocol with `generation` / `isCurrent` (and, for `ImportCoordinator`, `bumpGeneration`) as a permanent seam back to the manager. The Phase 0 cancellation helpers (`isCurrent(_:)`, `throwIfCancelledOrStale(_:)`) are now `internal` on `ExportManager` rather than `private`. The Host-protocol scaffolding the plan said would be deleted in Phase 5 is in fact load-bearing today.

The transfer was deferred from Phase 5 because: (a) the storage move is purely mechanical but touches every inline generation access across queue + import paths, (b) the Host seam preserves the Phase 0 cancellation contract correctly via callbacks, (c) it does not unblock any downstream phase. Tracked as a follow-up (see Deferred Follow-ups section at the bottom of this plan).

**Why the coordinator-owned counter was still the right target shape:** smallest delta from today's pattern. Adopting `Task.checkCancellation()` alone would change cooperative-cancellation semantics — a behavior change rather than a refactor. A free-floating `CancellationToken` value type adds an abstraction without removing the coordinator dependency, since the coordinator still needs to invalidate tokens.

### Actor isolation policy

- Stateful collaborators are `@MainActor final class`: `VariantExporter`, `ExportQueueCoordinator`, `ImportCoordinator`.
- Pure policy is plain `struct` or `enum`: `ExportJobPlanner`, `ExportCompletionPolicy`, `ExportDestinationResolver`. These take values in and return decisions out, no store dependencies.
- `RecordStoreRouter` is **not** pure — it is a `@MainActor final class` with `ExportRecordStore` and `CollectionExportRecordStore` injected (see Phase 1 for scope).
- Heavy work (PhotoKit fetches, file I/O, video render) continues to hop off MainActor via `await` on the existing protocol seams (`PhotoLibraryService`, `MediaRenderer`, `AssetResourceWriter`). The refactor introduces no new actor hops.
- Each extracted class should carry a one-line comment at its top declaring its isolation, so future contributors do not silently make it `nonisolated`.
- Phase 0 includes a Swift 6 Sendable audit pass on the existing protocol seams (`PhotoLibraryService` `nonisolated async` methods returning `AssetDescriptor`/`PhotoCollectionDescriptor`) so strict-concurrency warnings surface before extraction starts, not during.

**Why this direction:** today's `ExportManager` is implicitly all-MainActor with off-thread work behind `await` on protocol seams, and that pattern is already correct. Promoting `VariantExporter` to an `actor` would force every call site through additional `await` hops and re-order interleavings with `@Published` updates — a threading-model change masquerading as a refactor. A purely `nonisolated` `VariantExporter` is the lightest touch but offers no compiler protection against shared mutable state.

### AutoSync seam preservation

- `ExportManager+AutoSyncConformance.swift` stays untouched across every phase.
- `ExportManager` continues to own `@Published` mirrors for `isRunning`, `isImporting`, `importStage`, `versionSelection`, and `activeRunContext`.
- **Mirror shape (revised during implementation): stored `@Published` driven by Combine sinks from the coordinator.** The plan originally projected a passthrough publisher on `ExportManager`; in implementation, both `ExportQueueCoordinator` and `ImportCoordinator` ended up owning their own `@Published` state which is mirrored onto `ExportManager`'s same-named properties via `.sink { [weak self] self?.x = $0 }` in the manager's `init`. The mirrors fire synchronously on `@MainActor` (both objects are MainActor-isolated; `@Published`'s `willSet` emission is synchronous), so the AutoSync `exportRunStatePublisher` `CombineLatest3` still observes consistent state — a synchrony pin (`ExportQueueStateSnapshotTests.teardownQueue_synchronouslyClearsManagerMirrors`) covers the cancellation path. The "stored mirror" shape was chosen because (a) the queue/import state was already stored `@Published` on the manager pre-refactor, so a passthrough would have been a wider behavior change, and (b) it preserves the AutoSync source-of-truth on `ExportManager` (matching the conformance file's untouched-across-every-phase invariant).
- `PhotoLibraryManager` follows the equivalent rule when its production/screenshot service is extracted: forward the injected service's `objectWillChange` so existing `@EnvironmentObject` view bindings (e.g. `TimelineSidebarView`) see no behavior change.
- The Phase 0 characterization test snapshots the emission sequence on `exportRunStatePublisher`, `isImportingPublisher`, and `completedRunsPublisher`. Re-run after every phase as the regression gate. Test mechanics are specified in Phase 0.

**Why this direction:** the conformance file is 11 lines; preserving it costs nothing. Snapshot-then-refactor-freely is feasible but leaves the AutoSync source-of-truth in flux during Phases 4–5, exactly when it is hardest to debug. An explicit `AutoSyncExportAdapter` is the cleanest long-term shape but couples PhotoExportApp wiring changes to extraction PRs — too much churn at the wrong moment. Adapter extraction can happen later as a tiny follow-up once queue and import live in their own files.

## Proposed Components

### App

`AppContainer` should own construction of app-wide dependencies. `photo_exportApp` should become mostly app lifecycle and environment injection. Screenshot-mode dependency selection should live here rather than inside production services.

### Export

`ExportManager` should become an `@MainActor` observable facade. It should expose the same UI-facing state and commands, but delegate actual work to narrower collaborators.

`ExportQueueCoordinator` should own pending jobs, current job state, pause/resume/cancel, queue counts, cancellation generation, and sequential draining.

`ExportJobPlanner` should decide which assets become jobs for timeline months, years, all timeline exports, favorites, albums, shared albums, folders, and retry flows. It should depend on placement resolution and completion policy, not on file writing.

`ExportRunCoordinator` should connect queue jobs to execution. It should fetch asset details, call `VariantExporter`, update progress, and ask `RecordStoreRouter` to write state.

`VariantExporter` should own one asset variant write path: resource selection, static resource writing, rendered media writing, reuse-source copying, temporary-file cleanup, atomic move, timestamp application, and failure classification inputs.

`ExportDestinationResolver` should own paired stem allocation, `_orig` filename decisions, unique destination URL allocation, and inherited group-stem behavior.

`ExportReuseSourceFinder` should own same-destination reuse lookups so copy-from-existing behavior is testable without running a full export.

`RecordStoreRouter` should be the only export-layer type that switches on `ExportPlacement.Kind` for record writes and removals.

`ImportCoordinator` should own the Import Existing Backup flow: scanner invocation, import stages, import report creation, timeline bulk import, collection reconciliation, and failure reporting.

### Records

`ExportRecordStore` and `CollectionExportRecordStore` should remain separate stores with separate key spaces.

`ExportCompletionPolicy` should own required variant logic, edited-fallback behavior, and "is this asset already complete for this placement?" decisions.

`RecordReconciler` should own shared reconciliation mechanics that are currently easy to duplicate between stores.

`JSONLRecordFile` should remain the shared persistence primitive.

### PhotoLibrary

`PhotoLibraryManager` should be the observable facade for authorization, library changes, cache invalidation, and UI-facing fetch operations.

Production and screenshot behavior should be represented as concrete `PhotoLibraryService` implementations injected into the manager. This avoids inheritance-based partial overrides and makes it explicit which implementation is active.

Collection listing, count fetching, and thumbnail fetching can be split into small files under `PhotoLibrary/` if `PhotoLibraryManager` continues to grow.

### Views

Views should be grouped by feature rather than kept as one flat folder. Suggested groups:

- `Views/Timeline/` for timeline sidebar rows and month content.
- `Views/Collections/` for collection sidebar, collection content, folder content, and collection tiles.
- `Views/Export/` for toolbar, issue surfaces, import flow, and record-store alert host.
- `Views/Settings/` for about and preferences-style screens.
- `Views/Shared/` for reusable thumbnail/detail components.

If `FolderContentView` keeps accumulating loading and selection behavior, add a focused `FolderViewModel` rather than letting the view become another coordinator.

## Phased Plan

### Phase 0: Characterization

Land the safety net the rest of the phases lean on. No behavior changes; one small PR (or two, if the AutoSync test infrastructure grows).

**Generation seam.** Add an `isCurrent(_ gen: Int) -> Bool` private helper on `ExportManager` alongside the existing `throwIfCancelledOrStale(_:)`. Route the inline `self.generation == gen` checks through `isCurrent(_:)`. This is the seam Phase 2b collaborators will hold.

**AutoSync emission characterization.** A naive snapshot will flake: `exportRunStatePublisher` is a `CombineLatest3` over three MainActor `@Published` mirrors, and intermediate triples land in unobservable order across `await` hops while `removeDuplicates()` only drops adjacent dupes. The test must use:

- Gated fakes (`FakeAssetResourceWriter`, `FakeMediaRenderer`) that block until released — pattern already proven in `ExportManagerPauseResumeTests.pauseDuringActiveRunStopsQueueAndResumeRestarts`.
- A `Publishers.zip` (or async-stream) collector subscribed to `exportRunStatePublisher`, `isImportingPublisher`, *and* `completedRunsPublisher` **before** `runExport` is called.
- Assertions on a canonicalized state-transition sequence (idle → manual-active → idle → importing → idle), not raw frame count or exact triple values.

This is the regression gate that Phases 1–5 re-run unchanged.

**Cancel-during-render tempfile cleanup.** Existing tests (`ExportPipelineTests.writeFailureCleansUpAndMarksFailure`, `moveFailureMarksFailureAndCleansUpTempFile`, `EditedModeExportTests:279`, `ExportManagerVideoRenderTests:248,279`) already cover write-failure and move-failure cleanup. The Phase 0 addition targets the gap: cancellation arriving mid-render or during reuse-source `copyItem`. Inject a cancel via `cancelAndClear()` from the gated fake's wait point; assert no `.tmp` files remain in the destination directory.

**Swift 6 Sendable audit.** Run `xcodebuild ... SWIFT_STRICT_CONCURRENCY=complete build` on the existing target. Catalogue warnings on `PhotoLibraryService` `nonisolated async` methods returning `AssetDescriptor`/`PhotoCollectionDescriptor`. No fixes required in Phase 0; the inventory just informs whether the isolation contract needs revision before Phase 2. Output lives in [`phase-0-sendable-audit.md`](phase-0-sendable-audit.md).

Done when:

- All inline `self.generation == gen` checks route through `isCurrent(_:)` or `throwIfCancelledOrStale(_:)`.
- The AutoSync canonical-state-transition test passes 100 consecutive local runs with gated fakes.
- The cancel-during-render tempfile-cleanup test exists and passes.
- The Sendable warning inventory is in a comment block at the top of the next phase's PR description.
- No production behavior has changed.

### Phase 1: Stabilize Export Boundaries

Introduce `RecordStoreRouter` and `ExportCompletionPolicy` without changing `ExportManager`'s public API.

**`RecordStoreRouter` scope (revised).** Owns *every* placement-kind dispatch over the two record stores, not just writes:

- Variant writes (`markVariantExported`, `markVariantInProgress`, `markVariantFailed`).
- Variant reads (`currentVariants(assetId:placement:)`).
- Cancellation cleanup paths that remove in-progress records.
- Reuse-source lookup that probes both stores for an existing `.done` record under another placement.

If reads stay outside the router, the duplication this phase removes will silently come back. The router takes `ExportRecordStore` and `CollectionExportRecordStore` as injected dependencies (or small store protocols if Phase 0's Sendable audit demands it). It is a `@MainActor final class`, not a pure struct.

**`ExportCompletionPolicy` scope.** Required-variant logic, edited-fallback decisions, and "is this asset complete for this placement?" checks. The current code has edited-fallback logic mirrored in *both* stores plus `ExportManager` — this phase *removes* those mirrors and routes both stores through the policy. The policy must not become a third copy.

Done when:

- All `switch placement.kind` sites in `ExportManager` for record reads, writes, cleanup, and reuse-source probing route through `RecordStoreRouter`.
- Edited-fallback logic exists only in `ExportCompletionPolicy`; both record stores delegate to it.
- Unit tests cover routing dispatch (each placement kind → expected store call) and completion rules (required variants, edited fallback, asset-complete checks).
- The Phase 0 AutoSync emission test still passes unchanged.

### Phase 2: Extract Destination Resolution

**Reordered to come before variant extraction** — `exportSingleVariant` interleaves destination naming with writing, so extracting the writer first just moves tangled code. Destination resolution is a pure decision and lifts out cleanly; variant writing inherits the cleaner seam.

Move destination URL and filename decisions into `ExportDestinationResolver`.

This centralizes unique filename allocation, paired original/edited stem behavior, `_orig` companion naming, and inherited group-stem rules.

Done when:

- Filename and URL allocation can be tested without queue execution.
- `ExportFilenamePolicy` remains the low-level naming rule helper.
- Existing no-overwrite behavior is preserved.
- The Phase 0 AutoSync emission test still passes unchanged.

### Phase 3: Extract Variant Writing

**Split into two PRs** to bound regression risk for edited-video export. Phase 3a is the foundation; Phase 3b carries the rendered-media path that has historically been the most failure-prone area.

#### Phase 3a: `VariantExporter` skeleton + static-resource path

Extract `VariantExporter` with: resource selection, static-resource writing, destination temp files, atomic moves, timestamp preservation, cleanup, and per-variant error results. **Rendered media still routes through `ExportManager` in this PR** via a temporary delegate seam.

Done when:

- `ExportManager` no longer directly performs static-resource writes.
- Existing static-resource tests pass unchanged.
- Phase 0 cancel-during-render tempfile-cleanup test still passes.

#### Phase 3b: Move rendered-media path into `VariantExporter`

Move `MediaRenderer` invocation, edited-video export, and the render-failure cleanup path into `VariantExporter`. Remove the Phase 3a delegate seam.

Done when:

- `ExportManager` no longer references `MediaRenderer` directly.
- `EditedModeExportTests` and `ExportManagerVideoRenderTests` pass unchanged.
- The Phase 0 cancel-during-render test still passes; add a render-failure tempfile-cleanup test if not already covered.

### Phase 4: Split Queue Planning From Queue Execution

**Split into two PRs.** Planner is pure and easy to revert in isolation; queue coordinator changes call ordering subtly and benefits from landing alone so any regression bisects cleanly.

**Prerequisite test (add before Phase 4a opens).** A pause/resume/cancel state-snapshot test that records the tuple `(isRunning, isPaused, queueCount, currentTask != nil)` at each transition during a multi-job run. This is the regression gate for Phase 4b that the existing `ExportManagerPauseResumeTests` doesn't quite provide — those tests assert outcomes, not state-machine ordering.

#### Phase 4a: `ExportJobPlanner`

Extract pure planning: turn selections + retry requests into `[ExportJob]`. No state, no queue, no file I/O. `ExportManager` calls the planner then continues to enqueue and drain itself.

Done when:

- Planning tests verify what gets enqueued for each entry point (month, year, all, favorites, album, shared album, folder, retry) without running exports.
- `ExportManager` enqueue methods become thin wrappers over `planner.plan(...)`.

#### Phase 4b: `ExportQueueCoordinator`

Extract pending/current job state, pause/resume/cancel, queue counts, and the drain loop. **Generation ownership stays on `ExportManager` until Phase 5** (see Cross-Cutting Contracts) — the coordinator queries via the protocol seam introduced in Phase 0.

Defer `ExportRunCoordinator` unless a second consumer materializes during this phase.

Done when:

- Queue tests verify pause, resume, cancel, and sequential drain behavior without Photos or filesystem work.
- The Phase 4 prerequisite state-snapshot test passes unchanged.
- `ExportManager` reads as a UI-facing facade over planner, queue, and stores (with import still inline pending Phase 5).

### Phase 5: Move Import Flow Out Of ExportManager

Create `ImportCoordinator` for Import Existing Backup.

It should own import stages, scanner invocation, import report generation, bulk record import, and both-store reconciliation.

**Generation ownership transfer.** This phase closes the loop opened in Phase 4b. With import out of `ExportManager`, `generation` can move into `ExportQueueCoordinator` and `ImportCoordinator` can take a reference to the queue's `isCurrent(_:)` / `throwIfCancelledOrStale(_:)` surface (or its own counter if the two cancellation domains turn out to be independent — decide during this phase).

**Prerequisite test.** A bulk-import idempotency test: import a fixture, snapshot both record stores, import the same fixture again, assert store state is identical. Phase 5 reorganizes reconciliation and bulk-write code, and this property is currently untested in isolation.

**AutoSync mirror shape.** `ExportManager.importStagePublisher` becomes a passthrough of `coordinator.$stage` per the AutoSync seam contract. `isImporting` follows the same pattern.

Done when:

- Import state lives in `ImportCoordinator`; `ExportManager.importStage` is a sink-driven `@Published` mirror (revised from the original "passthrough publisher" plan — see Cross-Cutting Contracts §AutoSync seam preservation for the rationale).
- The Phase 5 idempotency test passes.
- Import tests target `ImportCoordinator` directly without spinning up `ExportManager`.
- Export queue changes do not require reading import code.
- ~~`generation` lives in `ExportQueueCoordinator`; the Phase 0 scaffolding protocol is deleted.~~ **Deferred** to a follow-up — see Cross-Cutting Contracts §Generation / cancellation ownership and the Deferred Follow-ups section at the bottom of this plan.

### Phase 6: Clean Photo Library Composition

Make screenshot and production PhotoKit behavior explicit through injected services.

The app container should choose between `ProductionPhotoLibraryService` and `ScreenshotPhotoLibraryService`. `PhotoLibraryManager` should not rely on inheritance or partial overrides for mode changes.

Done when:

- Screenshot mode cannot accidentally fall through to production PhotoKit calls.
- `PhotoLibraryManager` is easier to mark `final`.
- Existing screenshot automation keeps working.

### Phase 7: Reorganize Files By Feature

**Split per destination folder, not one monolithic move.** `project.pbxproj` conflicts are notoriously unmergeable, and this repo merges multiple PRs per day. A bulk move sitting unmerged for hours guarantees in-flight branches develop pbxproj conflicts that have to be resolved by hand. One PR per destination folder, each merged within hours during a low-cadence window (no in-flight feature branches touching the moved files), rebased not merged against `main`.

Sub-PR order, smallest-blast-radius first:

1. **Phase 7a: `Records/`** — `ExportRecordStore`, `CollectionExportRecordStore`, `JSONLRecordFile`, `ExportCompletionPolicy`.
2. **Phase 7b: `Destination/`** — `ExportDestinationManager`, `DestinationSafetyMonitor`, `DestinationFingerprint`, `DestinationSnapshotAdapter`, `ExportDestinationResolver`.
3. **Phase 7c: `AutoSync/`** — `AutoSyncManager`, `AutoSyncReducer`, `AutoSyncEnvironment`, plus the `Stores/` subgroup of file-backed AutoSync stores.
4. **Phase 7d: `PhotoLibrary/`** — `PhotoLibraryManager`, `ProductionPhotoLibraryService`, `ScreenshotPhotoLibraryService`, `PhotoLibraryPersistentChangeAdapter`.
5. **Phase 7e: `Export/`** — `ExportManager`, `ExportQueueCoordinator`, `ExportJobPlanner`, `VariantExporter`, `ExportDestinationResolver` (if not landed in 7b), `RecordStoreRouter`, `ImportCoordinator`, the `ExportManager+AutoSyncConformance.swift` adapter.
6. **Phase 7f: `Views/` regrouping** — `Timeline/`, `Collections/`, `Export/`, `Settings/`, `Shared/` subfolders.
7. **Phase 7g: `App/`** — `PhotoExportApp`, `AppContainer`, `ScreenshotMode`, `Commands`.

**Doc-drift surface.** Each sub-PR's "Done when" must include updating any doc that references the moved paths. Currently audited references:

- `AGENTS.md` (3 hits to `Managers/`)
- `website/src/content/docs/architecture.md`
- `docs/reference/swift-swiftui-best-practices.md`
- `docs/project/import-existing-backup-plan.md`
- `docs/project/plans/collections-export-plan.md`

Re-grep before each sub-PR opens; the list above is a 2026-05-15 snapshot and will drift as Phases 1–6 add or remove references.

Done (Phase 7 overall) when:

- Top-level folders match the target shape closely enough to guide new contributors.
- ~~`Managers/` no longer exists.~~ **Partial**: `Records/`, `AutoSync/{Stores/}`, `PhotoLibrary/`, and feature-grouped `Views/` are in place. The remaining `Destination/`, `Export/`, and `App/` moves are deferred — see Deferred Follow-ups.
- `ContentView` and `LibraryRootView` remain routing shells rather than feature containers.
- All schemes build, all tests pass, screenshot scheme runs successfully.
- All audited doc references point to current paths.

## Suggested Work Order

1. **Phase 0:** consolidate generation checks through `isCurrent(_:)` / existing `throwIfCancelledOrStale(_:)`; add gated-fake AutoSync canonical-state-transition test (covering `exportRunStatePublisher`, `isImportingPublisher`, `completedRunsPublisher`); add cancel-during-render tempfile-cleanup test; run Swift 6 Sendable audit and catalogue warnings.
2. **Phase 1:** `RecordStoreRouter` (reads + writes + cleanup + reuse-source) + `ExportCompletionPolicy` (with edited-fallback dedupe from both stores).
3. **Phase 2:** `ExportDestinationResolver` (destination first, before variant — `exportSingleVariant` is too tangled to extract writer-first).
4. **Phase 3a:** `VariantExporter` skeleton + static-resource path; rendered media stays in `ExportManager` via temporary delegate seam.
5. **Phase 3b:** move rendered-media path into `VariantExporter`; remove the delegate seam.
6. **Phase 4 prep:** add pause/resume/cancel state-snapshot test.
7. **Phase 4a:** `ExportJobPlanner` (pure).
8. **Phase 4b:** `ExportQueueCoordinator` (generation stays on `ExportManager`). Defer `ExportRunCoordinator` unless a second consumer materializes.
9. **Phase 5 prep:** add bulk-import idempotency test.
10. **Phase 5:** move import into `ImportCoordinator`; transfer generation ownership to `ExportQueueCoordinator`; delete the Phase 0 scaffolding protocol; switch `importStagePublisher` to passthrough shape.
11. **Phase 6:** replace screenshot inheritance with injected service composition; `PhotoLibraryManager` forwards `objectWillChange` from injected service.
12. **Phase 7a–g:** move files into feature folders, one destination folder per PR, low-cadence merge windows, doc references updated in the same PR.

## Testing Strategy

- Run the full macOS unit test suite after each phase:

```bash
xcodebuild -project photo-export.xcodeproj -scheme "photo-export" -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO test
```

- Add focused unit tests for pure policies before changing call sites.
- Keep integration-style `ExportManager` tests during extraction so UI-facing behavior remains stable.
- **Re-run the Phase 0 AutoSync canonical-state-transition test, the cancel-during-render tempfile test, and (once added) the pause/resume/cancel snapshot and bulk-import idempotency tests on every phase PR.** These are the regression gates that justify the contract-preservation strategy.
- Add queue tests with fake services after `ExportQueueCoordinator` exists.
- Add screenshot-mode tests or assertions that verify the screenshot service is the only active Photo Library backend in screenshot mode.
- Run SwiftLint and swift-format checks before merging a multi-phase branch.

## Risks And Mitigations

- Large refactor churn: extract collaborators behind the existing `ExportManager` facade before moving files.
- Hidden data-format change: keep both stores and `JSONLRecordFile` unchanged unless a separate migration plan exists.
- Actor isolation regression: follow the isolation contract in Cross-Cutting Contracts; the Phase 0 Sendable audit surfaces problems before extraction starts.
- AutoSync seam regression: the Phase 0 canonical-state-transition test is the single regression gate; do not let it flake or be skipped.
- Screenshot regression: move to injected composition and test that production PhotoKit is not used in screenshot mode.
- Over-abstraction: only keep extracted types that remove real responsibility from current large files and are testable on their own. `ExportRunCoordinator`, `ExportReuseSourceFinder`, and `RecordReconciler` from earlier drafts are explicitly deferred unless a second consumer appears.
- Phase 7 merge blockage: `project.pbxproj` conflicts are unmergeable, and the repo merges multiple PRs/day. Phase 7 sub-PRs only open during low-cadence windows and merge within hours; rebase, do not merge, against `main`.

## Non-Goals

- No record-store schema migration.
- No unification of timeline and collection record stores.
- No product behavior changes.
- No dependency manager or third-party architecture framework.
- No redesign of the SwiftUI user interface.

## Success Criteria

- ~~`ExportManager` is ≤ 600 lines after Phase 5~~ **Not met.** Actual post-Phase-5 line count: ~1,867. The original target underestimated how much surface (Host-protocol witnesses, `@Published` mirrors driven by sinks, the `export(job:gen:)` orchestration body, AutoSync conformance, run-summary bookkeeping, start/cancel/teardown lifecycle) would remain on `ExportManager` once the queue + import coordinators were carved out. The manager now reads as orchestration over the new collaborators, but the line-count budget was unrealistic and is restated below.
- `ExportManager` reads as orchestration over its collaborators (`VariantExporter`, `ExportQueueCoordinator`, `ImportCoordinator`, `RecordStoreRouter`, `ExportDestinationResolver`, `ExportJobPlanner`, `ExportCompletionPolicy`) — not as the implementation of any single export concern. **Met.**
- No method body in extracted collaborators exceeds 40 lines without justification.
- Export planning, queueing, variant writing, destination resolution, import, and record routing can be tested independently.
- New export placements can be added by touching a small, predictable set of files (`RecordStoreRouter`, `ExportCompletionPolicy`, and one resolver call site).
- Screenshot mode is selected by dependency composition instead of inheritance behavior — **partial**: composition refactor deferred; an override-gate regression test pins the property in the interim. See Deferred Follow-ups.
- Folder organization communicates ownership to a new contributor before they read implementation details — **partial**: `Records/`, `AutoSync/`, `PhotoLibrary/`, and feature-grouped `Views/` are in place; `Destination/`, `Export/`, and `App/` moves deferred.

## Deferred Follow-ups

The architecture refactor (Phases 0–7) landed substantially complete on the `architecture-refactor` integration branch in May 2026 and merged to `main` as a single mega-PR. The following items were explicitly deferred during the refactor and remain open work — each is safe to land independently and none unblocks the others:

1. **PhotoLibrary composition refactor.** Replace `ScreenshotPhotoLibraryService: PhotoLibraryManager` inheritance with composition: extract a `ProductionPhotoLibraryService` peer, drop the inheritance, mark `PhotoLibraryManager` `final`, and have `PhotoLibraryManager` hold an injected `PhotoLibraryService`. Phase 6 of this plan covers the intent; the partial Phase 6 commit (PR #62) added a 20-test override regression gate as an interim safety net. Why deferred: ~973 lines of production PhotoKit code to relocate; orthogonal to all other Phase-7 folder moves; the override gate covers today's risk surface.
2. **Generation-counter ownership transfer.** Move `var generation: Int` from `ExportManager` into `ExportQueueCoordinator` and delete the `Host.generation` / `Host.isCurrent` / `Host.bumpGeneration` getters that currently exist on the three collaborator Host protocols. Phase 5 of this plan called for this; in implementation, Phase 5 shipped without it because (a) the storage move is purely mechanical but touches every inline generation access across queue + import paths, (b) the Host seam preserves the Phase 0 cancellation contract correctly via callbacks, (c) it does not unblock any downstream phase.
3. **Remaining Phase 7 folder moves.** `Destination/` (`ExportDestinationManager`, `DestinationSafetyMonitor`, `DestinationSnapshotAdapter`, `FileBackedDestinationSafetyConfirmationStore`, `ExportDestinationResolver`), `Export/` (`ExportManager`, `ExportQueueCoordinator`, `ExportJobPlanner`, `VariantExporter`, `ImportCoordinator`, `RecordStoreRouter`, `BackupScanner`, plus the helper-policy types), and `App/` (`PhotoExportApp`, future `AppContainer`, `ScreenshotMode`, `Commands`). Phase 7 sub-PR #63 landed `Records/`, `AutoSync/{Stores/}`, `PhotoLibrary/`, and `Views/{Timeline,Collections,Export,Settings,Shared}/`. The deferred moves are low-priority because Xcode 15 filesystem-synchronized groups make the moves Xcode-config-free, so they can land opportunistically with no blast radius beyond `git log --follow` discontinuity.

A tracking GitHub issue captures these three items as checkboxes; the in-source `Host` protocol comments link back to this section.
