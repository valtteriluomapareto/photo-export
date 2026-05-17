# Open Tasks

Remaining work items, grouped by area. Move items to GitHub Issues when practical.

## Architecture follow-ups

Tracked as checkboxes in [issue #67](https://github.com/valtteriluomapareto/photo-export/issues/67). All three are deliberate deferrals from the May 2026 architecture refactor; each is safe to land independently.

- [ ] **PhotoLibrary composition refactor** — drop `ScreenshotPhotoLibraryService: PhotoLibraryManager` inheritance, extract a `ProductionPhotoLibraryService` peer, mark `PhotoLibraryManager` `final` with an injected `PhotoLibraryService`. ~973 lines of PhotoKit code. Today protected by `ScreenshotPhotoLibraryServiceOverridesTests` (20 tests).
- [ ] **Generation-counter ownership transfer** — move `var generation: Int` storage from `ExportManager` into `ExportQueueCoordinator` and delete the `Host.generation` / `Host.isCurrent` / `Host.bumpGeneration` getters on the three collaborator Host protocols. Mechanical storage move + Host-method deletion.
- [ ] **Remaining Phase 7 folder moves** — `Destination/`, `Export/`, `App/` not yet created. Filesystem-synchronized groups make moves Xcode-config-free; can land opportunistically.
- [ ] **AutoSync seam coverage during `isEnqueueingAll` window** — `exportRunStatePublisher` does not currently include `isEnqueueingAll`. Add a characterization test and decide whether the bulk-enqueue window should be observable as `manualActive`.
- [ ] **Consolidate the `start*` family with a shared bulk-loop helper** — best landed together with the AutoSync seam fix above.

See [`docs/reference/architecture-conventions.md`](../reference/architecture-conventions.md) for the contracts these items extend.

## UI

- [ ] Add filter control for media type (photos/videos) — backend supports `mediaType` parameter, needs UI toggle
- [ ] Visually indicate newly added assets for partially exported months — blue dot exists for unexported assets, but no "new since last export" indicator

## Features

- [ ] Allow user to export a custom selection (multi-select)
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
