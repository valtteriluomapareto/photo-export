import Darwin
import Foundation
import os

struct FileIOService: FileSystemService, AtomicFileReplacing {
  private static let logger = Logger(
    subsystem: "com.valtteriluoma.photo-export", category: "FileIO")

  /// Renames `source` to `destination` with `renamex_np` flags. Returns 0 on success,
  /// otherwise the `errno` the call left.
  typealias Renamer = @Sendable (_ source: URL, _ destination: URL, _ flags: UInt32) -> Int32
  /// Whether the volume holding an existing directory advertises an exclusive rename.
  typealias ExclusiveRenameCapability = @Sendable (_ directory: URL) -> Bool

  /// Test hooks around the final commit.
  struct Hooks: Sendable {
    /// Runs immediately before the call that commits the file, after any existence check.
    var beforeCommit: (@Sendable (_ source: URL, _ destination: URL) throws -> Void)?

    init(beforeCommit: (@Sendable (_ source: URL, _ destination: URL) throws -> Void)? = nil) {
      self.beforeCommit = beforeCommit
    }
  }

  private let renamer: Renamer
  private let supportsExclusiveRename: ExclusiveRenameCapability
  private let hooks: Hooks

  init(
    renamer: @escaping Renamer = FileIOService.systemRename,
    capability: @escaping ExclusiveRenameCapability = FileIOService.volumeSupportsExclusiveRename,
    hooks: Hooks = Hooks()
  ) {
    self.renamer = renamer
    self.supportsExclusiveRename = capability
    self.hooks = hooks
  }

  static let systemRename: Renamer = { source, destination, flags in
    source.withUnsafeFileSystemRepresentation { sourcePath in
      destination.withUnsafeFileSystemRepresentation { destinationPath in
        guard let sourcePath, let destinationPath else { return EINVAL }
        return renamex_np(sourcePath, destinationPath, flags) == 0 ? 0 : errno
      }
    }
  }

  /// Reads `VOL_CAP_INT_RENAME_EXCL` from the volume's interface capabilities. A volume
  /// that cannot be queried, or does not mark the bit valid, is treated as not capable.
  static let volumeSupportsExclusiveRename: ExclusiveRenameCapability = { directory in
    struct VolumeCapabilities {
      var length: UInt32 = 0
      var capabilities = vol_capabilities_attr_t()
    }
    var request = attrlist()
    request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
    request.volattr = attrgroup_t(ATTR_VOL_INFO) | attrgroup_t(ATTR_VOL_CAPABILITIES)
    var reply = VolumeCapabilities()
    let status = directory.withUnsafeFileSystemRepresentation { path -> Int32 in
      guard let path else { return -1 }
      return withUnsafeMutableBytes(of: &reply) {
        getattrlist(path, &request, $0.baseAddress, $0.count, 0)
      }
    }
    guard status == 0 else { return false }
    let index = Int(VOL_CAPABILITIES_INTERFACES)
    let bit = UInt32(VOL_CAP_INT_RENAME_EXCL)
    let valid = withUnsafeBytes(of: reply.capabilities.valid) {
      $0.load(fromByteOffset: index * MemoryLayout<UInt32>.size, as: UInt32.self)
    }
    let supported = withUnsafeBytes(of: reply.capabilities.capabilities) {
      $0.load(fromByteOffset: index * MemoryLayout<UInt32>.size, as: UInt32.self)
    }
    return valid & bit != 0 && supported & bit != 0
  }

  private static func destinationExistsError() -> NSError {
    NSError(
      domain: "Export", code: 2,
      userInfo: [NSLocalizedDescriptionKey: "Destination already exists"])
  }

  // MARK: - Static API (existing call sites)

  static func moveItemAtomically(from src: URL, to dst: URL) throws {
    try FileIOService().moveItemAtomically(from: src, to: dst)
  }

  static func applyTimestamps(creationDate: Date, to url: URL) {
    do {
      var values = URLResourceValues()
      values.creationDate = creationDate
      values.contentModificationDate = creationDate
      var mutableURL = url
      try mutableURL.setResourceValues(values)
    } catch {
      Self.logger.error(
        "Failed setting URLResourceValues timestamps: \(error.localizedDescription, privacy: .public)"
      )
    }
    do {
      try FileManager.default.setAttributes(
        [
          .creationDate: creationDate,
          .modificationDate: creationDate,
        ], ofItemAtPath: url.path)
    } catch {
      Self.logger.error(
        "Failed setting FileManager attributes timestamps: \(error.localizedDescription, privacy: .public)"
      )
    }
  }

  // MARK: - FileSystemService protocol (instance methods)

  /// Commits a staged file at its final name and never replaces an existing file there.
  /// A volume that advertises an exclusive rename commits with `renamex_np(RENAME_EXCL)`,
  /// so the refusal and the move are one step. Elsewhere the existence check precedes
  /// `FileManager.moveItem`, which also refuses an existing file; a file created between
  /// the two can still be lost to a non-atomic move on those volumes.
  func moveItemAtomically(from src: URL, to dst: URL) throws {
    let fm = FileManager.default
    let folder = dst.deletingLastPathComponent()
    try fm.createDirectory(at: folder, withIntermediateDirectories: true)
    if supportsExclusiveRename(folder) {
      try hooks.beforeCommit?(src, dst)
      let code = renamer(src, dst, UInt32(RENAME_EXCL))
      switch code {
      case 0:
        return
      case EEXIST:
        throw Self.destinationExistsError()
      default:
        throw NSError(
          domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [NSFilePathErrorKey: dst.path])
      }
    }
    if fm.fileExists(atPath: dst.path) {
      throw Self.destinationExistsError()
    }
    try hooks.beforeCommit?(src, dst)
    do {
      try fm.moveItem(at: src, to: dst)
    } catch let error as CocoaError where error.code == .fileWriteFileExists {
      throw Self.destinationExistsError()
    }
  }

  func applyTimestamps(creationDate: Date, to url: URL) {
    Self.applyTimestamps(creationDate: creationDate, to: url)
  }

  func createDirectory(at url: URL, withIntermediateDirectories: Bool) throws {
    try FileManager.default.createDirectory(
      at: url, withIntermediateDirectories: withIntermediateDirectories)
  }

  func fileExists(atPath path: String) -> Bool {
    FileManager.default.fileExists(atPath: path)
  }

  func regularFileSize(at url: URL) throws -> Int64? {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    guard attributes[.type] as? FileAttributeType == .typeRegular else { return nil }
    return (attributes[.size] as? NSNumber)?.int64Value
  }

  func removeItem(at url: URL) throws {
    try FileManager.default.removeItem(at: url)
  }

  func copyItem(from src: URL, to dst: URL) throws {
    try FileManager.default.copyItem(at: src, to: dst)
  }

  /// Only for replaceable persistence files. Exported media must continue to use
  /// `moveItemAtomically`, which refuses to overwrite an existing destination.
  func replaceItemAtomically(from source: URL, to destination: URL) throws {
    guard rename(source.path, destination.path) == 0 else {
      let code = errno
      throw NSError(
        domain: NSPOSIXErrorDomain, code: Int(code),
        userInfo: [NSFilePathErrorKey: destination.path])
    }
  }
}
