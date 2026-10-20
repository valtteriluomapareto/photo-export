import Foundation
import Testing

@testable import Photo_Export

final class FakeAssetResourceWriter: AssetResourceWriter, @unchecked Sendable {
  // Call tracking
  struct WriteCall: Equatable {
    let resource: ResourceDescriptor
    let assetId: String
    let url: URL
  }

  private let lock = NSLock()
  private var _writeCalls: [WriteCall] = []

  var writeCalls: [WriteCall] {
    lock.lock()
    defer { lock.unlock() }
    return _writeCalls
  }

  // Error injection
  var writeError: Error?

  // Behavior: if true, creates a small file at the destination (simulating a real write)
  var shouldCreateFile: Bool = true

  /// Bytes written for `resource` of `assetId`: the same for the same pair, different for
  /// another asset or resource. As long as `resource.fileSize` when it is positive, so
  /// size-based checks see the reported size, and 12 bytes otherwise.
  static func content(for resource: ResourceDescriptor, assetId: String) -> Data {
    let length = resource.fileSize.flatMap { $0 > 0 ? Int($0) : nil } ?? 12
    // FNV-1a over the identity, then a SplitMix64 stream for the bytes.
    var state: UInt64 = 0xcbf2_9ce4_8422_2325
    for byte in "\(assetId)|\(resource.type.rawValue)|\(resource.originalFilename)".utf8 {
      state = (state ^ UInt64(byte)) &* 0x0000_0100_0000_01b3
    }
    var bytes = Data(capacity: length)
    while bytes.count < length {
      state &+= 0x9e37_79b9_7f4a_7c15
      var mixed = state
      mixed = (mixed ^ (mixed >> 30)) &* 0xbf58_476d_1ce4_e5b9
      mixed = (mixed ^ (mixed >> 27)) &* 0x94d0_49bb_1331_11eb
      mixed ^= mixed >> 31
      let remaining = length - bytes.count
      withUnsafeBytes(of: mixed.littleEndian) { bytes.append(contentsOf: $0.prefix(remaining)) }
    }
    return bytes
  }

  /// Optional release-on-demand checkpoint. When set, every `writeResource` call
  /// reaches the checkpoint after recording its `WriteCall`, then suspends until
  /// the test releases it. Replaces the "sleep then poll for transient state"
  /// pattern in pause/cancel tests. The harness must call
  /// `await checkpoint.releaseAll()` during teardown to unblock anything still
  /// suspended (otherwise a `cancelAndClear()` from the manager strands the
  /// write task forever).
  var checkpoint: AsyncCheckpoint?
  var afterWriteCheckpoint: AsyncCheckpoint?

  func writeResource(_ resource: ResourceDescriptor, forAssetId assetId: String, to url: URL)
    async throws
  {
    lock.lock()
    _writeCalls.append(WriteCall(resource: resource, assetId: assetId, url: url))
    lock.unlock()

    if let checkpoint {
      await checkpoint.enter()
    }
    if let error = writeError { throw error }
    // The pipeline writes only to a fresh hidden staging file and moves it into place.
    // Refuse anything else so a write aimed at a final name, or over an existing file,
    // fails the export instead of silently replacing it.
    guard url.lastPathComponent.hasPrefix(".photo-export-") else {
      Issue.record("Resource written outside staging: \(url.lastPathComponent)")
      throw NSError(
        domain: "FakeAssetResourceWriter", code: 1,
        userInfo: [NSLocalizedDescriptionKey: "Write outside staging: \(url.lastPathComponent)"])
    }
    if FileManager.default.fileExists(atPath: url.path) {
      throw CocoaError(.fileWriteFileExists)
    }
    if shouldCreateFile,
      !FileManager.default.createFile(
        atPath: url.path, contents: Self.content(for: resource, assetId: assetId))
    {
      throw CocoaError(.fileWriteUnknown)
    }
    if let afterWriteCheckpoint { await afterWriteCheckpoint.enter() }
  }
}
