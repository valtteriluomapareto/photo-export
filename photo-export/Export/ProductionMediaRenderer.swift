import AVFoundation
import Foundation
import Photos
import os

/// Maps an original-side filename to the `AVFileType` we hand
/// `AVAssetExportSession`. The on-disk extension is always preserved
/// verbatim by the caller; this picks the closest container the export
/// session can render into. Anything outside the explicit table falls back
/// to `.mov`, which is the safe default for unrecognised inputs.
func avFileType(forOriginalFilename name: String) -> AVFileType {
  switch (name as NSString).pathExtension.lowercased() {
  case "mov": return .mov
  case "mp4": return .mp4
  case "m4v": return .m4v
  default: return .mov
  }
}

/// Opaque handle around an `AVAssetExportSession` so test executors don't
/// need to construct a real `AVAssetExportSession` to drive the
/// status-mapping branch.
final class ExportSessionHandle: @unchecked Sendable {
  let underlying: AnyObject
  init(_ underlying: AnyObject) { self.underlying = underlying }
}

/// Test seam between `ProductionMediaRenderer` and `PHImageManager` /
/// `AVAssetExportSession`. Production wires `LiveVideoExportExecutor`; tests
/// inject a fake to drive each `AVAssetExportSession.Status` branch.
protocol VideoExportExecutor: Sendable {
  func requestSession(for request: MediaRenderRequest) async throws -> ExportSessionHandle
  func runExport(session: ExportSessionHandle, to url: URL, fileType: AVFileType) async throws
  func cancel(session: ExportSessionHandle)
}

/// Production implementation of `MediaRenderer`. Drives the
/// `PHImageManager.requestExportSession` → `AVAssetExportSession` flow and
/// surfaces render activity through an injected callback so the toolbar
/// can show `(downloading…)` / `(rendering…)` while the user waits.
struct ProductionMediaRenderer: MediaRenderer {
  private static let logger = Logger(
    subsystem: "com.valtteriluoma.photo-export", category: "MediaRenderer")
  private let executor: any VideoExportExecutor
  private let activity: @Sendable (RenderActivity?) -> Void

  init(
    executor: any VideoExportExecutor = LiveVideoExportExecutor(),
    activity: @escaping @Sendable (RenderActivity?) -> Void
  ) {
    self.executor = executor
    self.activity = activity
  }

  func render(request: MediaRenderRequest, to url: URL) async throws {
    activity(.downloading)
    let session: ExportSessionHandle
    do {
      session = try await executor.requestSession(for: request)
    } catch {
      Self.logger.error(
        "requestSession failed for id: \(request.assetId, privacy: .public) error: \(String(describing: error), privacy: .public)"
      )
      throw error
    }
    activity(.rendering)
    do {
      try await withTaskCancellationHandler {
        try await executor.runExport(session: session, to: url, fileType: request.fileType)
      } onCancel: {
        executor.cancel(session: session)
      }
    } catch is CancellationError {
      // Throw a fresh CancellationError rather than rethrowing the
      // caught one so the call site sees a uniform cancel signal even
      // when AVAssetExportSession's internals surface cancellation as
      // a different concrete type in some macOS versions.
      throw CancellationError()
    } catch {
      // Some macOS releases report cancellation as a non-CancellationError
      // (an AVError code or NSError) after `cancelExport()` is called.
      // If the parent task is cancelled, treat any failure here as a
      // cancellation so the pipeline cleans up via its existing
      // cancel-aware paths instead of recording a `.failed` variant.
      if Task.isCancelled { throw CancellationError() }
      Self.logger.error(
        "runExport failed for id: \(request.assetId, privacy: .public) error: \(String(describing: error), privacy: .public)"
      )
      throw error
    }
  }
}

/// Default closures used by `LiveVideoExportExecutor`. Defined on a
/// separate enum because `Self`-typed default arguments are not allowed.
enum LiveVideoExportDefaults {
  static let resolveAsset: @Sendable (String) throws -> PHAsset = { assetId in
    let fetch = PHAsset.fetchAssets(withLocalIdentifiers: [assetId], options: nil)
    guard let asset = fetch.firstObject else {
      throw NSError(
        domain: "Export", code: 6,
        userInfo: [NSLocalizedDescriptionKey: "Asset not found for video render"])
    }
    return asset
  }
}

/// Production `VideoExportExecutor`. Resolves the `PHAsset`, asks PhotoKit
/// for an export session configured with `version: .current` and the
/// highest-quality preset, then drives the resulting `AVAssetExportSession`
/// to completion. Maps each terminal `AVAssetExportSession.Status` to a
/// throw or a normal return so callers do not need to inspect the session.
final class LiveVideoExportExecutor: VideoExportExecutor {
  private let resolveAsset: @Sendable (String) throws -> PHAsset

  init(
    resolveAsset: @escaping @Sendable (String) throws -> PHAsset =
      LiveVideoExportDefaults.resolveAsset
  ) {
    self.resolveAsset = resolveAsset
  }

  func requestSession(for request: MediaRenderRequest) async throws -> ExportSessionHandle {
    let asset = try resolveAsset(request.assetId)
    let options = PHVideoRequestOptions()
    options.version = .current
    options.deliveryMode = .highQualityFormat
    options.isNetworkAccessAllowed = true

    // PhotoKit may invoke the handler more than once during iCloud download
    // (e.g. with a degraded result). Resume the continuation exactly once
    // by tracking it in a small lock-guarded box and ignoring later calls.
    final class Box: @unchecked Sendable {
      private let lock = NSLock()
      private var resumed = false
      func tryResume(_ block: () -> Void) {
        lock.lock()
        let shouldRun = !resumed
        resumed = true
        lock.unlock()
        if shouldRun { block() }
      }
    }
    // Stores the PhotoKit request id once the call returns. The cancel
    // handler reads it to forward cancellation; the body checks it
    // immediately after the request returns to handle the case where
    // cancellation arrived during the call itself.
    final class RequestIDBox: @unchecked Sendable {
      private let lock = NSLock()
      private var _id: PHImageRequestID = PHInvalidImageRequestID
      func set(_ id: PHImageRequestID) {
        lock.lock()
        _id = id
        lock.unlock()
      }
      func get() -> PHImageRequestID {
        lock.lock()
        defer { lock.unlock() }
        return _id
      }
    }
    let box = Box()
    let idBox = RequestIDBox()

    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        let id = PHImageManager.default().requestExportSession(
          forVideo: asset,
          options: options,
          exportPreset: AVAssetExportPresetHighestQuality
        ) { session, info in
          // Cancellation may surface as PHImageCancelledKey == true
          // (PhotoKit standard) when our cancel handler fired before
          // the work completed. Treat it as a clean cancel.
          if let cancelled = info?[PHImageCancelledKey] as? Bool, cancelled {
            box.tryResume { continuation.resume(throwing: CancellationError()) }
            return
          }
          if let error = info?[PHImageErrorKey] as? Error {
            box.tryResume { continuation.resume(throwing: error) }
            return
          }
          if let isDegraded = info?[PHImageResultIsDegradedKey] as? Bool, isDegraded {
            // Intermediate progress callback — wait for the final one.
            return
          }
          guard let session else {
            box.tryResume {
              continuation.resume(throwing: Self.renderUnavailableError())
            }
            return
          }
          box.tryResume {
            continuation.resume(returning: ExportSessionHandle(session))
          }
        }
        idBox.set(id)
        // Race window: cancellation could have arrived between the
        // request starting and the id being stored. If so, the cancel
        // handler ran with an invalid id and was a no-op — propagate
        // here so we still cancel PhotoKit.
        if Task.isCancelled {
          PHImageManager.default().cancelImageRequest(id)
        }
      }
    } onCancel: {
      let id = idBox.get()
      if id != PHInvalidImageRequestID {
        PHImageManager.default().cancelImageRequest(id)
      }
    }
  }

  func runExport(session: ExportSessionHandle, to url: URL, fileType: AVFileType) async throws {
    guard let avSession = session.underlying as? AVAssetExportSession else {
      throw Self.renderFailedError()
    }
    avSession.shouldOptimizeForNetworkUse = false
    try await avSession.export(to: url, as: fileType)
  }

  func cancel(session: ExportSessionHandle) {
    (session.underlying as? AVAssetExportSession)?.cancelExport()
  }

  fileprivate static func renderUnavailableError() -> NSError {
    NSError(
      domain: "Export", code: 7,
      userInfo: [NSLocalizedDescriptionKey: "Photos returned no export session"])
  }

  fileprivate static func renderFailedError() -> NSError {
    NSError(
      domain: "Export", code: 8,
      userInfo: [NSLocalizedDescriptionKey: "AVAssetExportSession ended in a non-success state"])
  }
}
