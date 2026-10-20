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

  /// Where a variant may land, before its bytes exist. The final name is chosen against the
  /// staged bytes at commit time.
  struct Slot: Equatable, Sendable {
    enum CollisionPolicy: Equatable, Sendable {
      /// One fixed name: a paired original-side slot. An existing file there is a collision.
      case refuse(stem: String)
      /// The natural name, then ` (1)`, ` (2)`… An existing file may be adopted.
      case suffix(base: String, ext: String)
    }

    let directory: URL
    let filename: String
    let policy: CollisionPolicy

    var naturalURL: URL { directory.appendingPathComponent(filename) }

    /// Candidate `index` of the walk, where 0 is the natural name. A `.refuse` slot has only
    /// that one candidate.
    func candidate(_ index: Int) -> URL? {
      switch policy {
      case .refuse:
        return index == 0 ? naturalURL : nil
      case .suffix(let base, let ext):
        guard index <= ExportDestinationResolver.maxSuffixIndex else { return nil }
        let name = index == 0 ? base : "\(base) (\(index))"
        return directory.appendingPathComponent(name).appendingPathExtension(ext)
      }
    }

    /// The group stem a file committed under `filename` gives the variants after it.
    func chosenStem(forFilename filename: String) -> String {
      switch policy {
      case .refuse(let stem): return stem
      case .suffix: return (filename as NSString).deletingPathExtension
      }
    }
  }

  /// The highest suffix a walk tries, as in `uniqueFileURL`.
  static let maxSuffixIndex = 10_000

  /// The first free URL of `resolveSlot`'s slot, with the stem it gives later variants. A
  /// test convenience that sees no claims: exports choose the final name with
  /// `FinalNamePlanner` once the bytes are staged.
  func resolveDestination(
    variant: ExportVariant,
    descriptor: AssetDescriptor,
    originalFilename: String,
    resources: [ResourceDescriptor],
    destDir: URL,
    groupStem: String?,
    pairOriginalWithSuffix: Bool,
    interruptedFilename: String? = nil
  ) throws -> (URL, String) {
    let slot = try resolveSlot(
      variant: variant, descriptor: descriptor, originalFilename: originalFilename,
      resources: resources, destDir: destDir, groupStem: groupStem,
      pairOriginalWithSuffix: pairOriginalWithSuffix, interruptedFilename: interruptedFilename)
    let url = firstFreeURL(in: slot, isClaimed: { _ in false })
    return (url, slot.chosenStem(forFilename: url.lastPathComponent))
  }

  /// Decides the slot (natural name plus collision policy) for the variant being written.
  ///
  /// `groupStem` is the pre-allocated stem when both `.original` and `.edited` are being
  /// written together for this asset. When `nil`, only one variant is being written and
  /// the file lands at the natural stem, suffixed on collision.
  ///
  /// `pairOriginalWithSuffix` is `true` when this asset's `.original` is paired with an
  /// `.edited` variant (current run or prior record) and so must be written at
  /// `<stem>_orig.<ext>` instead of `<stem>.<ext>`.
  ///
  /// `interruptedFilename` authorizes only the exact paired candidate already verified
  /// by the exporter against interrupted history and regular-file metadata.
  ///
  /// Throws on the paired-original collision case (target already occupied by a prior
  /// `.original.done` write) so the caller marks the variant `.failed` rather than
  /// silently splitting the pair across stems. The error domain/code/message string is
  /// preserved verbatim from the pre-Phase-2 implementation — see the
  /// `ExportDestinationEscapeProtectionTests` and the paired-pair-collision tests.
  func resolveSlot(
    variant: ExportVariant,
    descriptor: AssetDescriptor,
    originalFilename: String,
    resources: [ResourceDescriptor],
    destDir: URL,
    groupStem: String?,
    pairOriginalWithSuffix: Bool,
    interruptedFilename: String? = nil
  ) throws -> Slot {
    switch variant {
    case .original, .originalPairedVideo:
      // The original-side filename rule is extension-agnostic: the image variant uses the
      // resource's image extension (HEIC/JPG/…), the paired-video variant uses `.mov` — both
      // pass through the same `<stem>[_orig].<ext>` shape. The collision-throw sentinel
      // (code 5) is preserved verbatim for both because either filename being already on
      // disk indicates a split-pair hazard the caller must surface.
      let origExt = (originalFilename as NSString).pathExtension
      if let stem = groupStem {
        let filename = ExportFilenamePolicy.originalFilename(
          stem: stem, ext: origExt, withSuffix: pairOriginalWithSuffix)
        let candidate = destDir.appendingPathComponent(filename)
        if fileSystem.fileExists(atPath: candidate.path), filename != interruptedFilename {
          throw NSError(
            domain: "Export", code: 5,
            userInfo: [
              NSLocalizedDescriptionKey:
                "Paired original filename already exists on disk: \(candidate.lastPathComponent)"
            ])
        }
        return Slot(directory: destDir, filename: filename, policy: .refuse(stem: stem))
      }
      // Fresh single-variant `.original`: no pairing, suffixed on collision.
      let (origStem, _) = Self.splitFilename(originalFilename)
      return Self.suffixSlot(in: destDir, base: origStem, ext: origExt)

    case .edited, .editedPairedVideo:
      // Same extension-agnostic story as `.original`: image side gets the rendered image
      // extension, paired-video side gets `.mov`. Both land at `<groupStem>.<ext>` and
      // share the post-edit collision-suffix rule.
      let editedExt = (originalFilename as NSString).pathExtension
      if let stem = groupStem {
        let filename = ExportFilenamePolicy.editedFilename(
          stem: stem, editedResourceFilename: originalFilename)
        let (base, ext) = Self.splitFilename(filename)
        // If the inherited natural stem is already taken (post-edit case where the prior
        // `.original.done` occupies it), the suffix walk splits the pair onto a `(N)`
        // suffix. This is the documented one-time cost on first re-export after each new
        // edit.
        return Self.suffixSlot(in: destDir, base: base, ext: ext)
      }
      // Fresh single-variant `.edited` (default mode adjusted asset, no prior records).
      // Use the original-side resource's stem so the edited file lands at e.g.
      // `IMG_0001.JPG` (matching what Photos.app does for a single-asset export). The
      // paired-video case falls through to this branch only if the caller forgot to
      // pre-allocate a group stem; we still land at a sane filename rather than trapping.
      let baseStem: String
      if let original = ResourceSelection.selectOriginalResource(
        from: resources, mediaType: descriptor.mediaType)
      {
        baseStem = Self.splitFilename(original.originalFilename).base
      } else {
        baseStem = Self.splitFilename(originalFilename).base
      }
      return Self.suffixSlot(in: destDir, base: baseStem, ext: editedExt)
    }
  }

  private static func suffixSlot(in directory: URL, base: String, ext: String) -> Slot {
    let natural = directory.appendingPathComponent(base).appendingPathExtension(ext)
    return Slot(
      directory: directory, filename: natural.lastPathComponent,
      policy: .suffix(base: base, ext: ext))
  }

  /// The first candidate of `slot` with nothing at it, following symbolic links as
  /// `fileExists` does, whose name `isClaimed` says no other record names. A `.refuse`
  /// slot's only candidate is returned as is.
  func firstFreeURL(in slot: Slot, isClaimed: (String) -> Bool) -> URL {
    guard case .suffix(let base, let ext) = slot.policy else { return slot.naturalURL }
    return uniqueFileURL(in: slot.directory, baseName: base, ext: ext, isClaimed: isClaimed)
  }

  // MARK: - Stem allocation

  /// Allocates a stem where every slot the active variant set will write is
  /// simultaneously free: nothing on disk, and a name `isClaimed` says no other asset's
  /// record names. Bumps the per-pair collision suffix until all slots are available so the
  /// pair (or paired group) never splits across stems.
  ///
  /// `pairOriginalWithSuffix` mirrors the call-site flag of the same name on
  /// `resolveDestination` and selects between the two layouts:
  /// - `true` (edited asset, both image sides written): `<stem>.<editedExt>` (rendered
  ///   edit) + `<stem>_orig.<imageExt>` (original companion). `editedExt` must be
  ///   non-nil. When `pairedVideoExt` is also non-nil (Live Photo), `<stem>.<pairedVideoExt>`
  ///   + `<stem>_orig.<pairedVideoExt>` are added to the freeness check. Here `imageExt`
  ///   names the extension of the file landing at the `_orig` slot (the original
  ///   companion).
  /// - `false` (single image side written): `<stem>.<imageExt>` only on the image side
  ///   (no `_orig` companion when there is no edit, and no natural-stem edited when
  ///   there is no original), plus `<stem>.<pairedVideoExt>` for the motion file.
  ///   `editedExt` is ignored. The caller passes `imageExt` as whichever image side is
  ///   actually being written — the original for an unedited Live Photo (`.original` +
  ///   `.originalPairedVideo`), or the edited for an adjusted Live Photo under
  ///   `selection = .edited` (`.edited` + `.editedPairedVideo`). Both cases exist for
  ///   the same reason: two assets that share a base stem but use different image
  ///   extensions (e.g. HEIC vs JPEG) coexist on the image side but collide on the
  ///   shared `.MOV` paired-video stem; the resolver must detect that upfront rather
  ///   than letting the second paired-video write throw at write-time.
  func allocatePairedGroupStem(
    baseStem: String,
    imageExt: String,
    editedExt: String?,
    destDir: URL,
    pairOriginalWithSuffix: Bool,
    pairedVideoExt: String? = nil,
    isClaimed: (String) -> Bool
  ) -> String {
    func isFree(_ url: URL) -> Bool {
      !fileSystem.fileExists(atPath: url.path) && !isClaimed(url.lastPathComponent)
    }
    var stem = baseStem
    var index = 1
    while index < 10_000 {
      var allFree: Bool
      if pairOriginalWithSuffix {
        // Edited-asset layout: natural-stem edited + `_orig` companion.
        guard let editedExt else {
          // Programmer error — `editedExt` is required when the edited slot is in
          // play. Falling back to the unedited layout would silently corrupt
          // collision detection for edited assets, so return the current stem
          // and let the caller's write-time collision throw surface the bug.
          return stem
        }
        let editedTarget = destDir.appendingPathComponent(stem)
          .appendingPathExtension(editedExt)
        let origTarget = destDir.appendingPathComponent(
          stem + ExportFilenamePolicy.originalSuffix
        ).appendingPathExtension(imageExt)
        allFree = isFree(editedTarget) && isFree(origTarget)
        if allFree, let movExt = pairedVideoExt {
          let editedMov = destDir.appendingPathComponent(stem).appendingPathExtension(movExt)
          let origMov = destDir.appendingPathComponent(
            stem + ExportFilenamePolicy.originalSuffix
          ).appendingPathExtension(movExt)
          allFree = isFree(editedMov) && isFree(origMov)
        }
      } else {
        // Single-image-side layout: only the natural-stem image + the natural-stem
        // motion file are written. `editedExt` is intentionally ignored — the caller
        // passed the relevant side as `imageExt`.
        let imageTarget = destDir.appendingPathComponent(stem)
          .appendingPathExtension(imageExt)
        allFree = isFree(imageTarget)
        if allFree, let movExt = pairedVideoExt {
          let mov = destDir.appendingPathComponent(stem).appendingPathExtension(movExt)
          allFree = isFree(mov)
        }
      }
      if allFree { return stem }
      stem = "\(baseStem) (\(index))"
      index += 1
    }
    return stem
  }

  /// Finds the smallest `(N)`-suffixed `baseStem` whose `_orig` companion slot is free: nothing
  /// on disk, and a name `isClaimed` says no other asset's record names. The edited-fallback
  /// only writes the original; the natural-stem edited slot is intentionally not checked
  /// because we don't know the edited extension here, and a future run that succeeds at the
  /// edit will allocate its own stem.
  func allocateUnusedOrigStem(
    baseStem: String, originalExt: String, destDir: URL, isClaimed: (String) -> Bool
  ) -> String {
    var stem = baseStem
    var index = 1
    while index < 10_000 {
      let target = destDir.appendingPathComponent(
        stem + ExportFilenamePolicy.originalSuffix
      ).appendingPathExtension(originalExt)
      if !fileSystem.fileExists(atPath: target.path), !isClaimed(target.lastPathComponent) {
        return stem
      }
      stem = "\(baseStem) (\(index))"
      index += 1
    }
    return stem
  }

  // MARK: - Unique-filename collision suffixing

  /// Returns a URL whose final path component does not already exist in `directory` and
  /// is not claimed. Appends ` (1)`, ` (2)`, etc. until a free slot is found, capped at
  /// 10 000 attempts.
  ///
  /// Production callers go through `firstFreeURL` — kept `internal` only as a unit test
  /// seam for `ExportDestinationResolverTests` (no-conflict, sequential conflicts, cap
  /// respected). Don't widen this surface; new production paths should compose via
  /// `firstFreeURL` instead.
  func uniqueFileURL(
    in directory: URL, baseName: String, ext: String, isClaimed: (String) -> Bool
  ) -> URL {
    var candidate = directory.appendingPathComponent(baseName).appendingPathExtension(ext)
    var index = 1
    while fileSystem.fileExists(atPath: candidate.path) || isClaimed(candidate.lastPathComponent) {
      let nextName = "\(baseName) (\(index))"
      candidate = directory.appendingPathComponent(nextName).appendingPathExtension(ext)
      index += 1
      if index > Self.maxSuffixIndex { break }
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
