import Foundation
import Photos
import Testing

@testable import Photo_Export

/// Backward-compat regression gate for **the on-disk shape of a multi-step
/// export lifecycle** — what a user's destination folder actually looks like
/// after the kind of sequences that play out over months of real use.
///
/// Each individual rule (split-filename, unique-suffix, paired-stem
/// allocation, group-stem inheritance, `_orig`-companion naming, sibling-
/// collision suffix) is pinned by `ExportDestinationResolverTests` and
/// `ExportPlacementResolverTests`. The gap those tests don't close is the
/// **composition**: a refactor that updates each rule "correctly but
/// inconsistently" could change the *sequence* of disk states a user sees
/// without breaking any single per-rule test.
///
/// These lifecycle scenarios pin the composed output. Each test is a small
/// trace through the pipeline's filename-shape decisions — when one of these
/// changes, the user's next export reuses different stems than the prior run
/// produced, which is the single most user-visible backward-compat regression
/// category in this codebase.
@MainActor
struct ExportShapeLifecycleGoldenTests {

  // MARK: - Helpers

  private static func makeResolver(prefix: String = "LifecycleGolden") throws
    -> (URL, ExportDestinationResolver)
  {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let resolver = ExportDestinationResolver(fileSystem: FileIOService())
    return (dir, resolver)
  }

  private static func cleanup(_ dir: URL) {
    try? FileManager.default.removeItem(at: dir)
  }

  private func plantFile(at url: URL) {
    FileManager.default.createFile(atPath: url.path, contents: Data("x".utf8))
  }

  private func makeAsset(hasAdjustments: Bool = false) -> AssetDescriptor {
    TestAssetFactory.makeAsset(hasAdjustments: hasAdjustments)
  }

  private func makePhotoResource(_ filename: String) -> ResourceDescriptor {
    TestAssetFactory.makeResource(type: .photo, originalFilename: filename)
  }

  /// Compact builder for a prior `.done` original record, mirroring what the
  /// store would have persisted after a real export.
  private func priorRecord(
    assetId: String = "asset-1",
    originalFilename: String?,
    editedFilename: String? = nil
  ) -> ExportRecord {
    var variants: [ExportVariant: ExportVariantRecord] = [:]
    if let originalFilename {
      variants[.original] = ExportVariantRecord(
        filename: originalFilename,
        status: .done,
        exportDate: Date(timeIntervalSinceReferenceDate: 770000000),
        lastError: nil)
    }
    if let editedFilename {
      variants[.edited] = ExportVariantRecord(
        filename: editedFilename,
        status: .done,
        exportDate: Date(timeIntervalSinceReferenceDate: 770000000),
        lastError: nil)
    }
    return ExportRecord(
      id: assetId, year: 2025, month: 2, relPath: "2025/02/", variants: variants)
  }

  // MARK: - Scenario A — fresh export of an adjusted asset (paired)

  /// Step 1 of an asset's life: the user exports an adjusted photo for the
  /// first time. The pipeline must produce two paired files at the same
  /// stem — original at `<stem>_orig.<ext>`, edited at `<stem>.<ext>`.
  ///
  /// If this golden breaks, the user's next re-export will not match prior
  /// records (it won't find `IMG_0001_orig.JPG` to reuse and will re-export
  /// the original bytes, doubling disk usage).
  @Test func freshAdjustedAssetProducesPairedFiles() throws {
    let (dir, resolver) = try Self.makeResolver()
    defer { Self.cleanup(dir) }
    let asset = makeAsset(hasAdjustments: true)
    let resources = [makePhotoResource("IMG_0001.JPG")]

    let stem = resolver.allocatePairedGroupStem(
      baseStem: "IMG_0001", imageExt: "JPG", editedExt: "HEIC",
      destDir: dir, pairOriginalWithSuffix: true)
    #expect(stem == "IMG_0001", "fresh paired allocation must keep the base stem")

    let (originalURL, originalStem) = try resolver.resolveDestination(
      variant: .original, descriptor: asset,
      originalFilename: "IMG_0001.JPG", resources: resources,
      destDir: dir, groupStem: stem, pairOriginalWithSuffix: true)
    #expect(
      originalURL.lastPathComponent == "IMG_0001_orig.JPG",
      "paired-original must land at <stem>_orig.<origExt> — `_orig` suffix is the companion marker")
    #expect(originalStem == "IMG_0001")
    plantFile(at: originalURL)

    let (editedURL, editedStem) = try resolver.resolveDestination(
      variant: .edited, descriptor: asset,
      originalFilename: "IMG_0001.HEIC", resources: resources,
      destDir: dir, groupStem: stem, pairOriginalWithSuffix: true)
    #expect(
      editedURL.lastPathComponent == "IMG_0001.HEIC",
      "paired-edited must land at the natural stem; a different name leaves the user with orphaned `_orig.JPG`")
    #expect(editedStem == "IMG_0001")
  }

  // MARK: - Scenario B — re-export after a new Photos edit

  /// Step 2 of the same asset's life: the user makes a fresh edit in
  /// Photos.app. On the next export run, `inheritedGroupStem` recovers the
  /// stem from the prior `.edited.done` record, and the new edited variant
  /// must collide with the existing on-disk `<stem>.<ext>` and bump to
  /// `<stem> (1).<ext>`. The original is untouched (its bytes haven't
  /// changed).
  ///
  /// This is the documented one-time stem-bump cost on first re-export
  /// after each new edit; pinning the exact suffix shape protects users
  /// from a refactor that switches to `_v2`, `.alt`, or some other
  /// convention.
  @Test func reExportAfterNewEditBumpsEditedToCollisionSuffix() throws {
    let (dir, resolver) = try Self.makeResolver()
    defer { Self.cleanup(dir) }
    let asset = makeAsset(hasAdjustments: true)
    let resources = [makePhotoResource("IMG_0001.JPG")]

    // Pre-plant the prior run's files on disk.
    plantFile(at: dir.appendingPathComponent("IMG_0001_orig.JPG"))
    plantFile(at: dir.appendingPathComponent("IMG_0001.HEIC"))

    // Prior record has both variants .done.
    let record = priorRecord(
      originalFilename: "IMG_0001_orig.JPG", editedFilename: "IMG_0001.HEIC")

    let inherited = ExportDestinationResolver.inheritedGroupStem(
      from: record, descriptor: asset, resources: resources)
    #expect(inherited == "IMG_0001", "inherited stem must come from the edited record's filename")

    // Re-export the edited variant only (Photos detected an adjustment
    // change). Original is unchanged.
    let (newEditedURL, newEditedStem) = try resolver.resolveDestination(
      variant: .edited, descriptor: asset,
      originalFilename: "IMG_0001.HEIC", resources: resources,
      destDir: dir, groupStem: inherited, pairOriginalWithSuffix: false)
    #expect(
      newEditedURL.lastPathComponent == "IMG_0001 (1).HEIC",
      "re-edit must bump to ` (1)` suffix; changing this shape (e.g. `-1`, `_v2`) creates duplicates for every existing user")
    #expect(newEditedStem == "IMG_0001 (1)")
  }

  // MARK: - Scenario C — user filename ending in `_orig`

  /// User's actual file in Photos is named `vacation_orig.JPG` (a perfectly
  /// legal user name, not an app-companion marker). The prior record has
  /// `.original.done` with that filename, and the filename **exactly equals**
  /// the asset's current original-side resource filename — which is the cue
  /// `inheritedGroupStem` uses to treat it as the user's natural name and
  /// keep the `_orig` in the stem.
  ///
  /// This test walks the full chain: prior record → inherited stem →
  /// `resolveDestination` for a fresh edited variant. The composed result
  /// must land at `vacation_orig (1).HEIC` (the edited natural-stem
  /// collides with the existing `vacation_orig.JPG` on disk, hence the
  /// `(1)` suffix). If any link in the chain breaks, the existing user's
  /// `vacation_orig.JPG` becomes orphaned and the re-export creates a
  /// duplicate at `vacation.JPG` / `vacation_orig.JPG`.
  @Test func userOrigSuffixedFilenamePreservedAsGroupStemAndComposes() throws {
    let (dir, resolver) = try Self.makeResolver()
    defer { Self.cleanup(dir) }
    let asset = makeAsset(hasAdjustments: true)
    let resources = [makePhotoResource("vacation_orig.JPG")]

    // Prior export wrote the user's original to disk.
    plantFile(at: dir.appendingPathComponent("vacation_orig.JPG"))
    let record = priorRecord(originalFilename: "vacation_orig.JPG")

    let inherited = ExportDestinationResolver.inheritedGroupStem(
      from: record, descriptor: asset, resources: resources)
    #expect(
      inherited == "vacation_orig",
      "user-named `_orig` filename must be preserved as the group stem; stripping it orphans the existing `vacation_orig.JPG`")

    // User later applies a Photos edit. Resolve the edited variant against
    // the inherited stem.
    let (editedURL, _) = try resolver.resolveDestination(
      variant: .edited, descriptor: asset,
      originalFilename: "vacation_orig.JPG", resources: resources,
      destDir: dir, groupStem: inherited, pairOriginalWithSuffix: false)
    #expect(
      editedURL.lastPathComponent == "vacation_orig (1).JPG",
      "edited variant must land at `<userOrigStem> (1).<ext>`; landing at `vacation.<ext>` orphans `vacation_orig.JPG`")
  }

  // MARK: - Scenario D — app-companion `_orig` stripped

  /// Same prior-record shape as Scenario C, but the asset's current
  /// original resource is `vacation.JPG` — meaning the recorded
  /// `vacation_orig.JPG` does NOT match the resource filename. That's the
  /// cue this was an app-written companion (the original variant of a
  /// paired export), so `inheritedGroupStem` strips the `_orig` and returns
  /// `vacation`.
  ///
  /// This test walks the full chain: prior `.original.done = vacation_orig.JPG`
  /// → inherited stem `vacation` → `resolveDestination` for a fresh edited
  /// variant → file lands at `vacation.HEIC` (the natural-stem pair slot).
  ///
  /// The disambiguation between this scenario and Scenario C is
  /// load-bearing for backward compat — flip the `if filename ==
  /// originalResourceFilename` check at `ExportDestinationResolver.swift`
  /// `inheritedGroupStem` and either every user `vacation_orig.JPG` becomes
  /// orphaned (C breaks) or every app-paired re-export loses its pair (D
  /// breaks).
  @Test func appCompanionOrigSuffixStrippedAndComposes() throws {
    let (dir, resolver) = try Self.makeResolver()
    defer { Self.cleanup(dir) }
    let asset = makeAsset(hasAdjustments: true)
    let resources = [makePhotoResource("vacation.JPG")]

    // Prior export wrote a paired original as `vacation_orig.JPG`.
    plantFile(at: dir.appendingPathComponent("vacation_orig.JPG"))
    let record = priorRecord(originalFilename: "vacation_orig.JPG")

    let inherited = ExportDestinationResolver.inheritedGroupStem(
      from: record, descriptor: asset, resources: resources)
    #expect(
      inherited == "vacation",
      "app-written `_orig` companion stem must be stripped to recover the natural stem")

    // User later applies a Photos edit. The edited variant pairs with the
    // existing `_orig` companion at the natural stem.
    let (editedURL, _) = try resolver.resolveDestination(
      variant: .edited, descriptor: asset,
      originalFilename: "vacation.HEIC", resources: resources,
      destDir: dir, groupStem: inherited, pairOriginalWithSuffix: false)
    #expect(
      editedURL.lastPathComponent == "vacation.HEIC",
      "edited variant must pair with the existing `_orig` companion at the natural stem; any other shape splits the pair across stems")
  }

  // MARK: - Scenario E — single-original fresh export, no pairing

  /// Asset with no adjustments. Single-variant export, no group stem
  /// pre-allocated, no prior record. Resolver uses `uniqueFileURL` to
  /// land the file at its natural filename.
  ///
  /// Pinned so a future refactor cannot silently introduce a default
  /// suffix (`_export`, `_v1`, etc.) or change extension casing.
  @Test func freshSingleOriginalLandsAtNaturalFilename() throws {
    let (dir, resolver) = try Self.makeResolver()
    defer { Self.cleanup(dir) }
    let asset = makeAsset(hasAdjustments: false)
    let resources = [makePhotoResource("IMG_0002.JPG")]

    let (url, stem) = try resolver.resolveDestination(
      variant: .original, descriptor: asset,
      originalFilename: "IMG_0002.JPG", resources: resources,
      destDir: dir, groupStem: nil, pairOriginalWithSuffix: false)
    #expect(
      url.lastPathComponent == "IMG_0002.JPG",
      "fresh single-original must land at the natural filename — no default suffix")
    #expect(stem == "IMG_0002")
  }

  // MARK: - Scenario F — single-original with pre-existing on-disk collision

  /// Same as Scenario E but `IMG_0002.JPG` is already on disk (from a
  /// prior unrelated export, a manual user copy, or anything else). The
  /// resolver must bump to ` (1)`. Pinned because the exact suffix string
  /// is user-visible and any change (e.g. ` (1)` → `-1`) creates duplicate
  /// files for every user on their next export run.
  @Test func freshSingleOriginalWithExistingCollisionBumpsToSuffix() throws {
    let (dir, resolver) = try Self.makeResolver()
    defer { Self.cleanup(dir) }
    let asset = makeAsset(hasAdjustments: false)
    let resources = [makePhotoResource("IMG_0002.JPG")]

    plantFile(at: dir.appendingPathComponent("IMG_0002.JPG"))

    let (url, stem) = try resolver.resolveDestination(
      variant: .original, descriptor: asset,
      originalFilename: "IMG_0002.JPG", resources: resources,
      destDir: dir, groupStem: nil, pairOriginalWithSuffix: false)
    #expect(
      url.lastPathComponent == "IMG_0002 (1).JPG",
      "collision must bump to ` (1)` suffix; any other shape (`-1`, `_v2`) creates duplicates on every existing user's next run")
    #expect(stem == "IMG_0002 (1)")
  }
}
