import CoreImage
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import Photo_Export

/// `ProductionImageConverter` is a thin CoreImage wrapper, but it's worth a
/// round-trip test because the only "interesting" behavior is the JPEG quality
/// option threading and the colorspace fallback. The fake (`FakeImageConverter`)
/// handles the integration-test side; this suite pins the production path's
/// real CoreImage interaction.
struct ProductionImageConverterTests {

  /// Build a tiny HEIC file in a temp dir and round-trip it through the
  /// converter, asserting the output is a valid JPEG.
  @Test func convertsHEICToJPEGAndProducesValidJPEG() async throws {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(
      "ProductionImageConverterTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
      at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let heicURL = tempDir.appendingPathComponent("source.heic")
    let jpegURL = tempDir.appendingPathComponent("dest.jpg")
    try writeHEICFixture(to: heicURL)

    let converter = ProductionImageConverter()
    try await converter.convertHEIC(at: heicURL, to: jpegURL, quality: 0.85)

    #expect(FileManager.default.fileExists(atPath: jpegURL.path))

    // JPEG bytes start with the SOI marker `0xFF 0xD8`. CoreImage adds its
    // own metadata before the actual image markers; SOI is always first.
    let firstBytes = try Data(contentsOf: jpegURL).prefix(2)
    #expect(firstBytes == Data([0xFF, 0xD8]), "Output is not a valid JPEG")
  }

  /// The `quality` parameter is clamped to `[0.0, 1.0]`. Passing an out-of-range
  /// value (negative, > 1) shouldn't trip CoreImage; the converter normalises.
  /// Pins the protocol contract — values outside the range are documented as
  /// clamped, not errored.
  @Test func clampsQualityOutOfRange() async throws {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(
      "ProductionImageConverterTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let heicURL = tempDir.appendingPathComponent("source.heic")
    try writeHEICFixture(to: heicURL)

    let converter = ProductionImageConverter()
    // Both outside [0,1] — converter clamps, doesn't throw.
    try await converter.convertHEIC(
      at: heicURL, to: tempDir.appendingPathComponent("high.jpg"), quality: 1.5)
    try await converter.convertHEIC(
      at: heicURL, to: tempDir.appendingPathComponent("neg.jpg"), quality: -0.2)
  }

  /// Source file that doesn't exist (or isn't a valid image) throws.
  @Test func throwsWhenSourceMissing() async throws {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(
      "ProductionImageConverterTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let bogus = tempDir.appendingPathComponent("nonexistent.heic")
    let dest = tempDir.appendingPathComponent("dest.jpg")

    let converter = ProductionImageConverter()
    await #expect(throws: (any Error).self) {
      try await converter.convertHEIC(at: bogus, to: dest, quality: 0.85)
    }
  }

  // MARK: - Helpers

  /// Writes a 2×2 HEIC image to `url`. macOS's ImageIO HEIC encoder is built
  /// in, so we can synthesise a valid HEIC file without bundled fixtures.
  private func writeHEICFixture(to url: URL) throws {
    let width = 2
    let height = 2
    let bytesPerRow = width * 4
    var pixels: [UInt8] = []
    for _ in 0..<(width * height) {
      pixels.append(contentsOf: [255, 0, 0, 255])  // RGBA red
    }
    guard
      let provider = CGDataProvider(data: Data(pixels) as CFData),
      let cgImage = CGImage(
        width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
        bytesPerRow: bytesPerRow, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    else {
      throw NSError(domain: "test", code: 1)
    }
    guard
      let dest = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.heic.identifier as CFString, 1, nil)
    else {
      throw NSError(domain: "test", code: 2)
    }
    CGImageDestinationAddImage(dest, cgImage, nil)
    guard CGImageDestinationFinalize(dest) else {
      throw NSError(domain: "test", code: 3)
    }
  }
}
