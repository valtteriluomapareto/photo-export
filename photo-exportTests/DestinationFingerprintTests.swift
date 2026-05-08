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
  /// in later commits). `id` is intentionally excluded from the persisted form and re-derived
  /// after decode, so the decoded fingerprint's id must equal the original's.
  @Test func fingerprintRoundTripsThroughCodableAndIdIsRederived() throws {
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
    #expect(decoded.id == original.id)

    // `id` is computed from the persistent components, not stored — its key must not appear
    // in the persisted JSON (so future schema bumps can re-derive without a migration).
    let json = try #require(
      try JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(json["id"] == nil)
  }

  /// The id of a low-confidence fingerprint depends *only* on `standardizedPath`, not on
  /// `volumeIdentifier` (which is a same-session-only token — encoding it would silently
  /// change the id across reboots and orphan the record store).
  @Test func lowConfidenceIdDependsOnStandardizedPathOnly() {
    let original = DestinationFingerprint(
      schemaVersion: DestinationFingerprint.currentSchemaVersion,
      volumeUUIDString: nil,
      volumeRootPath: nil,
      relativePathFromVolumeRoot: "/photos",
      standardizedPath: "/Volumes/External/photos",
      identityConfidence: .low
    )
    let drifted = DestinationFingerprint(
      schemaVersion: DestinationFingerprint.currentSchemaVersion,
      volumeUUIDString: nil,
      volumeRootPath: "/Volumes/Renamed",
      relativePathFromVolumeRoot: "/elsewhere",
      standardizedPath: "/Volumes/External/photos",
      identityConfidence: .low
    )

    #expect(original.id == drifted.id)
  }

  /// Two `.high`-confidence fingerprints with the same volume UUID + relative path produce
  /// the same id even if their `standardizedPath` differs (e.g. drive renamed).
  @Test func highConfidenceIdSurvivesDriveRename() {
    let beforeRename = DestinationFingerprint(
      schemaVersion: DestinationFingerprint.currentSchemaVersion,
      volumeUUIDString: "ABC-UUID",
      volumeRootPath: "/Volumes/MyDrive",
      relativePathFromVolumeRoot: "/photos",
      standardizedPath: "/Volumes/MyDrive/photos",
      identityConfidence: .high
    )
    let afterRename = DestinationFingerprint(
      schemaVersion: DestinationFingerprint.currentSchemaVersion,
      volumeUUIDString: "ABC-UUID",
      volumeRootPath: "/Volumes/PhotoBackup",
      relativePathFromVolumeRoot: "/photos",
      standardizedPath: "/Volumes/PhotoBackup/photos",
      identityConfidence: .high
    )

    #expect(beforeRename.id == afterRename.id)
  }

  /// Schema v1's id derivation is pinned and must not change when future schema versions
  /// land — old persisted fingerprints always re-derive a v1 id. Bumping `currentSchemaVersion`
  /// requires adding a new branch in `id`, never replacing this one.
  @Test func schemaV1IdLayoutIsPinned() {
    let high = DestinationFingerprint(
      schemaVersion: 1,
      volumeUUIDString: "fixed-uuid",
      volumeRootPath: nil,
      relativePathFromVolumeRoot: "/photos",
      standardizedPath: "/Volumes/X/photos",
      identityConfidence: .high
    )

    // Hash of "fixed-uuid" + U+0000 + "/photos". Computed once and pinned here so any
    // accidental change to the derivation immediately fails this test.
    #expect(
      high.id == "3a945585d7df9e765c1c96e9e5fd6cfd941e3a158d15ed404c408158e90d42c2")
  }

  /// An unknown future `schemaVersion` does not crash; it falls back to the latest known
  /// layout and (in production) logs an error. Tests can rely on it always returning a
  /// deterministic non-empty id rather than failing.
  @Test func unknownSchemaVersionFallsBackToLatestLayout() {
    let weird = DestinationFingerprint(
      schemaVersion: 99,
      volumeUUIDString: "u",
      volumeRootPath: nil,
      relativePathFromVolumeRoot: "/p",
      standardizedPath: "/Volumes/u/p",
      identityConfidence: .high
    )
    let v1 = DestinationFingerprint(
      schemaVersion: 1,
      volumeUUIDString: "u",
      volumeRootPath: nil,
      relativePathFromVolumeRoot: "/p",
      standardizedPath: "/Volumes/u/p",
      identityConfidence: .high
    )

    #expect(weird.id == v1.id)
  }

  /// `.high` and `.low` confidences with otherwise-equivalent path components must produce
  /// distinct ids — otherwise a low-confidence drive could collide with a high-confidence
  /// one whose UUID happens to digest the same.
  @Test func highAndLowConfidenceIdsAreDistinct() {
    let high = DestinationFingerprint(
      schemaVersion: DestinationFingerprint.currentSchemaVersion,
      volumeUUIDString: "UUID",
      volumeRootPath: nil,
      relativePathFromVolumeRoot: "/photos",
      standardizedPath: "/Volumes/X/photos",
      identityConfidence: .high
    )
    let low = DestinationFingerprint(
      schemaVersion: DestinationFingerprint.currentSchemaVersion,
      volumeUUIDString: nil,
      volumeRootPath: nil,
      relativePathFromVolumeRoot: "/photos",
      standardizedPath: "/Volumes/X/photos",
      identityConfidence: .low
    )

    #expect(high.id != low.id)
  }
}
