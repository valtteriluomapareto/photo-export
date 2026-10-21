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
  private var _inspectionHook: (@Sendable (URL) throws -> Void)?
  private var _identityHook: (@Sendable (URL) throws -> Void)?
  private var _chunkReadHook: (@Sendable (URL, Int64) async throws -> Void)?
  private var _identityOverride: (@Sendable (URL, FileItemIdentity?) -> FileItemIdentity?)?
  private var _chunkReads: [(url: URL, offset: Int64, length: Int)] = []
  private var _readOpens: [(url: URL, bypassingCache: Bool)] = []
  private var _readCloses: [URL] = []

  /// Runs before each identity lookup, so it can change what the lookup finds.
  var identityHook: (@Sendable (URL) throws -> Void)? {
    get { lock.withLock { _identityHook } }
    set { lock.withLock { _identityHook = newValue } }
  }

  /// Runs before each chunk read, so a test can hold or fail a byte comparison part way.
  var chunkReadHook: (@Sendable (URL, Int64) async throws -> Void)? {
    get { lock.withLock { _chunkReadHook } }
    set { lock.withLock { _chunkReadHook = newValue } }
  }

  /// Replaces what an identity lookup reports, given what the real lookup found.
  var identityOverride: (@Sendable (URL, FileItemIdentity?) -> FileItemIdentity?)? {
    get { lock.withLock { _identityOverride } }
    set { lock.withLock { _identityOverride = newValue } }
  }
  var chunkReads: [(url: URL, offset: Int64, length: Int)] { lock.withLock { _chunkReads } }
  var readOpens: [(url: URL, bypassingCache: Bool)] { lock.withLock { _readOpens } }
  var readCloses: [URL] { lock.withLock { _readCloses } }

  var inspectionHook: (@Sendable (URL) throws -> Void)? {
    get { lock.withLock { _inspectionHook } }
    set { lock.withLock { _inspectionHook = newValue } }
  }

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
  var moveError: Error? {
    get { lock.withLock { _moveError } }
    set { lock.withLock { _moveError = newValue } }
  }
  private var _moveError: Error?
  var copyError: Error? {
    get { lock.withLock { _copyError } }
    set { lock.withLock { _copyError = newValue } }
  }
  private var _copyError: Error?

  // Delegate to the real filesystem, through an injectable final commit.
  private let real: FileIOService

  init(real: FileIOService = FileIOService()) {
    self.real = real
  }

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

    real.applyTimestamps(creationDate: creationDate, to: url)
    afterTimestampsHook?(url)
  }

  func createDirectory(at url: URL, withIntermediateDirectories: Bool) throws {
    try real.createDirectory(at: url, withIntermediateDirectories: withIntermediateDirectories)
  }

  func fileExists(atPath path: String) -> Bool {
    real.fileExists(atPath: path)
  }

  func regularFileSize(at url: URL) throws -> Int64? {
    let size = try real.regularFileSize(at: url)
    try inspectionHook?(url)
    return size
  }

  func itemIdentity(at url: URL) throws -> FileItemIdentity? {
    try identityHook?(url)
    let identity = try real.itemIdentity(at: url)
    return identityOverride.map { $0(url, identity) } ?? identity
  }

  /// Answers `storedName(at:)` instead of reading the name.
  var storedNameOverride: (@Sendable (URL) throws -> String)? {
    get { lock.withLock { _storedNameOverride } }
    set { lock.withLock { _storedNameOverride = newValue } }
  }
  private var _storedNameOverride: (@Sendable (URL) throws -> String)?

  func storedName(at url: URL) throws -> String {
    if let override = storedNameOverride { return try override(url) }
    return try real.storedName(at: url)
  }

  func openForReading(at url: URL, bypassingCache: Bool) throws -> any FileReadHandle {
    lock.withLock { _readOpens.append((url: url, bypassingCache: bypassingCache)) }
    return RecordingReadHandle(
      real: try real.openForReading(at: url, bypassingCache: bypassingCache), url: url,
      owner: self)
  }

  fileprivate func recordRead(_ url: URL, _ offset: Int64, _ length: Int) {
    lock.withLock { _chunkReads.append((url: url, offset: offset, length: length)) }
  }

  fileprivate func recordClose(_ url: URL) {
    lock.withLock { _readCloses.append(url) }
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

/// Records each read and close, and runs `chunkReadHook` before each read.
private final class RecordingReadHandle: FileReadHandle, @unchecked Sendable {
  let real: any FileReadHandle
  let url: URL
  let owner: FakeFileSystem

  init(real: any FileReadHandle, url: URL, owner: FakeFileSystem) {
    self.real = real
    self.url = url
    self.owner = owner
  }

  func read(offset: Int64, length: Int) async throws -> Data {
    owner.recordRead(url, offset, length)
    try await owner.chunkReadHook?(url, offset)
    return try await real.read(offset: offset, length: length)
  }

  func close() {
    owner.recordClose(url)
    real.close()
  }
}
