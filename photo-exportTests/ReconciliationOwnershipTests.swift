import Foundation
import Testing

@testable import Photo_Export

actor GatedReconciliationFileChecker: ReconciliationFileChecking {
  private var gates: [AsyncCheckpoint] = []

  func suspendNextProbe(at gate: AsyncCheckpoint) { gates.append(gate) }

  func isFile(atPath path: String) async -> Bool {
    let gate = gates.isEmpty ? nil : gates.removeFirst()
    // Capture disk truth before suspension: restoration must not repair an old probe.
    let result = await ReconciliationFileChecker().isFile(atPath: path)
    if let gate { await gate.enter() }
    return result
  }
}

@MainActor
struct ReconciliationOwnershipTests {
  enum StoreKind: CaseIterable, Sendable { case timeline, collection }
  enum Reconfiguration: CaseIterable, Sendable { case other, roundTrip, sameID }
  enum Interruption: CaseIterable, Sendable { case task, generation, unavailable }

  private struct Summary {
    let variants: Int
    let records: Int
  }

  @MainActor
  private final class Fixture {
    let kind: StoreKind
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let checker = GatedReconciliationFileChecker()
    let timeline: ExportRecordStore
    let collection: CollectionExportRecordStore
    let placement = ExportPlacement.favorites()
    let date = Date(timeIntervalSince1970: 1_700_000_000)

    var recordsRoot: URL { root.appendingPathComponent("Records") }
    var mediaA: URL { root.appendingPathComponent("MediaA") }
    var mediaB: URL { root.appendingPathComponent("MediaB") }
    var relPath: String { kind == .timeline ? "2025/03/" : placement.relativePath }

    init(_ kind: StoreKind) throws {
      self.kind = kind
      timeline = ExportRecordStore(
        baseDirectoryURL: root.appendingPathComponent("Records"), reconciliationFileChecker: checker
      )
      collection = CollectionExportRecordStore(
        baseDirectoryURL: root.appendingPathComponent("Records"), reconciliationFileChecker: checker
      )
      try FileManager.default.createDirectory(at: mediaA, withIntermediateDirectories: true)
      try FileManager.default.createDirectory(at: mediaB, withIntermediateDirectories: true)
      configure("A")
    }

    func configure(_ id: String?) {
      timeline.configure(for: id)
      collection.configure(for: id)
    }

    func seed(filename: String? = "same.jpg", assetId: String = "same") {
      let variant = ExportVariantRecord(
        filename: filename, status: .done, exportDate: date, lastError: nil)
      switch kind {
      case .timeline:
        if let filename {
          timeline.markVariantExported(
            assetId: assetId, variant: .original, year: 2025, month: 3,
            relPath: relPath, filename: filename, exportedAt: date)
        } else {
          timeline.bulkImportRecords([
            ExportRecord(
              id: assetId, year: 2025, month: 3, relPath: relPath, variants: [.original: variant])
          ])
        }
      case .collection:
        if collection.placement(id: placement.id) == nil { collection.upsertPlacement(placement) }
        collection.upsert(
          ScopedExportRecord(placement: placement, assetId: assetId, variants: [.original: variant])
        )
      }
    }

    func info() -> ExportVariantRecord? {
      switch kind {
      case .timeline: timeline.exportInfo(assetId: "same")?.variants[.original]
      case .collection:
        collection.exportInfo(assetId: "same", placement: placement)?.variants[.original]
      }
    }

    func reconcile(at url: URL, isCurrent: @MainActor () -> Bool = { true }) async -> Summary {
      switch kind {
      case .timeline:
        let result = await timeline.reconcileAgainstFilesystem(at: url, isCurrent: isCurrent)
        return Summary(variants: result.prunedVariants, records: result.prunedRecords)
      case .collection:
        let result = await collection.reconcileAgainstFilesystem(at: url, isCurrent: isCurrent)
        return Summary(variants: result.prunedVariants, records: result.prunedRecords)
      }
    }

    @discardableResult
    func plant(at media: URL, filename: String = "same.jpg") throws -> URL {
      let dir = media.appendingPathComponent(relPath)
      try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
      let file = dir.appendingPathComponent(filename)
      try Data("destination media stays untouched".utf8).write(to: file)
      return file
    }

    func reopenedInfo(_ id: String) -> ExportVariantRecord? {
      flush()
      switch kind {
      case .timeline:
        let store = ExportRecordStore(baseDirectoryURL: recordsRoot)
        store.configure(for: id)
        defer { store.flushForTesting() }
        return store.exportInfo(assetId: "same")?.variants[.original]
      case .collection:
        let store = CollectionExportRecordStore(baseDirectoryURL: recordsRoot)
        store.configure(for: id)
        defer { store.flushForTesting() }
        return store.exportInfo(assetId: "same", placement: placement)?.variants[.original]
      }
    }

    func flush() {
      timeline.flushForTesting()
      collection.flushForTesting()
    }
    func cleanup() {
      flush()
      try? FileManager.default.removeItem(at: root)
    }
  }

  @Test(arguments: StoreKind.allCases, Reconfiguration.allCases)
  func reconfigurationRejectsOldDestinationPrunes(kind: StoreKind, change: Reconfiguration)
    async throws
  {
    let fixture = try Fixture(kind)
    defer { fixture.cleanup() }
    fixture.seed()
    fixture.flush()
    fixture.configure("B")
    fixture.seed()
    fixture.flush()
    let mediaB = try fixture.plant(at: fixture.mediaB)
    let beforeB = fixture.info()
    fixture.configure("A")
    let gate = AsyncCheckpoint()
    await fixture.checker.suspendNextProbe(at: gate)
    let old = Task { await fixture.reconcile(at: fixture.mediaA) }
    await gate.waitForEnter(count: 1)
    switch change {
    case .other: fixture.configure("B")
    case .roundTrip:
      fixture.configure(nil)
      fixture.configure("A")
    case .sameID: fixture.configure("A")
    }
    let beforeResume = fixture.info()
    await gate.releaseAll()
    let summary = await old.value
    #expect(summary.variants == 0 && summary.records == 0)
    #expect(fixture.info() == beforeResume)
    #expect(fixture.reopenedInfo(change == .other ? "B" : "A") == beforeResume)
    #expect(fixture.reopenedInfo("B") == beforeB)
    #expect(try Data(contentsOf: mediaB) == Data("destination media stays untouched".utf8))
  }

  @Test(arguments: StoreKind.allCases, [false, true])
  func newerRecordCannotBePrunedEvenWhenValueIsIdentical(kind: StoreKind, identical: Bool)
    async throws
  {
    let fixture = try Fixture(kind)
    defer { fixture.cleanup() }
    fixture.seed()
    let before = fixture.info()
    let gate = AsyncCheckpoint()
    await fixture.checker.suspendNextProbe(at: gate)
    let old = Task { await fixture.reconcile(at: fixture.mediaA) }
    await gate.waitForEnter(count: 1)
    let name = identical ? "same.jpg" : "new.jpg"
    let media = try fixture.plant(at: fixture.mediaA, filename: name)
    fixture.seed(filename: name)
    if identical { #expect(fixture.info() == before) }
    let updated = fixture.info()
    await gate.releaseAll()
    let summary = await old.value
    #expect(summary.variants == 0 && summary.records == 0)
    #expect(fixture.info() == updated)
    #expect(fixture.reopenedInfo("A") == updated)
    #expect(try Data(contentsOf: media) == Data("destination media stays untouched".utf8))
  }

  @Test(arguments: StoreKind.allCases, [false, true])
  func cancelledOrSupersededOperationCannotPrune(kind: StoreKind, taskCancellation: Bool)
    async throws
  {
    let fixture = try Fixture(kind)
    defer { fixture.cleanup() }
    fixture.seed()
    let expected = fixture.info()
    var current = true
    let gate = AsyncCheckpoint()
    await fixture.checker.suspendNextProbe(at: gate)
    let old = Task { await fixture.reconcile(at: fixture.mediaA, isCurrent: { current }) }
    await gate.waitForEnter(count: 1)
    if taskCancellation { old.cancel() } else { current = false }
    await gate.releaseAll()
    let summary = await old.value
    #expect(summary.variants == 0 && summary.records == 0)
    #expect(fixture.reopenedInfo("A") == expected)
  }

  @Test(arguments: StoreKind.allCases)
  func newerNoOpReconciliationSupersedesOldNegativeProbe(kind: StoreKind) async throws {
    let fixture = try Fixture(kind)
    defer { fixture.cleanup() }
    fixture.seed()
    let expected = fixture.info()
    let gate = AsyncCheckpoint()
    await fixture.checker.suspendNextProbe(at: gate)
    let old = Task { await fixture.reconcile(at: fixture.mediaA) }
    await gate.waitForEnter(count: 1)
    try fixture.plant(at: fixture.mediaA)
    let newer = await fixture.reconcile(at: fixture.mediaA)
    #expect(newer.variants == 0 && newer.records == 0)
    await gate.releaseAll()
    let stale = await old.value
    #expect(stale.variants == 0 && stale.records == 0)
    #expect(fixture.reopenedInfo("A") == expected)
  }

  private func makeImportManager(_ fixture: Fixture, destination: FakeExportDestination) -> (
    ExportManager, String
  ) {
    let suite = "ReconciliationOwnership-\(UUID().uuidString)"
    let manager = ExportManager(
      photoLibraryService: FakePhotoLibraryService(), exportDestination: destination,
      exportRecordStore: fixture.timeline, collectionExportRecordStore: fixture.collection,
      assetResourceWriter: FakeAssetResourceWriter(), fileSystem: FakeFileSystem(),
      userDefaults: UserDefaults(suiteName: suite)!)
    return (manager, suite)
  }

  @Test(arguments: StoreKind.allCases, Interruption.allCases)
  func importCannotPruneAfterTaskOrQueueGenerationCancellation(
    kind: StoreKind, interruption: Interruption
  ) async throws {
    let fixture = try Fixture(kind)
    let destination = FakeExportDestination()
    destination.selectedFolderURL = fixture.mediaA
    let (manager, suite) = makeImportManager(fixture, destination: destination)
    defer {
      fixture.cleanup()
      destination.cleanup()
      UserDefaults().removePersistentDomain(forName: suite)
    }
    fixture.seed()
    let expected = fixture.info()
    fixture.flush()
    let gate = AsyncCheckpoint()
    await fixture.checker.suspendNextProbe(at: gate)
    manager.startImport()
    let old = try #require(manager.importTask)
    await gate.waitForEnter(count: 1)
    #expect(manager.importStage == .reconcilingDiskState)
    #expect(destination.beginScopedAccessCount == 1 && destination.endScopedAccessCount == 0)
    let generation = manager.generation
    switch interruption {
    case .task: manager.cancelImport()
    case .generation: manager.cancelAndClear()
    case .unavailable: manager.interruptForDestinationUnavailable()
    }
    #expect(manager.generation != generation)
    #expect(old.isCancelled == (interruption == .task))
    #expect(fixture.timeline.destinationId == "A" && fixture.collection.destinationId == "A")
    await gate.releaseAll()
    await old.value
    #expect(fixture.info() == expected)
    #expect(fixture.reopenedInfo("A") == expected)
    #expect(manager.importResult == nil)
    #expect(destination.endScopedAccessCount == 1)
  }

  @Test(arguments: StoreKind.allCases)
  func lateCancelledImportCannotPruneOrCleanUpItsParkedReplacement(kind: StoreKind) async throws {
    let fixture = try Fixture(kind)
    let destination = FakeExportDestination()
    destination.selectedFolderURL = fixture.mediaA
    let (manager, suite) = makeImportManager(fixture, destination: destination)
    defer {
      fixture.cleanup()
      destination.cleanup()
      UserDefaults().removePersistentDomain(forName: suite)
    }
    fixture.seed()
    let expected = fixture.info()
    let oldGate = AsyncCheckpoint()
    await fixture.checker.suspendNextProbe(at: oldGate)
    manager.startImport()
    let old = try #require(manager.importTask)
    await oldGate.waitForEnter(count: 1)
    manager.cancelImport()
    let replacementGate = AsyncCheckpoint()
    await fixture.checker.suspendNextProbe(at: replacementGate)
    manager.startImport()
    let replacement = try #require(manager.importTask)
    await replacementGate.waitForEnter(count: 1)
    let generation = manager.generation
    #expect(destination.beginScopedAccessCount == 2 && destination.endScopedAccessCount == 0)
    await oldGate.releaseAll()
    await old.value
    #expect(manager.generation == generation)
    #expect(manager.isImporting && manager.importStage == .reconcilingDiskState)
    #expect(manager.importResult == nil)
    #expect(fixture.info() == expected)
    #expect(destination.endScopedAccessCount == 1)
    await replacementGate.releaseAll()
    await replacement.value
    #expect(manager.importResult?.prunedVariants == 1 && manager.importResult?.prunedRecords == 1)
    #expect(!manager.isImporting && manager.importStage == .done)
    #expect(destination.endScopedAccessCount == 2)
  }

  @Test(arguments: StoreKind.allCases)
  func healthyBatchPrunesEveryMissingAndCorruptRecord(kind: StoreKind) async throws {
    let fixture = try Fixture(kind)
    defer { fixture.cleanup() }
    fixture.seed()
    fixture.seed(assetId: "also-missing")
    fixture.seed(filename: nil, assetId: "corrupt")
    let result = await fixture.reconcile(at: fixture.mediaA)
    #expect(result.variants == 3 && result.records == 3)
    #expect(fixture.reopenedInfo("A") == nil)
  }
}
