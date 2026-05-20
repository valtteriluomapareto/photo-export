import Foundation
import Photos
import Testing

@testable import Photo_Export

/// Pins the Live Photo paired-export contract at the `requiredVariants` seam — the
/// single source of truth for "which files does this asset need." Issue #49 made
/// the behaviour opt-in via Settings, so every test here exercises the toggle as a
/// parameter: with `livePhotosPaired: false` (the shipped default) the output must
/// be byte-identical to today's stills-only behaviour; with `livePhotosPaired: true`
/// the paired-video variant lands alongside the matching image variant. The shared-
/// album `.singleResource` policy continues to win over both — Apple doesn't serve
/// paired video for shared assets, so the policy must keep collapsing to `[.original]`
/// regardless of the toggle.
@MainActor
struct LivePhotoVariantTests {

  // MARK: - Toggle OFF — byte-identical to pre-issue-#49 behaviour

  /// Issue #49 acceptance criterion: "Toggle off: byte-identical to today's behaviour
  /// against the existing fixtures." A Live Photo with the toggle off must emit the
  /// same variants as a non-Live-Photo image — no paired-video variants leak through.
  /// This is the load-bearing regression guard for the opt-in design.
  @Test func livePhotoWithToggleOffEmitsImageVariantsOnly() {
    let live = TestAssetFactory.makeAsset(id: "live", hasAdjustments: false, isLivePhoto: true)
    let still = TestAssetFactory.makeAsset(id: "still", hasAdjustments: false)
    #expect(
      requiredVariants(
        for: live, selection: .edited, policy: .standard, livePhotosPaired: false)
        == requiredVariants(
          for: still, selection: .edited, policy: .standard, livePhotosPaired: false))
  }

  /// Same byte-identical guarantee under the adjusted-asset cross product — toggle off
  /// must not surface a `.editedPairedVideo` regardless of edits or include-originals.
  @Test func adjustedLivePhotoWithToggleOffEmitsImageVariantsOnly() {
    let live = TestAssetFactory.makeAsset(id: "live", hasAdjustments: true, isLivePhoto: true)
    let result = requiredVariants(
      for: live, selection: .editedWithOriginals, policy: .standard,
      livePhotosPaired: false)
    #expect(result == [.original, .edited])
  }

  /// Default-argument value of `livePhotosPaired` is `false` — call sites that don't
  /// yet know about the toggle keep emitting the pre-issue-#49 set. Pinning the
  /// default value itself so a future maintainer can't flip it inadvertently.
  @Test func livePhotosPairedDefaultsToFalse() {
    let live = TestAssetFactory.makeAsset(id: "live", hasAdjustments: true, isLivePhoto: true)
    let withDefault = requiredVariants(
      for: live, selection: .editedWithOriginals, policy: .standard)
    let explicitOff = requiredVariants(
      for: live, selection: .editedWithOriginals, policy: .standard,
      livePhotosPaired: false)
    #expect(withDefault == explicitOff)
  }

  // MARK: - Toggle ON, standard policy, Live Photo

  /// Unedited Live Photo under `.edited` selection → still + paired video.
  /// The image side falls back to `.original` (no edits to render), and the motion
  /// file pairs with it as `.originalPairedVideo`.
  @Test func unadjustedLivePhotoEditedSelectionEmitsOriginalPair() {
    let live = TestAssetFactory.makeAsset(id: "live", hasAdjustments: false, isLivePhoto: true)
    let result = requiredVariants(
      for: live, selection: .edited, policy: .standard, livePhotosPaired: true)
    #expect(result == [.original, .originalPairedVideo])
  }

  /// Adjusted Live Photo under `.edited` selection → rendered still + rendered
  /// paired video. The user sees the edited bytes for both components.
  @Test func adjustedLivePhotoEditedSelectionEmitsEditedPair() {
    let live = TestAssetFactory.makeAsset(id: "live", hasAdjustments: true, isLivePhoto: true)
    let result = requiredVariants(
      for: live, selection: .edited, policy: .standard, livePhotosPaired: true)
    #expect(result == [.edited, .editedPairedVideo])
  }

  /// Adjusted Live Photo under `.editedWithOriginals` → all four variants. Both
  /// `_orig` companions land alongside the edited pair so the user keeps a full
  /// motion-and-still archive of the pre-edit bytes.
  @Test func adjustedLivePhotoEditedWithOriginalsEmitsFullQuad() {
    let live = TestAssetFactory.makeAsset(id: "live", hasAdjustments: true, isLivePhoto: true)
    let result = requiredVariants(
      for: live, selection: .editedWithOriginals, policy: .standard,
      livePhotosPaired: true)
    #expect(result == [.original, .originalPairedVideo, .edited, .editedPairedVideo])
  }

  /// Unedited Live Photo under `.editedWithOriginals` → no `.edited`/`.editedPairedVideo`
  /// because the asset has no Photos edit to render. Only the original pair is required.
  @Test func unadjustedLivePhotoEditedWithOriginalsEmitsOriginalPairOnly() {
    let live = TestAssetFactory.makeAsset(id: "live", hasAdjustments: false, isLivePhoto: true)
    let result = requiredVariants(
      for: live, selection: .editedWithOriginals, policy: .standard,
      livePhotosPaired: true)
    #expect(result == [.original, .originalPairedVideo])
  }

  // MARK: - Non-Live-Photo regression guard

  /// A plain (non-Live-Photo) image must not gain a paired-video variant, even when
  /// the toggle is on and `editedWithOriginals` is selected. Without this guard,
  /// a regression in the variant-expansion logic would silently start emitting `.MOV`
  /// jobs for every photo in the library.
  @Test func nonLivePhotoImageNeverEmitsPairedVideo() {
    let still = TestAssetFactory.makeAsset(id: "still", hasAdjustments: true, isLivePhoto: false)
    let result = requiredVariants(
      for: still, selection: .editedWithOriginals, policy: .standard,
      livePhotosPaired: true)
    #expect(result == [.original, .edited])
  }

  // MARK: - Single-resource policy wins over Live Photo

  /// Shared-album placements use `.singleResource`, which clamps to `[.original]`
  /// regardless of any other property — including the Live Photo paired toggle.
  /// Apple doesn't expose a paired video for shared assets, so emitting
  /// `.originalPairedVideo` here would queue a job for a resource that PhotoKit
  /// cannot satisfy.
  @Test func sharedAlbumClampWinsOverLivePhotoEvenWhenToggleOn() {
    let live = TestAssetFactory.makeAsset(id: "live", hasAdjustments: true, isLivePhoto: true)
    let edited = requiredVariants(
      for: live, selection: .edited, policy: .singleResource, livePhotosPaired: true)
    let withOrig = requiredVariants(
      for: live, selection: .editedWithOriginals, policy: .singleResource,
      livePhotosPaired: true)
    #expect(edited == [.original])
    #expect(withOrig == [.original])
  }

  // MARK: - Variant introspection helpers

  /// `isPairedVideo` partitions the variant set into image-side vs motion-side.
  /// Used by destination resolution and filename policy to pick the right rule.
  @Test func variantIntrospectionReportsPairedVideoCorrectly() {
    #expect(ExportVariant.originalPairedVideo.isPairedVideo)
    #expect(ExportVariant.editedPairedVideo.isPairedVideo)
    #expect(!ExportVariant.original.isPairedVideo)
    #expect(!ExportVariant.edited.isPairedVideo)
  }

}
