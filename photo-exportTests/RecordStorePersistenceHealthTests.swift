import Foundation
import Testing

@testable import Photo_Export

@MainActor
struct RecordStorePersistenceHealthTests {
  @MainActor
  private struct Stores {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let timeline: ExportRecordStore
    let collection: CollectionExportRecordStore
    let isCollection: Bool
    let placement = ExportPlacement.favorites()

    init(isCollection: Bool) {
      self.isCollection = isCollection
      timeline = ExportRecordStore(baseDirectoryURL: root)
      collection = CollectionExportRecordStore(baseDirectoryURL: root)
      configure("A")
    }

    var state: RecordStoreState { isCollection ? collection.state : timeline.state }
    var log: URL {
      root.appendingPathComponent(
        "A/" + (isCollection ? "collection-records.jsonl" : "export-records.jsonl"))
    }
    func configure(_ id: String) {
      timeline.configure(for: id)
      collection.configure(for: id)
    }
    func write(_ id: String) {
      if isCollection {
        collection.upsertPlacement(placement)
        collection.markVariantExported(
          assetId: id, placement: placement, variant: .original,
          filename: "\(id).jpg", exportedAt: Date())
      } else {
        timeline.markExported(
          assetId: id, year: 2026, month: 9, relPath: "2026/09/",
          filename: "\(id).jpg", exportedAt: Date())
      }
    }
    func hasRecord(_ id: String) -> Bool {
      if isCollection {
        return collection.exportInfo(assetId: id, placement: placement)?.variants[.original]?.status
          == .done
      }
      return timeline.exportInfo(assetId: id)?.variants[.original]?.status == .done
    }
    func flush() async throws {
      if isCollection { try await collection.flush() } else { try await timeline.flush() }
    }
    func retry() {
      if isCollection { collection.retryPersistence() } else { timeline.retryPersistence() }
    }
    func cleanup() {
      timeline.flushForTesting()
      collection.flushForTesting()
      try? FileManager.default.removeItem(at: root)
    }
  }

  @Test(arguments: [false, true])
  func pendingDoneRecordCannotAcknowledgeRetryBeforeFlush(isCollection: Bool) async throws {
    let stores = Stores(isCollection: isCollection)
    defer { stores.cleanup() }
    let router = RecordStoreRouter(
      timelineStore: stores.timeline, collectionStore: stores.collection)
    let scope: AutoSyncRetryScopeKey = isCollection ? .favorites : .timeline
    stores.write("pending")
    #expect(stores.state == .ready)
    #expect(stores.hasRecord("pending"))
    #expect(!router.isRetryVariantDone(scope: scope, assetId: "pending", variant: .original))
    try await stores.flush()
    #expect(router.isRetryVariantDone(scope: scope, assetId: "pending", variant: .original))
    stores.write("newer")
    #expect(!router.isRetryVariantDone(scope: scope, assetId: "newer", variant: .original))
    try await stores.flush()
    #expect(router.isRetryVariantDone(scope: scope, assetId: "newer", variant: .original))
  }

  @Test(arguments: [false, true])
  func unreadableLogBlocksStoreAndRetryPreservesHistory(isCollection: Bool) async throws {
    let stores = Stores(isCollection: isCollection)
    defer { stores.cleanup() }
    stores.write("saved")
    try await stores.flush()
    let bytes = try Data(contentsOf: stores.log)
    try FileManager.default.removeItem(at: stores.log)
    try FileManager.default.createDirectory(at: stores.log, withIntermediateDirectories: false)
    stores.configure("A")
    #expect(stores.state == .persistenceFailed)
    #expect(isCollection ? stores.timeline.state == .ready : stores.collection.state == .ready)
    // Retry cannot treat unreadable history as an empty store or overwrite it.
    stores.retry()
    #expect(stores.state == .persistenceFailed)
    try FileManager.default.removeItem(at: stores.log)
    try bytes.write(to: stores.log)
    stores.retry()
    #expect(stores.state == .ready)
    #expect(stores.hasRecord("saved"))
  }

  @Test(arguments: [false, true])
  func failedAppendRetainsInflightCompletionAndRetrySavesIt(isCollection: Bool) async throws {
    let stores = Stores(isCollection: isCollection)
    defer { stores.cleanup() }
    stores.write("saved")
    try await stores.flush()
    try FileManager.default.removeItem(at: stores.log)
    try FileManager.default.createDirectory(at: stores.log, withIntermediateDirectories: false)
    stores.write("pending")
    await #expect(throws: (any Error).self) { try await stores.flush() }
    #expect(stores.state == .persistenceFailed)
    // A file already being exported can finish after the IO failure is delivered.
    stores.write("inflight")
    #expect(stores.hasRecord("inflight"))
    let router = RecordStoreRouter(
      timelineStore: stores.timeline, collectionStore: stores.collection)
    let scope: AutoSyncRetryScopeKey = isCollection ? .favorites : .timeline
    #expect(!router.isRetryVariantDone(scope: scope, assetId: "inflight", variant: .original))
    stores.retry()
    #expect(stores.state == .persistenceFailed)
    try FileManager.default.removeItem(at: stores.log)
    stores.retry()
    #expect(stores.state == .ready)
    try await stores.flush()
    stores.configure("A")
    for id in ["saved", "pending", "inflight"] { #expect(stores.hasRecord(id)) }
    #expect(router.isRetryVariantDone(scope: scope, assetId: "inflight", variant: .original))
  }

  @Test(arguments: [false, true])
  func oldDestinationFailureCannotPoisonReplacement(isCollection: Bool) async throws {
    let stores = Stores(isCollection: isCollection)
    defer { stores.cleanup() }
    try FileManager.default.createDirectory(at: stores.log, withIntermediateDirectories: false)
    stores.write("old")
    stores.configure("B")
    stores.write("new")
    try await stores.flush()
    #expect(stores.state == .ready)
    #expect(stores.hasRecord("new"))
    #expect(!stores.hasRecord("old"))

    stores.configure("A")
    #expect(stores.state == .persistenceFailed)
    #expect(stores.hasRecord("old"))
    #expect(!stores.hasRecord("new"))

    try FileManager.default.removeItem(at: stores.log)
    stores.retry()
    #expect(stores.state == .ready)
    try await stores.flush()

    stores.configure("B")
    #expect(stores.state == .ready)
    #expect(stores.hasRecord("new"))
    stores.configure("A")
    #expect(stores.state == .ready)
    #expect(stores.hasRecord("old"))
    #expect(!stores.hasRecord("new"))
  }
}
