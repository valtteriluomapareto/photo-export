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

**Pattern:** SwiftUI + Managers. Views are thin; logic lives in Managers and ViewModels.

Source code under `photo-export/` is organized as follows:

- `Records/` — record stores (timeline + collection), the shared `JSONLRecordFile` persistence primitive, `RecordStoreRouter` (single placement-kind dispatch), and `ExportCompletionPolicy` (single completion/edited-fallback rule)
- `AutoSync/` — `AutoSyncManager`, `AutoSyncReducer`, `AutoSyncEnvironment`, with `AutoSync/Stores/` for the file-backed persistence (dirty state, per-destination tokens, retry state, run summary, scope, photo change token)
- `PhotoLibrary/` — `PhotoLibraryManager`, `ScreenshotPhotoLibraryService`, `PhotoLibraryPersistentChangeAdapter`, `CollectionCountCache`
- `Managers/` — remaining stateful services and pure helpers awaiting later phase moves (`ExportManager`, `ExportDestinationManager`, `ExportQueueCoordinator`, `VariantExporter`, `ImportCoordinator`, `BackupScanner`, `ExportFilenamePolicy`, `ExportPathPolicy`, `ExportPlacementResolver`, `ExportJobPlanner`, `ExportDestinationResolver`, `ResourceSelection`, `ProductionAssetResourceWriter`, `ProductionMediaRenderer`, `FileIOService`, `ExportRecordsDirectoryCoordinator`, `DestinationSafetyMonitor`, `DestinationSnapshotAdapter`, `FileBackedDestinationSafetyConfirmationStore`, `LoginItemController`, `AppLifecycleCoordinator`, `DiagnosticReporter`, `WhatsNewState`)
- `Protocols/` — test seams: `PhotoLibraryService`, `AssetResourceWriter`, `FileSystemService`, `ExportDestination`. Add a new protocol here when you need to inject a fake.
- `Models/` — value types: `AssetDescriptor`, `AssetDetails`, `ExportRecord`, `ExportVariant`, `ExportPlacement`, `LibrarySelection`, `PhotoCollectionDescriptor`
- `Views/` — SwiftUI views, grouped by feature: `Timeline/`, `Collections/`, `Export/`, `Settings/`, `Shared/`
- `ViewModels/` — `MonthViewModel`
- `Helpers/` — small pure utilities (`MonthFormatting`)
- `Resources/`, `SupportingFiles/`, `Assets.xcassets` — bundle resources, Info.plist, asset catalog

**App entry point** (`photo_exportApp.swift`): creates five `@StateObject` dependencies and injects them as `@EnvironmentObject` into the view hierarchy:

- **PhotoLibraryManager** — Photos framework authorization and asset fetching (thumbnails, full-size images). Uses `PHCachingImageManager`.
- **ExportDestinationManager** — manages the chosen export destination folder (security-scoped bookmarks).
- **ExportRecordStore** — tracks timeline (year/month) exports per-destination. Reconfigures when destination changes.
- **CollectionExportRecordStore** — sibling store for Favorites + user-album exports per-destination. Disjoint key space from the timeline store; the two stores cannot corrupt each other. Routed to by `ExportManager` via `placement.kind`.
- **ExportManager** — orchestrates the export queue (enqueue/pause/cancel/resume). Depends on the other four managers; routes record mutations to the correct store via `ExportPlacement.kind`.

**Other code under `Managers/` / `Records/` / `AutoSync/` / `PhotoLibrary/`:**

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
- **`libraryRevision` is a payloadless `@Published` counter.** It exists solely to break SwiftUI view-update equality so `.task(id:)` re-runs after a `photoLibraryDidChange` callback. The counter is bumped inside `invalidateCache()` and observed by `CollectionsSidebarView` (per-album count refresh) but **not** by `CollectionContentView`'s asset grid — observing it there caused the grid to blank on every unrelated Photos.app edit. If a future view adds `.task(id: photoLibraryManager.libraryRevision)`, audit whether the cost (full re-load on any library change) is justified for that view.
- **Routing record mutations via `placement.kind`.** `ExportManager` keeps two store references and dispatches every record write (`recordVariantInProgress`/`Exported`/`Failed`/`removeVariant`) on a `switch placement.kind`. The dispatch is duplicated in `cancelAndClear` and the run-loop catch block. A single `RecordStore` protocol that both stores conform to would centralize the routing — but the two stores' APIs are intentionally different shapes (`assetId` vs `(placementId, assetId)`), so an LCM protocol would either be sparse or force the timeline store to carry placement awareness it doesn't need. The cost of the duplicated `switch` blocks is bounded by `ExportPlacement.Kind` having three cases and being closed.
- **Edited video export goes through `PHImageManager.requestExportSession` + `AVAssetExportSession`, not `PHAssetResource`.** PhotoKit does not pre-render edited videos as static resources, so resource enumeration finds nothing and the render path is the only way to materialise the user-visible bytes.
- **Byte-source dispatch lives in `ResourceSelection.selectEditedProducer` as a single enum** (`.resource | .render | .none`). `ExportManager` switches on that and never inlines media-kind-specific branches. Widening the render path to a new media kind is an enum-extension change in one place rather than a new boolean scattered through the pipeline.

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
- The five UI-injected managers (`PhotoLibraryManager`, `ExportManager`, `ExportRecordStore`, `CollectionExportRecordStore`, `ExportDestinationManager`) are `@MainActor`. `JSONLRecordFile` (under `Records/`) is also `@MainActor` because both composing stores call into it from the main actor and it owns mutable state (`mutationCountSinceCompact`); its IO-queue-bound static helpers are explicitly `nonisolated`. Pure helpers (`FileIOService`, `ExportFilenamePolicy`, `ExportPathPolicy`, `ResourceSelection`, `ProductionAssetResourceWriter`, `BackupScanner`, `ExportPlacementResolver`, `ExportRecordsDirectoryCoordinator`, `ExportCompletionPolicy`, `ExportJobPlanner`, `ExportDestinationResolver`) are plain types — do not add `@MainActor` reflexively. `RecordStoreRouter` is `@MainActor`. `CollectionCountCache` is an actor.
- Track exports by `PHAsset.localIdentifier`; never overwrite existing files.
- Use `.task(id:)` for cancellation-aware async loading in views.
- New code that touches Photos, the filesystem, or the export destination should go through the `Protocols/` seams so it can be unit-tested with fakes.
- SwiftLint config (`.swiftlint.yml`): line length 140, several rules disabled (see file). CI runs `--strict`.
- swift-format config (`.swift-format.json`): 4-space indentation, 120-char line length.
- Website uses Prettier (with `prettier-plugin-astro`) and oxlint. Run `npm run format:check` and `npm run lint` from `website/`. Both are enforced in CI.
