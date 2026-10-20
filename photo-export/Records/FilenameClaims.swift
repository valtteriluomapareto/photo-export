import Foundation
import OSLog

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
/// either may name a file on disk. Names compare as `FilenameKey` does. A claimed name is
/// taken for every other asset or variant, whether or not a file is at it: an existing file
/// there is never adopted, and an empty name is never written.
struct FilenameClaims<Folder: Hashable> {
  private var counts: [Folder: [String: Int]] = [:]

  func count(_ filename: String, in folder: Folder) -> Int {
    counts[folder]?[FilenameKey.key(filename)] ?? 0
  }

  /// `count(filename, in: folder)` without the claims of `own`, the filenames and folders of
  /// the variant records that may reuse the name.
  func count(
    _ filename: String, in folder: Folder,
    excluding own: some Sequence<(filename: String?, folder: Folder)>
  ) -> Int {
    let ownClaims = own.filter {
      $0.folder == folder && $0.filename.map { FilenameKey.sameName($0, filename) } == true
    }
    return count(filename, in: folder) - ownClaims.count
  }

  /// An index filled by `add`, with a debug log of how long that took for `recordCount`
  /// records. Each store builds its index on the main actor.
  static func build(
    recordCount: Int, logger: Logger, _ add: (inout FilenameClaims) -> Void
  ) -> FilenameClaims {
    let started = ContinuousClock.now
    var claims = FilenameClaims()
    add(&claims)
    let elapsed = started.duration(to: .now)
    let milliseconds =
      Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
    logger.debug(
      "Built filename claims for \(recordCount, privacy: .public) records in \(milliseconds, format: .fixed(precision: 1), privacy: .public) ms"
    )
    return claims
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
