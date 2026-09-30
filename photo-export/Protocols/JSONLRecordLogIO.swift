import Darwin
import Foundation

/// The two disk operations whose failures must reach the composing record store. Keeping
/// this seam at the log boundary lets tests force open, write, and sync failures without
/// changing the snapshot replacement algorithm.
protocol JSONLRecordLogIO: Sendable {
  func readIfPresent(at url: URL) throws -> Data?
  func openForAppending(at url: URL) throws -> FileHandle
  func write(_ data: Data, to handle: FileHandle) throws
  func synchronize(_ handle: FileHandle) throws
}

struct ProductionJSONLRecordLogIO: JSONLRecordLogIO {
  func readIfPresent(at url: URL) throws -> Data? {
    do {
      return try Data(contentsOf: url)
    } catch {
      if Self.isMissingFile(error) { return nil }
      throw error
    }
  }

  func openForAppending(at url: URL) throws -> FileHandle {
    let fd = open(url.path, O_WRONLY | O_CREAT | O_APPEND, 0o600)
    guard fd >= 0 else { throw Self.posixError(for: url) }
    return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
  }

  func write(_ data: Data, to handle: FileHandle) throws {
    try handle.write(contentsOf: data)
  }

  func synchronize(_ handle: FileHandle) throws {
    try handle.synchronize()
  }

  private static func isMissingFile(_ error: Error) -> Bool {
    let nsError = error as NSError
    if nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileReadNoSuchFileError {
      return true
    }
    if nsError.domain == NSPOSIXErrorDomain && nsError.code == ENOENT { return true }
    if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
      return isMissingFile(underlying)
    }
    return false
  }

  private static func posixError(for url: URL) -> NSError {
    NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: url.path])
  }
}
