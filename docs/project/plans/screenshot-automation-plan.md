# Screenshot Automation Plan

Date: 2026-05-11
Status: Proposed (not started). Revised after multi-agent review (hobbyist / DevOps / Swift architect) — the original plan's XCUITest + Fastlane Deliver pipeline was over-engineered for a quarterly side-project release cadence, and its Phase 2 launch-argument switch as written would not have compiled (eight views use `@EnvironmentObject private var photoLibraryManager: PhotoLibraryManager` — concrete class, not protocol).

## Implementation Status

| Phase | Status | Notes |
|---|---|---|
| 1. `ScreenshotPhotoLibraryService` (subclass of `PhotoLibraryManager`) | ⏳ Proposed | Curated synthetic tree, bundle-loaded JPEGs, sibling launch-arg escape to the existing test-mode one. |
| 2. Bundled stock JPEGs + asset wiring | ⏳ Proposed | ~10 photos, ~200 KB each, ~2 MB total. Always compiled in; reachability gated on the launch arg. |
| 3. AppleScript driver + `screencapture` script | ⏳ Proposed | One bash script + one AppleScript file. No XCUITest. |
| 4. Manual App Store upload | ⏳ Proposed | Drag-and-drop in App Store Connect web UI. No Fastlane Deliver. |

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

### Curated tree

```
Favorites (5 photos)
"Iceland 2025"   (top-level album, 4 photos)
"Family"         (top-level album, 3 photos)
"Hiking"         (top-level album, 3 photos)
Folder "Trips"
  ├── "Iceland"  (3 photos)
  └── "Norway"   (3 photos)
```

Asset counts in `countAssets(in:)` can return larger values than the bundle contains — the
sidebar/toolbar shows "12 / 4,812 exported", and the photo grid only renders what's
returned from `fetchAssets`. Lie about counts for marketing realism.

## The capture script

`scripts/screenshots/capture.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
mkdir -p screenshots
xcodebuild -project photo-export.xcodeproj -scheme "photo-export" \
  -configuration Release -derivedDataPath build/screenshots \
  CODE_SIGNING_ALLOWED=NO build
APP_PATH="build/screenshots/Build/Products/Release/Photo Export.app"
open "$APP_PATH" --args --screenshot-mode --screenshot-width=2880 --screenshot-height=1800
sleep 2
osascript scripts/screenshots/drive.applescript
```

`scripts/screenshots/drive.applescript` walks the app through each surface and calls
`screencapture -l<windowID> -t png screenshots/NN-name.png` between steps. Window ID via
`tell app "System Events" to get id of window 1 of process "Photo Export"`.

**Window sizing** is the trickiest bit. Two options:

1. AppleScript sets the window frame after launch
   (`set bounds of window 1 to {0, 0, 2880, 1800}`).
2. The app reads `--screenshot-width`/`--screenshot-height` args and applies in `onAppear` on
   the root window.

Option 2 is more reliable across macOS versions. Start there; fall back to option 1 only if
the app's window controller resists programmatic sizing.

## App Store delivery

Drag-and-drop into App Store Connect's web UI. ~90 seconds per submission, ~4 submissions/year.
Fastlane Deliver is over-investment at this cadence; revisit only if the cadence picks up or
if a multi-locale set materialises.

## Cost estimate

- Phase 1 (subclass + 19 method overrides + un-finaling base class): **~3 hours**. Most overrides
  are short — a `nonisolated` `countAssets(in:)` that returns a hardcoded number is 2 lines —
  but 19 of them with correct signatures + isolation keywords adds up. Initial estimate of "6
  overrides" was wrong; auditing the protocol bumped it to 17 protocol methods plus 2
  `cachedCount*` siblings.
- Phase 2 (bundle + curated tree + stock photo curation): **~2 hours**, dominated by collecting
  + cropping stock photos and matching them to plausible album themes.
- Phase 3 (AppleScript + bash + window sizing): **~1 hour**, longer if the window-frame approach
  fights us.
- Phase 4 (first manual upload): **~10 minutes**.

Total: **~6 hours** for initial setup, ~10 minutes per submission thereafter. Up from the
original ~4-hour estimate after a re-review caught the undersized override surface — leaving
methods to inherit means they reach the real Photos library, which defeats the entire feature.

## When to revisit

Any of these makes the script-based approach hurt enough to justify the original plan's XCUITest + Fastlane pipeline:

- Localisation lands → 10 photos × N locales becomes manual hell.
- Submission cadence drops below quarterly (e.g. weekly TestFlight builds want fresh screenshots).
- A second person needs to take screenshots → reproducibility on someone else's Mac becomes load-bearing.
- The website wants screenshots that update on every PR → CI integration becomes non-optional.

Until then, the hobbyist version ships.

## Open questions

- **Stock photo curation**: keep the curated set under version control or as a separate
  release artifact? Bundle in the repo is simpler; ~2 MB doesn't move the dial.
- **Animation in the captures**: the export progress bar animates. The script `sleep`s briefly
  before `screencapture` — if the bar is mid-animation in the capture it'll look odd. Pause
  briefly in screenshot mode? Or just accept and recapture if a frame lands badly.
- **"What's New" sheet on screenshot launch**: it auto-shows on first launch of a new version.
  In screenshot mode the sheet should either auto-dismiss (so it's not in every screenshot) or
  be captured deliberately and then dismissed. Drive via AppleScript.
- **Auto Export menu bar item**: renders outside the app window. Either capture full-screen
  with `screencapture -t png` (then crop) or live with the menu bar item being an inline
  screenshot in marketing copy rather than its own automated capture.
