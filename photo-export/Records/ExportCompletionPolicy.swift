import Foundation

/// Pure rules for "is this asset complete?" and "should the edited-fallback recovery run?"
///
/// Centralizes decisions that were historically duplicated as private static helpers in
/// `ExportRecordStore` and `CollectionExportRecordStore` (the literal "Collection-store
/// mirror" labelled there) plus the `shouldRunEditedFallback` run-time decision that lived
/// on `ExportManager`. Per
/// `docs/project/archive/software-architecture-improvement-plan.md` Phase 1, this policy is
/// the single source: both record stores delegate; `ExportManager` calls it. The policy
/// holds no state and depends on no store; callers extract the variant dictionary first
/// and pass it in.
///
/// `requiredVariants(for:selection:policy:)` already lives as a free function in
/// `ExportVariant.swift` and is not duplicated, so it is not re-exposed here.
enum ExportCompletionPolicy {

  /// True when every required variant for `asset` under `(selection, policy)` is `.done`,
  /// OR the asset is covered by the edited-fallback case (see `satisfiesEditedFallback`).
  ///
  /// Consolidates `ExportRecordStore.isExported(asset:selection:)` and
  /// `CollectionExportRecordStore.isExported(asset:placement:selection:)`. The stores keep
  /// their public methods as thin wrappers that extract the variant dictionary.
  ///
  /// `convertHEICToJPEG` (issue #47) is forwarded to `requiredVariants` so a HEIC-original
  /// asset under the toggle reads as "requires `.edited`" — completion checks against the
  /// synthesized JPEG record rather than the untouched HEIC `.original`. Default `false`
  /// preserves call-site behavior for tests and pre-toggle wrappers.
  static func isComplete(
    variants: [ExportVariant: ExportVariantRecord],
    asset: AssetDescriptor,
    selection: ExportVersionSelection,
    policy: VariantPolicy,
    convertHEICToJPEG: Bool = false,
    livePhotosPaired: Bool = false
  ) -> Bool {
    let required = requiredVariants(
      for: asset, selection: selection, policy: policy,
      convertHEICToJPEG: convertHEICToJPEG,
      livePhotosPaired: livePhotosPaired)
    if required.allSatisfy({ variants[$0]?.status == .done }) { return true }
    return satisfiesEditedFallback(variants: variants, asset: asset, selection: selection)
  }

  /// True when an adjusted asset asked to export `.edited` is covered by the `_orig`
  /// recovery slot: `.original` is `.done` AND `.edited` is `.failed` with the explicit
  /// `editedUnavailableOriginalBackedUpMessage` sentinel (which `runEditedFallbackOriginal`
  /// writes only after a successful `<stem>_orig` write).
  ///
  /// Distinct from `shouldRunEditedFallback`:
  /// - `satisfiesEditedFallback` is the *success* state — the `_orig` write already
  ///   happened, so the asset counts as exported.
  /// - `shouldRunEditedFallback` is the *trigger* state — the edited write just failed
  ///   with the upstream `editedResourceUnavailableMessage`, so the recovery should run.
  ///
  /// We deliberately do not key on the `.original` filename's shape. The `_orig` ending is
  /// ambiguous — real user filenames like `vacation_orig.JPG` exist — so the explicit
  /// sentinel is the only authoritative signal that the fallback ran. See
  /// `ExportFilenamePolicy.isOrigCompanion`.
  static func satisfiesEditedFallback(
    variants: [ExportVariant: ExportVariantRecord],
    asset: AssetDescriptor,
    selection: ExportVersionSelection
  ) -> Bool {
    guard asset.hasAdjustments, selection == .edited else { return false }
    guard
      variants[.original]?.status == .done,
      let editedRecord = variants[.edited],
      editedRecord.status == .failed,
      editedRecord.lastError
        == ExportVariantRecovery.editedUnavailableOriginalBackedUpMessage
    else { return false }
    return true
  }

  /// True when the pipeline should run the `_orig` recovery write for this asset: the
  /// user asked for `.edited` only, and a prior `.edited` write failed with the
  /// `editedResourceUnavailableMessage` sentinel (which the variant write path emits when
  /// Photos refuses the edited resource).
  ///
  /// Was `private func shouldRunEditedFallback(...)` on `ExportManager` before Phase 1.
  /// The original signature took `descriptor` + `job` and looked up `variants` internally;
  /// the policy form is one level lower and pure — the caller supplies the variants and
  /// the required set.
  static func shouldRunEditedFallback(
    variants: [ExportVariant: ExportVariantRecord],
    required: Set<ExportVariant>
  ) -> Bool {
    guard required == [.edited] else { return false }
    guard let editedRecord = variants[.edited],
      editedRecord.status == .failed,
      editedRecord.lastError == ExportVariantRecovery.editedResourceUnavailableMessage
    else { return false }
    return true
  }
}
