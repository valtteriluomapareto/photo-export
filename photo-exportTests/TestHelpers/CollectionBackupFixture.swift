import Foundation
import Photos

@testable import Photo_Export

/// Builders for album trees, collection-folder scans and planted collection files.
enum CollectionBackupFixture {
  static func album(
    _ id: String, _ title: String, in path: [String] = []
  ) -> PhotoCollectionDescriptor {
    PhotoCollectionDescriptor(
      id: "album:\(id)", localIdentifier: id, title: title, kind: .album,
      pathComponents: path, children: [])
  }

  static func folder(
    _ id: String, _ title: String, in path: [String] = [],
    children: [PhotoCollectionDescriptor]
  ) -> PhotoCollectionDescriptor {
    PhotoCollectionDescriptor(
      id: "folder:\(id)", localIdentifier: id, title: title, kind: .folder,
      pathComponents: path, children: children)
  }

  static func sharedAlbum(_ id: String, _ title: String) -> PhotoCollectionDescriptor {
    PhotoCollectionDescriptor(
      id: "shared:\(id)", localIdentifier: id, title: title, kind: .sharedAlbum,
      pathComponents: [], children: [])
  }

  static let favorites = PhotoCollectionDescriptor(
    id: "favorites", localIdentifier: nil, title: "Favorites", kind: .favorites,
    pathComponents: [], children: [])

  /// A fixed instant per asset index, whole seconds apart so the matcher's date window
  /// separates them.
  static func date(_ index: Int) -> Date {
    Date(timeIntervalSince1970: 1_700_000_000 + TimeInterval(index * 3600))
  }

  /// A scanned file that was never on disk; its date aligns with the asset it names, so the
  /// matcher never reads its contents.
  static func file(_ name: String, date: Date?, size: UInt64? = nil) -> BackupScanner.ScannedFile {
    let ext = (name as NSString).pathExtension
    let stem = (name as NSString).deletingPathExtension
    let (base, suffixed) = BackupScanner.stripCollisionSuffix(from: stem)
    return BackupScanner.ScannedFile(
      url: URL(fileURLWithPath: "/nonexistent-collection-fixture/\(name)"),
      year: 0, month: 0, filename: name,
      baseFilename: ext.isEmpty ? base : base + "." + ext,
      hasCollisionSuffix: suffixed, fileExtension: ext.lowercased(),
      modificationDate: date, fileSize: size)
  }

  static func directory(
    _ root: ScannedCollectionDirectory.Root, _ components: [String],
    _ files: [BackupScanner.ScannedFile]
  ) -> ScannedCollectionDirectory {
    ScannedCollectionDirectory(root: root, components: components, files: files)
  }

  /// Writes a file at `<root>/<relativeDirectory><name>` with its modification date set, as
  /// an export would leave it.
  @discardableResult
  static func plant(
    at root: URL, _ relativeDirectory: String, _ name: String, date: Date,
    contents: String = "fake-content"
  ) throws -> URL {
    let directory = root.appendingPathComponent(relativeDirectory, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent(name)
    try Data(contents.utf8).write(to: url)
    try FileManager.default.setAttributes(
      [.modificationDate: date, .creationDate: date], ofItemAtPath: url.path)
    return url
  }

  /// Every regular file under `root`, including hidden staging files, as relative path →
  /// size and modification date. Two equal listings mean nothing was written, moved or
  /// removed.
  static func listing(of root: URL) throws -> [String: String] {
    var result: [String: String] = [:]
    let base = root.resolvingSymlinksInPath().path
    guard
      let enumerator = FileManager.default.enumerator(
        at: root, includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey])
    else { return result }
    for case let url as URL in enumerator {
      let values = try url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey])
      guard values.isRegularFile == true else { continue }
      let path = url.resolvingSymlinksInPath().path
      let relative = String(path.dropFirst(base.count))
      let attributes = try FileManager.default.attributesOfItem(atPath: path)
      let size = (attributes[.size] as? NSNumber)?.intValue ?? -1
      let modified = values.contentModificationDate?.timeIntervalSince1970 ?? -1
      result[relative] = "\(size)@\(modified)"
    }
    return result
  }
}
