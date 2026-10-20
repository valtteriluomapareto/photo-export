import Foundation
import Photos

/// Import Existing Backup for the folders under `Collections/`: Favorites, albums (nested in
/// their Photos folders) and shared albums, each with an optional `videos/` subfolder.
extension BackupScanner {
  /// Album folders nest at most this deep below `Collections/<root>/`. A deeper folder fails
  /// the scan instead of being skipped, so no exported files go unread.
  static let collectionsMaxDepth = 32

  /// Fingerprints shared by every match in one import, so each asset's resources are read
  /// once even when it is in a month and several albums.
  @MainActor
  final class FingerprintCache {
    private var byAssetId: [String: AssetFingerprint] = [:]

    func fingerprints(
      for assets: [AssetDescriptor], using service: any PhotoLibraryService
    ) -> [AssetFingerprint] {
      let missing = assets.filter { byAssetId[$0.id] == nil }
      for fingerprint in buildFingerprints(for: missing, using: service) {
        byAssetId[fingerprint.localIdentifier] = fingerprint
      }
      return assets.compactMap { byAssetId[$0.id] }
    }
  }

  // MARK: - Scanning

  /// Lists every folder under `Collections/Favorites/`, `Collections/Albums/` and
  /// `Collections/Shared Albums/` with the regular files directly inside it. A missing
  /// `Collections/` or root is empty. Symbolic links are not followed. A root that is not a
  /// folder, an unreadable folder or file type, or folders nested past `collectionsMaxDepth`
  /// throw `BackupScanReadError`. Cancellation is checked before each entry.
  static func scanCollectionsFolder(
    at rootURL: URL,
    directoryReader reader: any BackupDirectoryReading = ProductionBackupDirectoryReader()
  ) throws -> [ScannedCollectionDirectory] {
    try Task.checkCancellation()
    let collectionsURL = rootURL.appendingPathComponent("Collections", isDirectory: true)
    guard try isCollectionFolder(collectionsURL, reader: reader) else { return [] }
    var results: [ScannedCollectionDirectory] = []
    for root in ScannedCollectionDirectory.Root.allCases {
      try Task.checkCancellation()
      let url = collectionsURL.appendingPathComponent(root.rawValue, isDirectory: true)
      guard try isCollectionFolder(url, reader: reader) else { continue }
      try walk(url, root: root, components: [], reader: reader, into: &results)
    }
    let fileCount = results.reduce(0) { $0 + $1.files.count }
    logger.info(
      "Scanned \(fileCount) files in \(results.count) collection folders in backup folder")
    return results
  }

  /// `true` for a folder; `false` when it is missing or a symbolic link.
  private static func isCollectionFolder(_ url: URL, reader: any BackupDirectoryReading) throws
    -> Bool
  {
    let values: URLResourceValues
    do {
      values = try reader.resourceValues(at: url, keys: [.isDirectoryKey, .isSymbolicLinkKey])
    } catch {
      if isMissingFile(error) { return false }
      throw BackupScanReadError(path: url.path, detail: error.localizedDescription)
    }
    if values.isSymbolicLink == true { return false }
    guard values.isDirectory == true else {
      throw BackupScanReadError(path: url.path, detail: "Expected a directory")
    }
    return true
  }

  private static func walk(
    _ url: URL, root: ScannedCollectionDirectory.Root, components: [String],
    reader: any BackupDirectoryReading, into results: inout [ScannedCollectionDirectory]
  ) throws {
    try Task.checkCancellation()
    guard components.count <= collectionsMaxDepth else {
      throw BackupScanReadError(
        path: url.path,
        detail: "Folders are nested more than \(collectionsMaxDepth) levels deep")
    }
    let entries = try readDirectory(
      url,
      keys: [
        .isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey, .contentModificationDateKey,
        .fileSizeKey,
      ], reader: reader)
    var files: [ScannedFile] = []
    var subfolders: [URL] = []
    for entry in entries {
      try Task.checkCancellation()
      let values = try readValues(
        entry, keys: [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey], reader: reader)
      if values.isSymbolicLink == true { continue }
      guard let regular = values.isRegularFile, let directory = values.isDirectory else {
        throw BackupScanReadError(path: entry.path, detail: "File type is unavailable")
      }
      if regular {
        files.append(collectionFile(at: entry))
      } else if directory {
        subfolders.append(entry)
      }
    }
    results.append(
      ScannedCollectionDirectory(
        root: root, components: components,
        files: files.sorted { $0.filename < $1.filename }))
    for subfolder in subfolders.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
      try walk(
        subfolder, root: root, components: components + [subfolder.lastPathComponent],
        reader: reader, into: &results)
    }
  }

  private static func collectionFile(at url: URL) -> ScannedFile {
    let filename = url.lastPathComponent
    let ext = url.pathExtension
    let stem = (filename as NSString).deletingPathExtension
    let (baseStem, hadSuffix) = stripCollisionSuffix(from: stem)
    let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
    return ScannedFile(
      url: url, year: 0, month: 0, filename: filename,
      baseFilename: ext.isEmpty ? baseStem : baseStem + "." + ext,
      hasCollisionSuffix: hadSuffix, fileExtension: ext.lowercased(),
      modificationDate: values?.contentModificationDate,
      fileSize: values?.fileSize.map(UInt64.init))
  }

  // MARK: - Matching

  /// Matches the scanned collection folders to the current collections and decides which
  /// folder each adopts (see `CollectionBackupPlanner`). Each collection with a candidate
  /// folder has its assets fetched once; a fetch failure throws, so no album is silently left
  /// without history. Files in a `videos/` subfolder match only video assets, and shared
  /// albums, which hold one resource per asset, match originals only. `isCurrent` is checked
  /// before each fetch; a superseded caller stops with `CancellationError`.
  static func matchCollectionFolders(
    _ directories: [ScannedCollectionDirectory],
    collections: [PhotoCollectionDescriptor],
    existingPlacements: [ExportPlacement],
    photoLibraryService: any PhotoLibraryService,
    fingerprintCache: FingerprintCache,
    isCurrent: @MainActor () -> Bool = { true },
    progress: @MainActor (ImportStage) -> Void
  ) async throws -> CollectionBackupPlanner.Plan {
    let candidates = CollectionBackupPlanner.candidates(
      directories: directories, collections: collections, existingPlacements: existingPlacements)

    struct Library {
      let fingerprints: [AssetFingerprint]
      let assetById: [String: AssetDescriptor]
    }
    var libraries: [CollectionBackupPlanner.Target: Library] = [:]
    var scores: [CollectionBackupPlanner.Score] = []
    for candidate in candidates {
      try Task.checkCancellation()
      guard await isCurrent() else { throw CancellationError() }
      let library: Library
      if let cached = libraries[candidate.target] {
        library = cached
      } else {
        await progress(.readingPhotosLibrary)
        let assets = try await photoLibraryService.fetchAssets(
          in: candidate.target.scope, mediaType: nil)
        try Task.checkCancellation()
        guard await isCurrent() else { throw CancellationError() }
        var fingerprints = await fingerprintCache.fingerprints(
          for: assets, using: photoLibraryService)
        if case .sharedAlbum = candidate.target {
          fingerprints = fingerprints.map(\.singleResource)
        }
        var assetById: [String: AssetDescriptor] = [:]
        for asset in assets { assetById[asset.id] = asset }
        library = Library(fingerprints: fingerprints, assetById: assetById)
        libraries[candidate.target] = library
      }

      let group = try await matchGroup(
        candidate.files, fingerprints: library.fingerprints, assetById: library.assetById)
      let matched = group.matched.filter { match in
        if match.file.subfolder != nil, match.asset.mediaType != .video { return false }
        if case .sharedAlbum = candidate.target, match.variant != .original { return false }
        return true
      }
      scores.append(CollectionBackupPlanner.Score(candidate: candidate, matched: matched))
    }

    let plan = CollectionBackupPlanner.assign(
      scores, directories: directories, existingPlacements: existingPlacements)
    logger.info(
      "Collection match complete: \(plan.adoptions.count) folders adopted, \(plan.unrecognizedFolders.count) unrecognized"
    )
    return plan
  }
}

extension BackupScanner.AssetFingerprint {
  /// The fingerprint as a single-resource placement sees it: the original resource only, no
  /// edits or paired video, so the matcher can't classify a file as an `_orig` companion,
  /// edit or motion file.
  var singleResource: Self {
    Self(
      localIdentifier: localIdentifier, mediaType: mediaType, creationDate: creationDate,
      creationSecond: creationSecond, pixelWidth: pixelWidth, pixelHeight: pixelHeight,
      duration: duration, hasAdjustments: false, isLivePhoto: false,
      originalResources: originalResources, editedResources: [], pairedVideoResources: [],
      editedPairedVideoResources: [],
      originalResourceFilenamesLowercased: originalResourceFilenamesLowercased,
      originalResourceStemsLowercased: originalResourceStemsLowercased,
      pairedVideoResourceFilenamesLowercased: [], pairedVideoResourceStemsLowercased: [])
  }
}
