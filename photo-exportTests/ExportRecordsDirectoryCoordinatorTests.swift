import Foundation
import Testing

@testable import Photo_Export

struct ExportRecordsDirectoryCoordinatorTests {

  // MARK: - Helpers

  private func makeStoreRoot() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("ExportRecordsDirCoord-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func writeMarker(in dir: URL, named name: String, contents: String = "x") throws {
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let file = dir.appendingPathComponent(name)
    try Data(contents.utf8).write(to: file)
  }

  // MARK: - Fresh destination

  /// Plan §"Coordinator algorithm" step 5: legacy directory does not exist → treat destination as fresh.
  @Test func freshDestinationLeavesDirectoriesUntouched() throws {
    let root = try makeStoreRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let coord = ExportRecordsDirectoryCoordinator(storeRootURL: root)

    let result = coord.prepareDirectory(for: "newId-fresh", legacyIds: ["legacyId-fresh"])
    #expect(throws: Never.self) { try result.get() }

    let newDir = root.appendingPathComponent("newId-fresh")
    let legacyDir = root.appendingPathComponent("legacyId-fresh")
    #expect(!FileManager.default.fileExists(atPath: newDir.path))
    #expect(!FileManager.default.fileExists(atPath: legacyDir.path))
  }

  /// Caller doesn't know a legacy id (no bookmark, or first-ever launch).
  @Test func freshDestinationWithoutLegacyIdSucceeds() throws {
    let root = try makeStoreRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let coord = ExportRecordsDirectoryCoordinator(storeRootURL: root)

    let result = coord.prepareDirectory(for: "newId-only", legacyIds: [])
    #expect(throws: Never.self) { try result.get() }
  }

  // MARK: - Lazy migration

  /// Plan §"Coordinator algorithm" steps 2-3: legacy directory exists, new directory does not → rename.
  @Test func legacyDirectoryRenamedToNewId() throws {
    let root = try makeStoreRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let legacyDir = root.appendingPathComponent("legacyId-A")
    try writeMarker(in: legacyDir, named: "export-records.json", contents: "snapshot")

    let coord = ExportRecordsDirectoryCoordinator(storeRootURL: root)
    let result = coord.prepareDirectory(for: "newId-A", legacyIds: ["legacyId-A"])
    #expect(throws: Never.self) { try result.get() }

    let newDir = root.appendingPathComponent("newId-A")
    #expect(!FileManager.default.fileExists(atPath: legacyDir.path))
    #expect(FileManager.default.fileExists(atPath: newDir.path))
    let migrated = try Data(contentsOf: newDir.appendingPathComponent("export-records.json"))
    #expect(String(data: migrated, encoding: .utf8) == "snapshot")
  }

  /// Plan §"Coordinator algorithm" step 1: new directory already exists → use as-is, no rename.
  @Test func existingNewDirectoryIsLeftAsIs() throws {
    let root = try makeStoreRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let newDir = root.appendingPathComponent("newId-B")
    try writeMarker(in: newDir, named: "export-records.json", contents: "current")

    let coord = ExportRecordsDirectoryCoordinator(storeRootURL: root)
    let result = coord.prepareDirectory(for: "newId-B", legacyIds: [])
    #expect(throws: Never.self) { try result.get() }

    let bytes = try Data(contentsOf: newDir.appendingPathComponent("export-records.json"))
    #expect(String(data: bytes, encoding: .utf8) == "current")
  }

  /// Skip the just-after-upgrade directory (offline volume), then later configure it. Verify the rename
  /// happens *at that moment*, not at first launch — i.e. invoking the coordinator a second time does the
  /// migration that the first invocation skipped because the destination wasn't yet in scope.
  @Test func reconnectedDestinationMigratesOnLaterCall() throws {
    let root = try makeStoreRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let legacyDir = root.appendingPathComponent("legacyId-D2")
    try writeMarker(in: legacyDir, named: "export-records.json")

    let coord = ExportRecordsDirectoryCoordinator(storeRootURL: root)

    // First launch: D2 isn't being configured (different destination). Coordinator never runs for D2,
    // so nothing changes for D2.
    let other = root.appendingPathComponent("newId-D1")
    try writeMarker(in: other, named: "export-records.json")
    _ = coord.prepareDirectory(for: "newId-D1", legacyIds: [])
    #expect(FileManager.default.fileExists(atPath: legacyDir.path))

    // Months later, user reconnects D2 → coordinator runs against D2's ids → migration happens now.
    let result = coord.prepareDirectory(for: "newId-D2", legacyIds: ["legacyId-D2"])
    #expect(throws: Never.self) { try result.get() }

    let newDir = root.appendingPathComponent("newId-D2")
    #expect(!FileManager.default.fileExists(atPath: legacyDir.path))
    #expect(FileManager.default.fileExists(atPath: newDir.path))
  }

  // MARK: - Conflict

  /// Plan §"Coordinator algorithm" step 4: both `<newId>` and `<legacyId>` exist (shouldn't happen in
  /// normal use). Coordinator returns `.conflict`, leaves both directories untouched.
  @Test func conflictWhenBothDirectoriesExist() throws {
    let root = try makeStoreRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let newDir = root.appendingPathComponent("newId-C")
    let legacyDir = root.appendingPathComponent("legacyId-C")
    try writeMarker(in: newDir, named: "current.json")
    try writeMarker(in: legacyDir, named: "stale.json")

    let coord = ExportRecordsDirectoryCoordinator(storeRootURL: root)
    let result = coord.prepareDirectory(for: "newId-C", legacyIds: ["legacyId-C"])

    switch result {
    case .success:
      Issue.record("Expected conflict but got success")
    case .failure(let error):
      #expect(error == .conflict(newId: "newId-C", legacyId: "legacyId-C"))
    }

    // Both directories untouched.
    #expect(
      FileManager.default.fileExists(atPath: newDir.appendingPathComponent("current.json").path))
    #expect(
      FileManager.default.fileExists(atPath: legacyDir.appendingPathComponent("stale.json").path))
  }

  // MARK: - Multi-legacy migration (auto-sync Phase 0a)

  /// The auto-sync plan introduced a second legacy-id form for low-confidence drives
  /// (volumeIdentifier-based digest). The coordinator now takes a list of legacy ids and
  /// renames the *first* existing directory to `<newId>/`.
  @Test func secondLegacyIdMigratesWhenFirstIsAbsent() throws {
    let root = try makeStoreRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let secondLegacyDir = root.appendingPathComponent("legacyId-volId")
    try writeMarker(in: secondLegacyDir, named: "export-records.json", contents: "low-conf")

    let coord = ExportRecordsDirectoryCoordinator(storeRootURL: root)
    let result = coord.prepareDirectory(
      for: "newId-low",
      legacyIds: ["legacyId-bookmark", "legacyId-volId"]
    )
    #expect(throws: Never.self) { try result.get() }

    let newDir = root.appendingPathComponent("newId-low")
    #expect(FileManager.default.fileExists(atPath: newDir.path))
    #expect(!FileManager.default.fileExists(atPath: secondLegacyDir.path))
    let migrated = try Data(contentsOf: newDir.appendingPathComponent("export-records.json"))
    #expect(String(data: migrated, encoding: .utf8) == "low-conf")
  }

  /// When two legacy ids both exist, the first one in the list wins (priority order). Later
  /// legacy directories are left in place — they will surface as a `.conflict` on a future
  /// run if they ever align with a `<newId>` derivation.
  @Test func firstLegacyIdWinsWhenMultipleExist() throws {
    let root = try makeStoreRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let priorityDir = root.appendingPathComponent("legacyId-priority")
    let trailingDir = root.appendingPathComponent("legacyId-trailing")
    try writeMarker(in: priorityDir, named: "first.json", contents: "priority")
    try writeMarker(in: trailingDir, named: "first.json", contents: "trailing")

    let coord = ExportRecordsDirectoryCoordinator(storeRootURL: root)
    let result = coord.prepareDirectory(
      for: "newId-multi",
      legacyIds: ["legacyId-priority", "legacyId-trailing"]
    )
    #expect(throws: Never.self) { try result.get() }

    let newDir = root.appendingPathComponent("newId-multi")
    #expect(FileManager.default.fileExists(atPath: newDir.path))
    #expect(!FileManager.default.fileExists(atPath: priorityDir.path))
    // Trailing legacy dir is left alone for the user to inspect / clean up.
    #expect(FileManager.default.fileExists(atPath: trailingDir.path))
    let migrated = try Data(contentsOf: newDir.appendingPathComponent("first.json"))
    #expect(String(data: migrated, encoding: .utf8) == "priority")
  }

  /// When `<newId>/` already exists and ANY legacy directory also exists, the first
  /// matching legacy id is reported in the conflict.
  @Test func conflictReportsFirstMatchingLegacyId() throws {
    let root = try makeStoreRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let newDir = root.appendingPathComponent("newId-conflict")
    let secondLegacyDir = root.appendingPathComponent("legacyId-second")
    try writeMarker(in: newDir, named: "current.json")
    try writeMarker(in: secondLegacyDir, named: "stale.json")

    let coord = ExportRecordsDirectoryCoordinator(storeRootURL: root)
    let result = coord.prepareDirectory(
      for: "newId-conflict",
      legacyIds: ["legacyId-missing", "legacyId-second"]
    )

    switch result {
    case .success:
      Issue.record("Expected conflict")
    case .failure(let error):
      #expect(
        error == .conflict(newId: "newId-conflict", legacyId: "legacyId-second"))
    }
  }

  /// Same id reported as legacy and new — pathological caller. Coordinator should not move a directory
  /// onto itself; existing contents stay intact.
  @Test func sameIdLegacyAndNewIsNoop() throws {
    let root = try makeStoreRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let dir = root.appendingPathComponent("same-id")
    try writeMarker(in: dir, named: "export-records.json", contents: "preserved")

    let coord = ExportRecordsDirectoryCoordinator(storeRootURL: root)
    let result = coord.prepareDirectory(for: "same-id", legacyIds: ["same-id"])
    #expect(throws: Never.self) { try result.get() }

    let bytes = try Data(contentsOf: dir.appendingPathComponent("export-records.json"))
    #expect(String(data: bytes, encoding: .utf8) == "preserved")
  }
}
