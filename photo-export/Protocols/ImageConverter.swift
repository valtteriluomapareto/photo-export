import Foundation

/// Seam for the HEIC→JPEG conversion path (issue #47). Reads a source HEIC/HEIF
/// file from disk and writes a JPEG representation to a destination URL.
///
/// Production implementation in `ProductionImageConverter` uses
/// `CIContext.writeJPEGRepresentation(of:to:colorSpace:options:)`. Tests inject
/// `FakeImageConverter` to materialise a canned JPEG without invoking
/// CoreImage — matches the established pattern with `AssetResourceWriter` /
/// `MediaRenderer`.
///
/// `Sendable` so callers can pass the converter across actors. Production impl
/// holds no mutable state; the fake is value-typed.
protocol ImageConverter: Sendable {
  /// Reads HEIC/HEIF bytes from `sourceURL` and writes a JPEG to `destURL`.
  ///
  /// - `quality` is the JPEG compression quality (`0.0`–`1.0`, where higher is
  ///   larger files / closer to lossless). The export pipeline passes `0.85`,
  ///   which is the same default Apple's own apps use for "high quality" JPEG
  ///   export — the visible quality drop vs. the HEIC source is negligible for
  ///   photos while the file size shrinks meaningfully.
  /// - Throws when the source can't be decoded or the destination can't be
  ///   written. Callers translate any error into the export pipeline's
  ///   `editedResourceUnavailableMessage` sentinel so the existing
  ///   "edited variant failed" recovery path runs cleanly.
  func convertHEIC(at sourceURL: URL, to destURL: URL, quality: Double) throws
}
