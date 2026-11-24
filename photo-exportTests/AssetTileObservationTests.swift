import AppKit
import SwiftUI
import Testing

@testable import Photo_Export

@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct AssetTileObservationTests {
  @Observable final class Selection { var asset: AssetDescriptor? }

  private struct Host: View {
    let asset: AssetDescriptor
    let placement: ExportPlacement
    @Bindable var selection: Selection
    var body: some View {
      CollectionAssetTile(
        asset: asset, placement: placement, versionSelection: .edited,
        livePhotosPaired: false, selectedAsset: $selection.asset, onSelect: {})
    }
  }

  @Test func nativeTileReadsOnlyItsPlacementAndFollowsSelectionBinding() async throws {
    let h = await ExportManagerHarness(label: "NativeAssetTile")
    let library = PhotoLibraryManager(overrideService: h.photoLib)
    let asset = TestAssetFactory.makeAsset(id: "tile", creationDate: nil)
    let current = ExportPlacement.favorites()
    let other = ExportPlacement(
      kind: .album, id: "old", displayName: "Old", collectionLocalIdentifier: "old",
      relativePath: "Collections/Albums/Old/", createdAt: Date(timeIntervalSince1970: 0))
    let selection = Selection()
    h.collectionStore.upsertPlacement(current)
    h.collectionStore.upsertPlacement(other)
    h.collectionStore.markVariantExported(
      assetId: asset.id, placement: other, variant: .original,
      filename: "OTHER.JPG", exportedAt: Date())
    let window = HostedViewHarness.makeWindow(
      contentRect: NSRect(x: -10000, y: -10000, width: 160, height: 160),
      styleMask: [.borderless])
    window.contentView = NSHostingView(
      rootView: Host(
        asset: asset, placement: current, selection: selection
      )
      .environment(library).environment(h.collectionStore)
      .environment(\.accessibilityEnabled, true))
    defer {
      window.orderOut(nil)
      window.contentView = nil
      window.close()
      h.store.drainSynchronously()
      h.collectionStore.drainSynchronously()
      h.dest.cleanup()
      try? FileManager.default.removeItem(at: h.storeRoot)
    }
    window.orderFront(nil)
    try #require(
      await observe(in: window) {
        NativeViewAccess.texts(in: window).contains { $0.hasPrefix("Photo, not yet exported") }
      })
    h.collectionStore.markVariantExported(
      assetId: asset.id, placement: current, variant: .original,
      filename: "CURRENT.JPG", exportedAt: Date())
    h.collectionStore.flushPendingNotifications()
    try #require(
      await observe(in: window) {
        NativeViewAccess.texts(in: window).contains { $0.hasPrefix("Photo, exported") }
      })
    selection.asset = asset
    #expect(
      await observe(in: window) {
        NativeViewAccess.elements(in: window).contains {
          $0.accessibilityLabel?()?.hasPrefix("Photo, exported") == true
            && $0.isAccessibilitySelected?() == true
        }
      })
  }
}
