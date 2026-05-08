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
/// Migration notes:
///   - Pre-Phase-0a users with low-confidence drives (no volume UUID — exFAT, network
///     shares) had their record store keyed by a digest that included `volumeIdentifier`.
///     `ExportRecordsDirectoryCoordinator` accepts `preV2LowConfidenceId(for:)` as a
///     secondary legacy id so those record stores migrate transparently on first launch
///     after the upgrade.
///   - The persisted `Codable` shape changed: pre-Phase-0a fingerprints carried an `id`
///     key; the new form excludes it. Decoding is forward-compatible (extra keys are
///     ignored), but anyone holding pre-Phase-0a JSON should re-encode it on next save.
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

  /// Memberwise initializer enforcing the confidence ↔ volume-UUID invariant: `.high`
  /// requires a non-nil `volumeUUIDString`, `.low` requires nil. Violations are programmer
  /// errors — they would mint an id with no input distinguishing the two confidence levels
  /// (`.high` with nil UUID would silently digest `"" + relPath`, indistinguishable from
  /// `.low` minus the metadata field). Use the `makeHigh` / `makeLow` factories from
  /// production code; this initializer remains accessible for `Codable` synthesis to work.
  init(
    schemaVersion: Int,
    volumeUUIDString: String?,
    volumeRootPath: String?,
    relativePathFromVolumeRoot: String,
    standardizedPath: String,
    identityConfidence: DestinationIdentityConfidence
  ) {
    switch identityConfidence {
    case .high:
      precondition(
        volumeUUIDString != nil,
        ".high-confidence DestinationFingerprint requires a non-nil volumeUUIDString")
    case .low:
      precondition(
        volumeUUIDString == nil,
        ".low-confidence DestinationFingerprint must have a nil volumeUUIDString — the "
          + "low-confidence id derivation hashes standardizedPath only and a stray UUID would be "
          + "ignored, so storing it invites a misleading audit trail.")
    }
    self.schemaVersion = schemaVersion
    self.volumeUUIDString = volumeUUIDString
    self.volumeRootPath = volumeRootPath
    self.relativePathFromVolumeRoot = relativePathFromVolumeRoot
    self.standardizedPath = standardizedPath
    self.identityConfidence = identityConfidence
  }

  /// Factory for `.high`-confidence fingerprints — i.e. drives with a volume UUID.
  static func makeHigh(
    volumeUUIDString: String,
    volumeRootPath: String?,
    relativePathFromVolumeRoot: String,
    standardizedPath: String,
    schemaVersion: Int = currentSchemaVersion
  ) -> DestinationFingerprint {
    DestinationFingerprint(
      schemaVersion: schemaVersion,
      volumeUUIDString: volumeUUIDString,
      volumeRootPath: volumeRootPath,
      relativePathFromVolumeRoot: relativePathFromVolumeRoot,
      standardizedPath: standardizedPath,
      identityConfidence: .high
    )
  }

  /// Factory for `.low`-confidence fingerprints — i.e. drives without a volume UUID.
  /// `volumeUUIDString` is omitted because it would not be hashed and would mislead anyone
  /// reading the persisted record.
  static func makeLow(
    volumeRootPath: String?,
    relativePathFromVolumeRoot: String,
    standardizedPath: String,
    schemaVersion: Int = currentSchemaVersion
  ) -> DestinationFingerprint {
    DestinationFingerprint(
      schemaVersion: schemaVersion,
      volumeUUIDString: nil,
      volumeRootPath: volumeRootPath,
      relativePathFromVolumeRoot: relativePathFromVolumeRoot,
      standardizedPath: standardizedPath,
      identityConfidence: .low
    )
  }

  /// SHA-256 hex digest used as the per-destination record-store directory name. Derived
  /// purely from the persistent components, not stored, so a future `schemaVersion` bump
  /// can change the byte layout without invalidating decoded values.
  ///
  /// The derivation switches on `schemaVersion`: each schema version owns its own byte
  /// layout *forever*, so an old persisted v1 fingerprint always re-derives a v1 id even
  /// after the code learns a v2 layout. Bumping `currentSchemaVersion` requires adding a
  /// new case here plus a coordinator-level migration; it never replaces an existing case.
  var id: String {
    switch schemaVersion {
    case 1:
      return idV1
    default:
      // Forward-compatibility hatch for an in-flight schema bump or a v0 file from an
      // experimental build. Falls back to the latest known layout and logs once so the
      // mismatch is observable. Production v2+ code MUST add an explicit case above.
      Self.log.error(
        "Unknown DestinationFingerprint.schemaVersion=\(self.schemaVersion, privacy: .public); falling back to latest layout"
      )
      return idV1
    }
  }

  /// v1 id derivation: SHA-256(identityKey || U+0000 || pathComponent).
  /// `.high`: volume UUID + relative path within the volume. `.low`: empty key + canonical
  /// standardized path. Bug-for-bug compatible with the pre-Phase-0a high-confidence
  /// derivation; low-confidence callers are migrated separately by
  /// `ExportRecordsDirectoryCoordinator` via `preV2LowConfidenceId(for:)`.
  private var idV1: String {
    let identityKey: String
    let pathComponent: String
    switch identityConfidence {
    case .high:
      identityKey = volumeUUIDString ?? ""
      pathComponent = relativePathFromVolumeRoot
    case .low:
      identityKey = ""
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

  /// Pre-Phase-0a low-confidence id derivation for migration purposes only. Returns the
  /// `SHA-256(volumeIdentifier-description || U+0000 || /relativePath)` digest the previous
  /// code used as the record-store directory name when no volume UUID was available.
  /// Returns `nil` for high-confidence drives (the high-confidence id derivation is
  /// unchanged, so no migration applies) and for unmounted drives.
  ///
  /// The new low-confidence digest hashes `standardizedPath` only — `volumeIdentifier` is a
  /// same-session-only token. `ExportRecordsDirectoryCoordinator` accepts this value as a
  /// secondary legacy id so existing low-confidence record stores keep working across the
  /// upgrade.
  static func preV2LowConfidenceId(for url: URL) -> String? {
    let resolved = url.resolvingSymlinksInPath()
    let keys: Set<URLResourceKey> = [
      .volumeUUIDStringKey, .volumeIdentifierKey, .volumeURLKey,
    ]
    guard let values = try? resolved.resourceValues(forKeys: keys),
      values.volumeUUIDString == nil,
      let identifier = values.volumeIdentifier
    else { return nil }

    let volumeRoot = values.volume?.standardizedFileURL.path ?? ""
    let canonicalPath = resolved.standardizedFileURL.path
    var relativePath = canonicalPath
    if !volumeRoot.isEmpty, volumeRoot != "/", canonicalPath.hasPrefix(volumeRoot) {
      relativePath = String(canonicalPath.dropFirst(volumeRoot.count))
    }
    if !relativePath.hasPrefix("/") {
      relativePath = "/" + relativePath
    }

    let combined = String(describing: identifier) + "\u{0000}" + relativePath
    let digest = SHA256.hash(data: Data(combined.utf8))
    return digest.map { String(format: "%02x", $0) }.joined()
  }

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

    let fingerprint: DestinationFingerprint
    if let uuid = values.volumeUUIDString {
      fingerprint = .makeHigh(
        volumeUUIDString: uuid,
        volumeRootPath: volumeRoot.isEmpty ? nil : volumeRoot,
        relativePathFromVolumeRoot: relativePath,
        standardizedPath: canonicalPath
      )
    } else {
      fingerprint = .makeLow(
        volumeRootPath: volumeRoot.isEmpty ? nil : volumeRoot,
        relativePathFromVolumeRoot: relativePath,
        standardizedPath: canonicalPath
      )
    }
    return (fingerprint, hints)
  }
}
