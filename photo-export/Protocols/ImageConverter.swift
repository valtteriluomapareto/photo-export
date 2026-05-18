import Foundation

/// Seam for the HEIC→JPEG conversion path (issue #47). Reads a source image
/// from disk and writes a JPEG representation to a destination URL.
///
/// Despite the name `convertHEIC`, the production implementation accepts any
/// image format CoreImage can decode (HEIC, HEIF, JPEG, PNG, TIFF, etc.). The
/// HEIC-specific name is locally accurate at the call site (gated on
/// `AssetDescriptor.isHEICOriginal`, which matches both `public.heic` and
/// `public.heif`).
///
/// Production implementation in `ProductionImageConverter` uses
/// `CIContext.writeJPEGRepresentation(of:to:colorSpace:options:)`. Tests inject
/// `FakeImageConverter` to materialise a canned JPEG without invoking
/// CoreImage — matches the established pattern with `AssetResourceWriter` /
/// `MediaRenderer`.
///
/// **`async` is load-bearing.** Decoding a full-resolution HEIC and re-encoding
/// to JPEG is a 100ms+ CPU-bound operation. The seam is async so production
/// can dispatch the work off the main actor and the export pipeline's UI stays
/// responsive during long Year exports. `Sendable` so the converter can be
/// passed across actors freely.
protocol ImageConverter: Sendable {
  /// Reads image bytes from `sourceURL` and writes a JPEG to `destURL`.
  ///
  /// - `quality` is the JPEG compression quality. Values are clamped to
  ///   `[0.0, 1.0]`; higher is larger files / closer to lossless. The export
  ///   pipeline passes `0.85`, the same default Apple's own apps use for
  ///   "high quality" JPEG export — visible quality drop vs. the HEIC source
  ///   is negligible while the file size shrinks meaningfully.
  /// - Throws when the source can't be decoded or the destination can't be
  ///   written. Callers translate any error into the export pipeline's
  ///   `editedResourceUnavailableMessage` sentinel so the existing
  ///   "edited variant failed" recovery path runs cleanly.
  func convertHEIC(at sourceURL: URL, to destURL: URL, quality: Double) async throws
}
