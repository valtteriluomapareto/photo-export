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
      !FileManager.default.createFile(atPath: url.path, contents: Data("fake-content".utf8))
    {
      throw CocoaError(.fileWriteUnknown)
    }
    if let afterWriteCheckpoint { await afterWriteCheckpoint.enter() }
  }
}
