import Foundation

/// What `lstat` reports for one directory entry. An existing file is adopted only while all
/// of it is unchanged since its bytes were compared.
struct FileItemIdentity: Equatable, Sendable {
  let isRegularFile: Bool
  /// Hard links to the entry, itself included.
  let linkCount: Int
  let device: Int64
  let inode: UInt64
  let size: Int64
  let modificationSeconds: Int
  let modificationNanoseconds: Int
}

/// A file opened for reading byte ranges. Closed by `close()`, or when released.
protocol FileReadHandle: Sendable {
  /// Up to `length` bytes from `offset`, read off the caller's actor. Fewer only at the end
  /// of the file.
  func read(offset: Int64, length: Int) async throws -> Data
  /// Closes the file; a later `read` throws `EBADF`. Do not call while a `read` is in flight.
  func close()
}

/// Abstracts file system operations for testability.
/// FileIOService conforms in production; tests inject a fake.
protocol FileSystemService: Sendable {
  func moveItemAtomically(from src: URL, to dst: URL) throws
  func applyTimestamps(creationDate: Date, to url: URL)
  func createDirectory(at url: URL, withIntermediateDirectories: Bool) throws
  func fileExists(atPath: String) -> Bool
  /// Does not follow a symbolic link. Nil for non-regular files; throws on lookup errors.
  func regularFileSize(at url: URL) throws -> Int64?
  /// Does not follow a symbolic link. Nil when nothing is at `url`; throws on other lookup errors.
  func itemIdentity(at url: URL) throws -> FileItemIdentity?
  /// The entry's name as its folder stores it, which can differ from `url` in case or
  /// Unicode normalization on volumes that ignore either.
  func storedName(at url: URL) throws -> String
  /// Opens the file at `url` for reading without following a symbolic link. One handle
  /// serves a whole comparison, so a network volume is not asked to open the file per read.
  /// `bypassingCache` keeps the bytes read out of the buffer cache where the volume allows.
  func openForReading(at url: URL, bypassingCache: Bool) throws -> any FileReadHandle
  func removeItem(at url: URL) throws
  /// Copies a file from `src` to `dst`. On APFS volumes (typical for the user's chosen
  /// destination), `FileManager.copyItem(at:to:)` performs copy-on-write at the
  /// filesystem layer, so duplicates use no extra bytes until either copy is modified.
  /// On non-APFS destinations this is a real copy. The reuse-source path in
  /// `VariantExporter` invokes this synchronous primitive on an explicit utility
  /// worker and awaits physical completion before releasing destination access.
  func copyItem(from src: URL, to dst: URL) throws
}
