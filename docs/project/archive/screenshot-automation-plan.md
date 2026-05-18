# Screenshot Automation Plan

Date: 2026-05-11 (last revised 2026-05-18)
Status: ✅ Shipped — archived as a decision record. Marketing screenshots can be captured end-to-end via `scripts/screenshots/capture.sh` — six surfaces today (Timeline, Favorites, Family, Porvoo, Trips folder, London album); adding more is a one-case-in-Swift, one-line-in-bash extension. Bundled photos are user-supplied + AI-generated (see `photo-export/Resources/screenshots/ATTRIBUTION.txt`). Manual App Store upload remains the chosen path; no Fastlane Deliver wiring.

> **Architecture update (2026-05-18; issue #67 item 1, PR #76)**: `ScreenshotPhotoLibraryService` no longer inherits from `PhotoLibraryManager`. It is now a standalone `PhotoLibraryService` conformance that the app injects into `PhotoLibraryManager` via `init(overrideService:)`; the manager forwards every PhotoLibraryService method to the injected service. The inheritance-based design described below in §"Phase 1" was the originally-shipped shape; the structural fix closed the "newly-added protocol method silently inherits production behavior" hole that the override-gate test could not catch. The 20-test behavioral pin in `ScreenshotPhotoLibraryServiceOverridesTests` still runs against the standalone class.

## Implementation Status

| Phase | Status | Notes |
|---|---|---|
| 1. `ScreenshotPhotoLibraryService` (subclass of `PhotoLibraryManager`) | ✅ Done | All 19 `PhotoLibraryService` methods overridden; sibling launch-arg escape (`PhotoLibraryManager.isRunningInScreenshotMode`); `final` dropped from `PhotoLibraryManager` with a doc-comment explaining why. |
| 2. Bundled stock JPEGs + asset wiring | ✅ Done | Curated tree (Favorites + Family + Porvoo + Trips/London + Trips/Paris) wired; 27 real photos bundled. Thumbnail resolution tries `.jpg` / `.jpeg` / `.heic` / `.png` at the bundle root with a `screenshots/` subdirectory fallback. A deterministic colored-gradient placeholder still renders for any asset id whose bundled photo is missing. |
| 3. Capture script + multi-surface routing | ✅ Done | `scripts/screenshots/capture.sh` builds Release, then per surface: launches the app with `--screenshot-mode --screenshot-surface=<key> --screenshot-width=W --screenshot-height=H`, polls for the `NSWindow.windowNumber` published to `$TMPDIR/photo-export-screenshot-window-id.txt`, captures via `screencapture -t png -o -l<id>`, kills the instance, advances. Window-id targeting is display-agnostic; no AppleScript / System Events / Accessibility required. |
| 4. Manual App Store upload | ✅ Done — manual workflow | Drag-and-drop in App Store Connect web UI. `scripts/prepare-app-store-screenshot.py` (pre-existing) handles padding to spec sizes when needed. No Fastlane Deliver wiring; revisit if cadence changes per "When to revisit" below. |

## Goals

1. Generate App Store and website screenshots without exposing the maintainer's personal Photos
   library.
2. Reproducible *enough* that "rerun the script" produces a usable screenshot set on any of the
   maintainer's machines. Byte-identical PNGs are explicitly **not** a goal (see §Non-goals).
3. Cover the surfaces users see when evaluating the app: Timeline grid, Collections sidebar +
   Favorites/album view, folder-tile grid (the feature #44 just shipped), Auto Export Settings
   pane, "What's New" sheet, Import Existing Backup flow.

## Non-goals

- Byte-deterministic captures. The cost of freezing every source of non-determinism (clock,
  appearance, accent color, animation timing, font hinting, Xcode minor version) is
  disproportionate to the visual delta on a marketing screenshot.
- Localized screenshot sets. App ships English only; revisit when localisation lands.
- CI integration. The script is run locally by the maintainer before App Store submission.
- Snapshot regression testing (use `swift-snapshot-testing` separately if that need ever lands;
  the two use cases don't share infrastructure).
- Multi-size capture for the App Store. Apple accepts a single 2880×1800 set; future-proofing
  for additional device classes is deferred until those classes exist.

## Constraints worth knowing

- **macOS App Store screenshot sizes (16:10):** 1280×800, 1440×900, 2560×1600, 2880×1800. We
  capture once at 2880×1800; Apple downscales automatically for older device-class slots.
- **Sandboxing:** the app is sandboxed for App Store. The screenshot service reads stock images
  from the app bundle, not from arbitrary filesystem paths.
- **`PhotoLibraryManager`'s test-mode escape** (`XCTestConfigurationFilePath` check at
  `PhotoLibraryManager.swift:60-69`) skips PhotoKit registration under tests. Screenshot mode
  adds a *sibling* escape — not a merged condition — because the post-conditions differ
  (tests want no auth probe; screenshot mode wants `isAuthorized = true` and a curated tree
  served).

## Architecture

### The seam

The reviewers' decisive finding: eight views inject `@EnvironmentObject private var photoLibraryManager: PhotoLibraryManager`. That's a concrete `ObservableObject`, not a protocol. Refactoring all eight sites to `any PhotoLibraryService` would be a real change touching every view consumer.

**Subclass instead.** `ScreenshotPhotoLibraryService: PhotoLibraryManager` overrides the read methods, returns curated content, and inherits the `@Published` machinery + `ObservableObject` conformance the views already depend on. The existing `XCTestConfigurationFilePath` short-circuit at `PhotoLibraryManager.swift:60-69` is the precedent: it already proves `PhotoLibraryManager` can be constructed without registering PhotoKit observers. Add a parallel guard for screenshot mode.

**Required precondition: drop `final` from `PhotoLibraryManager`.** The class is declared `final class PhotoLibraryManager: NSObject, ObservableObject, PhotoLibraryService` at `PhotoLibraryManager.swift:8`. Subclassing is rejected until the keyword is removed. Same-module subclassing means we do **not** need `open` on the methods — `internal` (the Swift default) is sufficient once the class itself is inheritable. This is a deliberate API-surface change: removing `final` invites future subclasses we haven't planned for. The countermeasure is to keep the screenshot subclass the only one and add a comment to that effect on `PhotoLibraryManager`'s declaration.

```swift
// PhotoLibraryManager.swift — sibling to isRunningInTests
private static var isRunningInScreenshotMode: Bool {
  ProcessInfo.processInfo.arguments.contains("--screenshot-mode")
}

override init() {
  super.init()
  if Self.isRunningInTests || Self.isRunningInScreenshotMode { return }
  // …existing PhotoKit registration…
}
```

```swift
// ScreenshotPhotoLibraryService.swift
final class ScreenshotPhotoLibraryService: PhotoLibraryManager {
  override init() {
    super.init()
    self.authorizationStatus = .authorized
    self.isAuthorized = true
  }
  // …overrides listed below…
}
```

#### Override surface

A previous review draft listed six overrides; the actual surface is larger. `PhotoLibraryService` (`Protocols/PhotoLibraryService.swift`) declares 17 methods that the production `PhotoLibraryManager` implements; the views being captured exercise most of them transitively. **Any method left to inherit from `PhotoLibraryManager` reaches the real Photos library** — which defeats the entire reason for screenshot mode. Override every read method on the protocol, even the ones that look unused, and let the compiler/test runner catch anything missed.

Full override list (signatures match the protocol exactly — read `PhotoLibraryService.swift` lines 12–73 verbatim, not from memory):

```swift
override func fetchAssets(year: Int, month: Int?, mediaType: PHAssetMediaType?) async throws -> [AssetDescriptor]
override func fetchAssets(in scope: PhotoFetchScope, mediaType: PHAssetMediaType?) async throws -> [AssetDescriptor]
override func fetchAssetDescriptor(for assetId: String) -> AssetDescriptor?
override func fetchCollectionTree() throws -> [PhotoCollectionDescriptor]

override func countAssets(year: Int, month: Int) throws -> Int
override func countAssets(year: Int) throws -> Int
override func countAdjustedAssets(year: Int, month: Int) async throws -> Int
override func countAdjustedAssets(year: Int) async throws -> Int
nonisolated override func countAssets(in scope: PhotoFetchScope) async throws -> Int
nonisolated override func countAdjustedAssets(in scope: PhotoFetchScope) async throws -> Int
nonisolated override func cachedCountAssets(in scope: PhotoFetchScope) async throws -> Int
nonisolated override func cachedCountAdjustedAssets(in scope: PhotoFetchScope) async throws -> Int

override func availableYears() throws -> [Int]
override func availableYearsWithCounts() throws -> [(year: Int, count: Int)]

override func startCachingThumbnails(for assets: [AssetDescriptor])
override func stopCachingThumbnails(for assets: [AssetDescriptor])
override func loadThumbnail(for assetId: String, allowNetwork: Bool) async -> NSImage?
override func loadThumbnailHighQuality(for assetId: String, allowNetwork: Bool) async -> NSImage?
override func requestFullImage(for assetId: String) async throws -> NSImage  // non-optional!
```

The four `nonisolated` overrides must keep the keyword — `nonisolated` is part of the contract, not a base-class quirk. The `cachedCount*` variants are also `nonisolated` (`PhotoLibraryService.swift:60-67`).

Caching methods (`startCachingThumbnails` / `stopCachingThumbnails`) can be safe no-ops since the screenshot service returns pre-loaded bundle images and has no PhotoKit cache to prime.

Reviewers also flagged: `FakePhotoLibraryService` (the test fake) **cannot return images** — it uses in-memory `NSImage` dicts that tests pre-populate, not bundle loading. The "reuse vs duplicate" debate is moot — bundle resolution is new code either way. Don't move the test helper into the production target (AGENTS.md: `Protocols/` are test seams; `@testable import` belongs in tests).

### Launch wiring

`photo_exportApp.swift:38` currently:

```swift
let plm = PhotoLibraryManager()
```

becomes:

```swift
let plm = ProcessInfo.processInfo.arguments.contains("--screenshot-mode")
  ? ScreenshotPhotoLibraryService()
  : PhotoLibraryManager()
```

Type stays `PhotoLibraryManager` (the subclass is one). Eight `@EnvironmentObject` sites compile unchanged.

### Bundling

- ~10 stock photos under `photo-export/Resources/screenshots/` as JPEG, ~200 KB each. CC0 from
  Unsplash or Pexels. Add `Resources/screenshots/ATTRIBUTION.txt` listing source URLs.
- **Always compiled in**, *not* `#if DEBUG`-gated. Reasoning: gating diverges the release-config
  screenshot binary from the App Store binary in ways that defeat the (residual) reproducibility
  the maintainer cares about. The 2 MB cost is small compared to the dev-tooling cost of "I have
  to switch configurations to take screenshots." If the binary bloat becomes a problem later,
  the gate is one line.

### Curated tree (as shipped)

```
Favorites           (synthetic — family-1, porvoo-1, london-1, paris-1)
"Family"            (top-level album, 6 photos)
"Porvoo"            (top-level album, 7 photos)
Folder "Trips"
  ├── "London"      (7 photos)
  └── "Paris"       (7 photos)
```

27 photos total. The `Trips` folder is intentional — it gives the screenshot
capture for the new folder-export feature a meaningful subject (folder grid
shows two album-tile children with 4-up cover thumbnails and a working
"Export 2 Albums" toolbar action).

Asset counts in `countAssets(in:)` could return larger values than the bundle contains
to inflate the sidebar/toolbar numbers ("4,812 exported") for marketing realism — currently
they return the actual asset counts. Lie about counts in `countAssets(in:)` if the marketing
copy wants bigger numbers; the photo grid only renders what `fetchAssets` returns.

Source attribution for the bundled photos lives in
`photo-export/Resources/screenshots/ATTRIBUTION.txt` (Porvoo / London / Paris by the
maintainer; Family AI-generated).

## The capture pipeline (as shipped)

`scripts/screenshots/capture.sh` is the entrypoint. One build, then per surface:
launch the app with `--screenshot-mode --screenshot-surface=<key> --screenshot-width=W --screenshot-height=H`,
poll for `$TMPDIR/photo-export-screenshot-window-id.txt`, capture via
`screencapture -t png -o -l<window-id>`, kill the instance, advance.

Default surface set (six captures):

```
01-timeline                   → Timeline, current month
02-collections-favorites      → Favorites grid
03-collections-album-family   → Family album
04-collections-album-porvoo   → Porvoo album
05-collections-folder-trips   → Trips folder grid (showcases folder export)
06-collections-album-london   → London album
```

The script accepts positional arguments to capture a subset:

```
scripts/screenshots/capture.sh 1440x900 collections-folder-trips
```

Adding a new surface is two changes: a new `case` in
`LibraryRootView.requestedScreenshotSurface()` mapping a key to a
`(section, selection)` tuple, and a new entry in `DEFAULT_SURFACES` in
`capture.sh`.

**Window sizing**: the app reads `--screenshot-width` / `--screenshot-height` in
`photo_exportApp.applyScreenshotWindowSizeIfRequested()` and calls
`NSWindow.setFrame` on first appearance. After the resize settles, it publishes
`NSWindow.windowNumber` to the temp file the script reads.

**Why window-id capture**: an earlier draft used `screencapture -R x,y,w,h` against
AppleScript-reported window bounds, which broke on multi-display setups because
`-R` always targets the main display. Window-id targeting works regardless of
display, and it eliminates the `tell process` Apple-event chain that needed
both Automation and Accessibility TCC grants. Net: one permission to grant
(Screen Recording on the shell host), zero AppleScript.

## App Store delivery

Drag-and-drop into App Store Connect's web UI. ~90 seconds per submission, ~4 submissions/year.
Fastlane Deliver is over-investment at this cadence; revisit only if the cadence picks up or
if a multi-locale set materialises.

## Actual cost (post-shipping retrospective)

The original estimate was ~6 hours. Reality landed closer to a full day of work spread
across iterations. Costs that the plan undersold:

- AppleScript / TCC rabbit hole. The first capture pipeline drove the app via System Events
  and needed Automation + Accessibility permissions. The second drove it via AppleScript +
  `screencapture -R` against window bounds — broken on multi-display setups. Third pivot:
  app publishes its window-id, script captures by id. Net rewrites: 3.
- `NSSplitView` divider persistence. SwiftUI's `navigationSplitViewColumnWidth` modifiers
  were silently overridden by the per-user persisted divider positions. Required a clear in
  screenshot mode at `photo_exportApp.init`.
- AutoSync side-effects. `PhotoLibraryPersistentChangeAdapter.start()` calls
  `library.currentChangeToken` + `library.register(self)`, which trigger the Photos TCC
  prompt even when the screenshot service overrides everything else. Needed an explicit
  gate at `photo_exportApp.swift:191-224` to skip the AutoSync wiring entirely in
  screenshot mode.

Ongoing per-submission cost: ~5 minutes (build is cached; six captures at ~3s each;
manual drag-and-drop into App Store Connect).

## When to revisit

Any of these makes the script-based approach hurt enough to justify the original plan's XCUITest + Fastlane pipeline:

- Localisation lands → 10 photos × N locales becomes manual hell.
- Submission cadence drops below quarterly (e.g. weekly TestFlight builds want fresh screenshots).
- A second person needs to take screenshots → reproducibility on someone else's Mac becomes load-bearing.
- The website wants screenshots that update on every PR → CI integration becomes non-optional.

Until then, the hobbyist version ships.

## Open questions (post-shipping)

- **Stock photo curation**: bundled in the repo under `photo-export/Resources/screenshots/`.
  27 photos / ~10 MB. Attribution in `ATTRIBUTION.txt`. Could be `#if DEBUG`-gated if binary
  size becomes a concern — chose not to gate so the screenshot binary stays bit-identical to
  the App Store binary modulo the launch arg.
- **Animation in the captures**: the export progress bar would animate if running. Today's
  capture surfaces are all idle states (no in-progress export), so this hasn't surfaced.
  When we add an export-progress capture, will need to either pause the queue mid-capture
  or accept retake-if-bad.
- **Auto Export menu bar item**: still unsolved. Renders outside the app window so
  `screencapture -l<window-id>` can't see it. Either capture the full screen with
  `screencapture -t png` (then crop), or live with the menu bar item being an inline
  marketing screenshot rather than a script-captured one. Deferred.
- **Asset-detail capture**: the timeline capture's detail pane happens to show whichever
  asset hashes into the selected month. To showcase a specific photo (e.g. an edited photo
  with `_orig` companion) we'd need a `--screenshot-asset=<id>` arg that pre-selects an
  asset. Easy follow-up if marketing wants it.

## Resolved questions

- ~~"What's New" sheet on screenshot launch~~ → suppressed in screenshot mode via
  `WhatsNewState.markAsSeen()` call at app init.
- ~~Onboarding gate~~ → screenshot mode writes `hasCompletedOnboarding=true` to
  UserDefaults at app init so the capture never lands on OnboardingView.
