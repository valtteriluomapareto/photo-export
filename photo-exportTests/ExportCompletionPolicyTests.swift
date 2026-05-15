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
}
