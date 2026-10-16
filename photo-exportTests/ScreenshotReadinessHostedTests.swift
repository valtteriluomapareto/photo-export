import AppKit
import SwiftUI
import Testing

@testable import Photo_Export

/// Exercises the actual cell hook, window reporter, layout fence and JSON publication.
@MainActor
struct ScreenshotReadinessHostedTests {
  private func observe(_ condition: () -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(15))
    while !condition(), !Task.isCancelled, clock.now < deadline {
      try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
  }

  @Test(.timeLimit(.minutes(2)))
  func delayedVisibleThumbnailBlocksReadyThenPublishesAfterLayout() async throws {
    let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let state = try #require(ScreenshotSession.catalog().first)
    let session = try ScreenshotSession(id: UUID(), state: state, parent: parent)
    let gate = AsyncCheckpoint()
    let service = FakePhotoLibraryService()
    let context = try #require(
      CGContext(
        data: nil, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 64,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(NSColor.green.cgColor)
    context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
    let image = try #require(context.makeImage())
    service.decodedThumbnailOverride = { _, _, mode in
      if mode == .fast { await gate.enter() }
      return image
    }
    let manager = PhotoLibraryManager(overrideService: service)
    let hosted = NSHostingView(
      rootView:
        ThumbnailView(
          asset: TestAssetFactory.makeAsset(id: "capture-cell"), isSelected: false,
          isExported: false
        )
        .frame(width: 100, height: 100)
        .environmentObject(manager)
        .environment(\.screenshotSession, session)
        .background(ScreenshotWindowReporter(session: session))
        .onAppear { session.contentLoaded() })
    let window = NSWindow(
      contentRect: NSRect(x: -10_000, y: -10_000, width: 100, height: 100),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = hosted
    defer {
      window.orderOut(nil)
      window.contentView = nil
      window.close()
      manager.decodedThumbnailCache.clear()
      Task { await gate.releaseAll() }
      UserDefaults.standard.removePersistentDomain(forName: session.defaultsName)
      try? FileManager.default.removeItem(at: parent)
    }
    let reportURL = session.root.appendingPathComponent("readiness.json")
    func report() -> [String: Any] {
      guard let data = try? Data(contentsOf: reportURL) else { return [:] }
      return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }
    window.orderFront(nil)
    await gate.waitForEnter(count: 1)
    #expect(report()["status"] as? String == "loading")
    #expect((report()["pending"] as? [String])?.contains("ThumbnailView") == true)
    await gate.releaseAll()
    let becameReady = await observe { report()["status"] as? String == "ready" }
    #expect(becameReady, "actual session did not publish ready: \(report())")
    #expect(report()["windowID"] as? Int == window.windowNumber)
    #expect(report()["session"] as? String == session.id.uuidString)
    let token = session.beginWork("replacement image")
    #expect(report()["status"] as? String == "loading")
    session.finishWork(token)
    #expect(await observe { report()["status"] as? String == "ready" })
  }
}
