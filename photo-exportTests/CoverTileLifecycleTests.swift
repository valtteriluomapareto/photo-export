import AppKit
import SwiftUI
import Testing

@testable import Photo_Export

@MainActor
@Suite(.timeLimit(.minutes(2)), .serialized)
struct CoverTileLifecycleTests {
  @Observable final class Selection {
    var selected = false
    var year = 2025
  }

  private struct AlbumHost: View {
    let selection: Selection
    let service: FakePhotoLibraryService
    var body: some View {
      FolderTileView(
        descriptor: CoverTileLifecycleTests.collection(.album), photoCount: 1, albumCount: 0,
        isFullyExported: false, isSelected: selection.selected, photoLibraryService: service)
    }
  }

  private struct MonthHost: View {
    let selection: Selection
    let service: FakePhotoLibraryService
    var body: some View {
      MonthTileView(
        year: selection.year, month: 1, photoCount: 1, isFullyExported: false,
        photoLibraryService: service)
    }
  }

  private static func collection(_ kind: PhotoCollectionDescriptor.Kind)
    -> PhotoCollectionDescriptor
  {
    PhotoCollectionDescriptor(
      id: "cover", localIdentifier: "cover", title: "Trip", kind: kind,
      pathComponents: [], children: [])
  }

  private func window<Content: View>(_ content: Content) -> NSWindow {
    let window = HostedViewHarness.makeWindow(
      contentRect: NSRect(x: -10000, y: -10000, width: 220, height: 240),
      styleMask: [.borderless])
    window.contentView = NSHostingView(
      rootView: content.environment(\.accessibilityEnabled, true))
    window.orderFront(nil)
    return window
  }

  private func close(_ window: NSWindow) {
    window.orderOut(nil)
    window.contentView = nil
    window.close()
  }

  @Test func folderTileIsMountedWithoutFetchingCovers() async throws {
    let service = FakePhotoLibraryService()
    let window = window(
      FolderTileView(
        descriptor: Self.collection(.folder), photoCount: 1, albumCount: 2,
        isFullyExported: false, isSelected: false, photoLibraryService: service))
    defer { close(window) }
    try #require(
      await observe(in: window) {
        NativeViewAccess.containsText("Folder, Trip, 2 albums, 1 photos", in: window)
      })
    #expect(service.scopeFetchCalls.isEmpty)
    #expect(service.decodedThumbnailCalls.isEmpty)
  }

  @Test func selectingMountedAlbumDoesNotRefetchItsCover() async throws {
    let service = FakePhotoLibraryService()
    service.assetsByAlbumLocalId["cover"] = [TestAssetFactory.makeAsset(id: "cover-photo")]
    service.hqThumbnailsByAssetId["cover-photo"] = NSImage(
      size: NSSize(width: 20, height: 20), flipped: false
    ) { bounds in
      NSColor.red.setFill()
      bounds.fill()
      return true
    }
    let selection = Selection()
    let window = window(AlbumHost(selection: selection, service: service))
    defer { close(window) }
    let label = "Album, Trip, 1 photo"
    try #require(await observe(in: window) { NativeViewAccess.containsText(label, in: window) })
    #expect(service.scopeFetchCalls == [.album(collectionId: "cover")])
    #expect(service.decodedThumbnailCalls.count == 1)

    selection.selected = true
    try #require(
      await observe(in: window) {
        NativeViewAccess.elements(in: window).contains {
          $0.accessibilityLabel?() == label && $0.isAccessibilitySelected?() == true
        }
      })
    #expect(service.scopeFetchCalls == [.album(collectionId: "cover")])
    #expect(service.decodedThumbnailCalls.count == 1)
  }

  @Test func changingYearLoadsTheNewCoverWhileOldImagesAreHeld() async throws {
    let service = FakePhotoLibraryService()
    for year in [2025, 2026] {
      service.assetsByYearMonth["\(year)-1"] = [
        TestAssetFactory.makeAsset(
          id: "\(year)",
          creationDate: try #require(
            Calendar.current.date(
              from: DateComponents(year: year, month: 1, day: 15))))
      ]
    }
    let gate = AsyncCheckpoint()
    let red = try solidImage(.red)
    let blue = try solidImage(.blue)
    service.decodedThumbnailOverride = { id, _, _ in
      if id == "2025" { await gate.enter() }
      return id == "2025" ? red : blue
    }
    let selection = Selection()
    let window = window(MonthHost(selection: selection, service: service))
    try await withCleanup {
      try #require(await gate.waitForEnter(count: 1))
      selection.year = 2026
      // The old cover is held, so only the new year's load can clear "Loading preview".
      try #require(
        await observe(in: window) {
          NativeViewAccess.containsText("Month, January 2026, 1 photo", in: window)
        })
      #expect(
        service.scopeFetchCalls == [
          .timeline(year: 2025, month: 1), .timeline(year: 2026, month: 1),
        ])
    } cleanup: {
      close(window)
      await gate.releaseAll()
    }
  }

  private func solidImage(_ color: NSColor) throws -> CGImage {
    let context = try #require(
      CGContext(
        data: nil, width: 20, height: 20, bitsPerComponent: 8, bytesPerRow: 80,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(color.cgColor)
    context.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
    return try #require(context.makeImage())
  }
}
