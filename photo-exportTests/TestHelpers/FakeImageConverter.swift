import Foundation

@testable import Photo_Export

/// Test fake for `ImageConverter`. Records every call and synthesises a known
/// JPEG byte payload at the destination URL so callers can assert against the
/// "edited" variant on disk without invoking CoreImage.
final class FakeImageConverter: ImageConverter, @unchecked Sendable {
  struct ConvertCall: Equatable {
    let sourceURL: URL
    let destURL: URL
    let quality: Double
  }

  private let lock = NSLock()
  private var _convertCalls: [ConvertCall] = []

  var convertCalls: [ConvertCall] {
    lock.lock()
    defer { lock.unlock() }
    return _convertCalls
  }

  // Configuration is set on the main actor before the harness is constructed.
  // Not protected by `lock` — matches the discipline-via-doc-comment pattern
  // used by `FakeAssetResourceWriter` / `FakeMediaRenderer`.

  /// Error injection — when non-nil, the converter throws this on every call.
  var convertError: Error?

  /// When `true` (the default), the fake writes a JPEG signature byte payload
  /// to `destURL`. The bytes start with the JPEG SOI marker (`0xFF 0xD8 0xFF
  /// 0xE0`) so a consumer that only checks "looks like a JPEG" passes, but
  /// the bytes are NOT a parseable JPEG (no APP0 length, no EOI marker, no
  /// pixel data). Today the only consumer that reads the file is
  /// `FileManager.moveItem(atomically:)` in `VariantExporter`, which never
  /// decodes — if a future test path tries to actually parse the fake's
  /// output via ImageIO it will fail and the fake should be upgraded to emit
  /// a real 1×1 JPEG via `CGImageDestination`.
  var shouldCreateFile: Bool = true

  func convertHEIC(at sourceURL: URL, to destURL: URL, quality: Double) async throws {
    lock.lock()
    _convertCalls.append(
      ConvertCall(sourceURL: sourceURL, destURL: destURL, quality: quality))
    lock.unlock()

    if let error = convertError { throw error }
    if shouldCreateFile {
      let jpegSignature: [UInt8] = [0xFF, 0xD8, 0xFF, 0xE0]
      let payload = Data(jpegSignature) + Data("FAKE-JPEG-CONTENT".utf8)
      FileManager.default.createFile(atPath: destURL.path, contents: payload)
    }
  }
}
