import Foundation

/// How two filenames are compared for claims and adoption: case-folded and in NFC, as the
/// volumes an export lands on usually do.
enum FilenameKey {
  /// The comparison form of `filename`.
  static func key(_ filename: String) -> String {
    if filename.utf8.allSatisfy({ $0 < 0x80 }) { return filename.lowercased() }
    return filename.precomposedStringWithCanonicalMapping
      .folding(options: .caseInsensitive, locale: nil)
      .precomposedStringWithCanonicalMapping
  }

  static func sameName(_ lhs: String, _ rhs: String) -> Bool {
    key(lhs) == key(rhs)
  }
}

/// The filenames that variant records name, per folder, counted so each record adds and
/// removes its own claim. Every status counts, including in-progress and failed, since
/// either may name a file on disk. Names compare as `FilenameKey` does, so an existing file
/// another record names is never adopted for a different asset or variant.
struct FilenameClaims<Folder: Hashable> {
  private var counts: [Folder: [String: Int]] = [:]

  func count(_ filename: String, in folder: Folder) -> Int {
    counts[folder]?[FilenameKey.key(filename)] ?? 0
  }

  /// `count(filename, in: folder)` without the claim of `own`, one record's filename and
  /// folder, when that is one of them.
  func count(
    _ filename: String, in folder: Folder, excluding own: (filename: String?, folder: Folder)?
  ) -> Int {
    let total = count(filename, in: folder)
    guard let own, own.folder == folder, let ownName = own.filename,
      FilenameKey.sameName(ownName, filename)
    else { return total }
    return total - 1
  }

  mutating func add(_ filename: String?, in folder: Folder) {
    guard let filename, !filename.isEmpty else { return }
    counts[folder, default: [:]][FilenameKey.key(filename), default: 0] += 1
  }

  mutating func remove(_ filename: String?, in folder: Folder) {
    guard let filename, !filename.isEmpty else { return }
    let key = FilenameKey.key(filename)
    guard let current = counts[folder]?[key] else { return }
    if current > 1 {
      counts[folder]?[key] = current - 1
    } else {
      counts[folder]?.removeValue(forKey: key)
      if counts[folder]?.isEmpty == true { counts.removeValue(forKey: folder) }
    }
  }

  mutating func removeAll() {
    counts = [:]
  }
}
