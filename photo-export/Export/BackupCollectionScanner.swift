import Foundation
import os

/// Scans a backup folder's `Collections/` subtree and emits one
/// `CollectionScanGroup` per leaf folder (favorites, user-album, or
/// shared-album). Counterpart to `BackupScanner.scanBackupFolder(at:)`,
/// which walks the timeline `YYYY/MM/` tree.
///
/// Three roots under `<root>/Collections/`:
///
/// - `Favorites/` — flat. Direct files + optional `videos/` subfolder.
///   Empty roots are skipped (no group emitted).
/// - `Albums/` — recursive. A directory is a *leaf album* when it contains
///   at least one regular file directly OR an `videos/` child with files.
///   Otherwise the directory is treated as a user folder and the scan
///   recurses into its (non-`videos`) subdirectories.
/// - `Shared Albums/` — single level. Each child directory is a candidate
///   leaf; deeper nesting is ignored because PhotoKit does not allow
///   nested shared albums.
///
/// Files emitted into a group preserve their `subfolder` (issue #38) so
/// the downstream matcher and bulk-import path can record the file's
/// actual on-disk location for reconcile and reuse-source.
///
/// Empty leaf folders (no direct files, no `videos/` children with files)
/// are **not** emitted. The plan rationale (issue #106, §"Open Questions"):
/// writing a placement for an empty folder would create a stale entry
/// that the existing `reconcileAgainstFilesystem` cannot prune, since
/// reconcile prunes records and never placements.
struct BackupCollectionScanner {

  /// Outcome of one leaf folder under `Collections/`. The matcher
  /// (`BackupCollectionPlacementMatcher`) joins this against the existing
  /// placement set and the PhotoKit collection tree to resolve a real
  /// `ExportPlacement`.
  struct CollectionScanGroup: Equatable {
    enum Kind: Equatable {
      case favorites
      case album
      case sharedAlbum
    }

    let kind: Kind
    /// For `.album`: the sanitized parent-folder path components under
    /// `Collections/Albums/`. Empty for top-level albums and for the
    /// other two kinds.
    let parentPathComponents: [String]
    /// For `.album` and `.sharedAlbum`: the on-disk leaf folder name
    /// (sanitized form, since the resolver wrote it that way).
    /// For `.favorites`: the literal `"Favorites"`; the placement id is
    /// fixed and the leaf name is informational only.
    let leafName: String
    /// On-disk URL of the leaf folder containing files.
    let folderURL: URL
    /// Files in the leaf, including any `videos/`-subfolder children
    /// flattened in — each file carries its own `subfolder` value.
    let files: [BackupScanner.ScannedFile]
  }

  private static let logger = Logger(
    subsystem: "com.valtteriluoma.photo-export", category: "BackupCollectionScanner")

  /// Walks `<root>/Collections/` and returns one `CollectionScanGroup`
  /// per leaf folder. See type-level docs for the per-root layout rules.
  static func scanCollections(at rootURL: URL) -> [CollectionScanGroup] {
    let collectionsURL = rootURL.appendingPathComponent("Collections", isDirectory: true)
    guard isDirectory(collectionsURL) else { return [] }

    var results: [CollectionScanGroup] = []

    let favoritesURL = collectionsURL.appendingPathComponent("Favorites", isDirectory: true)
    if isDirectory(favoritesURL) {
      let files = leafFiles(in: favoritesURL)
      if !files.isEmpty {
        results.append(
          CollectionScanGroup(
            kind: .favorites,
            parentPathComponents: [],
            leafName: "Favorites",
            folderURL: favoritesURL,
            files: files))
      }
    }

    let albumsURL = collectionsURL.appendingPathComponent("Albums", isDirectory: true)
    if isDirectory(albumsURL) {
      let entries = childDirectories(of: albumsURL)
      for entry in entries {
        walkAlbumsTree(directory: entry, parentPathComponents: [], into: &results)
      }
    }

    let sharedAlbumsURL = collectionsURL.appendingPathComponent(
      "Shared Albums", isDirectory: true)
    if isDirectory(sharedAlbumsURL) {
      let entries = childDirectories(of: sharedAlbumsURL)
      for entry in entries {
        let files = leafFiles(in: entry)
        if !files.isEmpty {
          results.append(
            CollectionScanGroup(
              kind: .sharedAlbum,
              parentPathComponents: [],
              leafName: entry.lastPathComponent,
              folderURL: entry,
              files: files))
        }
      }
    }

    logger.info("Scanned \(results.count) collection group(s) under Collections/")
    return results
  }

  // MARK: - Albums tree walk

  /// Recursive descent under `Collections/Albums/`. A directory becomes a
  /// leaf as soon as it has any direct files (or a `videos/` child with
  /// files). Otherwise it's a user folder and the walk recurses, pushing
  /// the folder name onto `parentPathComponents`.
  ///
  /// Once a directory is identified as a leaf, non-`videos` subdirectories
  /// at that level are intentionally **not** descended: a real export
  /// layout never nests below an album, so anything found there is foreign
  /// content and emitting it as a phantom sub-album would be wrong.
  private static func walkAlbumsTree(
    directory: URL,
    parentPathComponents: [String],
    into results: inout [CollectionScanGroup]
  ) {
    let files = leafFiles(in: directory)
    if !files.isEmpty {
      results.append(
        CollectionScanGroup(
          kind: .album,
          parentPathComponents: parentPathComponents,
          leafName: directory.lastPathComponent,
          folderURL: directory,
          files: files))
      return
    }

    let subdirs = childDirectories(of: directory).filter {
      $0.lastPathComponent != "videos"
    }
    for subdir in subdirs {
      walkAlbumsTree(
        directory: subdir,
        parentPathComponents: parentPathComponents + [directory.lastPathComponent],
        into: &results)
    }
  }

  // MARK: - File enumeration

  /// Files directly inside `leaf` plus any files inside `leaf/videos/`.
  /// `subfolder` on each `ScannedFile` is stamped accordingly so the
  /// downstream record preserves the file's true on-disk location.
  ///
  /// Year/month are stamped as `0/0` for collection files — the matcher
  /// for collection groups scopes by placement, not by month, so these
  /// fields are unused on the collection side.
  private static func leafFiles(in leaf: URL) -> [BackupScanner.ScannedFile] {
    var files: [BackupScanner.ScannedFile] = []
    enumerateFiles(in: leaf, subfolder: nil, into: &files)
    let videosURL = leaf.appendingPathComponent("videos", isDirectory: true)
    if isDirectory(videosURL) {
      enumerateFiles(in: videosURL, subfolder: "videos", into: &files)
    }
    return files
  }

  /// Enumerates regular files directly inside `directory` (one level).
  /// Mirrors `BackupScanner.appendFiles(in:year:month:subfolder:into:)` but
  /// stamps `year/month = 0` because collection placements don't use them.
  private static func enumerateFiles(
    in directory: URL,
    subfolder: String?,
    into results: inout [BackupScanner.ScannedFile]
  ) {
    let fm = FileManager.default
    guard
      let entries = try? fm.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: [
          .isRegularFileKey, .contentModificationDateKey, .fileSizeKey,
        ],
        options: [.skipsHiddenFiles])
    else { return }

    for fileURL in entries {
      guard isRegularFile(fileURL) else { continue }

      let filename = fileURL.lastPathComponent
      let ext = fileURL.pathExtension
      let stem = (filename as NSString).deletingPathExtension
      let (baseStem, hadSuffix) = BackupScanner.stripCollisionSuffix(from: stem)
      let baseFilename = ext.isEmpty ? baseStem : baseStem + "." + ext

      let resourceValues = try? fileURL.resourceValues(forKeys: [
        .contentModificationDateKey, .fileSizeKey,
      ])

      results.append(
        BackupScanner.ScannedFile(
          url: fileURL,
          year: 0,
          month: 0,
          filename: filename,
          baseFilename: baseFilename,
          hasCollisionSuffix: hadSuffix,
          fileExtension: ext.lowercased(),
          modificationDate: resourceValues?.contentModificationDate,
          fileSize: resourceValues?.fileSize.map(UInt64.init),
          subfolder: subfolder))
    }
  }

  /// Direct child directories of `parent`, in the order `FileManager`
  /// returns them. Hidden entries are skipped.
  private static func childDirectories(of parent: URL) -> [URL] {
    let fm = FileManager.default
    guard
      let entries = try? fm.contentsOfDirectory(
        at: parent,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles])
    else { return [] }
    return entries.filter { isDirectory($0) }
  }

  private static func isDirectory(_ url: URL) -> Bool {
    let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
    return values?.isDirectory == true
  }

  private static func isRegularFile(_ url: URL) -> Bool {
    let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
    return values?.isRegularFile == true
  }
}
