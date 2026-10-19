import Foundation
import Testing

@testable import Photo_Export

@MainActor
@Suite(.timeLimit(.minutes(2)))
struct ReconciliationErrorSafetyTests {
  @MainActor
  private final class Fixture {
    let root = TestScratch.directory("ReconciliationErrorSafety")
    var media: URL { root.appendingPathComponent("Media") }
    var records: URL { root.appendingPathComponent("Records") }
    let collection: Bool
    let placement: ExportPlacement
    let timeline: ExportRecordStore
    let collections: CollectionExportRecordStore

    init(collection: Bool, checker: any ReconciliationFileChecking = ReconciliationFileChecker())
      throws
    {
      self.collection = collection
      placement = collection ? .favorites() : .timeline(year: 2025, month: 3)
      timeline = ExportRecordStore(
        baseDirectoryURL: root.appendingPathComponent("Records"), reconciliationFileChecker: checker
      )
      collections = CollectionExportRecordStore(
        baseDirectoryURL: root.appendingPathComponent("Records"), reconciliationFileChecker: checker
      )
      timeline.configure(for: "A")
      collections.configure(for: "A")
      collections.upsertPlacement(.favorites())
      try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
    }

    func seed(_ filename: String) {
      if collection {
        collections.markVariantExported(
          assetId: filename, placement: placement, variant: .original, filename: filename,
          exportedAt: Date())
      } else {
        timeline.markVariantExported(
          assetId: filename, variant: .original, year: 2025, month: 3,
          relPath: placement.relativePath, filename: filename, exportedAt: Date())
      }
    }

    func info(_ filename: String) -> ExportVariantRecord? {
      if collection {
        return collections.exportInfo(assetId: filename, placement: placement)?.variants[.original]
      }
      return timeline.exportInfo(assetId: filename)?.variants[.original]
    }

    func reconcile() async throws -> Int {
      if collection {
        return try await collections.reconcileAgainstFilesystem(at: media).prunedVariants
      }
      return try await timeline.reconcileAgainstFilesystem(at: media).prunedVariants
    }

    func cleanup() async {
      try? await timeline.flush()
      try? await collections.flush()
      try? FileManager.default.removeItem(at: root)
    }
  }

  private struct FaultChecker: ReconciliationFileChecking {
    let code: Int
    func isFile(atPath path: String) async throws -> Bool {
      if path.hasSuffix("ERROR.JPG") { throw NSError(domain: NSPOSIXErrorDomain, code: code) }
      return try await ReconciliationFileChecker().isFile(atPath: path)
    }
    func validateRoot(atPath path: String) async throws {
      try await ReconciliationFileChecker().validateRoot(atPath: path)
    }
  }

  private actor LateFailureChecker: ReconciliationFileChecking {
    private(set) var probes = 0
    func isFile(atPath path: String) async throws -> Bool {
      probes += 1
      if probes == 2 { throw NSError(domain: NSPOSIXErrorDomain, code: Int(EIO)) }
      return false
    }
    func validateRoot(atPath path: String) async throws {
      try await ReconciliationFileChecker().validateRoot(atPath: path)
    }
  }

  @Test(arguments: [false, true])
  func lookupErrorPreservesEntirePruneBatchAfterReload(collection: Bool) async throws {
    let root = TestScratch.directory("ReconciliationErrorSafety")
    defer { try? FileManager.default.removeItem(at: root) }
    let media = root.appendingPathComponent("Media")
    let records = root.appendingPathComponent("Records")
    let placement: ExportPlacement = collection ? .favorites() : .timeline(year: 2025, month: 3)
    let directory = media.appendingPathComponent(placement.relativePath)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data("present".utf8).write(to: directory.appendingPathComponent("PRESENT.JPG"))
    try FileManager.default.createSymbolicLink(
      atPath: directory.appendingPathComponent("LOOP.JPG").path,
      withDestinationPath: "LOOP.JPG")
    let timeline = ExportRecordStore(baseDirectoryURL: records)
    let collections = CollectionExportRecordStore(baseDirectoryURL: records)
    timeline.configure(for: "A")
    collections.configure(for: "A")
    collections.upsertPlacement(.favorites())
    for filename in ["PRESENT.JPG", "MISSING.JPG", "LOOP.JPG"] {
      if collection {
        collections.markVariantExported(
          assetId: filename, placement: placement, variant: .original,
          filename: filename, exportedAt: Date(timeIntervalSince1970: 1_700_000_000))
      } else {
        timeline.markVariantExported(
          assetId: filename, variant: .original, year: 2025, month: 3,
          relPath: placement.relativePath, filename: filename,
          exportedAt: Date(timeIntervalSince1970: 1_700_000_000))
      }
    }
    try await timeline.flush()
    try await collections.flush()
    if collection {
      let before = collections.recordBodies
      await #expect(throws: ReconciliationVerificationError.self) {
        try await collections.reconcileAgainstFilesystem(at: media)
      }
      #expect(collections.recordBodies == before)
      try await collections.flush()
      let fresh = CollectionExportRecordStore(baseDirectoryURL: records)
      fresh.configure(for: "A")
      #expect(fresh.recordBodies == before)
    } else {
      let before = timeline.recordsById
      await #expect(throws: ReconciliationVerificationError.self) {
        try await timeline.reconcileAgainstFilesystem(at: media)
      }
      #expect(timeline.recordsById == before)
      try await timeline.flush()
      let fresh = ExportRecordStore(baseDirectoryURL: records)
      fresh.configure(for: "A")
      #expect(fresh.recordsById == before)
    }
  }

  @Test(arguments: [false, true], [Int(EACCES), Int(EIO), Int(ENOTCONN)])
  func verificationFailuresNeverCommitMissingCandidates(collection: Bool, code: Int) async throws {
    let f = try Fixture(collection: collection, checker: FaultChecker(code: code))
    f.seed("MISSING.JPG")
    f.seed("ERROR.JPG")
    let before = f.info("MISSING.JPG")
    await #expect(throws: (any Error).self) { try await f.reconcile() }
    #expect(f.info("MISSING.JPG") == before)
    #expect(f.info("ERROR.JPG")?.status == .done)
    await f.cleanup()
  }

  @Test(arguments: [false, true])
  func laterProbeFailureDiscardsAlreadyAccumulatedMissingCandidate(collection: Bool) async throws {
    let checker = LateFailureChecker()
    let f = try Fixture(collection: collection, checker: checker)
    f.seed("FIRST.JPG")
    f.seed("SECOND.JPG")
    await #expect(throws: (any Error).self) { try await f.reconcile() }
    #expect(await checker.probes == 2)
    #expect(f.info("FIRST.JPG")?.status == .done)
    #expect(f.info("SECOND.JPG")?.status == .done)
    try await f.timeline.flush()
    try await f.collections.flush()
    if collection {
      let fresh = CollectionExportRecordStore(baseDirectoryURL: f.records)
      fresh.configure(for: "A")
      for filename in ["FIRST.JPG", "SECOND.JPG"] {
        #expect(
          fresh.exportInfo(assetId: filename, placement: f.placement)?.variants[.original]?.status
            == .done)
      }
    } else {
      let fresh = ExportRecordStore(baseDirectoryURL: f.records)
      fresh.configure(for: "A")
      for filename in ["FIRST.JPG", "SECOND.JPG"] {
        #expect(fresh.exportInfo(assetId: filename)?.variants[.original]?.status == .done)
      }
    }
    await f.cleanup()
  }

  @Test func malformedCollectionDirectoryCannotPruneExistingVideo() async throws {
    let f = try Fixture(collection: true)
    let malformed = ExportPlacement(
      kind: .favorites, id: f.placement.id, displayName: "Favorites",
      collectionLocalIdentifier: nil, relativePath: "Collections/Favorites", createdAt: Date())
    f.collections.upsertPlacement(malformed)
    let directory = f.media.appendingPathComponent("Collections/Favorites/videos")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data("existing video".utf8).write(to: directory.appendingPathComponent("FILE.MOV"))
    for filename in ["FILE.MOV", "MISSING.MOV"] {
      f.collections.markVariantExported(
        assetId: filename, placement: malformed, variant: .original, filename: filename,
        exportedAt: Date(timeIntervalSince1970: 1_700_000_000), subfolder: "videos")
    }
    let before = f.collections.recordBodies
    await #expect(throws: ReconciliationVerificationError.self) { try await f.reconcile() }
    #expect(f.collections.recordBodies == before)
    try await f.collections.flush()
    let fresh = CollectionExportRecordStore(baseDirectoryURL: f.records)
    fresh.configure(for: "A")
    #expect(fresh.recordBodies == before)
    #expect(
      try Data(contentsOf: directory.appendingPathComponent("FILE.MOV"))
        == Data("existing video".utf8))
    await f.cleanup()
  }

  @Test(arguments: [false, true])
  func genuineChildMissingAndNotDirectoryPathsArePruned(collection: Bool) async throws {
    let f = try Fixture(collection: collection)
    f.seed("ENOENT.JPG")
    #expect(try await f.reconcile() == 1)
    f.seed("ENOTDIR.JPG")
    // The placement's parent is now a regular file, so a child cannot exist.
    let parent = f.media.appendingPathComponent(f.placement.relativePath)
      .deletingLastPathComponent()
    try FileManager.default.createDirectory(
      at: parent.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("not a directory".utf8).write(to: parent)
    #expect(try await f.reconcile() == 1)
    #expect(f.info("ENOTDIR.JPG") == nil)
    await f.cleanup()
  }

  @Test func checkerFollowsValidFileLinksAndRejectsOtherTypes() async throws {
    let root = TestScratch.directory("ReconciliationErrorSafety")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let file = root.appendingPathComponent("file")
    let link = root.appendingPathComponent("link")
    try Data("bytes".utf8).write(to: file)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
    #expect(try await ReconciliationFileChecker().isFile(atPath: link.path))
    await #expect(throws: ReconciliationVerificationError.self) {
      try await ReconciliationFileChecker().isFile(atPath: root.path)
    }
  }

  @Test(.timeLimit(.minutes(1)), arguments: [false, true])
  func rootDisappearingAfterFileProbesRejectsPrunes(collection: Bool) async throws {
    let checker = GatedReconciliationFileChecker()
    let f = try Fixture(collection: collection, checker: checker)
    f.seed("MISSING.JPG")
    let before = f.info("MISSING.JPG")
    let gate = AsyncCheckpoint()
    await checker.suspendNextProbe(at: gate)
    let operation = Task { try await f.reconcile() }
    var failure: Error?
    do {
      await gate.waitForEnter(count: 1)
      try #require(await gate.enteredSoFar == 1)
      try FileManager.default.removeItem(at: f.media)
      await gate.releaseAll()
      await #expect(throws: ReconciliationVerificationError.self) { try await operation.value }
      #expect(f.info("MISSING.JPG") == before)
    } catch { failure = error }
    await gate.releaseAll()
    _ = try? await operation.value
    await f.cleanup()
    if let failure { throw failure }
  }

  @Test(arguments: [false, true])
  func nonDirectoryRootCannotAuthorizePruning(collection: Bool) async throws {
    let f = try Fixture(collection: collection)
    f.seed("MISSING.JPG")
    try FileManager.default.removeItem(at: f.media)
    try Data("file".utf8).write(to: f.media)
    await #expect(throws: ReconciliationVerificationError.self) { try await f.reconcile() }
    #expect(f.info("MISSING.JPG")?.status == .done)
    await f.cleanup()
  }

  @Test(arguments: ["", "../escape.JPG", "/absolute.JPG", "a/b.JPG", ".", ".."])
  func unsafeStoredFilenameCannotAuthorizePruning(filename: String) async throws {
    let f = try Fixture(collection: false)
    f.seed(filename)
    await #expect(throws: ReconciliationVerificationError.self) { try await f.reconcile() }
    #expect(f.info(filename)?.status == .done)
    await f.cleanup()
  }

  @Test(arguments: [false, true])
  func ownedVerificationFailureIsVisibleAndPreservesAffectedStore(collectionFailure: Bool)
    async throws
  {
    let root = TestScratch.directory("ReconciliationErrorSafety")
    let destination = FakeExportDestination()
    let suite = TestScratch.suiteName("VerificationFailure")
    defer {
      destination.cleanup()
      try? FileManager.default.removeItem(at: root)
    }
    let fault = FaultChecker(code: Int(EIO))
    let normal = ReconciliationFileChecker()
    let timeline = ExportRecordStore(
      baseDirectoryURL: root, reconciliationFileChecker: collectionFailure ? normal : fault)
    let collections = CollectionExportRecordStore(
      baseDirectoryURL: root, reconciliationFileChecker: collectionFailure ? fault : normal)
    timeline.configure(for: "A")
    collections.configure(for: "A")
    collections.upsertPlacement(.favorites())
    for filename in ["MISSING.JPG", "ERROR.JPG"] {
      timeline.markVariantExported(
        assetId: filename, variant: .original, year: 2025, month: 3, relPath: "2025/03/",
        filename: filename, exportedAt: Date(timeIntervalSince1970: 1_700_000_000))
      collections.markVariantExported(
        assetId: filename, placement: .favorites(), variant: .original,
        filename: filename, exportedAt: Date(timeIntervalSince1970: 1_700_000_000))
    }
    try await timeline.flush()
    try await collections.flush()
    let beforeTimeline = timeline.recordsById
    let beforeCollections = collections.recordBodies
    let manager = ExportManager(
      photoLibraryService: FakePhotoLibraryService(), exportDestination: destination,
      exportRecordStore: timeline, collectionExportRecordStore: collections,
      userDefaults: TestScratch.defaults(suiteName: suite))
    manager.startImport()
    await manager.waitForImportCompletion()
    #expect(manager.importError != nil)
    #expect(manager.importResult == nil && !manager.isImporting)
    #expect(collections.recordBodies == beforeCollections)
    // A collection failure does not roll back the earlier healthy timeline batch.
    #expect(timeline.recordsById == (collectionFailure ? [:] : beforeTimeline))
    try await timeline.flush()
    try await collections.flush()
    let fresh = CollectionExportRecordStore(baseDirectoryURL: root)
    fresh.configure(for: "A")
    #expect(fresh.recordBodies == beforeCollections)
    #expect(destination.beginScopedAccessCount == destination.endScopedAccessCount)
  }
}
