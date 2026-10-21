import Foundation

@testable import Photo_Export

/// A `JSONLRecordLogIO` that holds chosen file reads until the test releases them, so a test can
/// look at a record store while its load is still running. Reads go to the real files.
///
/// The hold has no deadline; the enclosing test's `.timeLimit` is the backstop. A read on the main
/// thread is recorded in `mainThreadReads` and never held, since holding it would block the test
/// itself: a store that loads on the main thread fails the test at once instead of hanging it.
///
/// A held read blocks the store's IO queue, and so does anything that waits for that queue, such as
/// `flushForTesting()` or a destination switch. Teardown must call `releaseAll()` before flushing.
final class HeldReadIO: JSONLRecordLogIO, @unchecked Sendable {
  private let production = ProductionJSONLRecordLogIO()
  private let condition = NSCondition()
  /// The first read of each URL that is held, counting from 1.
  private var holds: [URL: Int] = [:]
  private var readCounts: [URL: Int] = [:]
  private var heldNow: [URL] = []
  private var isShutdown = false
  private var mainReads: [URL] = []

  /// Holds reads of `url` from its `occurrence`-th read on (counting every read so far), until
  /// `release(_:)`.
  func hold(_ url: URL, fromRead occurrence: Int = 1) {
    condition.withLock { holds[url] = occurrence }
  }

  /// Lets the held read of `url` and every later one through.
  func release(_ url: URL) {
    condition.withLock {
      holds[url] = nil
      condition.broadcast()
    }
  }

  /// Lets every held and future read through. Call before any flush in teardown.
  func releaseAll() {
    condition.withLock {
      isShutdown = true
      holds.removeAll()
      condition.broadcast()
    }
  }

  /// Reads waiting for a release right now.
  var heldCount: Int { condition.withLock { heldNow.count } }

  /// Reads that ran on the main thread, in order.
  var mainThreadReads: [URL] { condition.withLock { mainReads } }

  /// How many times `url` has been read so far.
  func readCount(of url: URL) -> Int { condition.withLock { readCounts[url] ?? 0 } }

  func readIfPresent(at url: URL) throws -> Data? {
    condition.lock()
    let occurrence = (readCounts[url] ?? 0) + 1
    readCounts[url] = occurrence
    if Thread.isMainThread {
      mainReads.append(url)
    } else if let from = holds[url], occurrence >= from, !isShutdown {
      heldNow.append(url)
      while let from = holds[url], occurrence >= from, !isShutdown {
        condition.wait()
      }
      if let index = heldNow.firstIndex(of: url) { heldNow.remove(at: index) }
    }
    condition.unlock()
    return try production.readIfPresent(at: url)
  }

  func openForAppending(at url: URL) throws -> FileHandle {
    try production.openForAppending(at: url)
  }

  func write(_ data: Data, to handle: FileHandle) throws {
    try production.write(data, to: handle)
  }

  func synchronize(_ handle: FileHandle) throws {
    try production.synchronize(handle)
  }
}
