import Foundation

@testable import Photo_Export

/// A FileSystemService that delegates to the real filesystem but records calls and can inject errors.
final class FakeFileSystem: FileSystemService, @unchecked Sendable {
  private let lock = NSLock()

  // Call tracking
  private var _moveCalls: [(from: URL, to: URL)] = []
  private var _timestampCalls: [(date: Date, url: URL)] = []
  private var _copyCalls: [(from: URL, to: URL)] = []
  private var _beforeMoveHook: (@Sendable (URL, URL) throws -> Void)?
  private var _afterMoveHook: (@Sendable (URL, URL) throws -> Void)?
  private var _afterTimestampsHook: (@Sendable (URL) -> Void)?
  private var _copyHook: (@Sendable (URL, URL) throws -> Void)?

  /// Configured before an export. The callback runs without the tracking lock held.
  var copyHook: (@Sendable (URL, URL) throws -> Void)? {
    get { lock.withLock { _copyHook } }
    set { lock.withLock { _copyHook = newValue } }
  }

  var beforeMoveHook: (@Sendable (URL, URL) throws -> Void)? {
    get { lock.withLock { _beforeMoveHook } }
    set { lock.withLock { _beforeMoveHook = newValue } }
  }

  var afterMoveHook: (@Sendable (URL, URL) throws -> Void)? {
    get { lock.withLock { _afterMoveHook } }
    set { lock.withLock { _afterMoveHook = newValue } }
  }

  var afterTimestampsHook: (@Sendable (URL) -> Void)? {
    get { lock.withLock { _afterTimestampsHook } }
    set { lock.withLock { _afterTimestampsHook = newValue } }
  }

  var moveCalls: [(from: URL, to: URL)] {
    lock.lock()
    defer { lock.unlock() }
    return _moveCalls
  }

  var timestampCalls: [(date: Date, url: URL)] {
    lock.lock()
    defer { lock.unlock() }
    return _timestampCalls
  }

  var copyCalls: [(from: URL, to: URL)] {
    lock.lock()
    defer { lock.unlock() }
    return _copyCalls
  }

  // Error injection
  var moveError: Error?
  var copyError: Error?
  var shouldApplyTimestamps = true

  // Delegate to real filesystem by default
  private let real = FileIOService()

  func moveItemAtomically(from src: URL, to dst: URL) throws {
    lock.lock()
    _moveCalls.append((from: src, to: dst))
    lock.unlock()

    try beforeMoveHook?(src, dst)
    if let error = moveError { throw error }
    try real.moveItemAtomically(from: src, to: dst)
    try afterMoveHook?(src, dst)
  }

  func applyTimestamps(creationDate: Date, to url: URL) {
    lock.lock()
    _timestampCalls.append((date: creationDate, url: url))
    lock.unlock()

    if shouldApplyTimestamps {
      real.applyTimestamps(creationDate: creationDate, to: url)
    }
    afterTimestampsHook?(url)
  }

  func createDirectory(at url: URL, withIntermediateDirectories: Bool) throws {
    try real.createDirectory(at: url, withIntermediateDirectories: withIntermediateDirectories)
  }

  func fileExists(atPath path: String) -> Bool {
    real.fileExists(atPath: path)
  }

  func removeItem(at url: URL) throws {
    try real.removeItem(at: url)
  }

  func copyItem(from src: URL, to dst: URL) throws {
    lock.lock()
    _copyCalls.append((from: src, to: dst))
    lock.unlock()

    try copyHook?(src, dst)
    if let error = copyError { throw error }
    try real.copyItem(from: src, to: dst)
  }
}
