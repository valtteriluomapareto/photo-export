import Foundation

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

  /// Delay every `writeResource` call by this many seconds via `Task.sleep`. Used by
  /// cancellation tests to keep the writer hung long enough for `cancelAndClear` to
  /// race against the in-flight write deterministically. The sleep is cancellable, so
  /// the writer cooperates with `Task.isCancelled` checks higher in the stack.
  ///
  /// Prefer `checkpoint` over `writeDelaySeconds` for any test that asserts on
  /// transient queue state — a delay only widens a window, but a checkpoint makes
  /// arrival deterministic. `writeDelaySeconds` remains useful for coarse "is the
  /// in-flight cancel path correct" smoke tests where exact timing doesn't matter.
  var writeDelaySeconds: TimeInterval = 0

  /// Optional release-on-demand checkpoint. When set, every `writeResource` call
  /// reaches the checkpoint after recording its `WriteCall`, then suspends until
  /// the test releases it. Replaces the "sleep then poll for transient state"
  /// pattern in pause/cancel tests. The harness must call
  /// `await checkpoint.releaseAll()` during teardown to unblock anything still
  /// suspended (otherwise a `cancelAndClear()` from the manager strands the
  /// write task forever).
  var checkpoint: AsyncCheckpoint?

  func writeResource(_ resource: ResourceDescriptor, forAssetId assetId: String, to url: URL)
    async throws
  {
    lock.lock()
    _writeCalls.append(WriteCall(resource: resource, assetId: assetId, url: url))
    lock.unlock()

    if let checkpoint {
      await checkpoint.enter()
    }
    if writeDelaySeconds > 0 {
      try await Task.sleep(nanoseconds: UInt64(writeDelaySeconds * 1_000_000_000))
    }
    if let error = writeError { throw error }
    if shouldCreateFile {
      FileManager.default.createFile(atPath: url.path, contents: Data("fake-content".utf8))
    }
  }
}
