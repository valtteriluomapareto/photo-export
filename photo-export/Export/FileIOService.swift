import Foundation
import os

struct FileIOService: FileSystemService {
  private static let logger = Logger(
    subsystem: "com.valtteriluoma.photo-export", category: "FileIO")

  // MARK: - Static API (existing call sites)

  static func moveItemAtomically(from src: URL, to dst: URL) throws {
    let fm = FileManager.default
    if fm.fileExists(atPath: dst.path) {
      throw NSError(
        domain: "Export", code: 2,
        userInfo: [NSLocalizedDescriptionKey: "Destination already exists"])
    }
    try fm.createDirectory(
      at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
    try fm.moveItem(at: src, to: dst)
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

  func moveItemAtomically(from src: URL, to dst: URL) throws {
    try Self.moveItemAtomically(from: src, to: dst)
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

  func removeItem(at url: URL) throws {
    try FileManager.default.removeItem(at: url)
  }

  func copyItem(from src: URL, to dst: URL) throws {
    try FileManager.default.copyItem(at: src, to: dst)
  }
}
