import CryptoKit
import Foundation
import os

/// How confident we are that `DestinationFingerprint.id` will identify the same destination
/// across app launches and bookmark refreshes.
enum DestinationIdentityConfidence: String, Codable, Equatable, Sendable {
  /// Volume UUID was available; the id is stable across mount/unmount, drive-rename, and
  /// bookmark refresh.
  case high

  /// No volume UUID was available; the id falls back to the canonical/standardized path.
  /// The safety gate must require explicit user confirmation before automatic export when
  /// confidence is `.low`, because moving the same folder to a different absolute path
  /// would change the id (the volume UUID would have stabilized that case).
  case low
}

/// Stable, persistable identity for a destination folder. Wraps record-store id derivation in
/// a structured value so identity-confidence and migration-conflict handling are first-class
/// instead of implicit in a hex string.
///
/// `id` is a SHA-256 hex digest used as the per-destination directory name in the App Support
/// record store. For `.high` confidence (volume UUID available) the bytes are bug-for-bug
/// compatible with the pre-Phase-0 derivation in
/// `ExportDestinationManager.computeDestinationId(for:)`, so existing record stores keep
/// working without a migration. For `.low` confidence the bytes are the digest of the
/// canonical/standardized path only — the plan explicitly forbids encoding
/// `URLResourceValues.volumeIdentifier` (a same-session-only token) as the primary identity.
///
/// Migration note: a small number of pre-Phase-0 users with low-confidence drives (no volume
/// UUID — exFAT external volumes, network shares) had their record store keyed by a digest
/// that *included* `volumeIdentifier`. After this change those record stores appear orphaned
/// at `<oldId>/`. The plan's `ExportRecordsDirectoryCoordinator`-level multi-legacy-id
/// migration is a Phase 0b follow-up; until then affected users would need to re-run Import
/// Existing Backup. APFS users (high confidence) are unaffected.
struct DestinationFingerprint: Codable, Hashable, Sendable {
  /// Schema version of the fingerprint format. Bumping this is a deliberate breaking change
  /// that requires a migration plan; v1 reproduces the existing high-confidence id derivation.
  let schemaVersion: Int
  let volumeUUIDString: String?
  let volumeRootPath: String?
  let relativePathFromVolumeRoot: String
  /// Canonical absolute path under `standardizedFileURL`. Useful for diagnostics, display,
  /// and the low-confidence id fallback.
  let standardizedPath: String
  let identityConfidence: DestinationIdentityConfidence

  static let currentSchemaVersion = 1

  /// Persisted dictionary keys. `id` is intentionally excluded — it is derived from the
  /// other fields and therefore reproducible from any decoded fingerprint, while keeping it
  /// out of the persisted form lets future schema bumps re-derive without a migration.
  private enum CodingKeys: String, CodingKey {
    case schemaVersion
    case volumeUUIDString
    case volumeRootPath
    case relativePathFromVolumeRoot
    case standardizedPath
    case identityConfidence
  }

  /// SHA-256 hex digest used as the per-destination record-store directory name. Derived
  /// purely from the persistent components, not stored, so a future `schemaVersion` bump can
  /// change the byte layout without invalidating decoded values.
  var id: String {
    let identityKey: String
    switch identityConfidence {
    case .high:
      // Plan-compliant high-confidence input: volume UUID + relative path within the volume.
      identityKey = volumeUUIDString ?? ""
    case .low:
      // Plan-compliant low-confidence input: canonical/standardized path only. Volume
      // identifier is intentionally absent; it is a same-session-only hint.
      identityKey = ""
    }
    let pathComponent: String
    switch identityConfidence {
    case .high:
      pathComponent = relativePathFromVolumeRoot
    case .low:
      pathComponent = standardizedPath
    }
    let combined = identityKey + "\u{0000}" + pathComponent
    let digest = SHA256.hash(data: Data(combined.utf8))
    return digest.map { String(format: "%02x", $0) }.joined()
  }
}

/// In-memory hints collected at fingerprint computation time. Never persisted —
/// `URLResourceValues.fileResourceIdentifier` and `volumeIdentifier` are not stable across
/// launches and only support same-session comparisons and diagnostics.
struct LiveDestinationIdentityHints: Sendable {
  let fileResourceIdentifier: String?
  let volumeIdentifier: String?
}

extension DestinationFingerprint {
  private static let log = Logger(
    subsystem: "com.valtteriluoma.photo-export", category: "DestinationFingerprint")

  /// Computes the fingerprint for a folder URL. Returns `nil` when the URL's resource values
  /// cannot be read (typically because the volume is unmounted) or when no usable identity
  /// component is present even with successfully read resource values.
  static func compute(for url: URL) -> (
    fingerprint: DestinationFingerprint, hints: LiveDestinationIdentityHints
  )? {
    let resolved = url.resolvingSymlinksInPath()
    let keys: Set<URLResourceKey> = [
      .volumeUUIDStringKey, .volumeIdentifierKey, .volumeURLKey, .fileResourceIdentifierKey,
    ]
    let values: URLResourceValues
    do {
      values = try resolved.resourceValues(forKeys: keys)
    } catch {
      log.error(
        "Failed to read URLResourceValues for \(resolved.path, privacy: .public): \(error.localizedDescription, privacy: .public)"
      )
      return nil
    }

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
    if values.volumeUUIDString != nil {
      confidence = .high
    } else {
      confidence = .low
    }

    let fingerprint = DestinationFingerprint(
      schemaVersion: currentSchemaVersion,
      volumeUUIDString: values.volumeUUIDString,
      volumeRootPath: volumeRoot.isEmpty ? nil : volumeRoot,
      relativePathFromVolumeRoot: relativePath,
      standardizedPath: canonicalPath,
      identityConfidence: confidence
    )
    return (fingerprint, hints)
  }
}
