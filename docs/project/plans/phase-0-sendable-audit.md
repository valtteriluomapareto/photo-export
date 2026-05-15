# Phase 0 Sendable Audit

Date: 2026-05-15
Source build: `xcodebuild ... SWIFT_STRICT_CONCURRENCY=complete build` on `main` after the Phase 0 generation-seam + characterization-test commits.
Status: Informational. No fixes in Phase 0 per the
`software-architecture-improvement-plan.md` Cross-Cutting Contracts &gt; Isolation policy:
"Phase 0 includes a Swift 6 Sendable audit pass… so strict-concurrency warnings surface
before extraction starts, not during."

This inventory should be copied into the Phase 1 (and as relevant, Phase 5 / Phase 6) PR
descriptions so reviewers know which warnings are pre-existing vs. introduced by the
extraction.

## Inventory

Twelve unique concurrency warnings (after dedup), clustered into five themes.

### 1. `PhotoLibraryService` is non-Sendable (8 sites)

The single highest-impact finding. `any PhotoLibraryService` cannot cross actor
boundaries; every site that captures or passes the service into a non-MainActor context
warns.

- `photo-export/Managers/BackupScanner.swift:277:56` — `sending value of non-Sendable type 'any PhotoLibraryService'`
- `photo-export/Managers/BackupScanner.swift:280:46` — `sending 'photoLibraryService' risks causing data races`
- `photo-export/Managers/ExportManager.swift:2377:51` — `sending 'self.photoLibraryService'` (import path)
- `photo-export/ViewModels/TimelineSidebarCounts.swift:112:27` — `'service' cannot exit main actor-isolated context`
- `photo-export/ViewModels/TimelineSidebarCounts.swift:114:30` — same property, different call site
- `photo-export/Views/FolderTileView.swift:255:27` — `'photoLibraryService' cannot exit main actor-isolated context`
- `photo-export/Views/FolderTileView.swift:255:47` — `sending value of non-Sendable type 'any PhotoLibraryService'`

**Implication for the refactor.** Phase 6 (PhotoLibraryManager composition) is the
natural home for the fix: declaring `PhotoLibraryService` `Sendable` (or annotating it
`@MainActor` consistently and re-routing the background callers via local copies of just
the data they need) will resolve every site above. Phase 5 (ImportCoordinator extraction)
will inherit `BackupScanner.swift:277,280` and `ExportManager.swift:2377` if Phase 6 has
not landed first — flag the warnings in the Phase 5 PR description rather than fixing
them out of order.

### 2. `@MainActor` closure crossing into a background scanner (1 site)

- `photo-export/Managers/ExportManager.swift:2377:51` — `sending value of non-Sendable type '@MainActor (BackupScanner.ImportStage) -> Void'`

The import-stage progress callback is `@MainActor`-isolated but sent into the scanner's
background context. Phase 5's `ImportCoordinator` should switch the stage callback to a
`@Sendable` closure (or replace the callback with an async-stream `AsyncSequence<ImportStage>`
that the coordinator owns).

### 3. PhotoKit completion handler not `@Sendable` (1 site)

- `photo-export/Managers/ProductionAssetResourceWriter.swift:51:32` — `passing non-Sendable parameter 'completion' to function expecting a '@Sendable' closure`

PhotoKit's `PHAssetResourceManager.writeData` completion handler. The closure body only
captures the continuation, which *is* `Sendable`; the warning is about the parameter type
annotation. Likely fixable by adopting `@Sendable` on the local closure. Not blocking for
Phase 1; revisit when the writer protocol is touched.

### 4. Non-isolated deinit reading main-actor state (1 site)

- `photo-export/Managers/ExportDestinationManager.swift:116:21` — `cannot access property 'volumeObservers' with a non-Sendable type '[any NSObjectProtocol]' from nonisolated deinit`

Standard Swift 6 deinit trap: `deinit` is non-isolated; touching MainActor-only state from
it is illegal. The fix is `isolated deinit` (Swift 6.0+) or restructuring observer
teardown to happen explicitly before deinit. Independent of this refactor — track
separately.

### 5. `@preconcurrency` cleanup suggestions (2 sites)

- `photo-export/Managers/ExportDestinationManager.swift:1:1` — `add '@preconcurrency' to suppress 'Sendable'-related warnings from module 'ObjectiveC'`
- `photo-export/Managers/PhotoLibraryManager.swift:967:1` — `'@preconcurrency' on conformance to 'PHPhotoLibraryChangeObserver' has no effect`

Minor. The ObjectiveC import suggestion is mechanical; the PHPhotoLibraryChangeObserver
note is the inverse — a `@preconcurrency` annotation that no longer has effect. Both
can be cleaned up incidentally when the surrounding files are touched.

## Summary for downstream phases

| Phase | Sendable-audit work required |
|---|---|
| Phase 1 (RecordStoreRouter + CompletionPolicy) | None. No call sites touch the warning surface. |
| Phase 2 (DestinationResolver) | None. |
| Phase 3a/3b (VariantExporter) | None directly; but the `ProductionAssetResourceWriter` warning (theme 3) lives in the same domain. Consider folding the `@Sendable` annotation in. |
| Phase 4a (JobPlanner) | None. |
| Phase 4b (QueueCoordinator) | None directly. |
| Phase 5 (ImportCoordinator) | **Will inherit themes 1 (partial) and 2** unless Phase 6 lands first. Plan to either: (a) land Phase 6 before Phase 5, or (b) accept the warnings in the Phase 5 PR with a note pointing to this audit. |
| Phase 6 (PhotoLibrary composition) | **Resolves theme 1 in full.** Make `PhotoLibraryService` `Sendable` or `@MainActor`-consistent. |
| Phase 7 (file moves) | None. |

## Out of audit scope

Three non-concurrency warnings appeared in the same build pass; cataloging here so they
don't show up uncategorized in a future audit:

- `Managers/PhotoLibraryManager.swift:507:32` — `conditional downcast from 'NSError?' to 'any Error'`
- `Managers/BackupScanner.swift:651:22` — `'videoDuration(at:)' was deprecated in macOS 13.0`
- `Views/ThumbnailView.swift:124:28` and `Views/FolderTileView.swift:78:28` — `result of call to 'insert' is unused`
