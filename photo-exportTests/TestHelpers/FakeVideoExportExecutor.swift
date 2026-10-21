import AVFoundation
import Foundation

@testable import Photo_Export

/// Test double for `VideoExportExecutor`. Lets unit tests drive the
/// `requestSession` / `runExport` / `cancel` seam without constructing a
/// real `AVAssetExportSession` or talking to PhotoKit.
final class FakeVideoExportExecutor: VideoExportExecutor, @unchecked Sendable {
  // Recorded calls
  private let lock = NSLock()
  var requestCalls: [MediaRenderRequest] { lock.withLock { _requestCalls } }
  private var _requestCalls: [MediaRenderRequest] = []
  var runCalls: [(URL, AVFileType)] { lock.withLock { _runCalls } }
  private var _runCalls: [(URL, AVFileType)] = []
  var cancelCount: Int { lock.withLock { _cancelCount } }
  private var _cancelCount: Int = 0

  // Behavior knobs
  var requestSessionResult: Result<ExportSessionHandle, Error> {
    get { lock.withLock { _requestSessionResult } }
    set { lock.withLock { _requestSessionResult = newValue } }
  }
  private var _requestSessionResult: Result<ExportSessionHandle, Error> = .success(
    ExportSessionHandle(NSObject()))
  /// Closure invoked when `runExport` is called. Default: returns success.
  /// Use this to drive each `AVAssetExportSession.Status` mapping branch.
  var runExportBehavior: @Sendable (ExportSessionHandle, URL, AVFileType) async throws -> Void {
    get { lock.withLock { _runExportBehavior } }
    set { lock.withLock { _runExportBehavior = newValue } }
  }
  private var _runExportBehavior:
    @Sendable (ExportSessionHandle, URL, AVFileType) async throws -> Void = {
      _, url, _ in
      FileManager.default.createFile(atPath: url.path, contents: Data("fake".utf8))
    }
  /// Optional latch the runExport call awaits before doing anything. Used
  /// by cancel-during-render tests.
  var runExportLatch: AsyncSemaphore? {
    get { lock.withLock { _runExportLatch } }
    set { lock.withLock { _runExportLatch = newValue } }
  }
  private var _runExportLatch: AsyncSemaphore?

  func requestSession(for request: MediaRenderRequest) async throws -> ExportSessionHandle {
    lock.withLock { _requestCalls.append(request) }
    return try requestSessionResult.get()
  }

  func runExport(session: ExportSessionHandle, to url: URL, fileType: AVFileType) async throws {
    if let latch = runExportLatch { await latch.wait() }
    lock.withLock { _runCalls.append((url, fileType)) }
    try await runExportBehavior(session, url, fileType)
  }

  func cancel(session: ExportSessionHandle) {
    lock.withLock { _cancelCount += 1 }
  }
}
