# Open Tasks

Remaining work items, grouped by area. Move items to GitHub Issues when practical.

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
