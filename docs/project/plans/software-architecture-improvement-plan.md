# Software Architecture Improvement Plan

Date: 2026-05-15
Status: Proposed

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

### Phase 1: Stabilize Export Boundaries

Introduce `RecordStoreRouter` and `ExportCompletionPolicy` without changing `ExportManager`'s public API.

`RecordStoreRouter` should own record mutation routing for timeline, favorites, albums, shared albums, and folders. `ExportCompletionPolicy` should own required variant decisions and completion checks.

Done when:

- Repeated `switch placement.kind` record-write blocks are removed from `ExportManager`.
- Completion and retry decisions call `ExportCompletionPolicy`.
- Unit tests cover routing and completion rules.

### Phase 2: Extract Variant Writing

Move single-asset, single-variant file export behavior into `VariantExporter`.

This includes resource selection, rendered video export, static resource export, destination temp files, atomic moves, timestamp preservation, cleanup, and per-variant error results.

Done when:

- `ExportManager` no longer directly performs low-level resource writes.
- Existing edited photo and edited video behavior is covered by tests or existing test fixtures.
- Temporary-file cleanup is tested for success and failure paths where practical.

### Phase 3: Extract Destination Resolution

Move destination URL and filename decisions into `ExportDestinationResolver`.

This should centralize unique filename allocation, paired original/edited stem behavior, `_orig` companion naming, and inherited group-stem rules.

Done when:

- Filename and URL allocation can be tested without queue execution.
- `ExportFilenamePolicy` remains the low-level naming rule helper.
- Existing no-overwrite behavior is preserved.

### Phase 4: Split Queue Planning From Queue Execution

Introduce `ExportJobPlanner` and `ExportQueueCoordinator`.

`ExportJobPlanner` should produce jobs from selections and retry requests. `ExportQueueCoordinator` should own pending/current job state, pause/resume/cancel, queue counts, and the drain loop.

Done when:

- Planning tests can verify what gets enqueued without running file exports.
- Queue tests can verify pause, resume, cancel, and sequential drain behavior without Photos or filesystem work.
- `ExportManager` reads as a UI-facing facade over planner, queue, runner, and stores.

### Phase 5: Move Import Flow Out Of ExportManager

Create `ImportCoordinator` for Import Existing Backup.

It should own import stages, scanner invocation, import report generation, bulk record import, and both-store reconciliation.

Done when:

- Import state is not stored directly in `ExportManager` unless it is only mirrored for UI compatibility.
- Import tests target `ImportCoordinator`.
- Export queue changes do not require reading import code.

### Phase 6: Clean Photo Library Composition

Make screenshot and production PhotoKit behavior explicit through injected services.

The app container should choose between `ProductionPhotoLibraryService` and `ScreenshotPhotoLibraryService`. `PhotoLibraryManager` should not rely on inheritance or partial overrides for mode changes.

Done when:

- Screenshot mode cannot accidentally fall through to production PhotoKit calls.
- `PhotoLibraryManager` is easier to mark `final`.
- Existing screenshot automation keeps working.

### Phase 7: Reorganize Files By Feature

After behavior extraction, move files into the target folders.

Keep moves mechanical and separate from logic changes where possible. Update Xcode project membership and any documentation references in the same change.

Done when:

- Top-level folders match the target shape closely enough to guide new contributors.
- `Managers/` no longer acts as the default destination for unrelated code.
- `ContentView` and `LibraryRootView` remain routing shells rather than feature containers.

## Suggested Work Order

1. Add pure tests around current completion behavior before extraction.
2. Add `RecordStoreRouter`.
3. Add `ExportCompletionPolicy`.
4. Add `ExportDestinationResolver`.
5. Add `VariantExporter`.
6. Add `ExportJobPlanner`.
7. Add `ExportQueueCoordinator` and, if useful, `ExportRunCoordinator`.
8. Move import into `ImportCoordinator`.
9. Replace screenshot inheritance with injected service composition.
10. Move files into feature folders and clean stale comments.

## Testing Strategy

- Run the full macOS unit test suite after each phase:

```bash
xcodebuild -project photo-export.xcodeproj -scheme "photo-export" -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO test
```

- Add focused unit tests for pure policies before changing call sites.
- Keep integration-style `ExportManager` tests during extraction so UI-facing behavior remains stable.
- Add queue tests with fake services after `ExportQueueCoordinator` exists.
- Add screenshot-mode tests or assertions that verify the screenshot service is the only active Photo Library backend in screenshot mode.
- Run SwiftLint and swift-format checks before merging a multi-phase branch.

## Risks And Mitigations

- Large refactor churn: extract collaborators behind the existing `ExportManager` facade before moving files.
- Hidden data-format change: keep both stores and `JSONLRecordFile` unchanged unless a separate migration plan exists.
- Actor isolation regression: keep UI facades `@MainActor`; make extracted policies pure or explicitly isolated.
- Screenshot regression: move to injected composition and test that production PhotoKit is not used in screenshot mode.
- Over-abstraction: only keep extracted types that remove real responsibility from current large files and are testable on their own.

## Non-Goals

- No record-store schema migration.
- No unification of timeline and collection record stores.
- No product behavior changes.
- No dependency manager or third-party architecture framework.
- No redesign of the SwiftUI user interface.

## Success Criteria

- `ExportManager` is small enough to read as orchestration rather than implementation.
- Export planning, queueing, variant writing, destination resolution, import, and record routing can be tested independently.
- New export placements can be added by touching a small, predictable set of files.
- Screenshot mode is selected by dependency composition instead of inheritance behavior.
- Folder organization communicates ownership to a new contributor before they read implementation details.
