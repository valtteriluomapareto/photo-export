# AGENTS.md

Guidance for any AI coding agent working in this repository. Humans should read [`CONTRIBUTING.md`](CONTRIBUTING.md) and [`docs/README.md`](docs/README.md) instead — those are the sources of truth for contributor workflow and where docs live.

If your harness loads a tool-specific file (such as `CLAUDE.md`), that file is a stub that points back here.

## Project Overview

macOS SwiftUI app that exports the Apple Photos library to local/external storage in an organized folder hierarchy. Uses system frameworks only (no CocoaPods/SwiftPM dependencies). Targets macOS 15.x with Xcode 16.x.

## Build & Test Commands

```bash
# Build (Debug)
xcodebuild -project photo-export.xcodeproj -scheme "photo-export" -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build

# Run all unit tests
xcodebuild -project photo-export.xcodeproj -scheme "photo-export" -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO test

# Run a single test class
xcodebuild -project photo-export.xcodeproj -scheme "photo-export" -destination 'platform=macOS' -only-testing:photo-exportTests/ExportRecordStoreTests CODE_SIGNING_ALLOWED=NO test

# Lint (use a workspace-local cache if your sandbox blocks ~/Library)
swiftlint --strict
swiftlint --strict --cache-path build/swiftlint-cache  # sandboxed alternative

# Format check / auto-fix
swift-format lint --recursive photo-export
swift-format format --recursive --in-place photo-export
```

UI tests exist in `photo-exportUITests/` but are skipped by default in the shared scheme.

## Architecture

**Pattern:** SwiftUI + a single façade (`ExportManager`) over focused, `@MainActor` collaborators. Views are thin; orchestration lives on `ExportManager`; per-concern work is delegated. See [`docs/reference/architecture-conventions.md`](docs/reference/architecture-conventions.md) for the load-bearing contracts (cancellation seam, actor isolation policy, AutoSync seam preservation) — read it before touching `ExportManager`, the queue, or anything AutoSync observes.

Source code under `photo-export/` is organized as follows:

- `App/` — app entry point (`photo_exportApp.swift`) plus lifecycle/process-level services: `LoginItemController`, `AppLifecycleCoordinator`, `DiagnosticReporter`, `WhatsNewState`
- `Export/` — the export façade and its collaborators: `ExportManager`, `ExportManager+AutoSyncConformance`, `ExportQueueCoordinator`, `VariantExporter`, `ImportCoordinator`, plus the helper-policy types (`ExportJobPlanner`, `ExportFilenamePolicy`, `ExportPathPolicy`, `ExportPlacementResolver`, `ResourceSelection`, `ProductionAssetResourceWriter`, `ProductionMediaRenderer`, `FileIOService`, `ExportRecordsDirectoryCoordinator`, `BackupScanner`)
- `Destination/` — destination concerns: `ExportDestinationManager`, `DestinationSafetyMonitor`, `DestinationSnapshotAdapter`, `FileBackedDestinationSafetyConfirmationStore`, `ExportDestinationResolver`
- `Records/` — record stores (timeline + collection), the shared `JSONLRecordFile` persistence primitive, `RecordStoreRouter` (single placement-kind dispatch), and `ExportCompletionPolicy` (single completion/edited-fallback rule)
- `AutoSync/` — `AutoSyncManager`, `AutoSyncReducer`, `AutoSyncEnvironment`, with `AutoSync/Stores/` for the file-backed persistence (dirty state, per-destination tokens, retry state, run summary, scope, photo change token)
- `PhotoLibrary/` — `PhotoLibraryManager`, `ScreenshotPhotoLibraryService`, `PhotoLibraryPersistentChangeAdapter`, `CollectionCountCache`
- `Protocols/` — test seams: `PhotoLibraryService`, `AssetResourceWriter`, `FileSystemService`, `ExportDestination`, `MediaRenderer`. Add a new protocol here when you need to inject a fake.
- `Models/` — value types: `AssetDescriptor`, `AssetDetails`, `ExportRecord`, `ExportVariant`, `ExportPlacement`, `LibrarySelection`, `PhotoCollectionDescriptor`
- `Views/` — SwiftUI views, grouped by feature: `Timeline/`, `Collections/`, `Export/`, `Settings/`, `Shared/`
- `ViewModels/` — `MonthViewModel`
- `Helpers/` — small pure utilities (`MonthFormatting`, `ScreenshotSurfaceResolver`)
- `Resources/`, `SupportingFiles/`, `Assets.xcassets` — bundle resources, Info.plist, asset catalog

The Phase-7 folder split (issue #67 item 3) landed in May 2026, replacing the previous `Managers/` catch-all with the role-based `App/` / `Export/` / `Destination/` triad above. Classify new code by role:

- **Façade**: `ExportManager` (+ `ExportManager+AutoSyncConformance.swift` — that file only carries `extension ExportManager: …Host {}` lines and explanatory docstrings; never add method bodies there). In `Export/`.
- **Host-driven collaborators of `ExportManager`** (`@MainActor final class`, in `Export/`): `ExportQueueCoordinator`, `VariantExporter`, `ImportCoordinator`. Each holds a narrow `Host` protocol back to the manager for a few UI-state mutations; the cancellation seam routes through the queue coordinator directly (issue #67 item 2).
- **Pure helpers / policy** (plain `struct` or `enum`, `Sendable` where it crosses tasks): `ExportJobPlanner`, `ExportFilenamePolicy`, `ExportPathPolicy`, `ExportPlacementResolver` (in `Export/`); `ExportDestinationResolver` (in `Destination/`); `ResourceSelection`, `ExportRecordsDirectoryCoordinator`, `BackupScanner`, `FileIOService`, `ProductionAssetResourceWriter`, `ProductionMediaRenderer` (in `Export/`).
- **Destination services** (`@MainActor`, in `Destination/`): `ExportDestinationManager`, `DestinationSafetyMonitor`, `DestinationSnapshotAdapter`, `FileBackedDestinationSafetyConfirmationStore`.
- **App-level services** (`@MainActor`, in `App/`): `LoginItemController`, `AppLifecycleCoordinator`, `DiagnosticReporter`, `WhatsNewState`.

**App entry point** (`App/photo_exportApp.swift`): creates five `@StateObject` dependencies and injects them as `@EnvironmentObject` into the view hierarchy:

- **PhotoLibraryManager** — Photos framework authorization and asset fetching (thumbnails, full-size images). Uses `PHCachingImageManager`.
- **ExportDestinationManager** — manages the chosen export destination folder (security-scoped bookmarks).
- **ExportRecordStore** — tracks timeline (year/month) exports per-destination. Reconfigures when destination changes.
- **CollectionExportRecordStore** — sibling store for Favorites + user-album exports per-destination. Disjoint key space from the timeline store; the two stores cannot corrupt each other. Routed to by `ExportManager` via `RecordStoreRouter`.
- **ExportManager** — public façade for export work. Owns `activeRunContext`, `versionSelection`, `livePhotosPairedExport` (issue #49 — opt-in Live Photo paired-video export, snapshotted onto each `ExportJob` at enqueue time), and the `@Published` mirrors AutoSync observes. Delegates queue mechanics + the Phase-0 cancellation seam (`generation`, `isCurrent`, `bumpGeneration`) to `ExportQueueCoordinator`, per-variant writes to `VariantExporter`, the Import Existing Backup flow to `ImportCoordinator`, record-store dispatch to `RecordStoreRouter`, and completion logic to `ExportCompletionPolicy`. New `start*` entry points belong here and follow the canonical shape (see [`docs/reference/architecture-conventions.md`](docs/reference/architecture-conventions.md) §Canonical `start*` entry-point shape).

**Other code under `Export/` / `Records/` / `AutoSync/` / `PhotoLibrary/`:**

- `BackupScanner` — scans an existing backup folder and matches files to Photos assets (used by Import Existing Backup)
- `ExportFilenamePolicy` — pure rules for `_orig` companion filenames
- `ExportPathPolicy` — pure path-component sanitization for collection folder names
- `ExportPlacementResolver` — maps a `LibrarySelection` to an `ExportPlacement`, including sibling-collision suffixing for albums
- `CollectionCountCache` — actor that dedups concurrent count fetches for the Collections sidebar; invalidated on `PHPhotoLibraryChangeObserver` callbacks
- `JSONLRecordFile` — shared JSONL+snapshot persistence used by both record stores
- `ExportRecordsDirectoryCoordinator` — runs the legacy `<oldId>` → `<newId>` directory migration once before either store configures
- `ResourceSelection` — picks the byte source for an edited variant via the `EditedProducer` enum
- `ProductionAssetResourceWriter` — production implementation behind the `AssetResourceWriter` seam
- `ProductionMediaRenderer` — production implementation behind the `MediaRenderer` seam (edited videos)
- `FileIOService` — atomic file moves and timestamp handling (conforms to `FileSystemService`)

**Views** (`photo-export/Views/`): `ContentView` routes between auth/onboarding/library states. `LibraryRootView` hosts the `NavigationSplitView` with a Timeline / Collections segmented selector. `TimelineSidebarView` renders the year/month tree and `CollectionsSidebarView` renders Favorites + user albums and folders; both sidebars support Cmd/Shift-click multi-select and report the normalized selection via `TimelineSelectionBuckets` / `CollectionsSelectionBuckets`. `YearContentView` shows the focused-year summary pane (no asset grid). `MonthContentView` shows thumbnails for a month and `CollectionContentView` shows thumbnails for a Favorites/album scope (both share `MonthViewModel` via the scope-based loader). `ThumbnailView` renders an individual thumbnail. `ExportToolbarView` shows export controls. `RecordStoreAlertHost` is a view modifier that surfaces the corruption-recovery alert for whichever store enters `.failed`. `OnboardingView` handles first-run flow. `AssetDetailView` shows full-size preview. `ImportView` runs the Import Existing Backup flow. `AboutView` is the in-app about box.

**ViewModels** (`photo-export/ViewModels/`): `MonthViewModel` manages cancellation-aware asset loading for any `PhotoFetchScope` (timeline / favorites / album).

## Design Decisions Worth Knowing

Short rationales for choices a fresh reader will reasonably question. Each is a "why didn't the simpler approach work?" answer.

- **Two record stores, no migration.** `ExportRecordStore` (timeline, asset-keyed) and `CollectionExportRecordStore` (favorites + albums, placement-keyed) live side by side instead of one unified store with a v2 schema. Reasoning: the two store shapes have different keys (`assetId` vs `(placementId, assetId)`) and a unified store would either pay a denormalization tax on every read or require a one-shot migration over existing user data. Two stores with disjoint key spaces means a corrupt collection store cannot affect timeline progress and vice versa, and existing users' timeline records are physically untouched on upgrade. A future unification (if motivated) would be its own migration plan.
- **`JSONLRecordFile` is `@MainActor`, not an `actor`.** Both composing stores are themselves `@MainActor` because they're `ObservableObject`s with `@Published` properties that the SwiftUI view tree observes. Making `JSONLRecordFile` an `actor` would force every callsite into `await` for state that is already main-bound, with no thread-safety gain. The persistence work that has to leave the main actor (snapshot encode + file IO) is dispatched to `ioQueue` from inside `append(_:currentSnapshot:)`; the helpers it calls (`writeSnapshotAndTruncate`, `appendLogLine`, `fsyncDirectory`) are `nonisolated` so the dispatch closure can call them without re-entering the actor.
- **`LibrarySelection` and `PhotoFetchScope` are separate types.** The two have overlapping cases (`favorites`, `album`, `timelineMonth`/`timeline`) but model different things: `LibrarySelection` is UI state ("what is the user looking at?") and `PhotoFetchScope` is a Photos query ("what assets should we fetch?"). Today the two are mostly redundant — every selection maps 1:1 to a scope. The split exists to anchor the boundary for future UI-only states (a header row, an empty-state placeholder) that wouldn't have a corresponding fetch.
- **`libraryRevision` is a payloadless `@Published` counter.** Bumped inside `invalidateCache()` after every `photoLibraryDidChange`, so SwiftUI views that want to react to Photos library mutations (iCloud sync, user edits in Photos.app) can observe it. Sidebar count rows use `.task(id: photoLibraryManager.libraryRevision)` — a full re-fetch is fine there because the rows show numbers, not images. The asset grids (`MonthContentView`, `CollectionContentView`) instead observe it via `.onChange` and call `MonthViewModel.refresh(for:)`, which re-fetches and diff-updates `assets` in place. The earlier "use `.task(id:)` here too" pattern blanked the grid on every unrelated edit and was abandoned. If you add a new view that needs to track library mutations, prefer the `.onChange` + in-place-refresh pattern over `.task(id:)` whenever a visible blank flash would be wrong.
- **Routing record mutations via `RecordStoreRouter`.** Every record read/write/cleanup/reuse-source-probe goes through `Records/RecordStoreRouter.swift`, which switches on `placement.kind` in one place. A new placement kind requires extending the four switches in `RecordStoreRouter` plus the `ExportPlacement.Kind` enum and `ExportCompletionPolicy` (see [`docs/reference/architecture-conventions.md`](docs/reference/architecture-conventions.md) §Adding a new export placement kind). Do not re-inline the dispatch into `ExportManager`. A single `RecordStore` protocol that both stores conform to would centralize the routing further — but the two stores' APIs are intentionally different shapes (`assetId` vs `(placementId, assetId)`), so an LCM protocol would either be sparse or force the timeline store to carry placement awareness it doesn't need.
- **Edited video export goes through `PHImageManager.requestExportSession` + `AVAssetExportSession`, not `PHAssetResource`.** PhotoKit does not pre-render edited videos as static resources, so resource enumeration finds nothing and the render path is the only way to materialise the user-visible bytes.
- **Byte-source dispatch lives in `ResourceSelection.selectEditedProducer` as a single enum** (`.resource | .render | .convertHEIC | .none`). `ExportManager` (via `VariantExporter`) switches on that and never inlines media-kind-specific branches. Widening the render path to a new media kind or transcode is an enum-extension change in one place rather than a new boolean scattered through the pipeline. The `.convertHEIC` arm (issue #47) is the most recent addition.

## Cross-Cutting Contracts

Three contracts bind every collaborator (cancellation seam, actor isolation policy, AutoSync seam preservation), plus the Host-protocol pattern for extracted collaborators and a list of six regression-gate tests. **Canonical reference:** [`docs/reference/architecture-conventions.md`](docs/reference/architecture-conventions.md) — read it before changing `ExportManager` or anything AutoSync observes. Single-sentence summary of each contract so you don't have to follow the link to know whether you need to:

- **Cancellation:** capture `let gen = generation` synchronously before the first `await` in any export task; re-check `isCurrent(gen)` after every hop. `clearPending` is the only conflict method that doesn't bump generation.
- **Actor isolation:** `@MainActor final class` for stateful collaborators; plain `struct`/`enum` for pure helpers (don't reflexively add `@MainActor`); `actor` only when concurrent access is the real requirement.
- **AutoSync seam:** `ExportManager+AutoSyncConformance.swift` only holds protocol conformance lines (no bodies). Coordinator → manager mirrors are synchronous `.sink` — never `.receive(on:)` or `MainActor.run`.

## Documentation Layout

The canonical map of where docs live is [`docs/README.md`](docs/README.md). Quick reference:

- **User-facing docs** — `website/src/content/docs/` (Astro + Starlight site). Run with `cd website && npm install && npm run dev`.
- **Maintainer notes and plans** — `docs/project/`. Index in `docs/README.md`.
- **Reference material** (best practices, persistence format) — `docs/reference/`.
- **Roadmap** — only on the website (`website/src/content/docs/roadmap.md`). Do not duplicate elsewhere.

When changing user-visible behavior, update both the root `README.md` and the matching website page. The map of behavior → page is in `docs/README.md`.

## Workflow

- Open an issue or draft PR before a large feature or architecture change.
- After a non-trivial change, run a code review pass before requesting human review. If your harness exposes a slash-command or subagent for AI review (e.g. `/codex-review`, `/review`), use it; otherwise re-read your own diff against [`docs/reference/swift-swiftui-best-practices.md`](docs/reference/swift-swiftui-best-practices.md) and the conventions below.
- **Releasing:** always run `scripts/bump-version.sh <version>` before pushing a tag. Pushing a `v*` tag triggers both release pipelines (`release-direct.yml` and `release-app-store.yml`) and they validate that the tag matches `MARKETING_VERSION`. See [`docs/project/release-process.md`](docs/project/release-process.md).

### Delegating to opencode / Kimi K2.6 (scout model)

The `/opencode` skill (`.claude/skills/opencode/SKILL.md`) routes a one-shot prompt through the opencode CLI. By default it uses **Kimi K2.6 (Fireworks)** — fast, cheap, and a good fit for "scout" tasks where the goal is *generate a candidate report broadly* rather than *deliver a final precise verdict*. Use it for:

- **First-pass codebase reviews** — architecture, maintainability, docs, tests, UX, or website health. Treat the output as a triage list.
- **Stale-documentation detection.** Strong when prompted to compare docs against the actual code, tests, and CI rather than trusting the docs.
- **Test inventory and coverage-gap discovery** at the macro level (e.g. "no UI tests exist," "no tests for the import-backup flow").
- **Multi-area review synthesis** — turning a pile of findings into an executive summary.
- **Issue-backlog drafting** — generating candidate GitHub issues. A human or stricter model should verify each before filing.
- **Onboarding summaries** from `README.md` / `AGENTS.md`.
- **Prompted self-audits** that explicitly ask the model to verify, not trust docs, search before claiming missing, and separate facts from inference.

Do **not** use Kimi K2.6 (or accept its output unverified) for:

- Precise pre-merge code review where false positives are costly. Use `/codex-review` instead.
- Final testing-gap reports without a verifier — Kimi will sometimes recommend tests that already exist.
- Line-level factual authority. It cites lots of lines; spot-check before relying on them.

**Best workflow:** scout with Kimi → verify the top findings with a stricter model or a human → act. Tell the user when you're scouting so the output is read as a triage list rather than a decree.

## Key Conventions

- Log with `os.Logger` (subsystem `com.valtteriluoma.photo-export`), not `print`.
- The five UI-injected managers (`PhotoLibraryManager`, `ExportManager`, `ExportRecordStore`, `CollectionExportRecordStore`, `ExportDestinationManager`) are `@MainActor`. The Host-driven collaborators of `ExportManager` (`ExportQueueCoordinator`, `VariantExporter`, `ImportCoordinator`) are `@MainActor final class`. `JSONLRecordFile` (under `Records/`) is also `@MainActor` because both composing stores call into it from the main actor and it owns mutable state (`mutationCountSinceCompact`); its IO-queue-bound static helpers are explicitly `nonisolated`. `RecordStoreRouter` is `@MainActor`. `CollectionCountCache` is an actor. Pure helpers (`FileIOService`, `ExportFilenamePolicy`, `ExportPathPolicy`, `ResourceSelection`, `ProductionAssetResourceWriter`, `BackupScanner`, `ExportPlacementResolver`, `ExportRecordsDirectoryCoordinator`, `ExportCompletionPolicy`, `ExportJobPlanner`, `ExportDestinationResolver`) are plain types — do not add `@MainActor` reflexively. Full isolation policy: [`docs/reference/architecture-conventions.md`](docs/reference/architecture-conventions.md) §Actor isolation policy.
- Track exports by `PHAsset.localIdentifier`; never overwrite existing files.
- Use `.task(id:)` for cancellation-aware async loading in **views** (Swift Task cancellation). For **`ExportManager` background work**, the cancellation model is different — it uses the cooperative `generation` seam (`isCurrent(_:)` / `throwIfCancelledOrStale(_:)`), not `Task.checkCancellation()`. See [`docs/reference/architecture-conventions.md`](docs/reference/architecture-conventions.md) §Cancellation contract.
- New code that touches Photos, the filesystem, or the export destination should go through the `Protocols/` seams so it can be unit-tested with fakes.
- SwiftLint config (`.swiftlint.yml`): line length 140, several rules disabled (see file). CI runs `--strict`.
- swift-format config (`.swift-format.json`): 4-space indentation, 120-char line length.
- Website uses Prettier (with `prettier-plugin-astro`) and oxlint. Run `npm run format:check` and `npm run lint` from `website/`. Both are enforced in CI.
