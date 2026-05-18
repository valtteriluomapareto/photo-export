# Open Tasks

Remaining work items, grouped by area. Move items to GitHub Issues when practical.

## Architecture follow-ups

Tracked as checkboxes in [issue #67](https://github.com/valtteriluomapareto/photo-export/issues/67). The May 2026 refactor's six items mostly landed via PRs #75 and #76; the residual cleanup is below.

- [x] **PhotoLibrary composition refactor** — landed (PR #76). Inheritance dropped, `PhotoLibraryManager` is `final` with an optional `overrideService`, `ScreenshotPhotoLibraryService` is a standalone peer. The full ~970-line extraction of a `ProductionPhotoLibraryService` peer was deferred — tracked separately as a residual cleanup so the per-method early-return forwarders on `PhotoLibraryManager` can eventually be deleted in favor of a thin forwarding façade. File a fresh issue when ready to pick this up.
- [x] **Generation-counter ownership transfer** — landed (PR #76). `var generation` lives on `ExportQueueCoordinator`; `VariantExporter` and `ImportCoordinator` hold a direct weak reference; `Host.generation` / `Host.isCurrent` / `Host.bumpGeneration` getters are deleted.
- [x] **Remaining Phase 7 folder moves** — landed (PR #76). `App/`, `Destination/`, `Export/` exist; `Managers/` is gone. `RecordStoreRouter` stays in `Records/` (defensible per the records-coupling rationale; revisit if a future change wants it co-located with `ExportManager`).
- [x] **AutoSync seam coverage during `isEnqueueingAll` window** — landed (PR #76). `exportRunStatePublisher` is now `CombineLatest4` over `($activeRunContext, $isRunning, $queueCount, $isEnqueueingAll)`; the bulk-enqueue window registers as `manualActive`. New regression test in `AutoSyncSeamCharacterizationTests`.
- [x] **Consolidate the `start*` family with a shared bulk-loop helper** — landed (PR #76). `runBulkExportTask` + `runBulkEnqueueLoop` shared by `startExportAll`, `startExportTimelineSelection`, `startExportCollectionsSelection`, and `enqueueBulkAlbumExport`.
- [x] **Regression-gate symbol-existence guard in CI** — landed (PR #75). `scripts/ci/check-regression-gates.sh` greps the test files for each documented gate symbol and fails CI if any is missing.

See [`docs/reference/architecture-conventions.md`](../reference/architecture-conventions.md) for the contracts these items extend.

## UI

- [ ] Add filter control for media type (photos/videos) — backend supports `mediaType` parameter, needs UI toggle
- [ ] Visually indicate newly added assets for partially exported months — blue dot exists for unexported assets, but no "new since last export" indicator

## Features

- [x] Allow user to export a custom selection (multi-select) — sidebar Cmd/Shift-click in both Timeline and Collections (issue #46)
- [ ] Live-update sidebar and grid when Photos library changes — `PHPhotoLibraryChangeObserver` is adopted but only clears the cache; views don't reload automatically
- [ ] Manual refresh to rescan library on demand
- [ ] Add video playback in asset detail view — currently shows static image only
- [ ] Allow user to retry failed exports

## Performance

- [ ] Ensure video previews display quickly and at suitable size
- [ ] Add bounded concurrent export queue (2-3 workers) with a configurable limit — currently sequential

## Usability

- [ ] Follow macOS Human Interface Guidelines
- [ ] Add subtle animations where appropriate
- [ ] Ensure good accessibility for all interactive elements
- [ ] Persist filter choices and other relevant settings
- [ ] Remember window state and last viewed month/year
