import SwiftUI

/// Each visible timeline tile owns its record dependency, independently of the grid layout.
struct TimelineAssetTile: View {
  @Environment(ExportRecordStore.self) private var records
  let asset: AssetDescriptor
  let versionSelection: ExportVersionSelection
  let livePhotosPaired: Bool
  @Binding var selectedAsset: AssetDescriptor?
  let onSelect: () -> Void
  #if DEBUG
    @Environment(\.bodyInvalidationCounter) private var counter
  #endif

  var body: some View {
    #if DEBUG
      // swiftlint:disable:next redundant_discardable_let
      let _ = counter?.record("asset-tile-body:\(asset.id)")
    #endif
    AssetGridTile(
      asset: asset,
      isExported: records.isExportedForTile(
        asset: asset, selection: versionSelection, livePhotosPaired: livePhotosPaired),
      selectedAsset: $selectedAsset, onSelect: onSelect)
  }
}

/// Placement-scoped badges observe only their own asset record.
struct CollectionAssetTile: View {
  @Environment(CollectionExportRecordStore.self) private var records
  let asset: AssetDescriptor
  let placement: ExportPlacement?
  let versionSelection: ExportVersionSelection
  let livePhotosPaired: Bool
  @Binding var selectedAsset: AssetDescriptor?
  let onSelect: () -> Void
  #if DEBUG
    @Environment(\.bodyInvalidationCounter) private var counter
  #endif

  var body: some View {
    #if DEBUG
      // swiftlint:disable:next redundant_discardable_let
      let _ = counter?.record("asset-tile-body:\(asset.id)")
    #endif
    let isExported =
      placement.map {
        records.isExportedForTile(
          asset: asset, placement: $0, selection: versionSelection,
          livePhotosPaired: livePhotosPaired)
      } ?? false
    AssetGridTile(
      asset: asset, isExported: isExported, selectedAsset: $selectedAsset, onSelect: onSelect)
  }
}

private struct AssetGridTile: View {
  let asset: AssetDescriptor
  let isExported: Bool
  @Binding var selectedAsset: AssetDescriptor?
  let onSelect: () -> Void
  #if DEBUG
    @Environment(\.bodyInvalidationCounter) private var counter
  #endif

  var body: some View {
    #if DEBUG
      // swiftlint:disable:next redundant_discardable_let
      let _ = counter?.record("selected:\(selectedAsset?.id ?? "")")
    #endif
    ThumbnailView(asset: asset, isSelected: asset.id == selectedAsset?.id, isExported: isExported)
      .frame(width: 120, height: 120)
      .onTapGesture {
        selectedAsset = asset
        onSelect()
      }
  }
}
