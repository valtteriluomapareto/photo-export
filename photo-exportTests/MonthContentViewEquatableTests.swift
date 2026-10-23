import AppKit
import Foundation
import SwiftUI
import Testing

@testable import Photo_Export

/// The grid compares its stable layout/settings inputs. Action closures and selection bindings
/// belong to its children, so fresh wrappers and selection clicks leave the layout equal.
@MainActor
struct MonthContentViewEquatableTests {

  private func makeView(
    year: Int = 2025,
    month: Int = 6,
    versionSelection: ExportVersionSelection = .edited,
    livePhotosPaired: Bool = false,
    selected: AssetDescriptor? = nil,
    action: @escaping () -> Void = {}
  ) -> MonthContentView {
    var local = selected
    return MonthContentView(
      year: year, month: month,
      versionSelection: versionSelection,
      livePhotosPaired: livePhotosPaired,
      onExportMonth: action,
      selectedAsset: Binding(get: { local }, set: { local = $0 }),
      photoLibraryService: FakePhotoLibraryService()
    )
  }

  private func makeAsset(id: String) -> AssetDescriptor {
    AssetDescriptor(
      id: id,
      creationDate: Date(timeIntervalSince1970: 1_700_000_000),
      mediaType: .image,
      pixelWidth: 100, pixelHeight: 100, duration: 0, hasAdjustments: false
    )
  }

  @Test func equalWhenAllRenderingInputsMatch() {
    #expect(makeView() == makeView())
  }

  /// A freshly-allocated closure per parent render is the load-bearing case:
  /// `LibraryRootView` builds `{ exportManager.startExportMonth(year:month:) }`
  /// on every body re-run, so without this exclusion `.equatable()` would never
  /// short-circuit during an active export.
  @Test func equalEvenWhenOnExportMonthClosureDiffers() {
    let a = makeView(action: {
      // First action instance.
    })
    let b = makeView(action: {
      // Different action instance.
    })
    #expect(a == b)
  }

  /// Fresh wrappers do not change the layout; tile binding reads remain live independently.
  @Test func equalWhenBindingWrappersDifferButBoundIdsMatch() {
    let asset = makeAsset(id: "a")
    let a = makeView(selected: asset)
    let b = makeView(selected: asset)
    #expect(a == b)
  }

  @Test func notEqualOnYearChange() {
    #expect(makeView(year: 2025) != makeView(year: 2024))
  }

  @Test func notEqualOnMonthChange() {
    #expect(makeView(month: 6) != makeView(month: 7))
  }

  @Test func notEqualOnVersionSelectionChange() {
    #expect(
      makeView(versionSelection: .edited)
        != makeView(versionSelection: .editedWithOriginals))
  }

  /// `livePhotosPaired` flips the asset-aware `isExported(asset:selection:livePhotosPaired:)`
  /// call in each child badge, so a `false → true` flip MUST invalidate
  /// the cached equality and force the `LazyVGrid` to re-evaluate. Without this assertion
  /// a future refactor that drops `livePhotosPaired` from the `Equatable` comparison would
  /// silently freeze thumbnail badges at their pre-toggle state across runs.
  @Test func notEqualOnLivePhotosPairedChange() {
    let a = makeView(livePhotosPaired: false)
    let b = makeView(livePhotosPaired: true)
    #expect(a != b)
  }

  @Test func equalOnSelectedAssetIdChange() {
    let a = makeView(selected: makeAsset(id: "a"))
    let b = makeView(selected: makeAsset(id: "b"))
    #expect(a == b)
  }

  @Test func equalWhenOneHasSelectionAndOtherDoesNot() {
    let a = makeView(selected: makeAsset(id: "a"))
    let b = makeView(selected: nil)
    #expect(a == b)
  }
  @Test func selectionChangeThroughTheSameBindingLeavesLayoutEqual() {
    var selected: AssetDescriptor? = makeAsset(id: "A")
    let binding = Binding(get: { selected }, set: { selected = $0 })
    func view() -> MonthContentView {
      MonthContentView(
        year: 2026, month: 1, versionSelection: .edited, livePhotosPaired: false,
        onExportMonth: {}, selectedAsset: binding,
        photoLibraryService: FakePhotoLibraryService())
    }
    let before = view()
    selected = makeAsset(id: "B")
    #expect(before == view())
  }

}
