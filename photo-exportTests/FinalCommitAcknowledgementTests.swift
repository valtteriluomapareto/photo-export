import Foundation
import Testing

@testable import Photo_Export

/// A final commit is acknowledged with the name the file was committed or adopted under,
/// which can differ from the name planned before the bytes existed. Every path that turns
/// the acknowledgement into a record uses that name, in both stores, and the filename
/// claims follow it.
@MainActor
struct FinalCommitAcknowledgementTests {
  @MainActor
  private final class Fixture {
    let root = TestScratch.directory("FinalCommitAcknowledgement")
    let timeline: ExportRecordStore
    let collections: CollectionExportRecordStore
    let router: RecordStoreRouter
    let placement: ExportPlacement
    let collection: Bool

    init(collection: Bool) {
      self.collection = collection
      timeline = ExportRecordStore(baseDirectoryURL: root)
      collections = CollectionExportRecordStore(baseDirectoryURL: root)
      router = RecordStoreRouter(timelineStore: timeline, collectionStore: collections)
      placement = collection ? .favorites() : .timeline(year: 2025, month: 6)
      select("A")
    }

    func select(_ id: String) {
      timeline.configure(for: id)
      collections.configure(for: id)
    }

    var state: RecordStoreState { collection ? collections.state : timeline.state }

    func capture(fallback: Bool = false) throws -> (String?) async -> Void {
      try router.captureFinalCommit(
        assetId: "asset", placement: placement, variant: .original,
        relPath: placement.relativePath, subfolder: nil, acceptsEditedFallback: fallback)
    }

    func variant(_ variant: ExportVariant) -> ExportVariantRecord? {
      router.variants(forAssetId: "asset", placement: placement)[variant]
    }

    func filename(_ assetId: String = "asset") -> String? {
      router.variants(forAssetId: assetId, placement: placement)[.original]?.filename
    }

    func isClaimed(_ name: String, excluding assetId: String = "someone-else") -> Bool {
      router.isFilenameClaimed(
        name, placement: placement, subfolder: nil, exceptVariant: .original,
        of: assetId)
    }

    func seed(_ assetId: String, filename: String) async throws {
      if collection {
        collections.upsertPlacement(placement)
        collections.markVariantExported(
          assetId: assetId, placement: placement, variant: .original, filename: filename,
          exportedAt: Date())
        try await collections.flush()
      } else {
        timeline.markVariantExported(
          assetId: assetId, variant: .original, year: 2025, month: 6,
          relPath: placement.relativePath, filename: filename, exportedAt: Date())
        try await timeline.flush()
      }
    }

    func file(_ destination: String, snapshot: Bool) -> URL {
      let name =
        switch (collection, snapshot) {
        case (true, true): CollectionExportRecordStore.Constants.snapshotFileName
        case (true, false): CollectionExportRecordStore.Constants.logFileName
        case (false, true): ExportRecordStore.Constants.snapshotFileName
        case (false, false): ExportRecordStore.Constants.logFileName
        }
      return root.appendingPathComponent(destination).appendingPathComponent(name)
    }

    func cleanup() {
      timeline.flushForTesting()
      collections.flushForTesting()
      try? FileManager.default.removeItem(at: root)
    }
  }

  private static let committed = "IMG_0001 (1).JPG"

  /// The store is ready and still on the commit's destination.
  @Test(arguments: [false, true])
  func readyStoreRecordsTheAcknowledgedName(collection: Bool) async throws {
    let f = Fixture(collection: collection)
    defer { f.cleanup() }
    let acknowledge = try f.capture()
    await acknowledge(Self.committed)
    #expect(f.filename() == Self.committed)
    #expect(f.isClaimed("img_0001 (1).jpg"))
    #expect(!f.isClaimed(Self.committed, excluding: "asset"))
    f.select("A")
    #expect(f.filename() == Self.committed)
    #expect(f.isClaimed(Self.committed))
  }

  /// A nil acknowledgement records nothing.
  @Test(arguments: [false, true])
  func nilAcknowledgementRecordsNothing(collection: Bool) async throws {
    let f = Fixture(collection: collection)
    defer { f.cleanup() }
    let acknowledge = try f.capture()
    await acknowledge(nil)
    #expect(f.filename() == nil)
    #expect(!f.isClaimed(Self.committed))
  }

  /// The commit's destination loaded corrupt: the completion is deferred until the reset
  /// and then recorded under the acknowledged name.
  @Test(arguments: [false, true])
  func deferredCompletionRecordsTheAcknowledgedName(collection: Bool) async throws {
    let f = Fixture(collection: collection)
    defer { f.cleanup() }
    try await f.seed("old", filename: "OLD.JPG")
    let acknowledge = try f.capture()
    f.select("B")
    try Data("corrupt snapshot".utf8).write(to: f.file("A", snapshot: true))
    f.select("A")
    #expect(f.state == .failed)
    await acknowledge(Self.committed)
    #expect(f.filename() == nil)
    if collection { f.collections.resetToEmpty() } else { f.timeline.resetToEmpty() }
    #expect(f.state == .ready)
    #expect(f.filename() == Self.committed)
    #expect(f.isClaimed(Self.committed))
    #expect(!f.isClaimed("OLD.JPG"))
  }

  /// Another destination is active: the completion is written to the commit's own history
  /// and is there under the acknowledged name when that destination is selected again.
  @Test(arguments: [false, true])
  func parkedCompletionRecordsTheAcknowledgedName(collection: Bool) async throws {
    let f = Fixture(collection: collection)
    defer { f.cleanup() }
    let acknowledge = try f.capture()
    f.select("B")
    await acknowledge(Self.committed)
    #expect(f.filename() == nil)
    #expect(!f.isClaimed(Self.committed))
    f.select("A")
    #expect(f.filename() == Self.committed)
    #expect(f.isClaimed(Self.committed))
  }

  /// The commit's destination came back unreadable: its parked history is restored, with
  /// its claims, and the completion is added under the acknowledged name.
  @Test(arguments: [false, true])
  func restoredSnapshotRecordsTheAcknowledgedName(collection: Bool) async throws {
    let f = Fixture(collection: collection)
    defer { f.cleanup() }
    try await f.seed("old", filename: "OLD.JPG")
    let acknowledge = try f.capture()
    f.select("B")
    let log = f.file("A", snapshot: false)
    let logBytes = try Data(contentsOf: log)
    try FileManager.default.removeItem(at: log)
    try FileManager.default.createDirectory(at: log, withIntermediateDirectories: false)
    f.select("A")
    #expect(f.state == .persistenceFailed)
    #expect(!f.isClaimed("OLD.JPG"))
    await acknowledge(Self.committed)
    #expect(f.filename() == Self.committed)
    #expect(f.filename("old") == "OLD.JPG")
    #expect(f.isClaimed("OLD.JPG"))
    #expect(f.isClaimed(Self.committed))
    // Still unsaved: switching away and back restores the retained history and its claims.
    f.select("B")
    f.select("A")
    #expect(f.state == .persistenceFailed)
    #expect(f.isClaimed("OLD.JPG"))
    #expect(f.isClaimed(Self.committed))
    try FileManager.default.removeItem(at: log)
    try logBytes.write(to: log)
    if collection { f.collections.retryPersistence() } else { f.timeline.retryPersistence() }
    #expect(f.state == .ready)
    f.select("B")
    f.select("A")
    #expect(f.filename() == Self.committed)
    #expect(f.isClaimed(Self.committed))
  }

  /// An edited fallback records the edit as backed up by the original without naming a
  /// file, whether the store was active or parked when the commit was acknowledged, so the
  /// original's file is claimed only by the original.
  @Test(arguments: [false, true], [false, true])
  func editedFallbackNamesNoFile(collection: Bool, parked: Bool) async throws {
    let f = Fixture(collection: collection)
    defer { f.cleanup() }
    let acknowledge = try f.capture(fallback: true)
    if parked { f.select("B") }
    await acknowledge("IMG_0001_orig.JPG")
    if parked { f.select("A") }

    #expect(f.variant(.original)?.filename == "IMG_0001_orig.JPG")
    #expect(f.variant(.edited)?.reason == .editedUnavailableOriginalBackedUp)
    #expect(f.variant(.edited)?.filename == nil)
    #expect(!f.isClaimed("IMG_0001_orig.JPG", excluding: "asset"))
    #expect(f.isClaimed("IMG_0001_orig.JPG"))
  }
}
