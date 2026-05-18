import Foundation

/// Pure-ish destination/filename allocator for the export pipeline. Owns every decision
/// about *where on disk* a variant lands: stem allocation when both `.original` and
/// `.edited` are written together, `_orig` companion naming, recovered group stems from
/// prior records, unique-filename collision suffixing, and the natural-vs-`_orig`
/// disambiguation that defends against user filenames that happen to end with `_orig`.
///
/// Per `docs/project/archive/software-architecture-improvement-plan.md` Phase 2, the
/// resolver replaces the inline private methods that lived on `ExportManager`
/// (`resolveDestination`, `allocatePairedGroupStem`, `allocateUnusedOrigStem`,
/// `inheritedGroupStem`, `splitFilename`, `uniqueFileURL`). The low-level naming-rule
/// helper `ExportFilenamePolicy` is unchanged and remains the source of truth for the
/// `_orig` suffix string and the legacy filename-parsing rules.
///
/// `Sendable` because all stored state is `Sendable` (`fileSystem` is the
/// `Sendable`-bound `FileSystemService` protocol). The resolver carries no other state,
/// so it is safe to call from any isolation domain — though in practice every call site
/// is `@MainActor`.
struct ExportDestinationResolver: Sendable {

  private let fileSystem: any FileSystemService

  init(fileSystem: any FileSystemService) {
    self.fileSystem = fileSystem
  }

  // MARK: - Top-level resolution

  /// Decides the final destination URL and `chosenStem` for the variant being written.
  ///
  /// `groupStem` is the pre-allocated stem when both `.original` and `.edited` are being
  /// written together for this asset. When `nil`, only one variant is being written and
  /// the file lands at the natural stem with `uniqueFileURL` collision handling.
  ///
  /// `pairOriginalWithSuffix` is `true` when this asset's `.original` is paired with an
  /// `.edited` variant (current run or prior record) and so must be written at
  /// `<stem>_orig.<ext>` instead of `<stem>.<ext>`.
  ///
  /// Throws on the paired-original collision case (target already occupied by a prior
  /// `.original.done` write) so the caller marks the variant `.failed` rather than
  /// silently splitting the pair across stems. The error domain/code/message string is
  /// preserved verbatim from the pre-Phase-2 implementation — see the
  /// `ExportDestinationEscapeProtectionTests` and the paired-pair-collision tests.
  func resolveDestination(
    variant: ExportVariant,
    descriptor: AssetDescriptor,
    originalFilename: String,
    resources: [ResourceDescriptor],
    destDir: URL,
    groupStem: String?,
    pairOriginalWithSuffix: Bool
  ) throws -> (URL, String) {
    switch variant {
    case .original:
      let origExt = (originalFilename as NSString).pathExtension
      if let stem = groupStem {
        let filename = ExportFilenamePolicy.originalFilename(
          stem: stem, ext: origExt, withSuffix: pairOriginalWithSuffix)
        let candidate = destDir.appendingPathComponent(filename)
        if fileSystem.fileExists(atPath: candidate.path) {
          throw NSError(
            domain: "Export", code: 5,
            userInfo: [
              NSLocalizedDescriptionKey:
                "Paired original filename already exists on disk: \(candidate.lastPathComponent)"
            ])
        }
        return (candidate, stem)
      }
      // Fresh single-variant `.original`: no pairing, use uniqueFileURL collision handling.
      let (origStem, _) = Self.splitFilename(originalFilename)
      let finalURL = uniqueFileURL(in: destDir, baseName: origStem, ext: origExt)
      return (finalURL, finalURL.deletingPathExtension().lastPathComponent)

    case .edited:
      let editedExt = (originalFilename as NSString).pathExtension
      if let stem = groupStem {
        let filename = ExportFilenamePolicy.editedFilename(
          stem: stem, editedResourceFilename: originalFilename)
        let (base, ext) = Self.splitFilename(filename)
        // If the inherited natural stem is already taken (post-edit case where the prior
        // `.original.done` occupies it), uniqueFileURL splits the pair onto a `(N)`
        // suffix. This is the documented one-time cost on first re-export after each new
        // edit.
        let finalURL = uniqueFileURL(in: destDir, baseName: base, ext: ext)
        return (finalURL, finalURL.deletingPathExtension().lastPathComponent)
      }
      // Fresh single-variant `.edited` (default mode adjusted asset, no prior records).
      // Use the original-side resource's stem so the edited file lands at e.g.
      // `IMG_0001.JPG` (matching what Photos.app does for a single-asset export).
      let baseStem: String
      if let original = ResourceSelection.selectOriginalResource(
        from: resources, mediaType: descriptor.mediaType)
      {
        baseStem = Self.splitFilename(original.originalFilename).base
      } else {
        baseStem = Self.splitFilename(originalFilename).base
      }
      let finalURL = uniqueFileURL(in: destDir, baseName: baseStem, ext: editedExt)
      return (finalURL, finalURL.deletingPathExtension().lastPathComponent)
    }
  }

  // MARK: - Stem allocation

  /// Allocates a stem where both the natural-stem edited target (`<stem>.<editedExt>`)
  /// and the `_orig` companion target (`<stem>_orig.<originalExt>`) are simultaneously
  /// free. Bumps the per-pair collision suffix until both slots are available so the
  /// pair never splits across stems.
  func allocatePairedGroupStem(
    baseStem: String, editedExt: String, originalExt: String, destDir: URL
  ) -> String {
    var stem = baseStem
    var index = 1
    while index < 10_000 {
      let editedTarget = destDir.appendingPathComponent(stem)
        .appendingPathExtension(editedExt)
      let origTarget = destDir.appendingPathComponent(
        stem + ExportFilenamePolicy.originalSuffix
      ).appendingPathExtension(originalExt)
      if !fileSystem.fileExists(atPath: editedTarget.path)
        && !fileSystem.fileExists(atPath: origTarget.path)
      {
        return stem
      }
      stem = "\(baseStem) (\(index))"
      index += 1
    }
    return stem
  }

  /// Finds the smallest `(N)`-suffixed `baseStem` whose `_orig` companion slot is free.
  /// The edited-fallback only writes the original; the natural-stem edited slot is
  /// intentionally not checked because we don't know the edited extension here, and a
  /// future run that succeeds at the edit will allocate its own stem.
  func allocateUnusedOrigStem(
    baseStem: String, originalExt: String, destDir: URL
  ) -> String {
    var stem = baseStem
    var index = 1
    while index < 10_000 {
      let target = destDir.appendingPathComponent(
        stem + ExportFilenamePolicy.originalSuffix
      ).appendingPathExtension(originalExt)
      if !fileSystem.fileExists(atPath: target.path) { return stem }
      stem = "\(baseStem) (\(index))"
      index += 1
    }
    return stem
  }

  // MARK: - Unique-filename collision suffixing

  /// Returns a URL whose final path component does not already exist in `directory`.
  /// Appends ` (1)`, ` (2)`, etc. until a free slot is found, capped at 10 000 attempts.
  ///
  /// Production callers go through `resolveDestination` — kept `internal` only as a unit
  /// test seam for `ExportDestinationResolverTests` (no-conflict, sequential conflicts,
  /// cap respected). Don't widen this surface; new production paths should compose via
  /// `resolveDestination` instead.
  func uniqueFileURL(in directory: URL, baseName: String, ext: String) -> URL {
    var candidate = directory.appendingPathComponent(baseName).appendingPathExtension(ext)
    var index = 1
    while fileSystem.fileExists(atPath: candidate.path) {
      let nextName = "\(baseName) (\(index))"
      candidate = directory.appendingPathComponent(nextName).appendingPathExtension(ext)
      index += 1
      if index > 10_000 { break }
    }
    return candidate
  }

  // MARK: - Pure helpers

  /// Splits a filename into its `(base, ext)` parts via `URL` path operations. Pure.
  static func splitFilename(_ filename: String) -> (base: String, ext: String) {
    let url = URL(fileURLWithPath: filename)
    let base = url.deletingPathExtension().lastPathComponent
    let ext = url.pathExtension
    return (base, ext)
  }

  /// Recovers the group stem from a prior `.done` variant record so a follow-up run
  /// that adds the missing variant pairs against the same stem.
  ///
  /// `_orig` is both an app companion marker and a string a user can put in an actual
  /// original filename (e.g. `vacation_orig.JPG`). When the recorded `.original`
  /// filename exactly equals the asset's current original-side resource filename, treat
  /// it as the user's natural filename — even when its stem ends with `_orig` — so the
  /// asset stays pinned to the `vacation_orig` stem and a later edited write becomes
  /// `vacation_orig (1).<ext>` rather than `vacation.<ext>`.
  static func inheritedGroupStem(
    from record: ExportRecord?,
    descriptor: AssetDescriptor,
    resources: [ResourceDescriptor]
  ) -> String? {
    guard let record else { return nil }
    if let edited = record.variants[.edited], edited.status == .done,
      let filename = edited.filename
    {
      return splitFilename(filename).base
    }
    if let original = record.variants[.original], original.status == .done,
      let filename = original.filename
    {
      let originalResourceFilename = ResourceSelection.selectOriginalResource(
        from: resources, mediaType: descriptor.mediaType)?.originalFilename
      if let originalResourceFilename, filename == originalResourceFilename {
        return splitFilename(filename).base
      }
      if let parsed = ExportFilenamePolicy.parseOriginalCandidate(filename: filename) {
        return parsed.groupStem
      }
      return splitFilename(filename).base
    }
    return nil
  }
}
