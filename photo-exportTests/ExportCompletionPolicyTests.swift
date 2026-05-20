import Foundation
import Testing

@testable import Photo_Export

/// Phase 1 unit tests for `ExportCompletionPolicy`. The policy consolidates rules that
/// were previously duplicated as private static helpers in `ExportRecordStore` and
/// `CollectionExportRecordStore` (`satisfiesEditedFallback`) plus the
/// `shouldRunEditedFallback` run-time decision on `ExportManager`. These tests pin each
/// rule directly so the store-level integration tests (`ExportRecordStoreTests`,
/// `CollectionExportRecordStoreTests`, etc.) can keep covering the wiring without also
/// re-asserting the rule mechanics.
struct ExportCompletionPolicyTests {

  // MARK: - Fixture helpers

  private static let editedFailedRecoveryMessage =
    ExportVariantRecovery.editedResourceUnavailableMessage
  private static let editedFallbackSucceededMessage =
    ExportVariantRecovery.editedUnavailableOriginalBackedUpMessage

  private func doneVariant(filename: String = "IMG.JPG") -> ExportVariantRecord {
    ExportVariantRecord(filename: filename, status: .done, exportDate: Date(), lastError: nil)
  }

  private func failedVariant(message: String) -> ExportVariantRecord {
    ExportVariantRecord(filename: nil, status: .failed, exportDate: nil, lastError: message)
  }

  private func inProgressVariant() -> ExportVariantRecord {
    ExportVariantRecord(filename: nil, status: .inProgress, exportDate: nil, lastError: nil)
  }

  // MARK: - isComplete

  @Test func isComplete_unedited_assetWithOriginalDone_returnsTrue() {
    let asset = TestAssetFactory.makeAsset(hasAdjustments: false)
    let variants: [ExportVariant: ExportVariantRecord] = [.original: doneVariant()]
    #expect(
      ExportCompletionPolicy.isComplete(
        variants: variants, asset: asset, selection: .edited, policy: .standard))
  }

  @Test func isComplete_unedited_assetWithMissingOriginal_returnsFalse() {
    let asset = TestAssetFactory.makeAsset(hasAdjustments: false)
    let variants: [ExportVariant: ExportVariantRecord] = [:]
    #expect(
      !ExportCompletionPolicy.isComplete(
        variants: variants, asset: asset, selection: .edited, policy: .standard))
  }

  @Test func isComplete_edited_assetWithEditedDone_returnsTrue() {
    let asset = TestAssetFactory.makeAsset(hasAdjustments: true)
    let variants: [ExportVariant: ExportVariantRecord] = [.edited: doneVariant()]
    #expect(
      ExportCompletionPolicy.isComplete(
        variants: variants, asset: asset, selection: .edited, policy: .standard))
  }

  @Test func isComplete_editedWithOriginals_requiresBothVariantsDone() {
    let asset = TestAssetFactory.makeAsset(hasAdjustments: true)
    let onlyEdited: [ExportVariant: ExportVariantRecord] = [.edited: doneVariant()]
    #expect(
      !ExportCompletionPolicy.isComplete(
        variants: onlyEdited, asset: asset, selection: .editedWithOriginals, policy: .standard))
    let both: [ExportVariant: ExportVariantRecord] = [
      .edited: doneVariant(), .original: doneVariant(),
    ]
    #expect(
      ExportCompletionPolicy.isComplete(
        variants: both, asset: asset, selection: .editedWithOriginals, policy: .standard))
  }

  @Test func isComplete_singleResource_unaffectedByEditedSelection() {
    // shared-album placements always require only `.original`, regardless of selection.
    let asset = TestAssetFactory.makeAsset(hasAdjustments: true)
    let variants: [ExportVariant: ExportVariantRecord] = [.original: doneVariant()]
    #expect(
      ExportCompletionPolicy.isComplete(
        variants: variants, asset: asset, selection: .editedWithOriginals,
        policy: .singleResource))
  }

  @Test func isComplete_editedFallbackCovered_returnsTrue() {
    // Adjusted asset, `.edited` selection, the `_orig` recovery sentinel is set: counted.
    let asset = TestAssetFactory.makeAsset(hasAdjustments: true)
    let variants: [ExportVariant: ExportVariantRecord] = [
      .original: doneVariant(filename: "vacation_orig.JPG"),
      .edited: failedVariant(message: Self.editedFallbackSucceededMessage),
    ]
    #expect(
      ExportCompletionPolicy.isComplete(
        variants: variants, asset: asset, selection: .edited, policy: .standard))
  }

  // MARK: - satisfiesEditedFallback

  @Test func satisfiesEditedFallback_happyPath_returnsTrue() {
    let asset = TestAssetFactory.makeAsset(hasAdjustments: true)
    let variants: [ExportVariant: ExportVariantRecord] = [
      .original: doneVariant(),
      .edited: failedVariant(message: Self.editedFallbackSucceededMessage),
    ]
    #expect(
      ExportCompletionPolicy.satisfiesEditedFallback(
        variants: variants, asset: asset, selection: .edited))
  }

  @Test func satisfiesEditedFallback_unadjustedAsset_returnsFalse() {
    let asset = TestAssetFactory.makeAsset(hasAdjustments: false)
    let variants: [ExportVariant: ExportVariantRecord] = [
      .original: doneVariant(),
      .edited: failedVariant(message: Self.editedFallbackSucceededMessage),
    ]
    #expect(
      !ExportCompletionPolicy.satisfiesEditedFallback(
        variants: variants, asset: asset, selection: .edited))
  }

  @Test func satisfiesEditedFallback_editedWithOriginalsSelection_returnsFalse() {
    // The recovery is gated to `.edited` selection only.
    let asset = TestAssetFactory.makeAsset(hasAdjustments: true)
    let variants: [ExportVariant: ExportVariantRecord] = [
      .original: doneVariant(),
      .edited: failedVariant(message: Self.editedFallbackSucceededMessage),
    ]
    #expect(
      !ExportCompletionPolicy.satisfiesEditedFallback(
        variants: variants, asset: asset, selection: .editedWithOriginals))
  }

  @Test func satisfiesEditedFallback_originalNotDone_returnsFalse() {
    let asset = TestAssetFactory.makeAsset(hasAdjustments: true)
    let variants: [ExportVariant: ExportVariantRecord] = [
      .original: failedVariant(message: "disk full"),
      .edited: failedVariant(message: Self.editedFallbackSucceededMessage),
    ]
    #expect(
      !ExportCompletionPolicy.satisfiesEditedFallback(
        variants: variants, asset: asset, selection: .edited))
  }

  @Test func satisfiesEditedFallback_editedNotFailed_returnsFalse() {
    let asset = TestAssetFactory.makeAsset(hasAdjustments: true)
    let variants: [ExportVariant: ExportVariantRecord] = [
      .original: doneVariant(),
      .edited: inProgressVariant(),
    ]
    #expect(
      !ExportCompletionPolicy.satisfiesEditedFallback(
        variants: variants, asset: asset, selection: .edited))
  }

  @Test func satisfiesEditedFallback_wrongSentinel_returnsFalse() {
    // Generic failure (no sentinel) must not count — the recovery only triggers on the
    // explicit `editedUnavailableOriginalBackedUpMessage` written by the recovery path.
    let asset = TestAssetFactory.makeAsset(hasAdjustments: true)
    let variants: [ExportVariant: ExportVariantRecord] = [
      .original: doneVariant(),
      .edited: failedVariant(message: "Something else broke"),
    ]
    #expect(
      !ExportCompletionPolicy.satisfiesEditedFallback(
        variants: variants, asset: asset, selection: .edited))
  }

  @Test func satisfiesEditedFallback_triggerSentinel_returnsFalse() {
    // The *trigger* sentinel (`editedResourceUnavailableMessage`) is set BEFORE the
    // recovery runs and must not satisfy the fallback — only the *success* sentinel
    // (`editedUnavailableOriginalBackedUpMessage`) does. Mixing the two would mean
    // "edited failed; we tried to recover" gets counted as "recovery succeeded."
    let asset = TestAssetFactory.makeAsset(hasAdjustments: true)
    let variants: [ExportVariant: ExportVariantRecord] = [
      .original: doneVariant(),
      .edited: failedVariant(message: Self.editedFailedRecoveryMessage),
    ]
    #expect(
      !ExportCompletionPolicy.satisfiesEditedFallback(
        variants: variants, asset: asset, selection: .edited))
  }

  // MARK: - shouldRunEditedFallback

  @Test func shouldRunEditedFallback_happyPath_returnsTrue() {
    let variants: [ExportVariant: ExportVariantRecord] = [
      .edited: failedVariant(message: Self.editedFailedRecoveryMessage)
    ]
    #expect(
      ExportCompletionPolicy.shouldRunEditedFallback(
        variants: variants, required: [.edited]))
  }

  @Test func shouldRunEditedFallback_requiredMoreThanEdited_returnsFalse() {
    // Recovery is gated to the `.edited`-only case. When `.editedWithOriginals` requires
    // both variants, the user can already see the original — no recovery needed.
    let variants: [ExportVariant: ExportVariantRecord] = [
      .edited: failedVariant(message: Self.editedFailedRecoveryMessage)
    ]
    #expect(
      !ExportCompletionPolicy.shouldRunEditedFallback(
        variants: variants, required: [.edited, .original]))
  }

  @Test func shouldRunEditedFallback_noEditedRecord_returnsFalse() {
    let variants: [ExportVariant: ExportVariantRecord] = [:]
    #expect(
      !ExportCompletionPolicy.shouldRunEditedFallback(
        variants: variants, required: [.edited]))
  }

  @Test func shouldRunEditedFallback_editedNotFailed_returnsFalse() {
    let variants: [ExportVariant: ExportVariantRecord] = [.edited: inProgressVariant()]
    #expect(
      !ExportCompletionPolicy.shouldRunEditedFallback(
        variants: variants, required: [.edited]))
  }

  @Test func shouldRunEditedFallback_wrongSentinel_returnsFalse() {
    // Generic failures (disk full, asset missing) must not trigger the `_orig` recovery
    // — those are different problems that the recovery wouldn't fix.
    let variants: [ExportVariant: ExportVariantRecord] = [
      .edited: failedVariant(message: "disk full")
    ]
    #expect(
      !ExportCompletionPolicy.shouldRunEditedFallback(
        variants: variants, required: [.edited]))
  }

  @Test func shouldRunEditedFallback_successSentinel_returnsFalse() {
    // The *success* sentinel means recovery already ran. The trigger must be the
    // upstream failure sentinel — using the success one would re-run the recovery on
    // every future export.
    let variants: [ExportVariant: ExportVariantRecord] = [
      .edited: failedVariant(message: Self.editedFallbackSucceededMessage)
    ]
    #expect(
      !ExportCompletionPolicy.shouldRunEditedFallback(
        variants: variants, required: [.edited]))
  }

  // MARK: - Paired-video unavailable sentinel (iCloud edge case)

  /// A Live Photo whose `.original` landed but whose `.originalPairedVideo` is
  /// `.failed` with the `pairedVideoUnavailableMessage` sentinel counts as
  /// complete under `livePhotosPaired: true`. Mirrors the `editedFallbackCovered`
  /// pattern — Photos has no motion file to give, the still is on disk, the asset
  /// is as exported as it can be.
  @Test func isComplete_livePhotosPaired_pairedVideoUnavailableSentinel_isCovered() {
    let live = TestAssetFactory.makeAsset(id: "live", isLivePhoto: true)
    let variants: [ExportVariant: ExportVariantRecord] = [
      .original: doneVariant(filename: "IMG_0001.HEIC"),
      .originalPairedVideo: failedVariant(
        message: ExportVariantRecovery.pairedVideoUnavailableMessage),
    ]
    #expect(
      ExportCompletionPolicy.isComplete(
        variants: variants, asset: live, selection: .edited, policy: .standard,
        livePhotosPaired: true))
  }

  /// Regression guard for the sentinel-specificity claim above: a paired-video
  /// `.failed` with a GENERIC error message (e.g. "disk full", or the legacy
  /// "No exportable resource" before the sentinel rename) must NOT be treated
  /// as covered. Only the explicit `pairedVideoUnavailableMessage` qualifies.
  /// Without this assertion, a future "treat any paired-video failure as covered"
  /// regression would silently turn legitimate failures green.
  @Test func isComplete_livePhotosPaired_genericPairedVideoFailure_isNotCovered() {
    let live = TestAssetFactory.makeAsset(id: "live", isLivePhoto: true)
    let variants: [ExportVariant: ExportVariantRecord] = [
      .original: doneVariant(filename: "IMG_0001.HEIC"),
      .originalPairedVideo: failedVariant(message: "No exportable resource"),
    ]
    #expect(
      !ExportCompletionPolicy.isComplete(
        variants: variants, asset: live, selection: .edited, policy: .standard,
        livePhotosPaired: true))

    let diskFull: [ExportVariant: ExportVariantRecord] = [
      .original: doneVariant(filename: "IMG_0001.HEIC"),
      .originalPairedVideo: failedVariant(message: "disk full"),
    ]
    #expect(
      !ExportCompletionPolicy.isComplete(
        variants: diskFull, asset: live, selection: .edited, policy: .standard,
        livePhotosPaired: true))
  }

  /// `.editedPairedVideo` follows the same sentinel rule as `.originalPairedVideo`.
  /// An edited Live Photo whose still + edit are `.done` and whose
  /// `.editedPairedVideo` is `.failed` with the sentinel reads as complete
  /// under `editedWithOriginals` + `livePhotosPaired: true`.
  @Test func isComplete_editedLivePhoto_editedPairedVideoSentinel_isCovered() {
    let live = TestAssetFactory.makeAsset(id: "live", hasAdjustments: true, isLivePhoto: true)
    let variants: [ExportVariant: ExportVariantRecord] = [
      .original: doneVariant(filename: "IMG_0001_orig.HEIC"),
      .edited: doneVariant(filename: "IMG_0001.HEIC"),
      .originalPairedVideo: doneVariant(filename: "IMG_0001_orig.MOV"),
      .editedPairedVideo: failedVariant(
        message: ExportVariantRecovery.pairedVideoUnavailableMessage),
    ]
    #expect(
      ExportCompletionPolicy.isComplete(
        variants: variants, asset: live, selection: .editedWithOriginals, policy: .standard,
        livePhotosPaired: true))
  }
}
