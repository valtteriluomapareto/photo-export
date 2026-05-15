import Foundation
import Photos
import Testing

@testable import Photo_Export

/// Pins the "Include originals is a no-op for shared albums" guarantee — the
/// novel behaviour that justifies the `.sharedAlbum` placement kind in the
/// first place. `requiredVariants(...)` must clamp to `[.original]` whenever
/// the policy is `.singleResource`, regardless of asset adjustments or the
/// user-selected version mode, so the `_orig` companion is never written for
/// reduced-fidelity placements.
///
/// Sibling test files cover the surrounding concerns: resolver behaviour
/// (`ExportPlacementResolverTests`), record-store routing
/// (`CollectionExportRecordStoreTests`), tree partitioning
/// (`ExportAllAlbumsTests`).
@MainActor
struct SharedAlbumExportTests {

  // MARK: - Single-resource policy clamps to `[.original]`

  /// An adjusted asset under `.singleResource` must collapse to `[.original]`
  /// regardless of the selection mode. This is the regression guard for
  /// "Include originals" being a no-op on shared albums — without it, a
  /// `.editedWithOriginals` selection would try to write a `_orig` companion
  /// for content where no original bytes are actually available.
  @Test func singleResourcePolicyClampsAdjustedAssetToOriginal() {
    let adjusted = TestAssetFactory.makeAsset(id: "a", hasAdjustments: true)
    let edited = requiredVariants(
      for: adjusted, selection: .edited, policy: .singleResource)
    let withOrig = requiredVariants(
      for: adjusted, selection: .editedWithOriginals, policy: .singleResource)
    #expect(edited == [.original])
    #expect(withOrig == [.original])
  }

  /// Unadjusted assets under `.singleResource` resolve to `[.original]` too —
  /// same clamp, just exercising the other branch of the asset's
  /// `hasAdjustments` axis. Symmetric coverage of the policy's truth table.
  @Test func singleResourcePolicyClampsUnadjustedAssetToOriginal() {
    let unadjusted = TestAssetFactory.makeAsset(id: "b", hasAdjustments: false)
    let edited = requiredVariants(
      for: unadjusted, selection: .edited, policy: .singleResource)
    let withOrig = requiredVariants(
      for: unadjusted, selection: .editedWithOriginals, policy: .singleResource)
    #expect(edited == [.original])
    #expect(withOrig == [.original])
  }

  // MARK: - Standard policy keeps the user-selected variant set intact

  /// `.standard` policy on an adjusted asset honours the user's selection —
  /// `[.original, .edited]` under `editedWithOriginals`. Confirms the clamp
  /// is scoped to `.singleResource` and doesn't leak.
  @Test func standardPolicyHonoursEditedWithOriginalsForAdjustedAsset() {
    let adjusted = TestAssetFactory.makeAsset(id: "a", hasAdjustments: true)
    let result = requiredVariants(
      for: adjusted, selection: .editedWithOriginals, policy: .standard)
    #expect(result == [.original, .edited])
  }

  /// Symmetric case: unadjusted asset under `.standard × .editedWithOriginals`
  /// still produces `[.original]` (no edits to pair with). The combination is
  /// not exercised anywhere else, so a regression to "always include both" on
  /// the standard path would slip through without this.
  @Test func standardPolicyOnUnadjustedAssetReturnsOriginalOnly() {
    let unadjusted = TestAssetFactory.makeAsset(id: "a", hasAdjustments: false)
    let result = requiredVariants(
      for: unadjusted, selection: .editedWithOriginals, policy: .standard)
    #expect(result == [.original])
  }

  // MARK: - Kind → policy mapping

  /// The kind → policy mapping is what wires the placement family into the
  /// variant decision. `.sharedAlbum → .singleResource` is the load-bearing
  /// edge; the other three cases are coverage for any future refactor that
  /// might re-route policy lookup through a different surface.
  @Test func sharedAlbumKindIsTheOnlySingleResourcePolicy() {
    #expect(ExportPlacement.Kind.sharedAlbum.variantPolicy == .singleResource)
    #expect(ExportPlacement.Kind.timeline.variantPolicy == .standard)
    #expect(ExportPlacement.Kind.favorites.variantPolicy == .standard)
    #expect(ExportPlacement.Kind.album.variantPolicy == .standard)
  }
}
