import AVFoundation
import Foundation
import Testing

@testable import Photo_Export

/// Drives `ProductionMediaRenderer` through `FakeVideoExportExecutor` to
/// verify that:
/// - request/run/cancel calls reach the executor in the expected order,
/// - the activity callback flips through `.downloading` → `.rendering`
///   → `nil`,
/// - executor errors propagate (mapped to `editedResourceUnavailableMessage`
///   higher up; here we only verify the throw makes it back),
/// - cancellation forwards to `cancel(session:)`.
///
/// The tests do not exercise real `AVAssetExportSession`. The
/// status-mapping branches inside `LiveVideoExportExecutor.runExport`
/// (completed/cancelled/failed/default) are covered by the modern
/// `try await session.export(to:as:)` API which throws on every
/// non-success state — so the seam at `runExport` is the right level to
/// drive in tests.
@MainActor
struct VideoExportExecutorTests {
  private func makeRequest(
    id: String = "asset-id", filename: String = "IMG_0001.MOV",
    fileType: AVFileType = .mov
  ) -> MediaRenderRequest {
    MediaRenderRequest(
      assetId: id, originalFilename: filename, fileType: fileType, kind: .video)
  }

  private final class ActivityRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [RenderActivity?] = []
    var events: [RenderActivity?] {
      lock.lock()
      defer { lock.unlock() }
      return _events
    }
    func record(_ a: RenderActivity?) {
      lock.lock()
      _events.append(a)
      lock.unlock()
    }
  }

  @Test func happyPathFlipsActivityDownloadingThenRendering() async throws {
    let executor = FakeVideoExportExecutor()
    let recorder = ActivityRecorder()
    let renderer = ProductionMediaRenderer(executor: executor) { recorder.record($0) }
    let directory = TestScratch.directory("VideoExportExecutor")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("happy.mov")

    try await renderer.render(request: makeRequest(), to: url)

    #expect(executor.requestCalls.count == 1)
    #expect(executor.runCalls.count == 1)
    #expect(executor.cancelCount == 0)
    #expect(recorder.events == [.downloading, .rendering])
    #expect(FileManager.default.fileExists(atPath: url.path))
  }

  @Test func requestSessionFailureSkipsRunAndPropagates() async {
    let executor = FakeVideoExportExecutor()
    executor.requestSessionResult = .failure(
      NSError(domain: "Test", code: 99, userInfo: nil))
    let renderer = ProductionMediaRenderer(executor: executor) { _ in }

    await #expect(throws: (any Error).self) {
      try await renderer.render(
        request: makeRequest(),
        to: TestScratch.directory("VideoExportExecutor").appendingPathComponent("x.mov"))
    }

    #expect(executor.requestCalls.count == 1)
    #expect(executor.runCalls.isEmpty)
    #expect(executor.cancelCount == 0)
  }

  @Test func runExportFailurePropagates() async {
    let executor = FakeVideoExportExecutor()
    executor.runExportBehavior = { _, _, _ in
      throw NSError(domain: "Test", code: 7, userInfo: nil)
    }
    let renderer = ProductionMediaRenderer(executor: executor) { _ in }

    await #expect(throws: (any Error).self) {
      try await renderer.render(
        request: makeRequest(),
        to: TestScratch.directory("VideoExportExecutor").appendingPathComponent("y.mov"))
    }

    #expect(executor.runCalls.count == 1)
  }

  @Test func cancelDuringRunForwardsCancelToExecutor() async throws {
    let executor = FakeVideoExportExecutor()
    let latch = AsyncSemaphore()
    executor.runExportLatch = latch
    let renderer = ProductionMediaRenderer(executor: executor) { _ in }

    let directory = TestScratch.directory("VideoExportExecutor")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("cancel.mov")

    let task = Task {
      try await renderer.render(request: makeRequest(), to: url)
    }

    // Give the runner a moment to enter the latch wait so the cancel
    // arrives during the export rather than before it.
    try await Task.sleep(for: .milliseconds(20))
    task.cancel()
    latch.signal()

    // The fake's runExportBehavior returns success after the latch is
    // signalled. Whether the parent task surfaces `CancellationError`
    // (because the post-render `Task.isCancelled` branch in
    // ProductionMediaRenderer fires) or returns success depends on the
    // race between cancel propagation and the latch resume. The
    // load-bearing assertion is that `cancel(session:)` was forwarded,
    // not the eventual outcome of `task.value`.
    _ = try? await task.value
    #expect(executor.cancelCount >= 1)
  }
}
