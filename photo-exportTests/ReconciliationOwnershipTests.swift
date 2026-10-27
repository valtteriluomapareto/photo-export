import Foundation
import Testing

@testable import Photo_Export

actor GatedReconciliationFileChecker: ReconciliationFileChecking {
  private var gates: [AsyncCheckpoint] = []
  private var nextFailure: Int?
  /// Probes and root checks started, counted on entry.
  private(set) var isFileCalls = 0
  private(set) var validateRootCalls = 0

  func suspendNextProbe(at gate: AsyncCheckpoint) { gates.append(gate) }
  func failNextProbe(code: Int) { nextFailure = code }

  func isFile(atPath path: String) async throws -> Bool {
    isFileCalls += 1
    let gate = gates.isEmpty ? nil : gates.removeFirst()
    let failure = nextFailure
    nextFailure = nil
    let outcome: Result<Bool, Error>
    do {
      if let failure { throw NSError(domain: NSPOSIXErrorDomain, code: failure) }
      outcome = .success(try await ReconciliationFileChecker().isFile(atPath: path))
    } catch { outcome = .failure(error) }
    if let gate { await gate.enter() }
    return try outcome.get()
  }

  func validateRoot(atPath path: String) async throws {
    validateRootCalls += 1
    try await ReconciliationFileChecker().validateRoot(atPath: path)
  }
}

@MainActor
@Suite(.timeLimit(.minutes(2)))
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
    let root = TestScratch.directory("ReconciliationOwnership")
    let checker = GatedReconciliationFileChecker()
    let timeline: ExportRecordStore
    let collection: CollectionExportRecordStore
    let placement = ExportPlacement.favorites()
    let date = Date(timeIntervalSince1970: 1_700_000_000)

    var recordsRoot: URL { root.appendingPathComponent("Records") }
    var mediaA: URL { root.appendingPathComponent("MediaA") }
    var mediaB: URL { root.appendingPathComponent("MediaB") }
    var relPath: String { kind == .timeline ? "2025/03/" : placement.relativePath }

    init(_ kind: StoreKind) async throws {
      self.kind = kind
      timeline = ExportRecordStore(
        baseDirectoryURL: root.appendingPathComponent("Records"), reconciliationFileChecker: checker
      )
      collection = CollectionExportRecordStore(
        baseDirectoryURL: root.appendingPathComponent("Records"), reconciliationFileChecker: checker
      )
      try FileManager.default.createDirectory(at: mediaA, withIntermediateDirectories: true)
      try FileManager.default.createDirectory(at: mediaB, withIntermediateDirectories: true)
      await configure("A")
    }

    func configure(_ id: String?) async {
      await timeline.configureAndWait(for: id)
      await collection.configureAndWait(for: id)
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

    func status(assetId: String) -> ExportStatus? {
      switch kind {
      case .timeline: timeline.exportInfo(assetId: assetId)?.variants[.original]?.status
      case .collection:
        collection.exportInfo(assetId: assetId, placement: placement)?.variants[.original]?.status
      }
    }

    func info() -> ExportVariantRecord? {
      switch kind {
      case .timeline: timeline.exportInfo(assetId: "same")?.variants[.original]
      case .collection:
        collection.exportInfo(assetId: "same", placement: placement)?.variants[.original]
      }
    }

    func reconcile(at url: URL, isCurrent: @MainActor () -> Bool = { true }) async throws -> Summary
    {
      switch kind {
      case .timeline:
        let result = try await timeline.reconcileAgainstFilesystem(at: url, isCurrent: isCurrent)
        return Summary(variants: result.prunedVariants, records: result.prunedRecords)
      case .collection:
        let result = try await collection.reconcileAgainstFilesystem(at: url, isCurrent: isCurrent)
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

    func reopenedInfo(_ id: String) async -> ExportVariantRecord? {
      flush()
      switch kind {
      case .timeline:
        let store = ExportRecordStore(baseDirectoryURL: recordsRoot)
        await store.configureAndWait(for: id)
        defer { store.drainSynchronously() }
        return store.exportInfo(assetId: "same")?.variants[.original]
      case .collection:
        let store = CollectionExportRecordStore(baseDirectoryURL: recordsRoot)
        await store.configureAndWait(for: id)
        defer { store.drainSynchronously() }
        return store.exportInfo(assetId: "same", placement: placement)?.variants[.original]
      }
    }

    func flush() {
      timeline.drainSynchronously()
      collection.drainSynchronously()
    }
    func cleanup() {
      flush()
      try? FileManager.default.removeItem(at: root)
    }
  }

  /// Cancelling a reconcile stops new probes: the probe in flight finishes, no further
  /// probe or root check starts, and nothing is pruned. The uncancelled control proves the
  /// same seed prunes every variant.
  @Test(arguments: StoreKind.allCases, [false, true])
  func cancellationStartsNoFurtherProbes(kind: StoreKind, cancel: Bool) async throws {
    let fixture = try await Fixture(kind)
    defer { fixture.cleanup() }
    for assetId in ["a", "b", "c"] { fixture.seed(assetId: assetId) }
    let gate = AsyncCheckpoint()
    try await withCleanup {
      await fixture.checker.suspendNextProbe(at: gate)
      let run = Task { try await fixture.reconcile(at: fixture.mediaA) }
      let probing = await gate.waitForEnter(count: 1)
      try #require(probing)
      if cancel { run.cancel() }
      await gate.releaseAll()
      let summary = try await run.value
      let probes = await fixture.checker.isFileCalls
      let rootChecks = await fixture.checker.validateRootCalls
      #expect(probes == (cancel ? 1 : 3))
      #expect(rootChecks == (cancel ? 0 : 1))
      #expect(summary.variants == (cancel ? 0 : 3))
      let stillDone = ["a", "b", "c"].filter { fixture.status(assetId: $0) == .done }
      #expect(stillDone.count == (cancel ? 3 : 0))
    } cleanup: {
      await gate.releaseAll()
    }
  }

  @Test(arguments: StoreKind.allCases, Reconfiguration.allCases)
  func reconfigurationRejectsOldDestinationPrunes(kind: StoreKind, change: Reconfiguration)
    async throws
  {
    let fixture = try await Fixture(kind)
    defer { fixture.cleanup() }
    fixture.seed()
    fixture.flush()
    await fixture.configure("B")
    fixture.seed()
    fixture.flush()
    let mediaB = try fixture.plant(at: fixture.mediaB)
    let beforeB = fixture.info()
    await fixture.configure("A")
    let gate = AsyncCheckpoint()
    await fixture.checker.suspendNextProbe(at: gate)
    let old = Task { try await fixture.reconcile(at: fixture.mediaA) }
    await gate.waitForEnter(count: 1)
    switch change {
    case .other: await fixture.configure("B")
    case .roundTrip:
      await fixture.configure(nil)
      await fixture.configure("A")
    case .sameID: await fixture.configure("A")
    }
    let beforeResume = fixture.info()
    await gate.releaseAll()
    let summary = try await old.value
    #expect(summary.variants == 0 && summary.records == 0)
    #expect(fixture.info() == beforeResume)
    #expect(await fixture.reopenedInfo(change == .other ? "B" : "A") == beforeResume)
    #expect(await fixture.reopenedInfo("B") == beforeB)
    #expect(try Data(contentsOf: mediaB) == Data("destination media stays untouched".utf8))
  }

  @Test(arguments: StoreKind.allCases, [false, true])
  func newerRecordCannotBePrunedEvenWhenValueIsIdentical(kind: StoreKind, identical: Bool)
    async throws
  {
    let fixture = try await Fixture(kind)
    defer { fixture.cleanup() }
    fixture.seed()
    let before = fixture.info()
    let gate = AsyncCheckpoint()
    await fixture.checker.suspendNextProbe(at: gate)
    let old = Task { try await fixture.reconcile(at: fixture.mediaA) }
    await gate.waitForEnter(count: 1)
    let name = identical ? "same.jpg" : "new.jpg"
    let media = try fixture.plant(at: fixture.mediaA, filename: name)
    fixture.seed(filename: name)
    if identical { #expect(fixture.info() == before) }
    let updated = fixture.info()
    await gate.releaseAll()
    let summary = try await old.value
    #expect(summary.variants == 0 && summary.records == 0)
    #expect(fixture.info() == updated)
    #expect(await fixture.reopenedInfo("A") == updated)
    #expect(try Data(contentsOf: media) == Data("destination media stays untouched".utf8))
  }

  @Test(arguments: StoreKind.allCases, [false, true])
  func cancelledOrSupersededOperationCannotPrune(kind: StoreKind, taskCancellation: Bool)
    async throws
  {
    let fixture = try await Fixture(kind)
    defer { fixture.cleanup() }
    fixture.seed()
    let expected = fixture.info()
    var current = true
    let gate = AsyncCheckpoint()
    await fixture.checker.suspendNextProbe(at: gate)
    let old = Task { try await fixture.reconcile(at: fixture.mediaA, isCurrent: { current }) }
    await gate.waitForEnter(count: 1)
    if taskCancellation { old.cancel() } else { current = false }
    await gate.releaseAll()
    let summary = try await old.value
    #expect(summary.variants == 0 && summary.records == 0)
    #expect(await fixture.reopenedInfo("A") == expected)
  }

  @Test(arguments: StoreKind.allCases)
  func newerNoOpReconciliationSupersedesOldNegativeProbe(kind: StoreKind) async throws {
    let fixture = try await Fixture(kind)
    defer { fixture.cleanup() }
    fixture.seed()
    let expected = fixture.info()
    let gate = AsyncCheckpoint()
    await fixture.checker.suspendNextProbe(at: gate)
    let old = Task { try await fixture.reconcile(at: fixture.mediaA) }
    await gate.waitForEnter(count: 1)
    try fixture.plant(at: fixture.mediaA)
    let newer = try await fixture.reconcile(at: fixture.mediaA)
    #expect(newer.variants == 0 && newer.records == 0)
    await gate.releaseAll()
    let stale = try await old.value
    #expect(stale.variants == 0 && stale.records == 0)
    #expect(await fixture.reopenedInfo("A") == expected)
  }

  private func makeImportManager(_ fixture: Fixture, destination: FakeExportDestination)
    -> ExportManager
  {
    ExportManager(
      photoLibraryService: FakePhotoLibraryService(), exportDestination: destination,
      exportRecordStore: fixture.timeline, collectionExportRecordStore: fixture.collection,
      assetResourceWriter: FakeAssetResourceWriter(),
      localHEICStorage: LocalHEICStorage(root: TestScratch.directory("ExportHEIC")),
      fileSystem: FakeFileSystem(),
      userDefaults: TestScratch.defaults("ReconciliationOwnership"))
  }

  @Test(arguments: StoreKind.allCases, Interruption.allCases)
  func importCannotPruneAfterTaskOrQueueGenerationCancellation(
    kind: StoreKind, interruption: Interruption
  ) async throws {
    let fixture = try await Fixture(kind)
    let destination = FakeExportDestination()
    destination.selectedFolderURL = fixture.mediaA
    let manager = makeImportManager(fixture, destination: destination)
    defer {
      fixture.cleanup()
      destination.cleanup()
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
    #expect(await fixture.reopenedInfo("A") == expected)
    #expect(manager.importResult == nil)
    #expect(!manager.isImporting && manager.importStage == nil && manager.importError == nil)
    #expect(destination.endScopedAccessCount == 1)
  }

  @Test(arguments: StoreKind.allCases)
  func lateCancelledImportCannotPruneOrCleanUpItsParkedReplacement(kind: StoreKind) async throws {
    let fixture = try await Fixture(kind)
    let destination = FakeExportDestination()
    destination.selectedFolderURL = fixture.mediaA
    let manager = makeImportManager(fixture, destination: destination)
    defer {
      fixture.cleanup()
      destination.cleanup()
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
  func invalidMetadataRejectsWholeBatch(kind: StoreKind) async throws {
    let fixture = try await Fixture(kind)
    defer { fixture.cleanup() }
    fixture.seed()
    fixture.seed(assetId: "also-missing")
    fixture.seed(filename: nil, assetId: "corrupt")
    await #expect(throws: ReconciliationVerificationError.self) {
      try await fixture.reconcile(at: fixture.mediaA)
    }
    #expect(await fixture.reopenedInfo("A")?.status == .done)
  }

  enum ErrorInvalidation: CaseIterable { case sameID, mutation, reconciliation, task, generation }

  @Test(.timeLimit(.minutes(1)), arguments: StoreKind.allCases, ErrorInvalidation.allCases)
  func obsoleteProbeErrorIsDiscarded(kind: StoreKind, invalidation: ErrorInvalidation) async throws
  {
    let fixture = try await Fixture(kind)
    fixture.seed()
    fixture.flush()
    let gate = AsyncCheckpoint()
    await fixture.checker.suspendNextProbe(at: gate)
    await fixture.checker.failNextProbe(code: Int(EIO))
    var current = true
    let old = Task { try await fixture.reconcile(at: fixture.mediaA, isCurrent: { current }) }
    var failure: Error?
    do {
      await gate.waitForEnter(count: 1)
      try #require(await gate.enteredSoFar == 1)
      switch invalidation {
      case .sameID: await fixture.configure("A")
      case .mutation: fixture.seed(assetId: "newer")
      case .reconciliation: _ = try await fixture.reconcile(at: fixture.mediaA)
      case .task: old.cancel()
      case .generation: current = false
      }
      let before = fixture.info()
      await gate.releaseAll()
      let result = try await old.value
      #expect(result.variants == 0 && result.records == 0)
      #expect(fixture.info() == before)
    } catch { failure = error }
    await gate.releaseAll()
    _ = try? await old.value
    fixture.cleanup()
    if let failure { throw failure }
  }
}
