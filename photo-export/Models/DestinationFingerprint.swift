import CryptoKit
import Foundation

/// How confident we are that `DestinationFingerprint.id` will identify the same destination
/// across app launches and bookmark refreshes.
enum DestinationIdentityConfidence: String, Codable, Equatable, Sendable {
  /// Volume UUID was available; the id is stable across mount/unmount, drive-rename, and
  /// bookmark refresh.
  case high

  /// No volume UUID was available; the id falls back to a less-stable component
  /// (`URLResourceValues.volumeIdentifier`'s description). The safety gate must require
  /// explicit user confirmation before automatic export when confidence is `.low`, because
  /// the identifier may not survive a reboot.
  case low
}

/// Stable, persistable identity for a destination folder. Wraps the existing record-store id
/// derivation in a structured value so identity-confidence and migration-conflict handling are
/// first-class instead of implicit in a hex string.
///
/// `id` is the SHA-256 hex digest used as the per-destination directory name in the App Support
/// record store. The hash bytes are bug-for-bug compatible with the pre-Phase-0 derivation in
/// `ExportDestinationManager.computeDestinationId(for:)` so existing record stores keep working
/// without a migration. The new surface is the structured fields plus `identityConfidence`.
struct DestinationFingerprint: Codable, Hashable, Sendable {
  /// Schema version of the fingerprint format. Bumping this is a deliberate breaking change
  /// that requires a migration plan; v1 reproduces the existing on-disk id derivation.
  let schemaVersion: Int
  let volumeUUIDString: String?
  let volumeRootPath: String?
  let relativePathFromVolumeRoot: String
  /// Canonical absolute path under `standardizedFileURL`. Useful for diagnostics and display;
  /// not used as the primary identity component when a volume UUID is available.
  let standardizedPath: String
  let identityConfidence: DestinationIdentityConfidence
  let id: String

  static let currentSchemaVersion = 1
}

/// In-memory hints collected at fingerprint computation time. Never persisted —
/// `URLResourceValues.fileResourceIdentifier` and `volumeIdentifier` are not stable across
/// launches and only support same-session comparisons and diagnostics.
struct LiveDestinationIdentityHints: Sendable {
  let fileResourceIdentifier: String?
  let volumeIdentifier: String?
}

extension DestinationFingerprint {
  /// Computes the fingerprint for a folder URL. Returns `nil` when no usable identity
  /// component can be read (typically because the volume is unmounted).
  static func compute(for url: URL) -> (
    fingerprint: DestinationFingerprint, hints: LiveDestinationIdentityHints
  )? {
    let resolved = url.resolvingSymlinksInPath()
    let keys: Set<URLResourceKey> = [
      .volumeUUIDStringKey, .volumeIdentifierKey, .volumeURLKey, .fileResourceIdentifierKey,
    ]
    guard let values = try? resolved.resourceValues(forKeys: keys) else { return nil }

    let volumeRoot = values.volume?.standardizedFileURL.path ?? ""
    let canonicalPath = resolved.standardizedFileURL.path

    var relativePath = canonicalPath
    if !volumeRoot.isEmpty, volumeRoot != "/", canonicalPath.hasPrefix(volumeRoot) {
      relativePath = String(canonicalPath.dropFirst(volumeRoot.count))
    }
    if !relativePath.hasPrefix("/") {
      relativePath = "/" + relativePath
    }

    let hints = LiveDestinationIdentityHints(
      fileResourceIdentifier: values.fileResourceIdentifier.map { String(describing: $0) },
      volumeIdentifier: values.volumeIdentifier.map { String(describing: $0) }
    )

    let confidence: DestinationIdentityConfidence
    let identityKey: String

    if let uuid = values.volumeUUIDString {
      confidence = .high
      identityKey = uuid
    } else if let identifier = values.volumeIdentifier {
      // Same-session-only fallback. Marked low-confidence so the safety gate can require
      // explicit user confirmation before any automatic export.
      confidence = .low
      identityKey = String(describing: identifier)
    } else {
      return nil
    }

    let combined = identityKey + "\u{0000}" + relativePath
    let digest = SHA256.hash(data: Data(combined.utf8))
    let id = digest.map { String(format: "%02x", $0) }.joined()

    return (
      DestinationFingerprint(
        schemaVersion: currentSchemaVersion,
        volumeUUIDString: values.volumeUUIDString,
        volumeRootPath: volumeRoot.isEmpty ? nil : volumeRoot,
        relativePathFromVolumeRoot: relativePath,
        standardizedPath: canonicalPath,
        identityConfidence: confidence,
        id: id
      ),
      hints
    )
  }
}
