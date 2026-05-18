import Foundation

/// Parsed shape of a candidate `_orig` filename produced by this app.
struct ParsedOriginalCandidate: Equatable {
  /// Stem before the `_orig` marker. Includes any app-added collision suffix that was part
  /// of the group (e.g. "IMG_0001 (1)").
  var groupStem: String
  /// `groupStem` with any trailing collision suffix stripped, used for matching against
  /// original resource stems that the app itself collision-suffixed.
  var canonicalOriginalStem: String
  /// Trailing per-file collision suffix on the `_orig` filename itself (e.g. `(1)` in
  /// "IMG_0001_orig (1).HEIC"). Nil when the `_orig` filename had no added suffix.
  var fileCollisionSuffix: Int?
  /// Extension as it appeared on disk. Preserves casing.
  var fileExtension: String
}

/// Filename rules shared by the export pipeline and the backup scanner so both sides agree
/// about what a `_orig` companion looks like.
enum ExportFilenamePolicy {
  static let originalSuffix = "_orig"

  /// Original-side filename for an asset. Returns `<stem>_orig.<ext>` when the variant is
  /// being paired with an edited variant for the same asset; otherwise returns the bare
  /// stem with the original resource's extension.
  static func originalFilename(stem: String, ext: String, withSuffix: Bool) -> String {
    let resolvedStem = withSuffix ? stem + originalSuffix : stem
    return ext.isEmpty ? resolvedStem : "\(resolvedStem).\(ext)"
  }

  /// Edited-side filename. Always written at `<stem>.<editedExt>` — no suffix.
  static func editedFilename(stem: String, editedResourceFilename: String) -> String {
    let editedExt = (editedResourceFilename as NSString).pathExtension
    return editedExt.isEmpty ? stem : "\(stem).\(editedExt)"
  }

  /// Pure filename parsing: detects the "_orig" marker, strips any final `(N)` collision
  /// suffix, and derives the group and canonical original stems. Returns nil when the
  /// filename is not a `_orig` candidate.
  ///
  /// Does not consult any asset metadata. The backup scanner combines this with fingerprint
  /// data to confirm a `.original` companion classification.
  static func parseOriginalCandidate(filename: String) -> ParsedOriginalCandidate? {
    let ns = filename as NSString
    let ext = ns.pathExtension
    let stem = ns.deletingPathExtension

    let (afterFileCollision, fileCollisionSuffix) = stripTrailingCollisionSuffix(from: stem)

    guard afterFileCollision.hasSuffix(originalSuffix) else { return nil }

    let groupStem = String(afterFileCollision.dropLast(originalSuffix.count))
    guard !groupStem.isEmpty else { return nil }

    let (canonicalOriginalStem, _) = stripTrailingCollisionSuffix(from: groupStem)

    return ParsedOriginalCandidate(
      groupStem: groupStem,
      canonicalOriginalStem: canonicalOriginalStem,
      fileCollisionSuffix: fileCollisionSuffix,
      fileExtension: ext
    )
  }

  /// True when `filename`'s stem (after stripping a trailing collision suffix like ` (1)`)
  /// ends with `_orig`. Used by the sidebar's records-only count heuristic and by the
  /// scanner's `_orig` parser. **Not** used by the asset-aware
  /// `isExported(asset:selection:)`, which consults `asset.hasAdjustments` directly and so
  /// doesn't need filename inspection.
  static func isOrigCompanion(filename: String) -> Bool {
    let ns = filename as NSString
    let stem = ns.deletingPathExtension
    let (afterFileCollision, _) = stripTrailingCollisionSuffix(from: stem)
    guard afterFileCollision.hasSuffix(originalSuffix) else { return false }
    let groupStem = String(afterFileCollision.dropLast(originalSuffix.count))
    return !groupStem.isEmpty
  }

  /// Strips a trailing ` (N)` suffix from a stem. Returns the stripped stem and the parsed
  /// N, or nil when no suffix was present.
  static func stripTrailingCollisionSuffix(from stem: String) -> (stripped: String, suffix: Int?) {
    guard let regex = try? NSRegularExpression(pattern: #" \((\d+)\)$"#) else {
      return (stem, nil)
    }
    let range = NSRange(stem.startIndex..., in: stem)
    guard let match = regex.firstMatch(in: stem, range: range),
      let matchRange = Range(match.range, in: stem),
      let numberRange = Range(match.range(at: 1), in: stem)
    else {
      return (stem, nil)
    }
    let stripped = String(stem[stem.startIndex..<matchRange.lowerBound])
    let number = Int(stem[numberRange])
    return (stripped, number)
  }
}
