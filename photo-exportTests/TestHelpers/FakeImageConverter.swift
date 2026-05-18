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

  /// Error injection — when non-nil, the converter throws this on every call.
  var convertError: Error?

  /// When `true` (the default), the fake writes a known JPEG signature
  /// (`0xFF 0xD8 0xFF 0xE0`) followed by some test bytes at `destURL`. Callers
  /// that need to assert against the on-disk file (e.g. atomic-move tests)
  /// can read the file and verify the JPEG magic. Setting this to `false`
  /// skips the write and is useful for harnesses that only need the call
  /// record.
  var shouldCreateFile: Bool = true

  func convertHEIC(at sourceURL: URL, to destURL: URL, quality: Double) throws {
    lock.lock()
    _convertCalls.append(
      ConvertCall(sourceURL: sourceURL, destURL: destURL, quality: quality))
    lock.unlock()

    if let error = convertError { throw error }
    if shouldCreateFile {
      // JPEG SOI + APP0 marker — enough that `Data(contentsOf:)` round-trips
      // identifiably as JPEG without needing a real CoreImage encode.
      let jpegSignature: [UInt8] = [0xFF, 0xD8, 0xFF, 0xE0]
      let payload = Data(jpegSignature) + Data("FAKE-JPEG-CONTENT".utf8)
      FileManager.default.createFile(atPath: destURL.path, contents: payload)
    }
  }
}
