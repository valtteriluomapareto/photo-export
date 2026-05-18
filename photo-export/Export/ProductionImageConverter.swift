import CoreImage
import Foundation
import ImageIO
import os

/// Production `ImageConverter` backed by `CoreImage`.
///
/// `CIImage(contentsOf:)` + `CIContext.writeJPEGRepresentation(...)` is the
/// terse, well-tested macOS path for re-encoding an image file into JPEG. It
/// reads HEIC/HEIF transparently (CoreImage routes the decode through
/// `ImageIO`), preserves the source's color profile when one is present, and
/// avoids any third-party dependency. HDR HEIC inputs collapse to SDR JPEG
/// because JPEG can't carry HDR metadata — unavoidable in any
/// HEIC-to-JPEG path; the issue acknowledges it.
///
/// `CIContext` is expensive to build (it allocates a Metal-backed render
/// pipeline) so we hold a single process-lifetime instance. Production code
/// creates exactly one converter per `ExportManager`, but the static keeps
/// any defensive duplicate-construct cheap. `cacheIntermediates: false`
/// because each conversion is one-shot — there's no useful texture reuse
/// between calls, and the default would hold the intermediate working set
/// in the high-MB range per call indefinitely.
struct ProductionImageConverter: ImageConverter {
  private static let logger = Logger(
    subsystem: "com.valtteriluoma.photo-export", category: "ImageConverter")

  /// Shared CoreImage context. `CIContext` is `Sendable` and documented as
  /// thread-safe, so one shared instance serves the whole export pipeline.
  private static let sharedContext = CIContext(options: [.cacheIntermediates: false])

  func convertHEIC(at sourceURL: URL, to destURL: URL, quality: Double) async throws {
    // Dispatch the CoreImage decode/encode off the main actor — full-resolution
    // iPhone HEIC encodes are ~100–400ms on Apple Silicon and several seconds
    // on Intel, long enough to jank the SwiftUI progress UI if run on main.
    // `.utility` matches the QoS used by the surrounding atomic-move work in
    // `VariantExporter`.
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      DispatchQueue.global(qos: .utility).async {
        do {
          try Self.performConversion(at: sourceURL, to: destURL, quality: quality)
          continuation.resume(returning: ())
        } catch {
          continuation.resume(throwing: error)
        }
      }
    }
  }

  /// Synchronous body of the conversion, dispatched off-main by `convertHEIC`.
  /// Factored out so the dispatch boilerplate doesn't drown the actual
  /// CoreImage interaction.
  private static func performConversion(at sourceURL: URL, to destURL: URL, quality: Double) throws
  {
    guard let image = CIImage(contentsOf: sourceURL) else {
      throw NSError(
        domain: "Export", code: 10,
        userInfo: [
          NSLocalizedDescriptionKey: "Could not decode image at \(sourceURL.lastPathComponent)"
        ])
    }
    // Preserve the source image's color profile if CoreImage exposed one;
    // fall back to Display P3 (the iPhone capture default for HEIC) rather
    // than device-RGB so the JPEG isn't desaturated relative to the
    // original. The `nil`-`colorSpace` branch is rare in practice — HEIC
    // files carry an `nclx`/`colr` colorspace box — but the fallback chain
    // is well-defined.
    let resolvedColorSpace: CGColorSpace
    if let sourceColorSpace = image.colorSpace {
      resolvedColorSpace = sourceColorSpace
    } else if let p3 = CGColorSpace(name: CGColorSpace.displayP3) {
      logger.debug(
        "Source colorspace nil for \(sourceURL.lastPathComponent, privacy: .public); using Display P3 fallback"
      )
      resolvedColorSpace = p3
    } else {
      logger.debug(
        "Source colorspace nil and Display P3 unavailable for \(sourceURL.lastPathComponent, privacy: .public); using device RGB"
      )
      resolvedColorSpace = CGColorSpaceCreateDeviceRGB()
    }
    // `kCGImageDestinationLossyCompressionQuality` is the canonical
    // ImageIO key for JPEG compression quality. `CIImageRepresentationOption`
    // wraps it as a raw-value string.
    let options: [CIImageRepresentationOption: Any] = [
      CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String):
        max(0.0, min(1.0, quality))
    ]
    do {
      try sharedContext.writeJPEGRepresentation(
        of: image, to: destURL, colorSpace: resolvedColorSpace, options: options)
    } catch {
      logger.error(
        "HEIC→JPEG conversion failed for \(sourceURL.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)"
      )
      throw error
    }
  }
}
