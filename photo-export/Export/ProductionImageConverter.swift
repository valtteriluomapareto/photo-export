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
/// pipeline) so we hold a single instance for the lifetime of the converter.
/// Production code creates exactly one converter per `ExportManager`.
struct ProductionImageConverter: ImageConverter {
  private static let logger = Logger(
    subsystem: "com.valtteriluoma.photo-export", category: "ImageConverter")

  /// Shared CoreImage context. `CIContext` is `Sendable` and documented as
  /// thread-safe, so one shared instance serves the whole export pipeline.
  private static let sharedContext = CIContext()

  func convertHEIC(at sourceURL: URL, to destURL: URL, quality: Double) throws {
    guard let image = CIImage(contentsOf: sourceURL) else {
      throw NSError(
        domain: "ImageConverter", code: 1,
        userInfo: [
          NSLocalizedDescriptionKey: "Could not decode HEIC at \(sourceURL.lastPathComponent)"
        ])
    }
    // Preserve the source image's color profile if CoreImage exposed one;
    // fall back to Display P3 (the iPhone capture default for HEIC) rather
    // than device-RGB so the JPEG isn't desaturated relative to the original.
    let colorSpace =
      image.colorSpace ?? CGColorSpace(name: CGColorSpace.displayP3) ?? CGColorSpaceCreateDeviceRGB()
    // `kCGImageDestinationLossyCompressionQuality` is the canonical
    // ImageIO key for JPEG compression quality. `CIImageRepresentationOption`
    // wraps it as a raw-value string.
    let options: [CIImageRepresentationOption: Any] = [
      CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String):
        max(0.0, min(1.0, quality))
    ]
    do {
      try Self.sharedContext.writeJPEGRepresentation(
        of: image, to: destURL, colorSpace: colorSpace, options: options)
    } catch {
      Self.logger.error(
        "HEIC→JPEG conversion failed for \(sourceURL.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)"
      )
      throw error
    }
  }
}
