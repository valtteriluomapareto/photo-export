import AppKit
import SwiftUI
import Testing

@testable import Photo_Export

/// Exercises SwiftUI's actual task lifecycle with the detail view mounted in a window.
/// The fake holds each image request until the test releases it, so cancellation is
/// observable without depending on a scheduler yield or an image callback race.
@MainActor
struct AssetDetailViewLifecycleTests {
  @MainActor
  private final class Selection: ObservableObject {
    @Published var asset: AssetDescriptor?
    @Published var showsDetail = true

    init(asset: AssetDescriptor) {
      self.asset = asset
    }
  }

  @MainActor
  private struct HostedDetail: View {
    @ObservedObject var selection: Selection
    let photoLibraryManager: PhotoLibraryManager
    let exportRecordStore: ExportRecordStore

    var body: some View {
      Group {
        if selection.showsDetail {
          AssetDetailView(asset: selection.asset)
            .environmentObject(photoLibraryManager)
            .environmentObject(exportRecordStore)
        } else {
          Color.clear
        }
      }
    }
  }

  private actor CancellationSignals {
    private var cancelled: Set<String> = []
    private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    func record(_ assetId: String) {
      cancelled.insert(assetId)
      for waiter in waiters.removeValue(forKey: assetId) ?? [] {
        waiter.resume()
      }
    }

    func wait(for assetId: String) async {
      if cancelled.contains(assetId) { return }
      await withCheckedContinuation { continuation in
        waiters[assetId, default: []].append(continuation)
      }
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func switchingSelectionAndRemovingDetailCancelImageRequests() async throws {
    let first = TestAssetFactory.makeAsset(id: "detail-A")
    let second = TestAssetFactory.makeAsset(id: "detail-B")
    let firstGate = AsyncCheckpoint()
    let secondGate = AsyncCheckpoint()
    let cancellations = CancellationSignals()
    let service = FakePhotoLibraryService()
    service.fullImageRequestOverride = { assetId in
      let gate = assetId == first.id ? firstGate : secondGate
      return try await withTaskCancellationHandler {
        await gate.enter()
        try Task.checkCancellation()
        return NSImage(size: NSSize(width: 4, height: 4))
      } onCancel: {
        Task { await cancellations.record(assetId) }
      }
    }

    let photoLibraryManager = PhotoLibraryManager(overrideService: service)
    let storeRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent("AssetDetailLifecycle-\(UUID().uuidString)", isDirectory: true)
    let exportRecordStore = ExportRecordStore(baseDirectoryURL: storeRoot)
    exportRecordStore.configure(for: "detail-test")
    let selection = Selection(asset: first)
    let hostingView = NSHostingView(
      rootView: HostedDetail(
        selection: selection, photoLibraryManager: photoLibraryManager,
        exportRecordStore: exportRecordStore))
    let window = NSWindow(
      contentRect: NSRect(x: -10_000, y: -10_000, width: 400, height: 400),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = hostingView
    defer {
      window.orderOut(nil)
      window.contentView = nil
      window.close()
      Task {
        await firstGate.releaseAll()
        await secondGate.releaseAll()
      }
      exportRecordStore.flushForTesting()
      try? FileManager.default.removeItem(at: storeRoot)
    }
    window.orderFront(nil)

    await firstGate.waitForEnter(count: 1)
    selection.asset = second
    await cancellations.wait(for: first.id)
    await secondGate.waitForEnter(count: 1)

    selection.showsDetail = false
    await cancellations.wait(for: second.id)
    await firstGate.releaseAll()
    await secondGate.releaseAll()
  }
}
