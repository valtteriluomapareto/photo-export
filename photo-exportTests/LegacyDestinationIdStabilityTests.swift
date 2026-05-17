import Foundation
import Testing

@testable import Photo_Export

/// Backward-compat regression gate for `ExportDestinationManager.legacyDestinationId(from:)`.
///
/// This function exists exclusively so `ExportRecordsDirectoryCoordinator` can
/// find each existing user's legacy `ExportRecords/<oldId>/` directory and
/// rename it to `<newId>/` during the one-time lazy migration. The "oldId" is
/// the SHA-256 hex of the security-scoped bookmark bytes (the pre-Phase-0
/// identity scheme); the migration only triggers when the computed legacy id
/// for the current bookmark matches the name of an on-disk directory.
///
/// If the hash function, encoding, or input shape ever changes, the migration
/// stops finding existing users' legacy directories — and every user upgrading
/// from a pre-migration build silently loses their entire export history. The
/// `<oldId>` → `<newId>` test (`ExportRecordsDirectoryCoordinatorTests`)
/// exercises the rename mechanics; this test pins the **input → hash output**
/// mapping so an apparently-innocent refactor (switch to SHA-512, change hex
/// case, add a salt) is caught.
@MainActor
struct LegacyDestinationIdStabilityTests {

  /// Empty bookmark bytes. Not a realistic input but pins the trivial case
  /// against the standard SHA-256-of-empty-string hex digest.
  @Test func emptyBytesYieldKnownSHA256() {
    let id = ExportDestinationManager.legacyDestinationId(from: Data())
    #expect(
      id == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
      "SHA-256 hash of empty input must remain stable; any change orphans pre-migration directories")
  }

  /// "abc" — the canonical SHA-256 test vector. If this fails, the hash
  /// itself isn't SHA-256 anymore.
  @Test func canonicalAbcTestVector() {
    let id = ExportDestinationManager.legacyDestinationId(
      from: Data("abc".utf8))
    #expect(
      id == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
      "SHA-256 test-vector mismatch — hash function or encoding changed")
  }

  /// A realistic bookmark-shaped payload: 256 bytes of varied content. Pins
  /// the exact hex output so any drift in the (hash, encoding) pair fails
  /// here rather than silently mismatching real users' legacy directory
  /// names.
  ///
  /// The fixture bytes are `(0...255).map(UInt8.init)` — a deterministic
  /// sequence with no real meaning. The hash below was computed by the
  /// same function this test exercises; the point is that it must keep
  /// computing this value.
  @Test func arbitraryFixtureYieldsKnownHash() {
    let bytes = Data((0..<256).map { UInt8($0) })
    let id = ExportDestinationManager.legacyDestinationId(from: bytes)
    #expect(
      id == "40aff2e9d2d8922e47afd4648e6967497158785fbd1da870e7110266bf944880",
      "Hash of canonical 0-255 byte sequence drifted — pre-migration directories will be orphaned")
  }

  /// Hex encoding must be lowercase. The migration directory-name match is
  /// byte-equal; an uppercase regression silently misses every existing
  /// `<oldId>/` directory on disk.
  @Test func hexEncodingIsLowercase() {
    let id = ExportDestinationManager.legacyDestinationId(from: Data("abc".utf8))
    #expect(
      id == id.lowercased(),
      "Hex encoding must stay lowercase — directory names on disk are lowercase")
  }

  /// Output is always 64 chars (32 bytes × 2 hex chars). Catches a future
  /// switch to a different digest size.
  @Test func outputIsExactly64HexChars() {
    let id = ExportDestinationManager.legacyDestinationId(from: Data("abc".utf8))
    #expect(id.count == 64, "SHA-256 hex output must be 64 characters")
  }

  /// Same input → same output, every call. Pure function pin.
  @Test func sameInputYieldsSameOutput() {
    let bytes = Data((0..<128).map { UInt8($0) })
    let first = ExportDestinationManager.legacyDestinationId(from: bytes)
    let second = ExportDestinationManager.legacyDestinationId(from: bytes)
    #expect(first == second)
  }
}
