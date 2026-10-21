import Foundation
import Testing
import os

@testable import Photo_Export

/// Runs the load's read, decode and prepare steps off the main actor over the historical
/// fixtures, and checks they produce what `configure(for:)` installs from a second copy.
@MainActor
struct PreparedLoadParityTests {
  private typealias TimelineFile = JSONLRecordFile<[String: ExportRecord], ExportRecordMutation>
  private typealias CollectionFile = JSONLRecordFile<
    CollectionExportRecordStore.Snapshot, CollectionExportRecordStore.LogOp
  >

  private static let fixtureRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("test-fixtures/persistence")

  /// Names the snapshot gave an asset that the log then deleted or renamed. No record names
  /// them after the load, so neither side may count them as claimed.
  private static let releasedTimelineNames = ["DELETE.JPG", "OLD.JPG"]
  private static let releasedFavoritesNames = ["DELETE.JPG", "OLD-FAV.JPG"]

  private struct Copies {
    let prepared: URL
    let configured: URL

    func cleanup() {
      try? FileManager.default.removeItem(at: prepared)
      try? FileManager.default.removeItem(at: configured)
    }
  }

  /// Two copies, so each side reads files the other has not touched.
  private func copies(of tag: String) throws -> Copies {
    let source = Self.fixtureRoot.appendingPathComponent(tag)
    try #require(
      FileManager.default.fileExists(atPath: source.path),
      "Tests require the checkout fixture directory: \(source.path)")
    let copies = Copies(
      prepared: TestScratch.directory("PreparedLoadParity"),
      configured: TestScratch.directory("PreparedLoadParity"))
    try FileManager.default.copyItem(at: source, to: copies.prepared)
    try FileManager.default.copyItem(at: source, to: copies.configured)
    return copies
  }

  private struct Prepared<Load: Sendable>: Sendable {
    let outcome: Load
    /// How many records claim each released name in the index built from the prepared load.
    let releasedClaims: [String: Int]
  }

  @Test(arguments: ["v1.0.3/A", "v1.0.3/B", "v1.6.5/A", "v1.6.5/B"])
  func timelinePreparedLoadMatchesConfiguredStore(fixture: String) async throws {
    let parts = fixture.split(separator: "/").map(String.init)
    let (tag, destination) = (parts[0], parts[1])
    let copies = try copies(of: tag)
    defer { copies.cleanup() }
    let directory = copies.prepared.appendingPathComponent(destination)
    let snapshotURL = directory.appendingPathComponent(ExportRecordStore.Constants.snapshotFileName)
    let logURL = directory.appendingPathComponent(ExportRecordStore.Constants.logFileName)
    let released = destination == "A" ? Self.releasedTimelineNames : []
    let logger = Logger(subsystem: "test", category: "PreparedLoadParity")

    // No `await` on the steps: this only compiles while none is isolated to the main actor.
    let prepared = await Task.detached {
      let raw = TimelineFile.readFiles(
        snapshotURL: snapshotURL, logURL: logURL, logIO: ProductionJSONLRecordLogIO())
      let decoded = TimelineFile.decode(
        raw, snapshotURL: snapshotURL, logURL: logURL, dateDecodingStrategy: .iso8601,
        logger: logger)
      let outcome = ExportRecordStore.prepare(decoded)
      var releasedClaims: [String: Int] = [:]
      if case .loaded(let load) = outcome {
        let claims = ExportRecordStore.buildClaims(from: load.records, logger: logger)
        let folder = ExportRecordStore.ClaimFolder(year: 2024, month: 4, subfolder: nil)
        for name in released { releasedClaims[name] = claims.count(name, in: folder) }
      }
      return Prepared(outcome: outcome, releasedClaims: releasedClaims)
    }.value

    let store = ExportRecordStore(baseDirectoryURL: copies.configured)
    store.configure(for: destination)
    defer { store.flushForTesting() }
    #expect(store.state == .ready)
    guard case .loaded(let load) = prepared.outcome else {
      Issue.record("Expected a loaded outcome, got \(prepared.outcome)")
      return
    }
    #expect(!load.records.isEmpty)
    #expect(load.records == store.recordsById)
    #expect(load.monthCounters == store.monthCounters)
    for name in released {
      #expect(prepared.releasedClaims[name] == 0, "\(name) is claimed after the load")
      #expect(
        !store.isFilenameClaimed(name, year: 2024, month: 4, subfolder: nil, exceptAsset: "probe"))
    }
  }

  @Test(arguments: ["A", "B"])
  func collectionPreparedLoadMatchesConfiguredStore(destination: String) async throws {
    let copies = try copies(of: "v1.6.5")
    defer { copies.cleanup() }
    let directory = copies.prepared.appendingPathComponent(destination)
    let snapshotURL = directory.appendingPathComponent(
      CollectionExportRecordStore.Constants.snapshotFileName)
    let logURL = directory.appendingPathComponent(CollectionExportRecordStore.Constants.logFileName)
    let favoritesId = "collections:favorites"
    let released = destination == "A" ? Self.releasedFavoritesNames : []
    let logger = Logger(subsystem: "test", category: "PreparedLoadParity")

    // No `await` on the steps: this only compiles while none is isolated to the main actor.
    let prepared = await Task.detached {
      let raw = CollectionFile.readFiles(
        snapshotURL: snapshotURL, logURL: logURL, logIO: ProductionJSONLRecordLogIO())
      let decoded = CollectionFile.decode(
        raw, snapshotURL: snapshotURL, logURL: logURL, dateDecodingStrategy: .iso8601,
        logger: logger)
      let outcome = CollectionExportRecordStore.prepare(decoded, logger: logger)
      var releasedClaims: [String: Int] = [:]
      if case .loaded(let load) = outcome {
        let claims = CollectionExportRecordStore.buildClaims(
          from: load.recordBodies, logger: logger)
        let folder = CollectionExportRecordStore.ClaimFolder(
          placementId: favoritesId, subfolder: nil)
        for name in released { releasedClaims[name] = claims.count(name, in: folder) }
      }
      return Prepared(outcome: outcome, releasedClaims: releasedClaims)
    }.value

    let store = CollectionExportRecordStore(baseDirectoryURL: copies.configured)
    store.configure(for: destination)
    defer { store.flushForTesting() }
    #expect(store.state == .ready)
    guard case .loaded(let load) = prepared.outcome else {
      Issue.record("Expected a loaded outcome, got \(prepared.outcome)")
      return
    }
    #expect(!load.recordBodies.isEmpty)
    #expect(load.recordBodies == store.recordBodies)
    // `ExportPlacement` compares by id only, so compare every encoded field.
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    encoder.dateEncodingStrategy = .iso8601
    #expect(try encoder.encode(load.placements) == encoder.encode(store.placements))
    let favorites = try #require(store.placements[favoritesId])
    for name in released {
      #expect(prepared.releasedClaims[name] == 0, "\(name) is claimed after the load")
      #expect(
        !store.isFilenameClaimed(name, placement: favorites, subfolder: nil, exceptAsset: "probe"))
    }
  }
}
