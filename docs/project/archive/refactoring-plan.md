# Refactoring Plan

Status: Completed (Phases 1–4); archived as an early refactoring decision record.
The counts, file layout and assessment below are historical. Use the
[architecture conventions](../../reference/architecture-conventions.md) for
current contracts.

## Context

This plan was written when the app was ~2,750 lines across 15 Swift source files. A later revision recorded ~4,100 lines across 25 files; neither count describes the current app.

The project uses **Swift Testing** (not XCTest). There is currently no `.xctestplan` file — the scheme uses the `<Testables>` model directly.

## Completed Work

Phases 1–4 are done. Summary of what shipped:

- **Phase 1 — Bug fixes:** double-resume crash in `requestFullImage`, thread-unsafe `loadThumbnail` guard, temp file leak on export failure, `.limited` auth mapping, double security-scope in `urlForMonth`, fallback `PhotoLibraryManager()` in MonthContentView, stale-task guard in ExportManager.
- **Phase 2 — Dead code removal:** removed `TestPhotoAccessView`, `InfoPlist.swift`, `AssetMetadata`, unused fetch methods, deprecated `MainView` struct, empty test stub.
- **Phase 3 — Concurrency prep:** added `@MainActor` to PhotoLibraryManager, shared `MonthFormatting` helper.

## Non-Bugs Removed from Scope

These were considered and explicitly rejected:

- **State machine for ExportManager** — the sequential queue works. Bugs were fixed directly.
- **Domain wrappers (`ExportableAsset`, `resourceToken`)** — the code already passes `localIdentifier` strings via `ExportJob`.
- **`PhotoLibraryService` as a separate type** — one consumer, no polymorphism benefit. *(Revisited in Phase 4: once app-owned value types replaced `PHAsset` at the boundary, a `PhotoLibraryService` protocol became the natural testability seam. The original rejection was about extracting a new concrete type; Phase 4 added an injectable protocol that `PhotoLibraryManager` conforms to.)*
- **Destination type split** — `ExportDestinationManager` does its job at 293 lines.
- **`SidebarViewModel` extraction** — moving code between files doesn't reduce complexity.
- **CI concurrency baseline enforcement** — solo project. When Swift 6 arrives, the compiler will flag issues.
- **Characterization tests before rewrite** — there is no rewrite.

- **Phase 4 — Test infrastructure:** Added app-owned value types (`AssetDescriptor`, `ResourceDescriptor`) replacing `PHAsset`/`PHAssetResource` at all non-framework boundaries. Added injectable protocols (`PhotoLibraryService`, `AssetResourceWriter`, `FileSystemService`, `ExportDestination`). `FileIOService` conforms to `FileSystemService`. Export pipeline, record store recovery, and backup scanner matching are now testable without the Photos framework.
