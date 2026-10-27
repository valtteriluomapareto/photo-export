import Darwin
import Foundation
import os

/// App-owned source inputs stay on local temporary storage; JPEG stages stay at the destination.
final class LocalHEICStorage: Sendable {
  struct Failure: Error, LocalizedError {
    let detail: String
    var errorDescription: String? {
      "HEIC conversion could not use local temporary storage: \(detail)"
    }
  }

  private static let logger = Logger.app(.imageConverter)
  private let root: URL
  private let directory: URL
  private let processID: Int32
  private let io: any DestinationIOExecuting
  private let capacity: @Sendable (URL) throws -> Int64?
  private let processIsAlive: @Sendable (Int32) -> Bool

  init(
    root: URL, processID: Int32 = getpid(),
    capacity: @escaping @Sendable (URL) throws -> Int64? = { url in
      try url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        .volumeAvailableCapacityForImportantUsage
    },
    processIsAlive: @escaping @Sendable (Int32) -> Bool = { pid in
      kill(pid, 0) == 0 || errno != ESRCH
    }
  ) {
    self.root = root
    self.processID = processID
    self.directory = root.appendingPathComponent("process-\(processID)-\(UUID().uuidString)")
    self.capacity = capacity
    self.processIsAlive = processIsAlive
    self.io = DestinationIO(queue: DispatchQueue(label: "photo-export.local-heic", qos: .utility))
  }

  static func production() -> LocalHEICStorage {
    LocalHEICStorage(
      root: URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("photo-export-heic", isDirectory: true))
  }

  func allocate(sourceBytes: Int64?) async throws -> URL {
    do {
      return try await io.run { [self] in
        try prepareRoot()
        sweep()
        // This is a preflight, not a reservation. The writer still handles real exhaustion.
        let required = max(sourceBytes ?? 0, 1_048_576)
        if let available = try? capacity(root), available < required {
          throw Failure(detail: "Not enough free space on this Mac.")
        }
        try FileManager.default.createDirectory(
          at: directory, withIntermediateDirectories: true,
          attributes: [.posixPermissions: 0o700])
        return directory.appendingPathComponent(".photo-export-\(UUID().uuidString).heic-source")
      }
    } catch { throw Self.localizing(error) }
  }

  func remove(_ url: URL) async {
    guard
      url.deletingLastPathComponent().standardizedFileURL.path == directory.standardizedFileURL.path
    else { return }
    await io.run {
      do {
        if FileManager.default.fileExists(atPath: url.path) {
          try FileManager.default.removeItem(at: url)
        }
      } catch {
        Self.logger.warning(
          "Could not remove local HEIC input: \(error.localizedDescription, privacy: .public)")
      }
    }
  }

  func sweepAbandoned() async {
    await io.run { [self] in
      do {
        try prepareRoot()
        sweep()
      } catch {
        Self.logger.warning(
          "Could not sweep local HEIC inputs: \(error.localizedDescription, privacy: .public)")
      }
    }
  }

  private func prepareRoot() throws {
    var info = stat()
    if lstat(root.path, &info) == 0 {
      guard info.st_mode & S_IFMT == S_IFDIR else {
        throw Failure(detail: "The temporary input folder is not a directory.")
      }
    } else if errno != ENOENT {
      throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
    try FileManager.default.createDirectory(
      at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
  }

  private func sweep() {
    guard
      let children = try? FileManager.default.contentsOfDirectory(
        at: root, includingPropertiesForKeys: nil)
    else { return }
    for child in children {
      let name = child.lastPathComponent
      guard name.hasPrefix("process-"), let separator = name.dropFirst(8).firstIndex(of: "-"),
        let pid = Int32(name[name.index(name.startIndex, offsetBy: 8)..<separator]), pid > 0,
        UUID(uuidString: String(name[name.index(after: separator)...])) != nil,
        pid != processID, !processIsAlive(pid)
      else { continue }
      var info = stat()
      guard lstat(child.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { continue }
      do { try FileManager.default.removeItem(at: child) } catch {
        Self.logger.warning(
          "Could not remove abandoned HEIC inputs: \(error.localizedDescription, privacy: .public)")
      }
    }
  }

  /// Local filesystem failures must not diagnose the user's export destination as full or missing.
  static func localizing(_ error: Error) -> Error {
    if error is Failure || error is CancellationError { return error }
    let ns = error as NSError
    let localCodes: [Int32] = [ENOSPC, EACCES, EPERM, EROFS, ENOENT, ENOTDIR, EIO]
    let local: Bool
    switch ns.domain {
    case NSPOSIXErrorDomain:
      local = localCodes.contains(Int32(ns.code))
    case NSCocoaErrorDomain:
      local =
        [
          NSFileWriteOutOfSpaceError, NSFileWriteNoPermissionError,
          NSFileReadNoPermissionError, NSFileNoSuchFileError, NSFileReadNoSuchFileError,
          NSFileWriteVolumeReadOnlyError,
        ].contains(ns.code)
        || {
          guard let cause = ns.userInfo[NSUnderlyingErrorKey] as? NSError,
            cause.domain == NSPOSIXErrorDomain
          else { return false }
          return localCodes.contains(Int32(cause.code))
        }()
    default: local = false
    }
    return local ? Failure(detail: ns.localizedDescription) : error
  }
}
