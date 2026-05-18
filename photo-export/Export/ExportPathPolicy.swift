import Foundation

/// Rules for turning unsanitized album titles and folder names into safe path components.
///
/// Deliberately minimal — the goal is "produce a usable path on common filesystems without
/// surprising the user." Edge cases the policy does not handle:
///
/// - Reserved Windows/exFAT names (`AUX`, `CON`, `LPT1`): vanishingly rare album names; if a
///   user hits one and exports to a Windows-formatted drive, the OS refuses the directory
///   creation and the placement-level error path surfaces it once.
/// - Cross-tree case-fold collisions: sibling-only collisions (two albums with the same name
///   under the same parent folder) are handled by `ExportPlacementResolver`'s suffix
///   disambiguation; cross-tree case-only collisions are not detected.
/// - Component length: common filesystems allow 255 bytes per component; album titles longer
///   than that are not realistic and are passed through unchanged.
enum ExportPathPolicy {
  /// Path separators plus Windows/exFAT bans. Each gets replaced with `_`. Control
  /// characters (`0x00…0x1F`, `0x7F`) are also replaced.
  private static let bannedScalars: Set<Unicode.Scalar> = [
    "/", "\\", "<", ">", ":", "\"", "|", "?", "*",
  ]

  /// Returns a path-safe rendering of `component` suitable for use as a single directory
  /// name. Never returns an empty string — empty input or whitespace-only input returns
  /// `"_"` so the caller can always construct a valid path component.
  ///
  /// Order of operations matters:
  /// 1. NFC normalize (so combining-mark compositions trim/strip cleanly).
  /// 2. Trim leading/trailing whitespace and newlines. Whitespace control characters at the
  ///    edges (`\t`, `\n`, etc.) disappear here rather than becoming `_` underscores.
  /// 3. Strip trailing dots so `"Family."` becomes `"Family"`.
  /// 4. If now empty, or exactly `"."`/`".."`, return `"_"` (defense in depth against
  ///    `..` traversal; the destination's relative-path validator is the primary guard).
  /// 5. Replace any remaining banned characters and interior control characters with `_`
  ///    (path separators, Windows/exFAT bans, `0x00…0x1F`, `0x7F`).
  static func sanitizeComponent(_ component: String) -> String {
    if component.isEmpty { return "_" }

    // Step 1: NFC normalize.
    let normalized = component.precomposedStringWithCanonicalMapping

    // Step 2: trim leading/trailing whitespace and newlines.
    var trimmed = normalized.trimmingCharacters(in: .whitespacesAndNewlines)

    // Step 3: strip trailing dots.
    while trimmed.hasSuffix(".") { trimmed.removeLast() }

    if trimmed.isEmpty { return "_" }
    if trimmed == "." || trimmed == ".." { return "_" }

    // Step 4: replace remaining banned scalars and interior control chars with `_`.
    var replaced = String.UnicodeScalarView()
    replaced.reserveCapacity(trimmed.unicodeScalars.count)
    for scalar in trimmed.unicodeScalars {
      if scalar.value <= 0x1F || scalar.value == 0x7F || bannedScalars.contains(scalar) {
        replaced.append(Unicode.Scalar("_"))
      } else {
        replaced.append(scalar)
      }
    }
    return String(replaced)
  }
}
