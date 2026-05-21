import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import Photos
import os

/// Scans a backup folder in YYYY/MM/ layout and matches files to Photos library assets.
///
/// Used by the "Import Existing Backup…" feature to rebuild local export state
/// from an existing backup folder on a fresh install.
struct BackupScanner {

  // MARK: - Types

  /// A file discovered in the backup folder's YYYY/MM/ hierarchy.
  ///
  /// `subfolder` (issue #38) records the subfolder inside the month directory
  /// where the file was found — `nil` for files directly under `YYYY/MM/`,
  /// `"videos"` for files inside the `YYYY/MM/videos/` subfolder that the
  /// videos-in-a-subfolder export layout writes. The matcher classifies the
  /// variant by filename/stem regardless of where the file sits, so a paired
  /// motion `.MOV` that the user manually moved into `videos/` is still
  /// recognised; the subfolder is preserved here so the rebuilt record carries
  /// the file's actual on-disk location for reconcile and reuse-source.
  struct ScannedFile: Equatable {
    let url: URL
    let year: Int
    let month: Int
    let filename: String
    /// Filename with collision suffix ` (N)` stripped, e.g. "IMG_0001.jpg" from "IMG_0001 (2).jpg"
    let baseFilename: String
    let hasCollisionSuffix: Bool
    let fileExtension: String
    let modificationDate: Date?
    let fileSize: UInt64?
    /// `nil` ⇒ the bare placement path. Currently the scanner only emits
    /// `"videos"` for files discovered inside the `videos/` subfolder.
    let subfolder: String?

    init(
      url: URL,
      year: Int,
      month: Int,
      filename: String,
      baseFilename: String,
      hasCollisionSuffix: Bool,
      fileExtension: String,
      modificationDate: Date?,
      fileSize: UInt64?,
      subfolder: String? = nil
    ) {
      self.url = url
      self.year = year
      self.month = month
      self.filename = filename
      self.baseFilename = baseFilename
      self.hasCollisionSuffix = hasCollisionSuffix
      self.fileExtension = fileExtension
      self.modificationDate = modificationDate
      self.fileSize = fileSize
      self.subfolder = subfolder
    }
  }

  /// The outcome of matching scanned backup files against the Photos library.
  struct MatchResult {
    /// Files that matched exactly one Photos asset with strong confirmation.
    var matched: [MatchedExportFile] = []
    /// Files where multiple Photos assets fit equally well.
    var ambiguous: [ScannedFile] = []
    /// Files with no matching Photos asset found.
    var unmatched: [ScannedFile] = []
  }

  /// A scanned file that has been unambiguously matched to a Photos asset, along with which
  /// variant of that asset the file represents.
  struct MatchedExportFile {
    let file: ScannedFile
    let asset: AssetDescriptor
    let variant: ExportVariant
  }

  /// Progress updates emitted during scan/match.
  enum ImportStage: Equatable {
    case scanningBackupFolder
    case readingPhotosLibrary
    case matchingAssets(matched: Int, total: Int)
    case rebuildingLocalState
    case reconcilingDiskState
    case done
  }

  private static let logger = Logger(
    subsystem: "com.valtteriluoma.photo-export", category: "BackupScanner")

  // MARK: - Collision suffix pattern

  /// Matches the app's collision suffix pattern: ` (N)` before the extension.
  /// e.g., "IMG_0001 (2).jpg" → base "IMG_0001", suffix " (2)"
  private static let collisionSuffixPattern = try! NSRegularExpression(
    pattern: #" \(\d+\)$"#)

  /// Strips the collision suffix from a filename stem (no extension).
  /// Returns the stripped stem and whether a suffix was found.
  static func stripCollisionSuffix(from stem: String) -> (stripped: String, hadSuffix: Bool) {
    let range = NSRange(stem.startIndex..., in: stem)
    if let match = collisionSuffixPattern.firstMatch(in: stem, range: range) {
      let matchRange = Range(match.range, in: stem)!
      let stripped = String(stem[stem.startIndex..<matchRange.lowerBound])
      return (stripped, true)
    }
    return (stem, false)
  }

  // MARK: - Backup folder scanning

  /// Enumerates files in YYYY/MM/ directories under the backup root.
  /// Only considers directories where YYYY is a 4-digit year and MM is 01–12.
  static func scanBackupFolder(at rootURL: URL) -> [ScannedFile] {
    let fm = FileManager.default
    var results: [ScannedFile] = []

    // List year directories
    guard
      let yearEntries = try? fm.contentsOfDirectory(
        at: rootURL, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
    else {
      logger.warning("Could not enumerate backup root: \(rootURL.path, privacy: .public)")
      return []
    }

    for yearDir in yearEntries {
      guard isDirectory(yearDir),
        let year = parseYear(yearDir.lastPathComponent)
      else { continue }

      guard
        let monthEntries = try? fm.contentsOfDirectory(
          at: yearDir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
      else { continue }

      for monthDir in monthEntries {
        guard isDirectory(monthDir),
          let month = parseMonth(monthDir.lastPathComponent)
        else { continue }

        // Files directly under YYYY/MM/ (subfolder = nil).
        appendFiles(in: monthDir, year: year, month: month, subfolder: nil, into: &results)

        // Issue #38: also descend into YYYY/MM/videos/ (if present) so files written
        // under the subfolder layout are discovered by Import Existing Backup.
        let videosDir = monthDir.appendingPathComponent("videos", isDirectory: true)
        if isDirectory(videosDir) {
          appendFiles(
            in: videosDir, year: year, month: month, subfolder: "videos", into: &results)
        }
      }
    }

    logger.info("Scanned \(results.count) files in backup folder")
    return results
  }

  /// Enumerates regular files directly inside `directory` and emits a
  /// `ScannedFile` for each into `results`. Used by `scanBackupFolder` to walk
  /// both the bare month directory and its optional `videos/` child (issue #38).
  /// Caller passes `subfolder = nil` for files at the month root and
  /// `subfolder = "videos"` for files in the subfolder.
  private static func appendFiles(
    in directory: URL,
    year: Int,
    month: Int,
    subfolder: String?,
    into results: inout [ScannedFile]
  ) {
    let fm = FileManager.default
    guard
      let files = try? fm.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: [
          .isRegularFileKey, .contentModificationDateKey, .fileSizeKey,
        ],
        options: [.skipsHiddenFiles])
    else { return }

    for fileURL in files {
      guard isRegularFile(fileURL) else { continue }

      let filename = fileURL.lastPathComponent
      let ext = fileURL.pathExtension
      let stem = (filename as NSString).deletingPathExtension
      let (baseStem, hadSuffix) = stripCollisionSuffix(from: stem)
      let baseFilename =
        ext.isEmpty ? baseStem : baseStem + "." + ext

      let resourceValues = try? fileURL.resourceValues(forKeys: [
        .contentModificationDateKey, .fileSizeKey,
      ])

      results.append(
        ScannedFile(
          url: fileURL,
          year: year,
          month: month,
          filename: filename,
          baseFilename: baseFilename,
          hasCollisionSuffix: hadSuffix,
          fileExtension: ext.lowercased(),
          modificationDate: resourceValues?.contentModificationDate,
          fileSize: resourceValues?.fileSize.map(UInt64.init),
          subfolder: subfolder
        ))
    }
  }

  // MARK: - Asset fingerprint (cheap, built once per asset)

  /// Per-resource snapshot used by the matcher. Filename + the optional
  /// PhotoKit-reported file size; the size is used as a last-resort
  /// discriminator when otherwise-identical bursts would land in the
  /// "ambiguous" bucket. See issue #32.
  struct ResourceFingerprint: Sendable, Equatable {
    let filename: String
    let fileSize: Int64?
  }

  /// Value-type snapshot of an asset's metadata, built once per asset batch.
  /// Avoids repeated resource lookups during matching.
  struct AssetFingerprint {
    let localIdentifier: String
    let mediaType: PHAssetMediaType
    let creationDate: Date?
    /// Seconds since reference date, truncated — used as hash key for fast lookup
    let creationSecond: Int?
    let pixelWidth: Int
    let pixelHeight: Int
    let duration: TimeInterval
    /// Whether Photos reports this asset as adjusted at fingerprint time.
    let hasAdjustments: Bool
    /// True when the asset is a Live Photo. Used by the classifier to decide whether
    /// `.mov` siblings of an image resource are paired-video variants.
    let isLivePhoto: Bool
    /// Original-side resources (`.photo`, `.video`, `.alternatePhoto`).
    let originalResources: [ResourceFingerprint]
    /// Edited-side resources (`.fullSizePhoto`, `.fullSizeVideo`).
    let editedResources: [ResourceFingerprint]
    /// Live Photo motion file (unedited): `.pairedVideo`. Empty for non-Live-Photo
    /// assets. Kept separate from `originalResources` because the classifier needs to
    /// disambiguate `IMG_0001.mov` (Live Photo paired video) from a same-named
    /// full-length video asset's `.video` resource.
    let pairedVideoResources: [ResourceFingerprint]
    /// Live Photo motion file (rendered): `.fullSizePairedVideo`. Empty when Photos
    /// hasn't materialised an edited motion companion or for non-Live-Photo assets.
    let editedPairedVideoResources: [ResourceFingerprint]

    /// Filename adapters for the existing classifier code that only needs filenames.
    var originalResourceFilenames: [String] { originalResources.map(\.filename) }
    var editedResourceFilenames: [String] { editedResources.map(\.filename) }
    /// Stems of original-side resources, used for cross-extension edited matching.
    var originalResourceStems: [String] {
      originalResourceFilenames.map { ($0 as NSString).deletingPathExtension }
    }
    var pairedVideoResourceFilenames: [String] { pairedVideoResources.map(\.filename) }
    var pairedVideoResourceStems: [String] {
      pairedVideoResourceFilenames.map { ($0 as NSString).deletingPathExtension }
    }
    /// All resource filenames (kept for backward compatibility with filename-only matching).
    var originalFilenames: [String] {
      originalResourceFilenames + editedResourceFilenames
    }
  }

  /// Builds fingerprints for a batch of AssetDescriptors with resource info from the service.
  @MainActor
  static func buildFingerprints(
    for assets: [AssetDescriptor], using service: any PhotoLibraryService
  ) -> [AssetFingerprint] {
    assets.map { asset in
      let resources = service.resources(for: asset.id)
      let originalResources =
        resources
        .filter {
          ResourceSelection.isOriginalResource(type: $0.type, mediaType: asset.mediaType)
        }
        .map { ResourceFingerprint(filename: $0.originalFilename, fileSize: $0.fileSize) }
      let editedResources =
        resources
        .filter {
          ResourceSelection.isEditedResource(type: $0.type, mediaType: asset.mediaType)
        }
        .map { ResourceFingerprint(filename: $0.originalFilename, fileSize: $0.fileSize) }
      let pairedVideoResources =
        resources
        .filter { $0.type == .pairedVideo }
        .map { ResourceFingerprint(filename: $0.originalFilename, fileSize: $0.fileSize) }
      let editedPairedVideoResources =
        resources
        .filter { $0.type == .fullSizePairedVideo }
        .map { ResourceFingerprint(filename: $0.originalFilename, fileSize: $0.fileSize) }
      // Issue #49: derive `isLivePhoto` from the resource list rather than mirroring
      // `asset.isLivePhoto`. The descriptor flag is gated behind the user's Settings
      // toggle (so a fresh fetch with the toggle off may return `false` even for true
      // Live Photos on iCloud-synced libraries with a missing `.photoLive` subtype).
      // The scanner already has the full resource list — the presence of a paired-
      // video resource is the canonical signal, and using it here keeps Import
      // Existing Backup classifying `.mov` companions correctly regardless of the
      // toggle. Without this, importing a backup with paired-video files while the
      // toggle is off, then later turning the toggle on, would trip the destination
      // resolver's Code 5 "Paired original filename already exists on disk" on the
      // next export run.
      let scannerDetectedLivePhoto =
        !pairedVideoResources.isEmpty || !editedPairedVideoResources.isEmpty
      let creationSecond: Int? =
        asset.creationDate.map { Int($0.timeIntervalSinceReferenceDate) }
      return AssetFingerprint(
        localIdentifier: asset.id,
        mediaType: asset.mediaType,
        creationDate: asset.creationDate,
        creationSecond: creationSecond,
        pixelWidth: asset.pixelWidth,
        pixelHeight: asset.pixelHeight,
        duration: asset.duration,
        hasAdjustments: asset.hasAdjustments,
        isLivePhoto: scannerDetectedLivePhoto,
        originalResources: originalResources,
        editedResources: editedResources,
        pairedVideoResources: pairedVideoResources,
        editedPairedVideoResources: editedPairedVideoResources
      )
    }
  }

  // MARK: - Matching

  /// Matches scanned backup files against Photos library assets.
  ///
  /// Hybrid matching strategy:
  /// 1. Build AssetFingerprint snapshots once per asset (O(assets) resource calls)
  /// 2. Index fingerprints by (mediaType, creation-second) for fast lookup
  /// 3. For each file, use modification date as primary lookup key
  /// 4. If not unique, intersect with filename matches from cached fingerprints
  /// 5. Only if still ambiguous, lazily read file dimensions/duration (cached per file)
  ///
  /// Adjacent months are included to handle time-zone boundary drift.
  static func matchFiles(
    _ scannedFiles: [ScannedFile],
    photoLibraryService: any PhotoLibraryService,
    progress: @MainActor (ImportStage) -> Void
  ) async throws -> MatchResult {
    var result = MatchResult()

    // Group scanned files by year-month for batch fetching
    var filesByYearMonth: [String: [ScannedFile]] = [:]
    for file in scannedFiles {
      let key = "\(file.year)-\(file.month)"
      filesByYearMonth[key, default: []].append(file)
    }

    // Caches: assets and fingerprints per year-month
    var assetsByYearMonth: [String: [AssetDescriptor]] = [:]
    var fingerprintsByYearMonth: [String: [AssetFingerprint]] = [:]

    let totalFiles = scannedFiles.count
    var matchedCount = 0

    for (_, files) in filesByYearMonth {
      let year = files[0].year
      let month = files[0].month

      // Pre-fetch primary month and adjacent months (for time-zone boundary drift)
      let monthsToFetch = adjacentYearMonths(year: year, month: month)
      for (y, m) in monthsToFetch {
        let k = "\(y)-\(m)"
        if assetsByYearMonth[k] == nil {
          try Task.checkCancellation()
          await progress(.readingPhotosLibrary)
          let assets = (try? await photoLibraryService.fetchAssets(year: y, month: m)) ?? []
          assetsByYearMonth[k] = assets
          // Build fingerprints once — this is the only resource call site
          fingerprintsByYearMonth[k] = await buildFingerprints(
            for: assets, using: photoLibraryService)
        }
      }

      // Combine fingerprints from primary and adjacent months
      var combinedFingerprints: [AssetFingerprint] = []
      for (y, m) in monthsToFetch {
        combinedFingerprints.append(contentsOf: fingerprintsByYearMonth["\(y)-\(m)"] ?? [])
      }

      // Combine assets for result references
      var combinedAssets: [AssetDescriptor] = []
      for (y, m) in monthsToFetch {
        combinedAssets.append(contentsOf: assetsByYearMonth["\(y)-\(m)"] ?? [])
      }
      // Build id → AssetDescriptor lookup
      var assetById: [String: AssetDescriptor] = [:]
      for asset in combinedAssets {
        assetById[asset.id] = asset
      }

      // Pre-compute the set of group stems that have a `_orig` companion sibling in this
      // scope. When a natural-stem file's stem appears here, the file is an `.edited`
      // companion paired with that `_orig` original — even when the file's filename also
      // matches a known original-resource filename (the include-originals same-extension
      // case where the original moved out of the way to the `_orig` sibling).
      var stemsWithOrigSibling = Set<String>()
      for file in files {
        if let parsed = ExportFilenamePolicy.parseOriginalCandidate(filename: file.filename) {
          stemsWithOrigSibling.insert(parsed.groupStem)
          stemsWithOrigSibling.insert(parsed.canonicalOriginalStem)
        }
      }

      for file in files {
        try Task.checkCancellation()
        matchedCount += 1
        if matchedCount % 50 == 0 {
          await progress(.matchingAssets(matched: result.matched.count, total: totalFiles))
          await Task.yield()
        }

        if combinedFingerprints.isEmpty {
          result.unmatched.append(file)
          continue
        }

        let matchOutcome = matchSingleFile(
          file,
          fingerprints: combinedFingerprints,
          assetById: assetById,
          stemsWithOrigSibling: stemsWithOrigSibling
        )
        switch matchOutcome {
        case .matched(let matched):
          result.matched.append(matched)
        case .ambiguous:
          result.ambiguous.append(file)
        case .unmatched:
          result.unmatched.append(file)
        }
      }
    }

    logger.info(
      "Match complete: \(result.matched.count) matched, \(result.ambiguous.count) ambiguous, \(result.unmatched.count) unmatched"
    )
    return result
  }

  /// Returns (year, month) tuples for a month and its two neighbors.
  /// Handles year boundaries (e.g., Jan → prev Dec, Dec → next Jan).
  private static func adjacentYearMonths(year: Int, month: Int) -> [(Int, Int)] {
    var results = [(year, month)]
    if month == 1 {
      results.append((year - 1, 12))
    } else {
      results.append((year, month - 1))
    }
    if month == 12 {
      results.append((year + 1, 1))
    } else {
      results.append((year, month + 1))
    }
    return results
  }

  // MARK: - Hybrid single-file matching

  private enum SingleMatchOutcome {
    case matched(MatchedExportFile)
    case ambiguous
    case unmatched
  }

  /// Classifies a scanned file's filename as original-variant or edited-variant against the
  /// supplied fingerprints, then narrows the candidate set by date and, if still ambiguous, by
  /// file metadata (dimensions/duration).
  ///
  /// Classification order:
  /// 1. `_orig` companion: filename parses as a `_orig` candidate AND a fingerprint with
  ///    adjustments has matching original-resource stem and extension. Fall through to
  ///    step 2 on miss so a real user filename like `vacation_orig.JPG` is not silently lost.
  /// 2. Exact match against a known original resource filename → `.original`, **unless** a
  ///    `_orig` sibling exists in the same scope for the same stem and the candidate is
  ///    adjusted (the include-originals same-extension case where the natural-stem file is
  ///    actually the edit and the original moved out to `_orig`) — in that case classify
  ///    as `.edited`.
  /// 3. Collision-stripped match against a known original resource filename → `.original`
  ///    (with the same `_orig`-sibling override as step 2).
  /// 4. Cross-extension edited: filename's stem (collision-stripped) matches an adjusted
  ///    asset's original-resource stem AND the file extension matches one of that asset's
  ///    edited-resource extensions → `.edited`. Same-extension same-stem cases without a
  ///    `_orig` sibling land in step 2/3 as `.original` (the documented default-mode
  ///    import limitation).
  private static func matchSingleFile(
    _ file: ScannedFile,
    fingerprints: [AssetFingerprint],
    assetById: [String: AssetDescriptor],
    stemsWithOrigSibling: Set<String>
  ) -> SingleMatchOutcome {
    // Step 1: `_orig` companion. Filename ends with `_orig` (with optional ` (N)`).
    if let parsed = ExportFilenamePolicy.parseOriginalCandidate(filename: file.filename) {
      let origCandidates = fingerprints.filter { fp in
        guard fp.hasAdjustments else { return false }
        let exts = Set(
          fp.originalResourceFilenames.map { ($0 as NSString).pathExtension.lowercased() }
        )
        guard exts.isEmpty || exts.contains(file.fileExtension) else { return false }
        return fp.originalResourceStems.contains(parsed.groupStem)
          || fp.originalResourceStems.contains(parsed.canonicalOriginalStem)
      }
      if !origCandidates.isEmpty {
        return narrow(
          file: file, candidates: origCandidates,
          assetById: assetById, variant: .original)
      }
      // Fall through: a user filename like `vacation_orig.JPG` whose asset has no adjusted
      // sibling at the `vacation` stem must still classify via step 2.
    }

    let fileStem = (file.filename as NSString).deletingPathExtension
    let (canonicalFileStem, _) = ExportFilenamePolicy.stripTrailingCollisionSuffix(from: fileStem)
    let hasOrigSibling =
      stemsWithOrigSibling.contains(fileStem)
      || stemsWithOrigSibling.contains(canonicalFileStem)

    // Step 2: exact match to a known original-resource filename.
    let originalExactCandidates = fingerprints.filter {
      $0.originalResourceFilenames.contains(file.filename)
    }
    if !originalExactCandidates.isEmpty {
      if hasOrigSibling {
        let editedFromPair = originalExactCandidates.filter { fp in
          guard fp.hasAdjustments else { return false }
          let editedExts = Set(
            fp.editedResourceFilenames.map { ($0 as NSString).pathExtension.lowercased() }
          )
          if editedExts.isEmpty { return true }
          return editedExts.contains(file.fileExtension)
        }
        if !editedFromPair.isEmpty {
          return narrow(
            file: file, candidates: editedFromPair,
            assetById: assetById, variant: .edited)
        }
      }
      return narrow(
        file: file, candidates: originalExactCandidates,
        assetById: assetById, variant: .original)
    }

    // Step 3: collision-stripped match to a known original-resource filename.
    if file.hasCollisionSuffix {
      let baseCandidates = fingerprints.filter {
        $0.originalResourceFilenames.contains(file.baseFilename)
      }
      if !baseCandidates.isEmpty {
        if hasOrigSibling {
          let editedFromPair = baseCandidates.filter { fp in
            guard fp.hasAdjustments else { return false }
            let editedExts = Set(
              fp.editedResourceFilenames.map { ($0 as NSString).pathExtension.lowercased() }
            )
            if editedExts.isEmpty { return true }
            return editedExts.contains(file.fileExtension)
          }
          if !editedFromPair.isEmpty {
            return narrow(
              file: file, candidates: editedFromPair,
              assetById: assetById, variant: .edited)
          }
        }
        return narrow(
          file: file, candidates: baseCandidates,
          assetById: assetById, variant: .original)
      }
    }

    // Step 4: cross-extension edited. The file's stem (collision-stripped) matches an
    // adjusted asset's original-resource stem AND the file's extension matches one of that
    // asset's edited-resource extensions.
    let stem = (file.filename as NSString).deletingPathExtension
    let (canonicalStem, _) = ExportFilenamePolicy.stripTrailingCollisionSuffix(from: stem)
    let editedCandidates = fingerprints.filter { fp in
      guard fp.hasAdjustments else { return false }
      guard
        fp.originalResourceStems.contains(stem)
          || fp.originalResourceStems.contains(canonicalStem)
      else { return false }
      let editedExts = Set(
        fp.editedResourceFilenames.map { ($0 as NSString).pathExtension.lowercased() }
      )
      let originalExts = Set(
        fp.originalResourceFilenames.map { ($0 as NSString).pathExtension.lowercased() }
      )
      if !editedExts.isEmpty {
        guard editedExts.contains(file.fileExtension) else { return false }
        // Defensive: a same-extension natural-stem file should already have matched in
        // step 2 (exact filename) or step 3 (collision-stripped). The only way this
        // branch fires is the rare alternate-photo edge where a fingerprint has multiple
        // original-side resources with different stems sharing an extension. In that
        // case we cannot tell edit from original by filename alone — leave unmatched.
        if originalExts.contains(file.fileExtension) { return false }
        return true
      }
      // No edited-extension info — only accept when the extension differs from any
      // original-resource extension to avoid over-matching same-extension natural-stem files.
      return !originalExts.contains(file.fileExtension)
    }
    if !editedCandidates.isEmpty {
      return narrow(
        file: file, candidates: editedCandidates, assetById: assetById, variant: .edited)
    }

    // Step 5: Live Photo paired-video classification. Reached when image-side rules
    // didn't match and the file is a `.mov` whose stem matches a Live Photo's
    // paired-video resource. We classify here rather than as part of step 2/3 because
    // the image-side filename matchers compare against `originalResourceFilenames` —
    // a Live Photo's `.pairedVideo` filename lives in a sibling bucket
    // (`pairedVideoResourceFilenames`) so that a `.mov` file isn't misclassified as
    // the `.original` of a separate full-length video asset that happens to share the
    // filename. Disambiguation against the still side is via the `_orig.mov` sibling:
    // its presence promotes the natural-stem motion file to `.editedPairedVideo`.
    if file.fileExtension == "mov" {
      // 5a: `<stem>_orig.mov` → `.originalPairedVideo` against a Live Photo whose
      // paired-video resource stem matches.
      if let parsed = ExportFilenamePolicy.parseOriginalCandidate(filename: file.filename) {
        let pairedOrigCandidates = fingerprints.filter { fp in
          guard fp.isLivePhoto else { return false }
          let stems = Set(fp.pairedVideoResourceStems)
          return stems.contains(parsed.groupStem)
            || stems.contains(parsed.canonicalOriginalStem)
        }
        if !pairedOrigCandidates.isEmpty {
          return narrow(
            file: file, candidates: pairedOrigCandidates,
            assetById: assetById, variant: .originalPairedVideo)
        }
      }
      // 5b: natural-stem `.mov` matching a paired-video resource filename. The
      // `_orig.mov` sibling check decides original vs edited paired video.
      let pairedCandidates = fingerprints.filter {
        $0.isLivePhoto && $0.pairedVideoResourceFilenames.contains(file.filename)
      }
      if !pairedCandidates.isEmpty {
        let variant: ExportVariant =
          hasOrigSibling ? .editedPairedVideo : .originalPairedVideo
        return narrow(
          file: file, candidates: pairedCandidates,
          assetById: assetById, variant: variant)
      }
    }

    return .unmatched
  }

  /// Narrows a candidate fingerprint set to a single match by date and then by lazy file
  /// metadata.
  private static func narrow(
    file: ScannedFile,
    candidates: [AssetFingerprint],
    assetById: [String: AssetDescriptor],
    variant: ExportVariant
  ) -> SingleMatchOutcome {
    func wrap(_ fp: AssetFingerprint) -> SingleMatchOutcome {
      if let asset = assetById[fp.localIdentifier] {
        return .matched(
          MatchedExportFile(file: file, asset: asset, variant: variant))
      }
      return .unmatched
    }

    if candidates.count == 1 {
      let only = candidates[0]
      if datesAlign(file: file, fingerprint: only) { return wrap(only) }
      // Single filename candidate whose creation date does not align with the file's mod
      // date — require a stronger metadata confirmation before claiming a match, matching the
      // pre-variant behaviour around the filename-only fallback.
      let confirmed = discriminateByFileMetadata(file: file, candidates: [only])
      if confirmed.count == 1 { return wrap(only) }
      return .ambiguous
    }

    if let modDate = file.modificationDate {
      let byDate = candidates.filter { fp in
        guard let created = fp.creationDate else { return false }
        return abs(modDate.timeIntervalSince(created)) <= 1.0
      }
      if byDate.count == 1 { return wrap(byDate[0]) }
      if byDate.count > 1 {
        // Burst photos commonly land here: same filename or near-stem, same
        // creation second, identical dimensions. Resource file size is
        // usually the only metadata that differs. See issue #32.
        if let bySize = narrowByResourceFileSize(
          file: file, candidates: byDate, variant: variant), bySize.count == 1
        {
          return wrap(bySize[0])
        }
        return .ambiguous
      }
    }

    let discriminated = discriminateByFileMetadata(file: file, candidates: candidates)
    if discriminated.count == 1 { return wrap(discriminated[0]) }
    if discriminated.count > 1 { return .ambiguous }
    return .ambiguous
  }

  private static func datesAlign(file: ScannedFile, fingerprint: AssetFingerprint) -> Bool {
    guard let modDate = file.modificationDate, let created = fingerprint.creationDate
    else { return false }
    return abs(modDate.timeIntervalSince(created)) <= 1.0
  }

  /// Narrows by exact byte-for-byte resource file size. Returns nil when the
  /// scanned file's size is missing — the caller should treat that as
  /// "discriminator unavailable" and stay conservative.
  ///
  /// The check is scoped to the resource(s) on each candidate that *could have
  /// admitted the candidate* via the classifier's filename/stem rules — see
  /// `resourcesCompatible(with:in:variant:)`. Without that scoping, an
  /// unrelated resource (e.g. an `.alternatePhoto` on the same asset) of the
  /// right size could rescue a candidate whose named resource doesn't match,
  /// silently mismatching the wrong asset to the wrong file. Filtering to the
  /// admitting resources keeps the discriminator strict.
  ///
  /// Resources with nil size are skipped. Multiple candidates passing the
  /// filter leaves the result ambiguous — the caller's `count == 1` check
  /// enforces conservative behaviour.
  private static func narrowByResourceFileSize(
    file: ScannedFile,
    candidates: [AssetFingerprint],
    variant: ExportVariant
  ) -> [AssetFingerprint]? {
    guard let scannedSize = file.fileSize else { return nil }
    let target = Int64(scannedSize)
    return candidates.filter { fp in
      let resources = resourcesCompatible(with: file, in: fp, variant: variant)
      return resources.contains { $0.fileSize == target }
    }
  }

  /// Returns the resources of `fp` that could have admitted the candidate for
  /// matching `file` under `variant`. The classifier admits candidates by
  /// filename, collision-stripped base filename, `_orig` parsed stem (with
  /// extension), or edited-resource extension; this helper mirrors those
  /// predicates so the size discriminator only considers resources the file
  /// could plausibly correspond to.
  private static func resourcesCompatible(
    with file: ScannedFile,
    in fp: AssetFingerprint,
    variant: ExportVariant
  ) -> [ResourceFingerprint] {
    switch variant {
    case .original:
      // `_orig` companion path: scanned filename parses as `_orig` and the
      // candidate has an original resource at the parsed stem with matching
      // extension. The byte source is that resource.
      if let parsed = ExportFilenamePolicy.parseOriginalCandidate(filename: file.filename) {
        let acceptableStems: Set<String> = [parsed.groupStem, parsed.canonicalOriginalStem]
        let matches = fp.originalResources.filter { res in
          let stem = (res.filename as NSString).deletingPathExtension
          let ext = (res.filename as NSString).pathExtension.lowercased()
          return acceptableStems.contains(stem) && ext == file.fileExtension
        }
        if !matches.isEmpty { return matches }
      }
      // Step 2 / 3: exact filename match (or collision-stripped base).
      let acceptableFilenames: Set<String> = [file.filename, file.baseFilename]
      return fp.originalResources.filter { acceptableFilenames.contains($0.filename) }
    case .edited:
      // Step 2/3 override and step 4 (cross-extension edited): the byte source
      // is an edited-side resource whose extension matches the scanned file.
      return fp.editedResources.filter {
        ($0.filename as NSString).pathExtension.lowercased() == file.fileExtension
      }
    case .originalPairedVideo:
      // Step 5: Live Photo motion file. Either an `_orig.mov` companion classified
      // against the paired-video resource stem, or a natural-stem `.mov` filename
      // match. The byte source is the asset's `.pairedVideo` resource.
      if let parsed = ExportFilenamePolicy.parseOriginalCandidate(filename: file.filename) {
        let acceptableStems: Set<String> = [parsed.groupStem, parsed.canonicalOriginalStem]
        let matches = fp.pairedVideoResources.filter { res in
          let stem = (res.filename as NSString).deletingPathExtension
          return acceptableStems.contains(stem)
        }
        if !matches.isEmpty { return matches }
      }
      return fp.pairedVideoResources.filter { $0.filename == file.filename }
    case .editedPairedVideo:
      // Natural-stem `.mov` with an `_orig.mov` sibling: the byte source is the
      // edited-side `.fullSizePairedVideo` when present, otherwise it's the same
      // `.pairedVideo` resource the matcher already classified against (Photos
      // elides the rendered companion when the edit doesn't touch motion).
      let editedMatches = fp.editedPairedVideoResources.filter {
        ($0.filename as NSString).pathExtension.lowercased() == file.fileExtension
      }
      if !editedMatches.isEmpty { return editedMatches }
      return fp.pairedVideoResources.filter { $0.filename == file.filename }
    }
  }

  /// Lazy discriminator: reads file dimensions/duration ONCE and checks all candidates.
  private static func discriminateByFileMetadata(
    file: ScannedFile, candidates: [AssetFingerprint]
  ) -> [AssetFingerprint] {
    // Read file metadata once
    var fileDimensions: (width: Int, height: Int)?
    var fileDuration: TimeInterval?

    let mediaType = mediaType(for: file.fileExtension)
    if mediaType == .image {
      fileDimensions = imagePixelDimensions(at: file.url)
    } else if mediaType == .video {
      fileDuration = videoDuration(at: file.url)
    }

    return candidates.filter { fp in
      // Mod date match
      if let modDate = file.modificationDate, let cd = fp.creationDate {
        if abs(modDate.timeIntervalSince(cd)) <= 1.0 {
          return true
        }
      }

      // Image dimensions match
      if let dims = fileDimensions {
        let widthMatch = dims.width == fp.pixelWidth && dims.height == fp.pixelHeight
        let rotatedMatch = dims.width == fp.pixelHeight && dims.height == fp.pixelWidth
        if widthMatch || rotatedMatch {
          return true
        }
      }

      // Video duration match
      if let dur = fileDuration, dur > 0, abs(dur - fp.duration) <= 1.0 {
        return true
      }

      return false
    }
  }

  // MARK: - Media type inference

  private static let imageExtensions: Set<String> = [
    "jpg", "jpeg", "heic", "heif", "png", "tiff", "tif", "gif", "bmp", "webp", "dng", "raw",
    "cr2", "cr3", "nef", "arw", "orf", "rw2",
  ]

  private static let videoExtensions: Set<String> = [
    "mov", "mp4", "m4v", "avi", "mkv", "3gp", "mts",
  ]

  static func mediaType(for fileExtension: String) -> PHAssetMediaType {
    let ext = fileExtension.lowercased()
    if imageExtensions.contains(ext) { return .image }
    if videoExtensions.contains(ext) { return .video }
    return .unknown
  }

  // MARK: - File metadata helpers

  /// Reads pixel dimensions from an image file without loading the full image.
  private static func imagePixelDimensions(at url: URL) -> (width: Int, height: Int)? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    guard
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
    else { return nil }
    guard let width = properties[kCGImagePropertyPixelWidth] as? Int,
      let height = properties[kCGImagePropertyPixelHeight] as? Int
    else { return nil }
    return (width, height)
  }

  /// Reads the duration of a video file.
  /// Uses the legacy synchronous `duration` property since this is only called
  /// for the rare ambiguous-file fallback path, not the hot loop.
  @available(macOS, deprecated: 13.0, message: "Acceptable: only used in rare fallback path")
  private static func videoDuration(at url: URL) -> TimeInterval {
    let avAsset = AVURLAsset(
      url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
    let duration = avAsset.duration
    guard duration.timescale > 0 else { return 0 }
    return CMTimeGetSeconds(duration)
  }

  // MARK: - Filesystem helpers

  private static func isDirectory(_ url: URL) -> Bool {
    let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
    return values?.isDirectory == true
  }

  private static func isRegularFile(_ url: URL) -> Bool {
    let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
    return values?.isRegularFile == true
  }

  private static func parseYear(_ component: String) -> Int? {
    guard component.count == 4, let year = Int(component), year >= 1900, year <= 2100 else {
      return nil
    }
    return year
  }

  private static func parseMonth(_ component: String) -> Int? {
    guard component.count == 2, let month = Int(component), (1...12).contains(month) else {
      return nil
    }
    return month
  }
}
