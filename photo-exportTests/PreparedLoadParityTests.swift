import Foundation
import Testing
import os

@testable import Photo_Export

/// Runs the load's read, decode and prepare steps off the main actor over the historical
/// fixtures, and checks they produce what `configure(for:)` installs from a second copy.
@MainActor
@Suite(.timeLimit(.minutes(2)))
struct PreparedLoadParityTests {
  private static let fixtureRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("test-fixtures/persistence")

  /// Names the snapshot gave an asset that the log then deleted or renamed. No record names
  /// them after the load, so the store may not count them as claimed.
  private static let releasedTimelineNames = ["DELETE.JPG", "OLD.JPG"]
  private static let releasedFavoritesNames = ["DELETE.JPG", "OLD-FAV.JPG"]
  /// A name a record still holds after the load, so the store must count it as claimed.
  private static let keptName = "SNAP.JPG"

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

  @Test(arguments: ["v1.0.3/A", "v1.0.3/B", "v1.6.5/A", "v1.6.5/B"])
  func timelinePreparedLoadMatchesConfiguredStore(fixture: String) async throws {
    let parts = fixture.split(separator: "/").map(String.init)
    let (tag, destination) = (parts[0], parts[1])
    let copies = try copies(of: tag)
    defer { copies.cleanup() }
    let directory = copies.prepared.appendingPathComponent(destination)
    let snapshotURL = directory.appendingPathComponent(ExportRecordStore.Constants.snapshotFileName)
    let logURL = directory.appendingPathComponent(ExportRecordStore.Constants.logFileName)
    let logger = Logger(subsystem: TestLogging.subsystem, category: "PreparedLoadParity")
    // The store's own file supplies the decoding, as the store's load does.
    let inputs = ExportRecordStore.RecordFile(
      snapshotURL: snapshotURL, logURL: logURL, ioQueue: DispatchQueue(label: "parity"),
      logger: logger
    ).readInputs

    // No `await` on the steps: this only compiles while none is isolated to the main actor.
    let (outcome, needsLogSeparator) = await Task.detached {
      let raw = ExportRecordStore.RecordFile.readFiles(
        snapshotURL: inputs.snapshotURL, logURL: inputs.logURL, logIO: inputs.logIO)
      let decoded = ExportRecordStore.RecordFile.decode(
        raw, snapshotURL: inputs.snapshotURL, logURL: inputs.logURL,
        dateDecodingStrategy: inputs.dateDecodingStrategy, logger: inputs.logger)
      return (ExportRecordStore.prepare(decoded), decoded.needsLogSeparator)
    }.value

    let store = ExportRecordStore(baseDirectoryURL: copies.configured)
    store.configure(for: destination)
    defer { store.drainSynchronously() }
    #expect(store.state == .ready)
    // Every fixture log ends in LF.
    #expect(needsLogSeparator == false)
    guard case .loaded(let load) = outcome else {
      Issue.record("Expected a loaded outcome, got \(outcome)")
      return
    }
    #expect(!load.records.isEmpty)
    #expect(load.records == store.recordsById)
    guard destination == "A" else { return }
    for name in Self.releasedTimelineNames {
      #expect(
        !store.isFilenameClaimed(name, year: 2024, month: 4, subfolder: nil, exceptAsset: "probe"),
        "\(name) is claimed after the load")
    }
    #expect(
      store.isFilenameClaimed(
        Self.keptName, year: 2024, month: 4, subfolder: nil, exceptAsset: "probe"))
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
    let logger = Logger(subsystem: TestLogging.subsystem, category: "PreparedLoadParity")
    // The store's own file supplies the decoding, as the store's load does.
    let inputs = CollectionExportRecordStore.RecordFile(
      snapshotURL: snapshotURL, logURL: logURL, ioQueue: DispatchQueue(label: "parity"),
      logger: logger
    ).readInputs

    // No `await` on the steps: this only compiles while none is isolated to the main actor.
    let (outcome, needsLogSeparator) = await Task.detached {
      let raw = CollectionExportRecordStore.RecordFile.readFiles(
        snapshotURL: inputs.snapshotURL, logURL: inputs.logURL, logIO: inputs.logIO)
      let decoded = CollectionExportRecordStore.RecordFile.decode(
        raw, snapshotURL: inputs.snapshotURL, logURL: inputs.logURL,
        dateDecodingStrategy: inputs.dateDecodingStrategy, logger: inputs.logger)
      return (
        CollectionExportRecordStore.prepare(decoded, logger: inputs.logger),
        decoded.needsLogSeparator
      )
    }.value

    let store = CollectionExportRecordStore(baseDirectoryURL: copies.configured)
    store.configure(for: destination)
    defer { store.drainSynchronously() }
    #expect(store.state == .ready)
    // Every fixture log ends in LF.
    #expect(needsLogSeparator == false)
    guard case .loaded(let load) = outcome else {
      Issue.record("Expected a loaded outcome, got \(outcome)")
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
    guard destination == "A" else { return }
    for name in Self.releasedFavoritesNames {
      #expect(
        !store.isFilenameClaimed(name, placement: favorites, subfolder: nil, exceptAsset: "probe"),
        "\(name) is claimed after the load")
    }
    #expect(
      store.isFilenameClaimed(
        Self.keptName, placement: favorites, subfolder: nil, exceptAsset: "probe"))
  }

  /// The asynchronous load installs what the blocking `configure(for:)` installs.
  @Test(arguments: ["v1.0.3/A", "v1.0.3/B", "v1.6.5/A", "v1.6.5/B"])
  func timelineAsyncLoadMatchesConfiguredStore(fixture: String) async throws {
    let parts = fixture.split(separator: "/").map(String.init)
    let (tag, destination) = (parts[0], parts[1])
    let copies = try copies(of: tag)
    defer { copies.cleanup() }

    let loaded = ExportRecordStore(baseDirectoryURL: copies.prepared)
    loaded.beginConfigure(for: destination)
    await loaded.waitUntilSettled()
    defer { loaded.drainSynchronously() }
    let store = ExportRecordStore(baseDirectoryURL: copies.configured)
    store.configure(for: destination)
    defer { store.drainSynchronously() }

    #expect(loaded.state == .ready)
    #expect(store.state == .ready)
    #expect(!loaded.recordsById.isEmpty)
    #expect(loaded.recordsById == store.recordsById)
    #expect(Set(loaded.monthCounters.keys) == Set(store.monthCounters.keys))
    for (key, counters) in store.monthCounters {
      #expect(loaded.monthCounters[key]?.variantStatus == counters.variantStatus)
      #expect(loaded.monthCounters[key]?.bothVariantsDone == counters.bothVariantsDone)
      #expect(
        loaded.monthCounters[key]?.originalDoneAtNaturalStem == counters.originalDoneAtNaturalStem)
      #expect(loaded.monthCounters[key]?.editedFallbackCovered == counters.editedFallbackCovered)
      #expect(loaded.monthCounters[key]?.pairedVideoIncomplete == counters.pairedVideoIncomplete)
    }
    guard destination == "A" else { return }
    for name in Self.releasedTimelineNames {
      #expect(
        !loaded.isFilenameClaimed(
          name, year: 2024, month: 4, subfolder: nil, exceptAsset: "probe"),
        "\(name) is claimed after the load")
    }
    #expect(
      loaded.isFilenameClaimed(
        Self.keptName, year: 2024, month: 4, subfolder: nil, exceptAsset: "probe"))
  }

  /// The asynchronous load installs what the blocking `configure(for:)` installs.
  @Test(arguments: ["A", "B"])
  func collectionAsyncLoadMatchesConfiguredStore(destination: String) async throws {
    let copies = try copies(of: "v1.6.5")
    defer { copies.cleanup() }

    let loaded = CollectionExportRecordStore(baseDirectoryURL: copies.prepared)
    loaded.beginConfigure(for: destination)
    await loaded.waitUntilSettled()
    defer { loaded.drainSynchronously() }
    let store = CollectionExportRecordStore(baseDirectoryURL: copies.configured)
    store.configure(for: destination)
    defer { store.drainSynchronously() }

    #expect(loaded.state == .ready)
    #expect(store.state == .ready)
    #expect(!loaded.recordBodies.isEmpty)
    #expect(loaded.recordBodies == store.recordBodies)
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    encoder.dateEncodingStrategy = .iso8601
    #expect(try encoder.encode(loaded.placements) == encoder.encode(store.placements))
    guard destination == "A" else { return }
    let favorites = try #require(loaded.placements["collections:favorites"])
    for name in Self.releasedFavoritesNames {
      #expect(
        !loaded.isFilenameClaimed(
          name, placement: favorites, subfolder: nil, exceptAsset: "probe"),
        "\(name) is claimed after the load")
    }
    #expect(
      loaded.isFilenameClaimed(
        Self.keptName, placement: favorites, subfolder: nil, exceptAsset: "probe"))
  }
}
