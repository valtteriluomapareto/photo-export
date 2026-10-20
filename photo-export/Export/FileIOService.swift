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
    /// Runs immediately before each commit attempt, after any existence check: twice when
    /// an exclusive rename is rejected with `ENOTSUP`/`ENOSYS` and check-then-move follows.
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
  /// getattrlist(2) documents `EINVAL` for volume attributes on a path that is not the
  /// volume root, but XNU answers for any path on the volume;
  /// `scratchVolumeAdvertisesExclusiveRenameAndAMissingFolderDoesNot` covers that.
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
    guard status == 0 else {
      let code = errno
      logger.debug(
        "getattrlist failed for \(directory.path, privacy: .public): errno \(code, privacy: .public)"
      )
      return false
    }
    return advertisesExclusiveRename(reply.capabilities)
  }

  /// True when the interfaces word marks `VOL_CAP_INT_RENAME_EXCL` both valid and supported.
  static func advertisesExclusiveRename(_ caps: vol_capabilities_attr_t) -> Bool {
    let offset = Int(VOL_CAPABILITIES_INTERFACES) * MemoryLayout<UInt32>.size
    let bit = UInt32(VOL_CAP_INT_RENAME_EXCL)
    let valid = withUnsafeBytes(of: caps.valid) {
      $0.load(fromByteOffset: offset, as: UInt32.self)
    }
    let supported = withUnsafeBytes(of: caps.capabilities) {
      $0.load(fromByteOffset: offset, as: UInt32.self)
    }
    return valid & bit != 0 && supported & bit != 0
  }

  private static let unsupportedVolumesLogged = OSAllocatedUnfairLock(initialState: Set<dev_t>())

  /// Logs the first rejected exclusive rename per volume in this process.
  private static func noteUnsupportedExclusiveRename(in folder: URL, code: Int32) {
    var info = stat()
    let device = stat(folder.path, &info) == 0 ? info.st_dev : -1
    let isFirst = unsupportedVolumesLogged.withLock { $0.insert(device).inserted }
    guard isFirst else { return }
    logger.notice(
      "Exclusive rename rejected in \(folder.path, privacy: .public) (errno \(code, privacy: .public)); checking, then moving on this volume"
    )
  }

  /// The collision refusal, `Export` code 2. Also reported when an existing file stops
  /// being the one an export planned to adopt.
  static func isDestinationExists(_ error: Error) -> Bool {
    let error = error as NSError
    return error.domain == "Export" && error.code == 2
  }

  static func destinationExistsError() -> NSError {
    NSError(
      domain: "Export", code: 2,
      userInfo: [NSLocalizedDescriptionKey: "Destination already exists"])
  }

  // MARK: - Timestamps

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
  /// so the refusal and the move are one step. Elsewhere an existence check precedes
  /// `FileManager.moveItem`, which refuses an existing file itself; a file that appears
  /// inside `moveItem`, between its own check and its rename, can still be replaced there.
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
      case ENOTSUP, ENOSYS:
        // The volume advertised the flag but rejected it. A failed rename leaves the stage
        // in place, so the check-then-move path below can still commit it.
        Self.noteUnsupportedExclusiveRename(in: folder, code: code)
      default:
        Self.logger.error(
          "Exclusive rename failed in \(folder.path, privacy: .public): errno \(code, privacy: .public)"
        )
        throw NSError(
          domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [NSFilePathErrorKey: dst.path])
      }
    } else {
      Self.logger.debug(
        "No exclusive rename on the volume of \(folder.path, privacy: .public); checking, then moving"
      )
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

  func itemIdentity(at url: URL) throws -> FileItemIdentity? {
    var info = stat()
    let status = url.withUnsafeFileSystemRepresentation { path -> Int32 in
      guard let path else {
        errno = EINVAL
        return -1
      }
      return lstat(path, &info)
    }
    guard status == 0 else {
      let code = errno
      if code == ENOENT || code == ENOTDIR { return nil }
      throw Self.posixError(code, url)
    }
    return FileItemIdentity(
      isRegularFile: info.st_mode & S_IFMT == S_IFREG, linkCount: Int(info.st_nlink),
      device: Int64(info.st_dev),
      inode: UInt64(info.st_ino), size: Int64(info.st_size),
      modificationSeconds: Int(info.st_mtimespec.tv_sec),
      modificationNanoseconds: Int(info.st_mtimespec.tv_nsec))
  }

  /// Reads `ATTR_CMN_NAME`, which reports the name the folder stores rather than the
  /// spelling used to look the entry up. A symbolic link is not followed.
  func storedName(at url: URL) throws -> String {
    var request = attrlist()
    request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
    request.commonattr = attrgroup_t(ATTR_CMN_NAME)
    let referenceOffset = MemoryLayout<UInt32>.size
    var reply = [UInt8](
      repeating: 0, count: referenceOffset + MemoryLayout<attrreference_t>.size + Int(MAXPATHLEN))
    let status = url.withUnsafeFileSystemRepresentation { path -> Int32 in
      guard let path else {
        errno = EINVAL
        return -1
      }
      return reply.withUnsafeMutableBytes {
        getattrlist(path, &request, $0.baseAddress, $0.count, UInt32(FSOPT_NOFOLLOW))
      }
    }
    guard status == 0 else { throw Self.posixError(errno, url) }
    return try reply.withUnsafeBytes { raw in
      let reference = raw.loadUnaligned(fromByteOffset: referenceOffset, as: attrreference_t.self)
      let start = referenceOffset + Int(reference.attr_dataoffset)
      // The length counts the terminating NUL.
      let length = Int(reference.attr_length) - 1
      guard start >= referenceOffset, length > 0, start + length <= raw.count,
        let name = String(bytes: raw[start..<(start + length)], encoding: .utf8)
      else {
        throw Self.posixError(EIO, url)
      }
      return name
    }
  }

  func openForReading(at url: URL, bypassingCache: Bool) throws -> any FileReadHandle {
    let descriptor = url.withUnsafeFileSystemRepresentation { path -> Int32 in
      guard let path else {
        errno = EINVAL
        return -1
      }
      return open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    }
    guard descriptor >= 0 else { throw Self.posixError(errno, url) }
    // Advisory: a volume that ignores it still reads correctly.
    if bypassingCache { _ = fcntl(descriptor, F_NOCACHE, 1) }
    return DescriptorReadHandle(descriptor: descriptor, url: url)
  }

  /// Reads with `pread` on a utility worker. The descriptor closes once.
  private final class DescriptorReadHandle: FileReadHandle, @unchecked Sendable {
    private let descriptor: Int32
    private let url: URL
    private let isClosed = OSAllocatedUnfairLock(initialState: false)

    init(descriptor: Int32, url: URL) {
      self.descriptor = descriptor
      self.url = url
    }

    deinit { close() }

    func read(offset: Int64, length: Int) async throws -> Data {
      try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global(qos: .utility).async { [self] in
          continuation.resume(with: Result { try readNow(offset: offset, length: length) })
        }
      }
    }

    func close() {
      let wasOpen = isClosed.withLock { closed in
        defer { closed = true }
        return !closed
      }
      if wasOpen { Darwin.close(descriptor) }
    }

    private func readNow(offset: Int64, length: Int) throws -> Data {
      var data = Data(count: length)
      var filled = 0
      try data.withUnsafeMutableBytes { buffer in
        // A network volume may return fewer bytes than asked for before the end of the file.
        while filled < length {
          let count = pread(
            descriptor, buffer.baseAddress! + filled, length - filled,
            off_t(offset) + off_t(filled))
          if count < 0 {
            if errno == EINTR { continue }
            throw FileIOService.posixError(errno, url)
          }
          if count == 0 { break }
          filled += count
        }
      }
      data.count = filled
      return data
    }
  }

  private static func posixError(_ code: Int32, _ url: URL) -> NSError {
    NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [NSFilePathErrorKey: url.path])
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
