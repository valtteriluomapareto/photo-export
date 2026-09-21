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
    let allSatisfied = required.allSatisfy { variant in
      // `.done` always counts. Paired-video variants additionally count when
      // they're `.failed` with the `pairedVideoUnavailableMessage` sentinel — a
      // known iCloud data-availability state where the still side is on disk
      // and Photos genuinely cannot deliver the motion file. Mirrors the
      // `editedFallbackCovered` pattern for the `_orig`-rescue case.
      if variants[variant]?.status == .done { return true }
      if variant.isPairedVideo,
        variants[variant]?.status == .failed,
        variants[variant]?.lastError == ExportVariantRecovery.pairedVideoUnavailableMessage
      {
        return true
      }
      return false
    }
    if allSatisfied { return true }
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

  // MARK: - Replace-updated-files staleness rule

  /// True when the asset's content in Photos changed *after* at least one of its
  /// recorded `.done` exports was written — i.e. at least one file in the destination
  /// is stale and the next run should re-export (replace) it.
  ///
  /// Decision inputs:
  /// - `asset.modificationDate` — PhotoKit's last-content-change timestamp. `nil`
  ///   means "unknown", which is treated as *never stale* so descriptors that don't
  ///   model the field (tests, fakes) keep the never-replace behavior.
  /// - Each `.done` variant's `exportDate` — when the pipeline wrote the file. A
  ///   `.done` variant with a `nil` `exportDate` (legacy records) counts as stale:
  ///   its write time is unknowable, so conservatism says re-export.
  ///
  /// Asset-level granularity is deliberate: `modificationDate` can't be attributed
  /// to a single variant, so a changed asset re-exports its full required variant
  /// set rather than guessing which side changed.
  ///
  /// Only consulted when the user turns on the "Replace updated files" cleanup
  /// option; with the option off this helper is never called and completion checks
  /// keep today's "every required variant `.done`" semantics.
  static func isUpdatedAfterExport(
    asset: AssetDescriptor,
    variants: [ExportVariant: ExportVariantRecord]
  ) -> Bool {
    guard let modified = asset.modificationDate else { return false }
    let doneExportDates = variants.values
      .filter { $0.status == .done }
      .map { $0.exportDate }
    guard !doneExportDates.isEmpty else { return false }
    // Any `.done` variant without a recorded export date (or one written before the
    // last modification) makes the asset stale.
    return doneExportDates.contains { date in
      guard let date else { return true }
      return date < modified
    }
  }
}
