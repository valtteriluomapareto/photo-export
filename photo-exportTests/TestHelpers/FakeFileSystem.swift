import Foundation

@testable import Photo_Export

/// A FileSystemService that delegates to the real filesystem but records calls and can inject errors.
final class FakeFileSystem: FileSystemService, @unchecked Sendable {
  private let lock = NSLock()

  // Call tracking
  private var _moveCalls: [(from: URL, to: URL)] = []
  private var _timestampCalls: [(date: Date, url: URL)] = []
  private var _copyCalls: [(from: URL, to: URL)] = []

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

    if let error = moveError { throw error }
    try real.moveItemAtomically(from: src, to: dst)
  }

  func applyTimestamps(creationDate: Date, to url: URL) {
    lock.lock()
    _timestampCalls.append((date: creationDate, url: url))
    lock.unlock()

    if shouldApplyTimestamps {
      real.applyTimestamps(creationDate: creationDate, to: url)
    }
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

  /// Hermetic stand-in for the real Trash: records the call and removes the
  /// item, so tests never pollute the user's `~/.Trash`.
  private var _trashCalls: [URL] = []
  var trashCalls: [URL] {
    lock.lock()
    defer { lock.unlock() }
    return _trashCalls
  }

  func trashItem(at url: URL) throws -> URL? {
    lock.lock()
    _trashCalls.append(url)
    lock.unlock()
    try real.removeItem(at: url)
    return nil
  }

  func copyItem(from src: URL, to dst: URL) throws {
    lock.lock()
    _copyCalls.append((from: src, to: dst))
    lock.unlock()

    if let error = copyError { throw error }
    try real.copyItem(from: src, to: dst)
  }
}
