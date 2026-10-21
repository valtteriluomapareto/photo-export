# Edited Video Export Plan

Date: 2026-05-01
Status: Shipped via PR #21 (commit `9d4f7a0`); archived as a decision record.
`ResourceSelection.selectEditedProducer` routes edited video to
`ProductionMediaRenderer`, backed by `PHImageManager.requestExportSession` and
`AVAssetExportSession`. `VideoExportExecutorTests` and
`ExportManagerVideoRenderTests` cover the renderer and pipeline. The problem and
proposed steps below describe the pre-fix state; current behavior is documented in
[Features](../../../website/src/content/docs/features.md).
Tracking: [#18](https://github.com/valtteriluomapareto/photo-export/issues/18)

## Summary

Edited videos currently fail with `"Edited version was not provided by Photos. Future exports will try again."` and never produce a file. The pipeline asks `ResourceSelection.selectEditedResource` for a `.fullSizeVideo` `PHAssetResource`, PhotoKit returns nothing for most edited videos, the variant is recorded `.failed`, and the user sees a recoverable copy that hints at a future retry that will never succeed.

The fix renders edited videos through `PHImageManager.requestExportSession(forVideo:options:exportPreset:)` and runs an `AVAssetExportSession`. Three cross-cutting design decisions shape the rest of the plan:

1. **Producer-level dispatch.** Byte-source selection moves into `ResourceSelection` as an enum (`EditedProducer.resource | .render | .none`), so `ExportManager` no longer carries an inline boolean for "is this a render?". The producer carries the metadata needed to derive the destination filename, removing the `destinationResource ?? selectOriginalResource` smell from the previous draft.
2. **Forward-compatible renderer seam.** A `MediaRenderer` protocol with a single `render(request:)` method (rather than `renderEditedVideo`) keeps the door open for future Live-Photo motion edits or other manager-rendered content without a rename later.
3. **In-scope render-state hint.** The toolbar shows `IMG_xxxx.MOV (rendering…)` / `(downloading…)` so a long render is not perceived as a hang. This was an open question; it is now in scope for v1 because long renders without it will be the dominant new perception of the feature.

The output preserves the original file extension and uses `AVAssetExportPresetHighestQuality`. When the render fails, the variant is recorded `.failed` with `ExportVariantRecovery.editedResourceUnavailableMessage`. The persisted `lastError` string stays the same (so legacy records still match), but the user-facing copy is softened to be accurate across both the resource-missing and the render-failed cases.

## Problem and Root Cause

### Symptom

Issue #18: edited videos never export. The toolbar progresses, the asset is counted complete, but no file is written and the inspector shows the recoverable failure copy.

### Trace

1. `ExportManager.exportSingleVariant` (`ExportManager.swift:566`) calls `ResourceSelection.selectEditedResource(from: resources, mediaType: .video)`.
2. `ResourceSelection.selectEditedResource` (`ResourceSelection.swift:64`) returns `resources.first(where: { $0.type == .fullSizeVideo })`.
3. `PHAssetResource.assetResources(for: asset)` — used to build `resources` in `PhotoLibraryManager.resources(for:)` — almost never includes `.fullSizeVideo` for an edited video, because Photos does not pre-render edited videos as static resources. The edit is `original bytes + adjustment data`, rendered on demand.
4. `selectEditedResource` returns nil.
5. `exportSingleVariant` (`ExportManager.swift:577–589`) hits the `guard let resource else` branch, records `.failed` with `ExportVariantRecovery.editedResourceUnavailableMessage`, and returns nil.
6. `ExportRecord.swift:55–56` maps that message to `"\(label) version was not provided by Photos. Future exports will try again."`.

### Why "future exports will try again" never works

The retry is real — `editedResourceUnavailableMessage` is intentionally classified as recoverable so a future export run reattempts the variant. The reattempt fails the same way for the same reason, because the missing `.fullSizeVideo` resource is not transient. PhotoKit will keep refusing to expose a static edited video resource for these assets.

### Why this gap was anticipated

The archived `docs/project/archive/edited-photos-modes-redesign-plan.md` notes:

> "For videos, the first implementation uses `.fullSizeVideo` through the existing resource writer. `requestExportSession` remains a possible future refinement if resource export proves insufficient."

This plan picks up that deferred work.

## Goals

- Export edited videos correctly when Photos has adjustments on the asset.
- Preserve the original file's extension on the rendered output (`.MOV` stays `.MOV`, `.MP4` stays `.MP4`).
- Use `AVAssetExportPresetHighestQuality` so the rendered output preserves as much fidelity as the preset allows.
- Surface render activity in the toolbar so long renders do not look like a hang.
- Keep the persisted recoverable `lastError` string stable (`"Edited resource unavailable"`) and soften only the user-facing copy.
- Stay within the existing `ExportManager` pipeline: same generation/cancel discipline, same record-store transitions, same `_orig`-companion semantics for `editedWithOriginals` mode.
- Keep tests deterministic by introducing a protocol seam analogous to `AssetResourceWriter` and a test executor seam under it for the AVAssetExportSession status-mapping logic.

## Non-Goals

- Live Photo paired-video export. The motion file inside a Live Photo is a separate code path (`.pairedVideo` resource type) and is out of scope.
- Per-asset codec selection or HDR/Dolby Vision preservation guarantees. `AVAssetExportPresetHighestQuality` is what `AVAssetExportSession` offers; we accept its limits.
- Slow-motion frame-rate metadata preservation beyond what `requestExportSession` returns. We do not custom-build an `AVAssetExportSession` from scratch.
- ProRes-quality output for HEVC originals. Source codec drives session capabilities; we use what PhotoKit gives us.
- Audio-mix overrides. The `audioMix` returned by PhotoKit (when applicable) is preserved as-is.
- Concurrency changes. The pipeline still runs sequentially, one asset at a time.
- Changes to the unedited-video path. Those continue to use `selectOriginalResource` + `PHAssetResourceManager.writeData`.
- Per-asset render-progress percentage in the UI. The toolbar gets a textual `(rendering…)` / `(downloading…)` hint, not a sub-progress bar.

## Approach

### Producer-level dispatch

`ResourceSelection.selectEditedResource` currently returns `ResourceDescriptor?`. That return shape forces callers to ask "if nil, do I render?" inline. Replace it with an enum that names the byte source:

```swift
enum EditedProducer {
  /// Write the static resource directly via AssetResourceWriter.
  case resource(ResourceDescriptor)
  /// Render via MediaRenderer. The carried request holds everything needed to
  /// derive the destination filename and run the export session.
  case render(MediaRenderRequest)
  /// No edited-side bytes available for this asset.
  case none
}
```

`MediaRenderRequest` (defined alongside the renderer protocol):

```swift
struct MediaRenderRequest: Sendable, Equatable {
  /// Photos library identifier of the asset to render.
  let assetId: String
  /// Original-side filename used to derive the on-disk extension and to drive
  /// `resolveDestination`'s pairing/collision logic. Identical role to
  /// `ResourceDescriptor.originalFilename`.
  let originalFilename: String
  /// AVFoundation file type derived from `originalFilename`'s extension.
  let fileType: AVFileType
  /// Media kind. Today only `.video` produces a render request; future Live
  /// Photo motion edits would extend this enum.
  let kind: Kind

  enum Kind: Sendable { case video }
}
```

`ResourceSelection.selectEditedProducer(from:mediaType:descriptor:)` becomes the single decision point:

```swift
static func selectEditedProducer(
  from resources: [ResourceDescriptor],
  mediaType: PHAssetMediaType,
  descriptor: AssetDescriptor
) -> EditedProducer {
  switch mediaType {
  case .image:
    if let r = resources.first(where: { $0.type == .fullSizePhoto }) { return .resource(r) }
    return .none
  case .video:
    if let r = resources.first(where: { $0.type == .fullSizeVideo }) { return .resource(r) }
    if descriptor.hasAdjustments,
       let original = resources.first(where: { $0.type == .video }) {
      return .render(.init(
        assetId: descriptor.id,
        originalFilename: original.originalFilename,
        fileType: avFileType(forOriginalFilename: original.originalFilename),
        kind: .video
      ))
    }
    return .none
  default:
    return .none
  }
}
```

Notes:
- The legacy `selectEditedResource(from:mediaType:)` is removed in this PR. Grep confirms only `ExportManager` and `ResourceSelectionTests` call it; `BackupScanner` uses the type predicates (`isEditedResource` / `isOriginalResource`), not the selector. Both call sites switch to `selectEditedProducer` here.
- The render branch is video-only. Asserting that explicitly in the type means widening the render path to images later is an enum-extension change, not an `if` change scattered through `ExportManager`.

### Pipeline integration in `exportSingleVariant`

The dispatch site collapses to a single switch:

```swift
let originalProducer = (variant == .original)
  ? ResourceSelection.selectOriginalResource(from: resources, mediaType: descriptor.mediaType)
      .map(EditedProducer.resource) ?? .none
  : ResourceSelection.selectEditedProducer(from: resources, mediaType: descriptor.mediaType, descriptor: descriptor)

let producer = originalProducer  // .resource / .render / .none

switch producer {
case .none:
  let errMsg: String = (variant == .original) ? "No exportable resource"
                                              : ExportVariantRecovery.editedResourceUnavailableMessage
  exportRecordStore.markVariantFailed(...)
  return nil

case .resource(let resource):
  let (finalURL, chosenStem) = try resolveDestination(
    variant: variant, descriptor: descriptor,
    originalFilename: resource.originalFilename, /* extension source */
    resources: resources, destDir: destDir,
    groupStem: groupStem, pairOriginalWithSuffix: pairOriginalWithSuffix
  )
  let tempURL = finalURL.appendingPathExtension("tmp")
  // tmp cleanup, defer, throwIfCancelledOrStale, currentAssetFilename, inFlight, markVariantInProgress as today
  try await assetResourceWriter.writeResource(resource, forAssetId: descriptor.id, to: tempURL)
  // post-write checkpoints, atomic move, timestamps, markVariantExported as today

case .render(let request):
  let (finalURL, chosenStem) = try resolveDestination(
    variant: variant, descriptor: descriptor,
    originalFilename: request.originalFilename,
    resources: resources, destDir: destDir,
    groupStem: groupStem, pairOriginalWithSuffix: pairOriginalWithSuffix
  )
  let tempURL = finalURL.appendingPathExtension("tmp")
  // tmp cleanup, defer, throwIfCancelledOrStale, currentAssetFilename, inFlight, markVariantInProgress as today
  inFlight = (assetId: descriptor.id, variant: variant)  // <-- explicit, same as resource path
  exportManager.renderActivity = .downloading // initial; flips to .rendering when bytes start (see Toolbar UX)
  defer { exportManager.renderActivity = nil }
  try await mediaRenderer.render(request: request, to: tempURL)
  // post-write checkpoints, atomic move, timestamps, markVariantExported as today
}
```

Concrete deltas vs. the previous draft:
- Single dispatch point. No `editedVideoNeedsRender` boolean. No `destinationResource ?? selectOriginalResource(.video)` fallback. No "unreachable" comment.
- `resolveDestination` is refactored to take `originalFilename: String` rather than `resource: ResourceDescriptor`. Internally, the only field it ever reads is `resource.originalFilename` (for the extension and the stem) — see `ExportManager.swift:677–720`. Threading the string through is clearer at the call site and lets the render path supply the value without inventing a `ResourceDescriptor`.
- `inFlight = (assetId, variant)` is set in both branches — the previous draft elided this in the render-path pseudo-code; making it explicit prevents a cancel-cleanup regression.
- `renderActivity` is the new `@Published` flag (see Toolbar UX). Set to `.downloading` before the request (because PhotoKit may need to fetch the original from iCloud before it returns an export session), set to `.rendering` once the executor reports the session is ready, cleared in `defer`.

### Why `requestExportSession` and not `requestAVAsset` + DIY composition

`PHImageManager.requestExportSession(forVideo:options:exportPreset:)`:

- Returns a fully configured `AVAssetExportSession` that already honours `version: .current`, embedded adjustments, and any `audioMix` Photos applies.
- Handles iCloud-only originals via `options.isNetworkAccessAllowed = true`.
- Reports progress (we don't bind it to the bar in v1; it's available later).
- Avoids us building and reasoning about `AVMutableComposition` / `AVVideoComposition`.

`requestAVAsset(forVideo:options:resultHandler:)` would force us to build the export session ourselves, re-implementing parts of what Photos does for adjustments. Not worth it.

### File-extension and AVFileType mapping

The original `.video` `PHAssetResource`'s `originalFilename` extension drives both the on-disk extension and the `AVAssetExportSession.outputFileType`:

| Original extension (lowercased) | `AVFileType` | Notes                                 |
| ------------------------------- | ------------ | ------------------------------------- |
| `mov`                           | `.mov`       | QuickTime — most iPhone videos        |
| `mp4`                           | `.mp4`       | MPEG-4 — some imports                 |
| `m4v`                           | `.m4v`       | iTunes-style MPEG-4                   |
| any other (e.g. `avi`, `mkv`, no extension, multi-dot like `clip.final.mov`) | fall back to `.mov`, keep original on-disk extension verbatim | safe default |

`outputFileType` and the on-disk extension are independent. We use the original extension verbatim on disk (case preserved); we pick the closest `AVFileType` for the session. The fall-back covers exotic originals the export session may still be able to render (the session may also fail; mapped to recoverable failure).

We do not "upgrade" containers or transcode to a smaller container even if the session would technically permit it. The user asked for original-extension preservation and we keep that promise even when suboptimal.

### Quality preset

`AVAssetExportPresetHighestQuality`. Trade-offs:

- Adapts to source resolution; uses passthrough where possible. Not lossless — Photos always renders edits, and the export session always re-encodes when there's a video composition.
- Slow-motion / time-lapse: the export session preserves rate-of-change metadata authored in Photos.
- Cinematic mode: `version: .current` returns the user-applied focus track; the session renders it as a flat video. Acceptable.
- HDR: preserved when source is HDR and the chosen file type supports it. Not explicitly enforced; covered by manual test.

### `_orig` companion in `editedWithOriginals` mode

The pairing logic in `exportEditedAndPossiblyOriginal` already enqueues both variants for adjusted assets. With the fix:

- `.edited` writes the rendered bytes via the new path.
- `.original` writes the canonical `.video` resource via the existing writer.
- The shared group stem and `_orig` suffix policy in `ExportFilenamePolicy` still apply; the only change is that the `.edited` filename now carries the original extension (e.g. `IMG_1234.MOV`) rather than depending on a `.fullSizeVideo` resource that doesn't exist.

User-visible result for an edited HEVC `.MOV`: `IMG_1234.MOV` (rendered edit) and `IMG_1234_orig.MOV` (original) side by side. Both files have the same extension; the `_orig` suffix is the only filename differentiator. Documented explicitly in the website docs (see Documentation Sync).

## API Surface

### `MediaRenderer` (new protocol)

```swift
// photo-export/Protocols/MediaRenderer.swift
import AVFoundation
import Foundation

/// Renders managed media (currently edited videos) to a destination URL.
/// Production wraps PHImageManager.requestExportSession + AVAssetExportSession.
/// Tests inject a fake. Forward-compatible with future render kinds via
/// MediaRenderRequest.Kind.
protocol MediaRenderer: Sendable {
  func render(request: MediaRenderRequest, to url: URL) async throws
}
```

### `ProductionMediaRenderer` (new) with `VideoExportExecutor` test seam

```swift
// photo-export/Managers/ProductionMediaRenderer.swift
struct ProductionMediaRenderer: MediaRenderer {
  private let executor: VideoExportExecutor
  private let activity: (RenderActivity?) -> Void  // injected toolbar-state hook

  init(
    executor: VideoExportExecutor = LiveVideoExportExecutor(),
    activity: @escaping (RenderActivity?) -> Void
  ) {
    self.executor = executor
    self.activity = activity
  }

  func render(request: MediaRenderRequest, to url: URL) async throws {
    activity(.downloading)
    let session = try await executor.requestSession(for: request)
    activity(.rendering)
    try await withTaskCancellationHandler {
      try await executor.runExport(session: session, to: url, fileType: request.fileType)
    } onCancel: {
      executor.cancel(session: session)
    }
  }
}

protocol VideoExportExecutor: Sendable {
  func requestSession(for request: MediaRenderRequest) async throws -> ExportSessionHandle
  func runExport(session: ExportSessionHandle, to url: URL, fileType: AVFileType) async throws
  func cancel(session: ExportSessionHandle)
}

/// Opaque handle so tests don't depend on AVAssetExportSession concrete type.
final class ExportSessionHandle: @unchecked Sendable {
  let underlying: AnyObject  // AVAssetExportSession in production; a stub in tests
  init(_ underlying: AnyObject) { self.underlying = underlying }
}
```

`LiveVideoExportExecutor` is the production implementation:

- `requestSession` calls `PHImageManager.default().requestExportSession(forVideo:options:exportPreset:)` with `options.version = .current`, `options.deliveryMode = .highQualityFormat`, `options.isNetworkAccessAllowed = true`, preset `AVAssetExportPresetHighestQuality`. Resolves the `PHAsset` via `PHAsset.fetchAssets(withLocalIdentifiers: [request.assetId], options: nil)`.
- `runExport` sets `outputURL` / `outputFileType` / `shouldOptimizeForNetworkUse = false`, calls `exportAsynchronously`, and maps `AVAssetExportSession.Status` to throws/returns. Cancellation throws `CancellationError()`. All other terminal failures throw the underlying `session.error` (or a fallback `NSError`).
- `cancel` calls `(session.underlying as? AVAssetExportSession)?.cancelExport()`.

Why this seam shape instead of the previous draft's closure-based `Backend`:
- The status-mapping logic (`completed` / `cancelled` / `failed` / default) is the failure-prone part. Naming it `runExport` and giving it a faked input lets tests drive every branch without real `PHImageManager`.
- `requestSession` separation lets tests cover the multi-callback question (Open Question #1) at the seam: a fake executor whose `requestSession` invokes its handler twice can verify the production code resumes its continuation exactly once.
- `cancel` is a separate entry point so the `withTaskCancellationHandler` wiring is testable without a real export session.

### `MediaRenderRequest` (new value type)

Defined above; lives next to the protocol.

### `RenderActivity` (new)

```swift
// photo-export/Models/RenderActivity.swift
enum RenderActivity: Sendable, Equatable {
  case downloading  // PhotoKit is fetching the iCloud original
  case rendering    // AVAssetExportSession is actively writing
}
```

### `ExportManager` published state addition

```swift
@Published private(set) var renderActivity: RenderActivity?
```

Set by the renderer's `activity` callback (production wiring closes over `[weak self]` and updates on `MainActor`). Cleared in the render-path `defer`.

### `ExportToolbarView` change

Replace the current `Text(exportManager.currentAssetFilename ?? "")` (`ExportToolbarView.swift:180`) with a computed string:

```swift
private var currentAssetLabel: String {
  let filename = exportManager.currentAssetFilename ?? ""
  switch exportManager.renderActivity {
  case .none:        return filename
  case .downloading: return filename.isEmpty ? "Downloading…" : "\(filename) (downloading…)"
  case .rendering:   return filename.isEmpty ? "Rendering…" : "\(filename) (rendering…)"
  }
}
```

Plus `.accessibilityLabel("Currently exporting \(currentAssetLabel)")` on the same `Text` — captured here because the existing label has no a11y label and the new state matters for VoiceOver.

### `ExportManager.init` signature

```swift
init(
  photoLibraryService: any PhotoLibraryService,
  exportDestination: any ExportDestination,
  exportRecordStore: ExportRecordStore,
  assetResourceWriter: any AssetResourceWriter = ProductionAssetResourceWriter(),
  mediaRenderer: any MediaRenderer = makeDefaultMediaRenderer(),
  fileSystem: any FileSystemService = FileIOService()
)
```

`makeDefaultMediaRenderer()` is a small static factory that wires `ProductionMediaRenderer` with an `activity` closure that posts to `ExportManager` on the main actor. This avoids a self-reference cycle in init while keeping the dependency-injection story clean.

### `FakeMediaRenderer` (new test helper)

```swift
// photo-exportTests/TestHelpers/FakeMediaRenderer.swift
final class FakeMediaRenderer: MediaRenderer, @unchecked Sendable {
  struct RenderCall: Equatable {
    let request: MediaRenderRequest
    let url: URL
  }

  private let lock = NSLock()
  private var _renderCalls: [RenderCall] = []
  var renderCalls: [RenderCall] { lock.lock(); defer { lock.unlock() }; return _renderCalls }

  // All injection points are lock-guarded so parallel Swift Testing runs are safe.
  private var _renderError: Error?
  private var _shouldCreateFile: Bool = true
  private var _fileWriter: ((URL) -> Void)?
  private var _renderDelay: Duration?
  private var _renderLatch: AsyncSemaphore?

  var renderError: Error? {
    get { lock.lock(); defer { lock.unlock() }; return _renderError }
    set { lock.lock(); _renderError = newValue; lock.unlock() }
  }
  // (similar accessors for the other knobs)

  /// Optional latch for cancel-during-render tests. Test arms it; render call
  /// awaits it before doing anything; test releases it after triggering cancel.
  func arm(latch: AsyncSemaphore) { lock.lock(); _renderLatch = latch; lock.unlock() }

  func render(request: MediaRenderRequest, to url: URL) async throws {
    if let latch = _renderLatch { await latch.wait() }
    if let delay = _renderDelay { try await Task.sleep(for: delay) }
    lock.lock(); _renderCalls.append(.init(request: request, url: url)); lock.unlock()
    if let err = _renderError { throw err }
    if let writer = _fileWriter { writer(url); return }
    if _shouldCreateFile {
      FileManager.default.createFile(atPath: url.path, contents: Data("fake-rendered".utf8))
    }
  }
}
```

Differences from the previous draft:
- `renderError`, `shouldCreateFile`, `fileWriter`, `renderDelay`, `renderLatch` are all lock-guarded. Swift Testing parallel runs won't TSAN-flag this fake.
- `fileWriter` hook lets tests simulate "renderer reports success but produces a zero-byte file" (the edge case the previous draft mentioned but didn't test).
- `renderLatch` removes the need for cancel tests to sleep or own a continuation directly.
- The lock-pattern hazards in `FakeAssetResourceWriter` are *not* inherited; we tighten the contract here. (`FakeAssetResourceWriter` can be tightened in a follow-up if it ever shows up under TSAN.)

## Failure Modes and Error Copy

| Failure | Detection | Recorded `lastError` | Logged underlying |
| --- | --- | --- | --- |
| `requestSession` returns nil / errors | executor throws | `editedResourceUnavailableMessage` | yes |
| `AVAssetExportSession.status == .failed` | executor throws `session.error` | `editedResourceUnavailableMessage` | yes |
| iCloud download fails | mapped through PHImage error | `editedResourceUnavailableMessage` | yes |
| Disk full mid-render | session error → throws | `editedResourceUnavailableMessage` | yes |
| Asset deleted between fetch and render | executor throws | `editedResourceUnavailableMessage` | yes |
| Session cancelled by us | executor throws `CancellationError` | not a record-store failure; pipeline unwinds via `throwIfCancelledOrStale` | n/a |
| Render handler invoked >1× (e.g. iCloud progress callbacks) | continuation must resume exactly once; verified by test | n/a (success path) | n/a |

All non-cancel failures collapse to the single `editedResourceUnavailableMessage`. Two consequences worth being explicit about:

1. **Persisted string is stable.** `lastError` keeps its existing value so legacy `ExportRecord` snapshots and `ExportVariantRecovery.isRecoverable` continue to match. No migration.
2. **User-facing copy is softened.** Change `ExportRecord.swift:55–56` from `"\(label) version was not provided by Photos. Future exports will try again."` to `"\(label) version could not be exported this time. Future exports will try again."`. Accurate across both the resource-missing case (still happens for photos and for the rare video edge case) and the render-failed case.
3. **Underlying error survives in logs.** Subsystem `Export`, category `MediaRenderer`. A test asserts the captured log line includes the underlying error string so this fidelity is verified, not assumed.

## Cancellation

`AVAssetExportSession.cancelExport()` is the framework-level entry point. The renderer wires it via `withTaskCancellationHandler`:

```swift
try await withTaskCancellationHandler {
  try await executor.runExport(session: session, to: url, fileType: request.fileType)
} onCancel: {
  executor.cancel(session: session)
}
```

Pipeline-level integration:
- Existing `throwIfCancelledOrStale(gen)` checkpoints in `ExportManager.swift:614`, `:623`, `:642`, `:654` apply unchanged. Calls happen before and after `mediaRenderer.render(...)`.
- A cancel arriving during the render triggers `cancelExport()`, the executor's continuation resumes with `CancellationError`, and the pipeline's catch in `processQueue` clears `inFlight` and skips recording `.failed`.
- Generation increment + queue clearing in `cancelAndClear` (`ExportManager.swift:223–230`) is unchanged. The post-render `throwIfCancelledOrStale(gen)` is the second line of defence: if the cancel handler fired but the executor's continuation hadn't resumed yet, the next checkpoint trips the stale generation and unwinds.

Cancel-test contract (must hold; tests assert all of these):
1. After cancel during render, no file exists at `finalURL` and no `.tmp` sibling lingers.
2. The in-progress record for the cancelled variant is **removed** from the store (not "marked failed").
3. `inFlight` is cleared.
4. `renderActivity` is cleared.
5. Generation has incremented; if the fake renderer resumes after cancel, the post-render checkpoint throws and no file is written.

## iCloud handling

`PHVideoRequestOptions.isNetworkAccessAllowed = true` lets PhotoKit fetch the iCloud original before rendering. Consistent with the existing `PHAssetResourceRequestOptions.isNetworkAccessAllowed = true` in `ProductionAssetResourceWriter` (`ProductionAssetResourceWriter.swift:46`).

`deliveryMode = .highQualityFormat` ensures we wait for the high-quality version. Trade-off: longer renders for iCloud-only assets, but matches user expectation for an export tool. The toolbar's `(downloading…)` hint covers the wait visibility.

Bandwidth/time cost is documented in `export-icloud-photos.md` (see Documentation Sync) — not gated in the UI.

## Edge Cases

- **Slow-motion video.** `version: .current` + `AVAssetExportPresetHighestQuality` honours the slow-mo segment authored in Photos. May not be bit-identical to a manually-exported high-frame-rate file, but matches Photos playback.
- **Cinematic mode.** Flat output of the user-chosen focus track. Acceptable.
- **Time-lapse.** Same as slow-mo.
- **Live Photo motion-video edits.** Out of scope — only `mediaType == .video` triggers render. Live Photos are `mediaType == .image` with `.fullSizePhoto` resources.
- **Trim-only edits.** Export session time range reflects the trim; output is the trimmed bytes.
- **Reverted-then-re-edited video.** `descriptor.hasAdjustments` is the source of truth.
- **Re-edit after a successful export.** Existing post-edit re-export policy applies: the new render lands at `<stem> (1).MOV` per `uniqueFileURL` collision handling. Same as photos today.
- **Adjustments roll back to "no adjustments" between scan and render.** `hasAdjustments` is captured at job-build time. If Photos clears adjustments before render, `requestExportSession` may still succeed (Photos returns the original) — our gate is already past. Acceptable; locked down by test.
- **Disk full mid-render.** Session reports `.failed`, mapped to recoverable error. Temp file cleaned by `defer`. Next manual export retries.
- **Render reports success but produces a zero-byte file.** Atomic move step or downstream readers detect the zero-byte file; we don't add a size-sanity check (the `_renderActivity` defer runs, the next export retries). Tested via `FakeMediaRenderer.fileWriter` knob.
- **Asset deleted between fetch and render.** Executor throws → `editedResourceUnavailableMessage`. Acceptable.

## Testing Strategy

### Pre-merge must-verify

**Multi-callback handling for `PHImageManager.requestExportSession`.** AVFoundation may invoke the handler more than once during iCloud download progress (specifically: a "degraded" callback before the terminal callback). Production code must resume its continuation exactly once. A `FakeVideoExportExecutor` that fires its handler twice is sufficient to verify; a CheckedContinuation crash if double-resumed would catch any regression. This is a pre-merge gate, not a post-merge research item.

### Unit tests

- `ResourceSelection.selectEditedProducer` table — mediaType ∈ {image, video}, hasAdjustments ∈ {true, false}, resources ∈ {only `.video`, `.video` + `.fullSizeVideo`, `.fullSizePhoto`, empty} → asserts the right `.resource` / `.render` / `.none` case. This is the single dispatch decision; testing it well is high value.
- `avFileType(forOriginalFilename:)` — `.mov`, `.MP4`, `.m4v`, `.heic` (default → `.mov`), no extension (`"IMG_0001"`), multi-dot (`"clip.final.mov"`), unsupported (`"foo.avi"`, `"foo.mkv"`) → fallback `.mov`.

### `VideoExportExecutor` impl tests

A `FakeVideoExportExecutor` drives `LiveVideoExportExecutor`'s status-mapping branch by simulating each `AVAssetExportSession.Status`. Concrete tests:

- `.completed` → returns normally; no throw.
- `.cancelled` → throws `CancellationError`.
- `.failed` with `session.error == X` → throws `X`.
- Default / `.unknown` → throws a fallback `NSError` whose domain/code is asserted.
- `requestSession` handler invoked twice (once with `PHImageResultIsDegradedKey == true`, then with the real session) → continuation resumes exactly once with the real session; no crash.
- `cancel(session:)` is forwarded to `AVAssetExportSession.cancelExport()` (verified via test executor counting calls).

`withTaskCancellationHandler` wiring is tested at this layer too: a parent task that cancels during `runExport` triggers `cancel(session:)` on the executor.

### `ExportManager` pipeline tests (expanded)

Drive the queue with `FakeAssetResourceWriter` + `FakeMediaRenderer` combinations:

1. **Edited video, no `.fullSizeVideo` resource, hasAdjustments=true** → renderer called once; `assetResourceWriter.writeResource` not called for `.edited`; final file lands at expected URL with original extension; record store transitions in-progress → exported.
2. **Edited video, has `.fullSizeVideo` resource (synthetic) AND hasAdjustments=true** → fast path; resource writer called; renderer **not** called. Backwards compatibility for the rare existing case.
3. **Edited video, render fails (renderError set)** → record store ends `.failed` with `editedResourceUnavailableMessage`; no file at finalURL; tmp cleaned; `inFlight` cleared; `renderActivity` cleared; **log capture asserts the underlying error string is present** (fidelity gate).
4. **Edited video, hasAdjustments=true, but neither `.fullSizeVideo` nor `.video` resource present** → record store `.failed` with `editedResourceUnavailableMessage`; renderer not called.
5. **`editedWithOriginals` mode, edited video** → both variants enqueued; `.edited` goes through renderer; `.original` goes through resource writer at `<stem>_orig.MOV`; group-stem and pair semantics intact.
6. **Cancel during render** (using `FakeMediaRenderer.arm(latch:)`):
   - No `.failed` record for the cancelled variant.
   - The in-progress record is **removed** (not failed).
   - No file at `finalURL`; no leftover `.tmp`.
   - `inFlight` and `renderActivity` are cleared.
   - When the latch is later released and the fake completes, the post-render checkpoint trips on the bumped generation and the move never happens.
7. **Stale `.tmp` from a prior render run** → pre-create `IMG_0001.MOV.tmp`; render path clears it and succeeds. Mirrors `EditedModeExportTests.swift:257` for the writer path.
8. **Paired-stem conflict on edited filename** → `groupStem` set, edited natural stem already taken; rendered output lands at `(N)`-suffixed name per `uniqueFileURL`.
9. **Move/timestamp failure post-render** → inject `FakeFileSystem.moveError`; assert temp cleaned by `defer`. Mirror of `moveFailureMarksFailureAndCleansUpTempFile`.
10. **Re-edit after a successful export** → first run produces `IMG_1234.MOV`; user re-edits in Photos; second run renders to `IMG_1234 (1).MOV`. Video analogue of `postEditReExportLandsAtCollisionSuffixedPath`.
11. **Adjustment rollback between scan and render** → `descriptor.hasAdjustments = true` at job-build time, but Photos has cleared adjustments by render time. Render still completes successfully (Photos returns original bytes); record-store transitions cleanly. Locks down behaviour.
12. **Unedited video** → unchanged behaviour: no render, no failure.

### Test inversion call-out

`EditedModeExportTests.swift:168` — `defaultModeAdjustedFailsWhenEditedResourceUnavailable` — currently asserts the bug is "correct" behaviour (variant ends `.failed` with `editedResourceUnavailableMessage`). With this fix landed, that test must:

- For the **video** branch: invert. Rename to `defaultModeAdjustedVideoRendersWhenNoFullSizeVideoResource` and assert success via `FakeMediaRenderer`.
- For the **photo** branch: keep. The render path is video-only by design; an edited photo with no `.fullSizePhoto` resource still fails. Splitting the test along media kind makes the boundary explicit and prevents accidental widening of the render path to images later.

### `FakeMediaRenderer` realism gates

Spec-tested by:
- A test that uses `fileWriter` to write zero bytes and asserts the move step still completes (exposing the "zero-byte success" edge case as a known-acceptable outcome rather than a hidden bug).
- A test that verifies `renderCalls` is correct under concurrent test execution (parallel two-test harness asserting no TSAN findings — sanity rather than coverage).

### Manual test plan additions (`docs/project/edited-photos-manual-testing-guide.md`)

- **PA-4 (revised)**: Edited iPhone `.MOV`, trim in Photos, export. Expected: `IMG_xxxx.MOV`, plays trimmed, no error.
- **PA-4b**: Edited video, `editedWithOriginals` mode. Expected: `IMG_xxxx.MOV` + `IMG_xxxx_orig.MOV`; first plays trimmed, second plays full.
- **PA-4c**: Edited iCloud-only video. Expected: download + render + write succeed; toolbar shows `(downloading…)` then `(rendering…)`.
- **PA-4d**: Edited slow-mo video. Expected: slow-mo segment preserved; visual matches Photos.
- **PA-4e**: Cancel mid-render. Expected: queue stops within ~1–2 seconds (not instant — `AVAssetExportSession` wind-down is acceptable); no partial file; no `.failed` record for the cancelled asset. The 1–2 second wait is documented as expected, not a bug.
- **PA-4f**: Edited cinematic-mode video. Expected: flat render matching Photos preview.
- **PA-4g**: Edited HDR video (iPhone 13+). Expected: HDR metadata survives in output where the file type supports it. If degraded, document the actual behaviour as known-limitation; don't expand scope.
- **PA-4h**: Re-edit after successful export. Expected: second export creates `(1)` suffix; no overwrite of the prior file.
- **PA-4i**: Trim + adjust (combined edits). Expected: both adjustments applied in render.
- **PA-4j**: Adjustment rollback. Edit a video, queue export, revert edit in Photos before render starts. Expected: render completes with original bytes; no error; record store clean.
- **PA-4k**: Unsupported-extension fallback (verification gate for Resolved Decision #1). Find or synthesise a video in Photos whose original extension is `.avi` or `.mkv`. Edit it. Run the export. Open the result in QuickTime. Acceptance: plays correctly. Failure: switch `selectEditedProducer` to refuse-mode for unsupported extensions per the contingency.

### Other test risks worth noting

- `currentTask?.cancel()` test patterns currently use `Task.sleep` (`ExportPipelineTests.swift:296`). Render-path cancel tests use `FakeMediaRenderer.arm(latch:)` instead — deterministic, no sleeps.
- `TestAssetFactory` may not have video-resource helpers. Confirm during implementation; add a one-line helper if missing.
- `AVFileType` is `RawRepresentable<String>`, so `Equatable` works in struct conformance; verified before writing `MediaRenderRequest`'s `Equatable`.

## Phasing

Single PR. Self-contained scope, ~450–650 lines (revised up from 250–450 to reflect the added executor seam, the producer enum, the toolbar hint, the softer copy, and the expanded test list):

- `photo-export/Models/AssetDescriptor.swift` or new file — `EditedProducer` + `MediaRenderRequest` + `RenderActivity` (~40 lines)
- `photo-export/Protocols/MediaRenderer.swift` (new, ~12 lines)
- `photo-export/Managers/ProductionMediaRenderer.swift` (new, including `VideoExportExecutor` + `LiveVideoExportExecutor` + status-mapping branch, ~150 lines)
- `photo-export/Managers/ResourceSelection.swift` — `selectEditedProducer` added; old `selectEditedResource` removed (~30 net new lines)
- `photo-export/Managers/ExportManager.swift` — switch over `EditedProducer`, `renderActivity` published state, `mediaRenderer` init param (~60 lines net delta)
- `photo-export/Models/ExportRecord.swift` — softened user-facing copy (~1 line change)
- `photo-export/Views/ExportToolbarView.swift` — currentAssetLabel computed property + accessibility label (~20 lines)
- `photo-export/photo_exportApp.swift` — wire `mediaRenderer` (~5 lines)
- `photo-exportTests/TestHelpers/FakeMediaRenderer.swift` (new, ~80 lines including lock-guarded knobs and latch)
- `photo-exportTests/TestHelpers/FakeVideoExportExecutor.swift` (new, ~60 lines)
- `photo-exportTests/ExportManagerVideoRenderTests.swift` (new, ~250 lines covering the 12 pipeline scenarios)
- `photo-exportTests/VideoExportExecutorTests.swift` (new, ~80 lines)
- `photo-exportTests/AVFileTypeMappingTests.swift` (new, ~30 lines)
- `photo-exportTests/ResourceSelectionTests.swift` (existing, expanded for `selectEditedProducer` table; ~50 lines)
- `photo-exportTests/EditedModeExportTests.swift` — invert `defaultModeAdjustedFailsWhenEditedResourceUnavailable` for video, keep for photo, split along media kind (~40 lines)
- `docs/project/edited-photos-manual-testing-guide.md` — PA-4 family expansions
- `website/src/content/docs/features.md`, `getting-started.md`, `export-icloud-photos.md` — copy edits (see Documentation Sync)
- `AGENTS.md` — one-line "Design Decisions Worth Knowing" entry

## Documentation Sync

### `website/src/content/docs/features.md`

Line 22 — change `"Handles both images and videos"` → `"Handles both images and videos, including edits made in Photos"`.

After line 35 (in the version-selection section), append:

> Edited videos export the user-visible version with the original container preserved (e.g. an edited `.MOV` stays `.MOV`). With Include originals on, the companion is named `IMG_xxxx_orig.MOV` — the `_orig` suffix is the only filename difference, since videos keep their original container both times. (Photos can change containers — an edited HEIC may export as `.JPG` because Photos rendered the edit as JPEG; videos do not get that asymmetric rename.)

### `website/src/content/docs/getting-started.md`

After line 51 (in step 3's bullet list), append:

> Edited videos render through Photos and may take longer than copying — especially for 4K or iCloud-only originals. The toolbar shows `(downloading…)` while Photos fetches the original, then `(rendering…)` while the edit is applied.

### `website/src/content/docs/export-icloud-photos.md`

After the existing iCloud sentence at lines 46–47, append:

> Edited videos render on your Mac during export, which is slower than copying — expect 4K iCloud videos to take several minutes per file. Plain copies remain fast.

### `AGENTS.md`

Add to "Design Decisions Worth Knowing":

> Edited video export goes through `PHImageManager.requestExportSession` + `AVAssetExportSession`, not `PHAssetResource`. PhotoKit does not pre-render edited videos as static resources, so resource enumeration finds nothing and the render path is the only way to materialise the user-visible bytes. The dispatch decision lives in `ResourceSelection.selectEditedProducer` as an `EditedProducer` enum (`.resource | .render | .none`); `ExportManager` switches on that and never inlines media-kind specific branches.

## Architectural notes for future work

- **PHAsset re-fetch duplication.** `ProductionAssetResourceWriter.Backend.live` and `LiveVideoExportExecutor` both call `PHAsset.fetchAssets(withLocalIdentifiers:options:)`. Two call sites is fine; a third (e.g. a future Live-Photo motion renderer) is the trigger to extract a `PHAssetResolver` helper or add the lookup to `PhotoLibraryService`. Don't extract preemptively.
- **Per-asset render progress.** Out of scope for v1. If real users hit slow renders and the textual `(rendering…)` hint isn't enough, a future change can bind `AVAssetExportSession.progress` to a sub-progress UI. The `RenderActivity` enum is intentionally state-shaped (rather than just a `Bool`) so a future `.rendering(progress: Double)` case is additive.
- **Image render path.** `EditedProducer` is media-kind-aware; widening to images would be an enum-extension change in one place, not a new boolean in `ExportManager`. No commitment to do this; the structure just doesn't fight the change.

## Resolved Decisions and Contingencies

The earlier draft listed three open questions. After review they collapse to two empirical checks (with pre-decided contingencies) and one resolved cleanup:

### 1. AVFileType fallback for unrecognised extensions — **decided + one verification test**

**Decision.** Default behaviour is the current plan: extension preserved verbatim on disk; `AVFileType` falls back to `.mov` for anything outside `{mov, mp4, m4v}`. A `foo.avi` original will export as `foo.avi` on disk with `.mov`-shaped bytes inside.

**Contingency.** If the verification test below shows the file is unplayable in QuickTime (or another standard macOS video player), switch the renderer to refuse unsupported extensions: return `.none` from `selectEditedProducer` for video originals whose extension isn't in the explicit table, so the variant is recorded `.failed` with the recoverable copy. The user sees a soft failure rather than a broken file.

**Verification test (PA-4k, manual).** Synthesise (or find) a video asset in Photos whose original extension is `.avi` or `.mkv`. Edit it in Photos. Run an export. Open the result in QuickTime. Acceptance: plays correctly. Failure: switch to refuse-mode per the contingency.

We do not pre-build the refuse path. It's a one-line change in `selectEditedProducer` if the test fails.

### 2. HDR preservation under `AVAssetExportPresetHighestQuality` — **empirical + pre-written docs**

**Decision.** No design change up front. Run PA-4g (edited HDR video). Two outcomes:

- **HDR preserved:** ship as-is. No docs change needed.
- **HDR degraded to SDR:** ship as-is, add the pre-drafted line below to `website/src/content/docs/features.md` (in the version-selection section, next to the edited-video paragraph):

  > Edited HDR videos may export as SDR — `AVFoundation` does not always preserve HDR metadata when re-encoding. To keep an HDR copy of the original bytes, turn on **Include originals**: the `_orig` companion is a passthrough copy of the source and stays HDR.

We do not expand scope to build HDR-aware rendering. The "Include originals" workaround already exists for users who care; the docs note routes them to it.

### 3. `selectEditedResource` legacy wrapper — **resolved: retire in this PR**

Grep confirms only `ExportManager.swift:490`, `ExportManager.swift:572`, and `ResourceSelectionTests.swift` call `selectEditedResource`. `BackupScanner.swift:200` uses the type-predicate `isEditedResource(type:mediaType:)`, not the selector function. Both ExportManager call sites move to `selectEditedProducer` in this PR; the test file is updated alongside. The legacy wrapper is removed in the same change — no separate follow-up.
