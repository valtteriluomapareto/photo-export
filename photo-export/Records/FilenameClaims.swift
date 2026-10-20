import Foundation

/// The filenames that variant records name, per folder, counted so each record adds and
/// removes its own claim. Every status counts, including in-progress and failed, since
/// either may name a file on disk. Names compare case-folded and in NFC, as the volumes an
/// export lands on usually do, so an existing file another record names is never adopted
/// for a different asset or variant.
struct FilenameClaims<Folder: Hashable> {
  private var counts: [Folder: [String: Int]] = [:]

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

  func count(_ filename: String, in folder: Folder) -> Int {
    counts[folder]?[Self.key(filename)] ?? 0
  }

  mutating func add(_ filename: String?, in folder: Folder) {
    guard let filename, !filename.isEmpty else { return }
    counts[folder, default: [:]][Self.key(filename), default: 0] += 1
  }

  mutating func remove(_ filename: String?, in folder: Folder) {
    guard let filename, !filename.isEmpty else { return }
    let key = Self.key(filename)
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
