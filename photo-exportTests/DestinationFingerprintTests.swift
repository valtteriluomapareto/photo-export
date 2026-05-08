import Foundation
import Testing

@testable import Photo_Export

/// Phase 0a (auto-sync plan): the existing stable `destinationId` derivation is promoted into a
/// `DestinationFingerprint` value type. The id bytes must stay bug-for-bug compatible with the
/// pre-Phase-0 derivation so existing record stores keep working without a migration.
@MainActor
struct DestinationFingerprintTests {

  /// `ExportDestinationManager.computeDestinationId(for:)` is a thin wrapper over the
  /// fingerprint factory; the id field is the same hex string.
  @Test func managerIdMatchesFingerprintId() throws {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("Fingerprint-Match-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let managerId = ExportDestinationManager.computeDestinationId(for: dir)
    let fingerprint = ExportDestinationManager.computeDestinationFingerprint(for: dir)

    #expect(managerId != nil)
    #expect(fingerprint != nil)
    #expect(managerId == fingerprint?.id)
  }

  /// The fingerprint is deterministic — two calls against the same folder produce the same
  /// structured output (no per-call randomness).
  @Test func fingerprintIsDeterministic() throws {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("Fingerprint-Stable-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let f1 = DestinationFingerprint.compute(for: dir)?.fingerprint
    let f2 = DestinationFingerprint.compute(for: dir)?.fingerprint

    #expect(f1 != nil)
    #expect(f1 == f2)
  }

  /// A folder on the boot/internal volume has a volume UUID, so identity confidence is `.high`.
  /// Temp dirs live under `/var/folders/...` which is on the boot volume in test environments.
  @Test func tempDirectoryReportsHighConfidenceIdentity() throws {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("Fingerprint-Confidence-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let result = DestinationFingerprint.compute(for: dir)
    let fingerprint = result?.fingerprint

    #expect(fingerprint != nil)
    #expect(fingerprint?.identityConfidence == .high)
    #expect(fingerprint?.volumeUUIDString != nil)
    #expect(fingerprint?.schemaVersion == DestinationFingerprint.currentSchemaVersion)
  }

  /// `LiveDestinationIdentityHints` are populated from same-session resource keys when
  /// available. They are diagnostic only — never persisted, never the primary identity.
  @Test func liveHintsIncludeFileResourceIdentifier() throws {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("Fingerprint-Hints-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let result = DestinationFingerprint.compute(for: dir)
    let hints = result?.hints

    #expect(hints != nil)
    // Both hints are best-effort and may be nil in unusual sandbox configurations, but on a
    // standard macOS APFS temp dir at least one of them is populated.
    #expect(hints?.fileResourceIdentifier != nil || hints?.volumeIdentifier != nil)
  }

  /// The structured fields populate the volume root and the relative path within that volume,
  /// matching the pre-Phase-0 hash input layout (`volumeUUID || \0 || /relativePath`).
  @Test func structuredFieldsCarryRelativePathFromVolumeRoot() throws {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("Fingerprint-Path-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let fingerprint = DestinationFingerprint.compute(for: dir)?.fingerprint

    #expect(fingerprint != nil)
    #expect(fingerprint?.relativePathFromVolumeRoot.hasPrefix("/") == true)
    #expect(fingerprint?.standardizedPath.contains("Fingerprint-Path-") == true)
  }

  /// The fingerprint round-trips through Codable (it is persisted alongside record-store state
  /// in later commits).
  @Test func fingerprintRoundTripsThroughCodable() throws {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("Fingerprint-Codable-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    guard let original = DestinationFingerprint.compute(for: dir)?.fingerprint else {
      Issue.record("Expected a fingerprint for \(dir.path)")
      return
    }

    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(DestinationFingerprint.self, from: data)

    #expect(decoded == original)
  }
}
