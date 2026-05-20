import AppKit
import Foundation
import SwiftUI
import Testing

@testable import Photo_Export

/// `MonthContentView` is `Equatable` so SwiftUI's `.equatable()` modifier can
/// short-circuit `body` re-evaluation when the rendering inputs haven't changed.
/// `LibraryRootView` re-renders on every `ExportManager.objectWillChange` (manager
/// fires per export job for `queueCount` / `activeRunContext`), so without this
/// the `LazyVGrid` would re-evaluate on every fire and re-execute its ForEach.
///
/// These tests pin the equality rules — closures and `Binding` instances must be
/// excluded so a freshly-allocated `onExportMonth` per render doesn't defeat the
/// diff, and a new `Binding<AssetDescriptor?>` instance per render compares by
/// the bound asset id rather than by wrapper identity.
@MainActor
struct MonthContentViewEquatableTests {

  private func makeView(
    year: Int = 2025,
    month: Int = 6,
    versionSelection: ExportVersionSelection = .edited,
    livePhotosPaired: Bool = false,
    isExportRunning: Bool = false,
    selected: AssetDescriptor? = nil,
    action: @escaping () -> Void = {}
  ) -> MonthContentView {
    var local = selected
    return MonthContentView(
      year: year, month: month,
      versionSelection: versionSelection,
      livePhotosPaired: livePhotosPaired,
      isExportRunning: isExportRunning,
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
    let a = makeView(action: { /* noop a */ })
    let b = makeView(action: { /* noop b — different instance */ })
    #expect(a == b)
  }

  /// `Binding<AssetDescriptor?>` is non-`Equatable`; SwiftUI rebuilds the wrapper
  /// per parent render. The equality check compares the *bound asset id*, not
  /// the wrapper, so the same selection survives parent re-renders.
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

  @Test func notEqualOnIsExportRunningChange() {
    #expect(makeView(isExportRunning: false) != makeView(isExportRunning: true))
  }

  @Test func notEqualOnSelectedAssetIdChange() {
    let a = makeView(selected: makeAsset(id: "a"))
    let b = makeView(selected: makeAsset(id: "b"))
    #expect(a != b)
  }

  @Test func notEqualWhenOneHasSelectionAndOtherDoesNot() {
    let a = makeView(selected: makeAsset(id: "a"))
    let b = makeView(selected: nil)
    #expect(a != b)
  }
}
