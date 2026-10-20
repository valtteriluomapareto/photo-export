import Foundation
import Testing

@testable import Photo_Export

/// A re-export whose history was lost finds its own earlier files in the folder. A file
/// with the same bytes that no record names is recorded instead of written again, and
/// each record keeps a file of its own.
@MainActor
@Suite(.timeLimit(.minutes(2)))
struct IdenticalFileAdoptionTests {
  @MainActor
  final class Harness {
    let photos = FakePhotoLibraryService()
    let destination = FakeExportDestination()
    let writer = FakeAssetResourceWriter()
    let files: FakeFileSystem
    let storeRoot = TestScratch.directory("IdenticalFileAdoption")
    let timeline: ExportRecordStore
    let collections: CollectionExportRecordStore
    let defaultsName = TestScratch.suiteName("IdenticalFileAdoption")
    let defaults: UserDefaults
    let manager: ExportManager
    private var historyGeneration = 0

    init(files: FakeFileSystem = FakeFileSystem()) {
      self.files = files
      timeline = ExportRecordStore(baseDirectoryURL: storeRoot)
      collections = CollectionExportRecordStore(baseDirectoryURL: storeRoot)
      timeline.configure(for: "history-0")
      collections.configure(for: "history-0")
      defaults = TestScratch.defaults(suiteName: defaultsName)
      manager = ExportManager(
        photoLibraryService: photos, exportDestination: destination,
        exportRecordStore: timeline, collectionExportRecordStore: collections,
        assetResourceWriter: writer, fileSystem: files,
        userDefaults: defaults)
    }

    /// Points both stores at an empty history for the same folder, as when the record
    /// folder is lost or a destination is picked again under a new id.
    func loseRecords() async throws {
      try await timeline.flush()
      try await collections.flush()
      historyGeneration += 1
      timeline.configure(for: "history-\(historyGeneration)")
      collections.configure(for: "history-\(historyGeneration)")
    }

    /// Gives another asset's original a record naming `name` with `claim`'s status, in the
    /// folder for 2025/`month` or its `subfolder`. That asset is not in the photo library, so
    /// no export touches its record.
    func recordOther(
      named name: String, as claim: Claim = .otherAssetDone, month: Int = 6,
      subfolder: String? = nil
    ) {
      let relPath = String(format: "2025/%02d/", month) + (subfolder.map { "\($0)/" } ?? "")
      switch claim {
      case .otherAssetDone:
        timeline.markVariantExported(
          assetId: "other", variant: .original, year: 2025, month: month, relPath: relPath,
          filename: name, exportedAt: Date(), subfolder: subfolder)
      case .otherAssetFailed:
        timeline.markVariantInProgress(
          assetId: "other", variant: .original, year: 2025, month: month, relPath: relPath,
          filename: name, subfolder: subfolder)
        timeline.markVariantFailed(
          assetId: "other", variant: .original, error: "Interrupted", reason: .interrupted,
          at: Date())
      case .otherAssetInProgress:
        timeline.markVariantInProgress(
          assetId: "other", variant: .original, year: 2025, month: month, relPath: relPath,
          filename: name, subfolder: subfolder)
      case .otherAssetPending:
        timeline.bulkImportRecords([
          ExportRecord(
            id: "other", year: 2025, month: month, relPath: relPath,
            variants: [
              .original: ExportVariantRecord(
                filename: name, status: .pending, exportDate: nil, lastError: nil,
                subfolder: subfolder)
            ])
        ])
      }
    }

    /// Every name `assetId`'s `variant` was marked in progress under, in order, read back
    /// from both record logs of the current history. The log of the store the export wrote,
    /// the collection store's when `inCollection`, must exist; a missing one fails the test.
    func inProgressNames(
      of assetId: String, variant: ExportVariant = .original, inCollection: Bool = false
    ) async throws -> [String] {
      try await timeline.flush()
      try await collections.flush()
      let folder = storeRoot.appendingPathComponent("history-\(historyGeneration)")
      let decoder = JSONDecoder()
      decoder.dateDecodingStrategy = .iso8601
      var names: [String] = []
      let inProgress = { (record: ExportVariantRecord?) in
        if let record, record.status == .inProgress, let name = record.filename {
          names.append(name)
        }
      }
      let timelineLog = folder.appendingPathComponent(ExportRecordStore.Constants.logFileName)
      let collectionLog = folder.appendingPathComponent(
        CollectionExportRecordStore.Constants.logFileName)
      try #require(
        FileManager.default.fileExists(atPath: (inCollection ? collectionLog : timelineLog).path))
      for line in try Self.lines(of: timelineLog) {
        let mutation = try decoder.decode(ExportRecordMutation.self, from: line)
        if mutation.id == assetId { inProgress(mutation.record?.variants[variant]) }
      }
      for line in try Self.lines(of: collectionLog) {
        let op = try decoder.decode(CollectionExportRecordStore.LogOp.self, from: line)
        if case .upsertRecord(_, assetId, let body) = op {
          inProgress(body.variants[variant.rawValue])
        }
      }
      return names
    }

    private static func lines(of file: URL) throws -> [Data] {
      guard FileManager.default.fileExists(atPath: file.path) else { return [] }
      return try Data(contentsOf: file).split(separator: UInt8(ascii: "\n")).map { Data($0) }
    }

    func exportMonth(year: Int = 2025, month: Int = 6) async {
      manager.startExportMonth(year: year, month: month)
      await manager.waitForQueueDrained()
    }

    func monthFolder(year: Int = 2025, month: Int = 6) throws -> URL {
      try destination.urlForMonth(year: year, month: month, createIfNeeded: false)
    }

    func contents(of folder: URL) throws -> [String] {
      try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
    }

    func cleanup() async {
      manager.cancelAndClear()
      if let task = manager.currentTask { _ = await finished(task) }
      timeline.flushForTesting()
      collections.flushForTesting()
      destination.cleanup()
      try? FileManager.default.removeItem(at: storeRoot)
      defaults.removePersistentDomain(forName: defaultsName)
    }
  }

  private static let june15 = Calendar.current.date(
    from: DateComponents(year: 2025, month: 6, day: 15))!

  /// Export, lose the records, export again: the folder still holds one file, recorded
  /// under its natural name, with its bytes and timestamps untouched.
  @Test func lostRecordIdenticalFileIsAdopted() async throws {
    let h = Harness()
    try await withCleanup {
      let asset = TestAssetFactory.makeAsset(id: "asset", creationDate: Self.june15)
      let resource = TestAssetFactory.makeResource(originalFilename: "IMG_0001.JPG")
      h.photos.assetsByYearMonth["2025-6"] = [asset]
      h.photos.resourcesByAssetId[asset.id] = [resource]
      await h.exportMonth()
      let folder = try h.monthFolder()
      let file = folder.appendingPathComponent("IMG_0001.JPG")
      let before = try FileManager.default.attributesOfItem(atPath: file.path)

      try await h.loseRecords()
      await h.exportMonth()

      #expect(try h.contents(of: folder) == ["IMG_0001.JPG"])
      let variant = h.timeline.exportInfo(assetId: asset.id)?.variants[.original]
      #expect(variant?.status == .done)
      #expect(variant?.filename == "IMG_0001.JPG")
      #expect(
        try Data(contentsOf: file)
          == FakeAssetResourceWriter.content(for: resource, assetId: asset.id))
      let after = try FileManager.default.attributesOfItem(atPath: file.path)
      #expect(after[.modificationDate] as? Date == before[.modificationDate] as? Date)
      #expect(after[.systemFileNumber] as? Int == before[.systemFileNumber] as? Int)
      #expect(h.writer.writeCalls.count == 2)
      #expect(h.files.moveCalls.count == 1)
      #expect(h.files.timestampCalls.count == 1)
    } cleanup: {
      await h.cleanup()
    }
  }

  /// Two byte-identical assets with the same filename were exported as `IMG_0001.JPG` and
  /// `IMG_0001 (1).JPG`. After the records are lost, re-exporting them in either order
  /// records each against a different one of those files; nothing new is written.
  @Test(arguments: [false, true])
  func identicalAssetsKeepDistinctFilesAfterRecordLoss(reversed: Bool) async throws {
    let h = Harness()
    try await withCleanup {
      let first = TestAssetFactory.makeAsset(id: "first", creationDate: Self.june15)
      let second = TestAssetFactory.makeAsset(id: "second", creationDate: Self.june15)
      let resource = TestAssetFactory.makeResource(originalFilename: "IMG_0001.JPG")
      h.writer.contentAssetIds = [second.id: first.id]
      h.photos.assetsByYearMonth["2025-6"] = [first, second]
      h.photos.resourcesByAssetId[first.id] = [resource]
      h.photos.resourcesByAssetId[second.id] = [resource]
      await h.exportMonth()
      let folder = try h.monthFolder()
      #expect(try h.contents(of: folder) == ["IMG_0001 (1).JPG", "IMG_0001.JPG"])

      try await h.loseRecords()
      h.photos.assetsByYearMonth["2025-6"] = reversed ? [second, first] : [first, second]
      await h.exportMonth()

      #expect(try h.contents(of: folder) == ["IMG_0001 (1).JPG", "IMG_0001.JPG"])
      let names = [first, second].compactMap {
        h.timeline.exportInfo(assetId: $0.id)?.variants[.original]?.filename
      }
      #expect(Set(names) == ["IMG_0001.JPG", "IMG_0001 (1).JPG"])
      #expect(names.count == 2)
      let byFirstInOrder = h.timeline.exportInfo(assetId: (reversed ? second : first).id)
      #expect(byFirstInOrder?.variants[.original]?.filename == "IMG_0001.JPG")
      #expect(h.files.moveCalls.count == 2)
      #expect(h.files.timestampCalls.count == 2)
    } cleanup: {
      await h.cleanup()
    }
  }

  // MARK: - What is not adopted

  enum Unadoptable: String, CaseIterable, CustomTestStringConvertible {
    case differentBytes, middleChunkDiffers, truncated, longer, empty, symlink, hardLink
    case directory
    var testDescription: String { rawValue }
  }

  /// Three chunks, so a compare reads the head, the tail, then the middle chunk.
  private static let threeChunks = Int64(3 * FinalNamePlanner.defaultEdgeChunkSize)

  /// Whatever sits at the natural name stays exactly as it was, and the export lands at
  /// ` (1)`: a file of the same size but other bytes (also when only a middle chunk
  /// differs), a shorter or longer file, an empty file, a symbolic link to an identical
  /// file, a second hard link to an identical file, and a folder.
  @Test(arguments: Unadoptable.allCases)
  func nonIdenticalOrIrregularTargetsAreSuffixedAndUntouched(target: Unadoptable) async throws {
    let h = Harness()
    try await withCleanup {
      let asset = TestAssetFactory.makeAsset(id: "asset", creationDate: Self.june15)
      let resource = TestAssetFactory.makeResource(
        originalFilename: "IMG_0001.JPG",
        fileSize: target == .middleChunkDiffers ? Self.threeChunks : nil)
      h.photos.assetsByYearMonth["2025-6"] = [asset]
      h.photos.resourcesByAssetId[asset.id] = [resource]
      let folder = try h.destination.urlForMonth(year: 2025, month: 6, createIfNeeded: true)
      let natural = folder.appendingPathComponent("IMG_0001.JPG")
      var bytes = FakeAssetResourceWriter.content(for: resource, assetId: asset.id)
      switch target {
      case .differentBytes:
        bytes[bytes.startIndex] ^= 0xff
        try bytes.write(to: natural)
      case .middleChunkDiffers:
        bytes[FinalNamePlanner.defaultEdgeChunkSize + 7] ^= 0xff
        try bytes.write(to: natural)
      case .truncated:
        try bytes.dropLast().write(to: natural)
      case .longer:
        try (bytes + Data([0])).write(to: natural)
      case .empty:
        try Data().write(to: natural)
      case .symlink:
        let identical = folder.appendingPathComponent("elsewhere.bin")
        try bytes.write(to: identical)
        try FileManager.default.createSymbolicLink(at: natural, withDestinationURL: identical)
      case .hardLink:
        let identical = folder.appendingPathComponent("elsewhere.bin")
        try bytes.write(to: identical)
        try FileManager.default.linkItem(at: identical, to: natural)
      case .directory:
        try FileManager.default.createDirectory(at: natural, withIntermediateDirectories: false)
      }
      let before = try? Data(contentsOf: natural)
      let beforeIdentity = try FileIOService().itemIdentity(at: natural)

      await h.exportMonth()

      let variant = h.timeline.exportInfo(assetId: asset.id)?.variants[.original]
      #expect(variant?.status == .done)
      #expect(variant?.filename == "IMG_0001 (1).JPG")
      #expect(try FileIOService().itemIdentity(at: natural) == beforeIdentity)
      #expect((try? Data(contentsOf: natural)) == before)
      #expect(
        try Data(contentsOf: folder.appendingPathComponent("IMG_0001 (1).JPG"))
          == FakeAssetResourceWriter.content(for: resource, assetId: asset.id))
      if target == .middleChunkDiffers {
        let offsets = h.files.chunkReads.filter { $0.url == natural }.map(\.offset)
        let chunk = Int64(FinalNamePlanner.defaultEdgeChunkSize)
        #expect(offsets == [0, Self.threeChunks - chunk, chunk])
      }
    } cleanup: {
      await h.cleanup()
    }
  }

  enum Claim: String, CaseIterable, CustomTestStringConvertible {
    case otherAssetDone, otherAssetFailed, otherAssetInProgress, otherAssetPending
    var testDescription: String { rawValue }
  }

  /// A file another record names is never adopted, whatever that record's status: the
  /// identical file stays with its claimant and the export lands at ` (1)`.
  @Test(arguments: Claim.allCases)
  func fileNamedByAnyOtherRecordIsNotAdopted(claim: Claim) async throws {
    let h = Harness()
    try await withCleanup {
      let asset = TestAssetFactory.makeAsset(id: "asset", creationDate: Self.june15)
      let resource = TestAssetFactory.makeResource(originalFilename: "IMG_0001.JPG")
      h.photos.assetsByYearMonth["2025-6"] = [asset]
      h.photos.resourcesByAssetId[asset.id] = [resource]
      await h.exportMonth()
      try await h.loseRecords()
      h.recordOther(named: "IMG_0001.JPG", as: claim)

      await h.exportMonth()

      #expect(
        h.timeline.exportInfo(assetId: asset.id)?.variants[.original]?.filename
          == "IMG_0001 (1).JPG")
      #expect(try h.contents(of: h.monthFolder()) == ["IMG_0001 (1).JPG", "IMG_0001.JPG"])
    } cleanup: {
      await h.cleanup()
    }
  }

  /// An edited variant on an inherited stem (#127): the original is recorded at
  /// `IMG_0001.JPG`, the edit went to `IMG_0001 (1).JPG` and its record was lost. The
  /// natural name belongs to the asset's own original, so it is skipped even when its bytes
  /// match the edit; the identical ` (1)` is adopted rather than written again as ` (2)`.
  @Test func editedOnInheritedStemSkipsItsOwnOriginalAndAdoptsItsCopy() async throws {
    let h = Harness()
    try await withCleanup {
      let unedited = TestAssetFactory.makeAsset(id: "asset", creationDate: Self.june15)
      let edited = TestAssetFactory.makeAsset(
        id: "asset", creationDate: Self.june15, hasAdjustments: true)
      let original = TestAssetFactory.makeResource(type: .photo, originalFilename: "IMG_0001.JPG")
      let render = TestAssetFactory.makeResource(
        type: .fullSizePhoto, originalFilename: "FullSizeRender.JPG")
      h.manager.versionSelection = .editedWithOriginals
      h.photos.assetsByYearMonth["2025-6"] = [unedited]
      h.photos.resourcesByAssetId[edited.id] = [original]
      await h.exportMonth()
      h.photos.assetsByYearMonth["2025-6"] = [edited]
      h.photos.resourcesByAssetId[edited.id] = [original, render]
      await h.exportMonth()
      let folder = try h.monthFolder()
      #expect(try h.contents(of: folder) == ["IMG_0001 (1).JPG", "IMG_0001.JPG"])
      #expect(
        h.timeline.exportInfo(assetId: edited.id)?.variants[.edited]?.filename
          == "IMG_0001 (1).JPG")
      let moves = h.files.moveCalls.count

      h.timeline.removeVariant(assetId: edited.id, variant: .edited)
      let renderBytes = FakeAssetResourceWriter.content(for: render, assetId: edited.id)
      try renderBytes.write(to: folder.appendingPathComponent("IMG_0001.JPG"))
      await h.exportMonth()

      #expect(try h.contents(of: folder) == ["IMG_0001 (1).JPG", "IMG_0001.JPG"])
      let variants = h.timeline.exportInfo(assetId: edited.id)?.variants
      #expect(variants?[.original]?.filename == "IMG_0001.JPG")
      #expect(variants?[.edited]?.status == .done)
      #expect(variants?[.edited]?.filename == "IMG_0001 (1).JPG")
      #expect(h.files.moveCalls.count == moves)
      #expect(try Data(contentsOf: folder.appendingPathComponent("IMG_0001.JPG")) == renderBytes)
    } cleanup: {
      await h.cleanup()
    }
  }

  // MARK: - Spelling, placements and folders

  private nonisolated static let caseInsensitiveScratch: Bool = {
    let probe = TestScratch.directory("CaseProbe")
    try? FileManager.default.createDirectory(at: probe, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: probe) }
    FileManager.default.createFile(atPath: probe.appendingPathComponent("a").path, contents: nil)
    return FileManager.default.fileExists(atPath: probe.appendingPathComponent("A").path)
  }()

  /// On a volume that ignores case and normalization, an identical file whose name differs
  /// only in case or in Unicode normalization is adopted, and the record keeps the name as
  /// the folder spells it.
  @Test(
    .enabled(if: caseInsensitiveScratch, "Needs a case-insensitive scratch volume"),
    arguments: [
      ("IMG_0001.JPG", "img_0001.jpg"),
      ("Caf\u{E9}.JPG", "Cafe\u{301}.JPG"),
    ])
  func adoptionRecordsTheStoredSpelling(resourceName: String, storedName: String) async throws {
    let h = Harness()
    try await withCleanup {
      let asset = TestAssetFactory.makeAsset(id: "asset", creationDate: Self.june15)
      let resource = TestAssetFactory.makeResource(originalFilename: resourceName)
      h.photos.assetsByYearMonth["2025-6"] = [asset]
      h.photos.resourcesByAssetId[asset.id] = [resource]
      let folder = try h.destination.urlForMonth(year: 2025, month: 6, createIfNeeded: true)
      try FakeAssetResourceWriter.content(for: resource, assetId: asset.id)
        .write(to: folder.appendingPathComponent(storedName))

      await h.exportMonth()

      let recorded = h.timeline.exportInfo(assetId: asset.id)?.variants[.original]?.filename
      #expect(recorded.map { Array($0.unicodeScalars) } == Array(storedName.unicodeScalars))
      #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).count == 1)
      #expect(h.files.moveCalls.isEmpty)
      #expect(h.files.timestampCalls.isEmpty)
    } cleanup: {
      await h.cleanup()
    }
  }

  enum Location: String, CaseIterable, CustomTestStringConvertible {
    case favorites, videosSubfolder
    var testDescription: String { rawValue }
  }

  /// Adoption works the same in a collection folder and in a timeline month's `videos/`.
  @Test(arguments: Location.allCases)
  func lostRecordIdenticalFileIsAdoptedInOtherFolders(location: Location) async throws {
    let h = Harness()
    try await withCleanup {
      let asset: AssetDescriptor
      let relativePath: String
      switch location {
      case .favorites:
        asset = TestAssetFactory.makeAsset(id: "asset", creationDate: Self.june15)
        h.photos.favoritesAssets = [asset]
        h.photos.resourcesByAssetId[asset.id] = [
          TestAssetFactory.makeResource(originalFilename: "IMG_0001.JPG")
        ]
        relativePath = "Collections/Favorites/"
      case .videosSubfolder:
        asset = TestAssetFactory.makeAsset(
          id: "asset", creationDate: Self.june15, mediaType: .video)
        h.photos.assetsByYearMonth["2025-6"] = [asset]
        h.photos.resourcesByAssetId[asset.id] = [
          TestAssetFactory.makeResource(type: .video, originalFilename: "CLIP.MOV")
        ]
        h.manager.videoLayout = .subfolder
        relativePath = "2025/06/videos/"
      }
      let export = {
        if location == .favorites {
          h.manager.startExportFavorites()
        } else {
          h.manager.startExportMonth(year: 2025, month: 6)
        }
        await h.manager.waitForQueueDrained()
      }
      await export()
      try await h.loseRecords()
      if location == .favorites { h.collections.upsertPlacement(.favorites()) }
      await export()

      let folder = try h.destination.urlForRelativeDirectory(relativePath, createIfNeeded: false)
      let variant =
        location == .favorites
        ? h.collections.exportInfo(assetId: asset.id, placement: .favorites())?.variants[
          .original]
        : h.timeline.exportInfo(assetId: asset.id)?.variants[.original]
      #expect(variant?.status == .done)
      #expect(try h.contents(of: folder).count == 1)
      #expect(variant?.filename == (try h.contents(of: folder).first))
      #expect(variant?.subfolder == (location == .videosSubfolder ? "videos" : nil))
      #expect(h.files.moveCalls.count == 1)
      #expect(h.files.timestampCalls.count == 1)
    } cleanup: {
      await h.cleanup()
    }
  }

  // MARK: - Cancellation and staleness

  /// Cancelling while the bytes are being compared stops the comparison before its next
  /// chunk. The tail is read second and the middle last, so holding the tail read and
  /// cancelling must leave the middle unread. The stage is removed, the existing file is
  /// untouched, and nothing is recorded or adopted.
  ///
  /// `cancelAndClear` also cancels the export's Task, so this pins the per-read Task
  /// cancellation check. The generation check alone is pinned by
  /// `VariantExporterTests.staleGenerationStopsTheCompareBeforeItsNextRead` and the
  /// interval by `FinalNamePlannerTests.stopIsAskedOncePerInterval`.
  @Test func cancelDuringTheCompareLeavesNothingBehind() async throws {
    let h = Harness()
    let held = AsyncCheckpoint()
    try await withCleanup {
      let asset = TestAssetFactory.makeAsset(id: "asset", creationDate: Self.june15)
      let resource = TestAssetFactory.makeResource(
        originalFilename: "IMG_0001.JPG", fileSize: Self.threeChunks)
      h.photos.assetsByYearMonth["2025-6"] = [asset]
      h.photos.resourcesByAssetId[asset.id] = [resource]
      await h.exportMonth()
      let folder = try h.monthFolder()
      let natural = folder.appendingPathComponent("IMG_0001.JPG")
      let identity = try FileIOService().itemIdentity(at: natural)
      try await h.loseRecords()
      let middle = Int64(FinalNamePlanner.defaultEdgeChunkSize)
      let tail = Self.threeChunks - middle
      h.files.chunkReadHook = { url, offset in
        if url == natural, offset == tail { await held.enter() }
      }

      h.manager.startExportMonth(year: 2025, month: 6)
      #expect(await held.waitForEnter(count: 1))
      let task = try #require(h.manager.currentTask)
      let readsBefore = h.files.chunkReads.count
      h.manager.cancelAndClear()
      await held.releaseAll()
      _ = await finished(task)

      // The held read finishes; no further chunk is read.
      #expect(h.files.chunkReads.count == readsBefore)
      #expect(!h.files.chunkReads.contains { $0.offset == middle })
      #expect(try h.contents(of: folder) == ["IMG_0001.JPG"])
      #expect(try FileIOService().itemIdentity(at: natural) == identity)
      #expect(h.timeline.exportInfo(assetId: asset.id) == nil)
      #expect(h.files.moveCalls.count == 1)
    } cleanup: {
      await held.releaseAll()
      await h.cleanup()
    }
  }

  /// Gate that holds a filesystem worker until the test releases it.
  final class Gate: @unchecked Sendable {
    let entered = AsyncCheckpoint()
    private let semaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var used = false

    func holdOnce() {
      guard
        lock.withLock({
          if used { return false }
          used = true
          return true
        })
      else { return }
      Task { await entered.enter() }
      // Teardown always releases; the bound only keeps a broken test from stranding the worker.
      if semaphore.wait(timeout: .now() + 60) != .success {
        Issue.record("Adoption gate timed out")
      }
    }

    func release() { semaphore.signal() }
  }

  /// Once an adoption is admitted to the commit, cancelling the run does not undo it: the
  /// record names the existing file, its timestamps are not touched and the stage is gone.
  @Test func adoptionAdmittedBeforeCancellationIsStillRecorded() async throws {
    let h = Harness()
    let gate = Gate()
    try await withCleanup {
      let asset = TestAssetFactory.makeAsset(id: "asset", creationDate: Self.june15)
      h.photos.assetsByYearMonth["2025-6"] = [asset]
      h.photos.resourcesByAssetId[asset.id] = [
        TestAssetFactory.makeResource(originalFilename: "IMG_0001.JPG")
      ]
      await h.exportMonth()
      let folder = try h.monthFolder()
      let natural = folder.appendingPathComponent("IMG_0001.JPG")
      try await h.loseRecords()
      // The planning walk looks the natural name up once; the commit's recheck is the second.
      let lookups = LockedBox(0)
      h.files.identityHook = { url in
        guard url == natural else { return }
        lookups.mutate { $0 += 1 }
        if lookups.value == 2 { gate.holdOnce() }
      }

      h.manager.startExportMonth(year: 2025, month: 6)
      #expect(await gate.entered.waitForEnter(count: 1))
      // Re-marked under the adopted name before the commit was admitted.
      let marked = h.timeline.exportInfo(assetId: asset.id)?.variants[.original]
      #expect(marked?.status == .inProgress)
      #expect(marked?.filename == "IMG_0001.JPG")
      let task = try #require(h.manager.currentTask)
      h.manager.cancelAndClear()
      gate.release()
      _ = await finished(task)

      let variant = h.timeline.exportInfo(assetId: asset.id)?.variants[.original]
      #expect(variant?.status == .done)
      #expect(variant?.filename == "IMG_0001.JPG")
      #expect(try h.contents(of: folder) == ["IMG_0001.JPG"])
      #expect(h.files.timestampCalls.count == 1)
      #expect(h.files.moveCalls.count == 1)
    } cleanup: {
      gate.release()
      await gate.entered.releaseAll()
      await h.cleanup()
    }
  }

  /// A file that changes after its bytes were compared is not adopted: the commit's recheck
  /// sees a different file, the export plans again, finds it different now and writes
  /// ` (1)`.
  @Test func fileChangedAfterTheCompareIsNotAdopted() async throws {
    let h = Harness()
    try await withCleanup {
      let asset = TestAssetFactory.makeAsset(id: "asset", creationDate: Self.june15)
      let resource = TestAssetFactory.makeResource(originalFilename: "IMG_0001.JPG")
      h.photos.assetsByYearMonth["2025-6"] = [asset]
      h.photos.resourcesByAssetId[asset.id] = [resource]
      await h.exportMonth()
      let folder = try h.monthFolder()
      let natural = folder.appendingPathComponent("IMG_0001.JPG")
      try await h.loseRecords()
      var changed = FakeAssetResourceWriter.content(for: resource, assetId: asset.id)
      changed[changed.startIndex] ^= 0xff
      let replacement = changed
      // The planning walk looks the natural name up once; before the commit's recheck (the
      // second lookup) the file is replaced by one of the same size.
      let lookups = LockedBox(0)
      h.files.identityHook = { url in
        guard url == natural else { return }
        lookups.mutate { $0 += 1 }
        if lookups.value == 2 {
          try FileManager.default.removeItem(at: natural)
          try replacement.write(to: natural)
        }
      }

      await h.exportMonth()

      #expect(
        h.timeline.exportInfo(assetId: asset.id)?.variants[.original]?.filename
          == "IMG_0001 (1).JPG")
      #expect(try Data(contentsOf: natural) == replacement)
      #expect(try h.contents(of: folder) == ["IMG_0001 (1).JPG", "IMG_0001.JPG"])
    } cleanup: {
      await h.cleanup()
    }
  }

  /// A claim recorded while the bytes were being compared still prevents the adoption: the
  /// claim is checked again on the main actor before the variant is marked under the name.
  @Test func claimRecordedDuringTheCompareStopsTheAdoption() async throws {
    let h = Harness()
    try await withCleanup {
      let asset = TestAssetFactory.makeAsset(id: "asset", creationDate: Self.june15)
      let resource = TestAssetFactory.makeResource(originalFilename: "IMG_0001.JPG")
      h.photos.assetsByYearMonth["2025-6"] = [asset]
      h.photos.resourcesByAssetId[asset.id] = [resource]
      await h.exportMonth()
      let folder = try h.monthFolder()
      let natural = folder.appendingPathComponent("IMG_0001.JPG")
      try await h.loseRecords()
      let claimed = LockedBox(false)
      h.files.chunkReadHook = { url, _ in
        guard url == natural, !claimed.value else { return }
        claimed.mutate { $0 = true }
        await h.recordOther(named: "IMG_0001.JPG")
      }

      await h.exportMonth()

      #expect(claimed.value)
      #expect(
        h.timeline.exportInfo(assetId: asset.id)?.variants[.original]?.filename
          == "IMG_0001 (1).JPG")
      #expect(
        h.timeline.exportInfo(assetId: "other")?.variants[.original]?.filename == "IMG_0001.JPG")
      #expect(try h.contents(of: folder) == ["IMG_0001 (1).JPG", "IMG_0001.JPG"])
    } cleanup: {
      await h.cleanup()
    }
  }

  enum LivePhotoSide: String, CaseIterable, CustomTestStringConvertible {
    case edited, original
    var testDescription: String { rawValue }
  }

  /// A Live Photo whose image is identical to a file on disk but whose motion file's name
  /// holds something else is not split across stems: both files land at the next stem.
  ///
  /// - Edited: the edit inherits the recorded original's stem, so its image is a suffix slot
  ///   and is held back from adoption because its paired video follows.
  /// - Original (an unedited asset, so only the original side is written): the group stem
  ///   is allocated with both slots free, which moves the pair before any adoption is
  ///   considered. `pairedVideoFollowsItsImageOnEachSide` pins the rule itself.
  @Test(arguments: LivePhotoSide.allCases)
  func livePhotoImageIsNotAdoptedAheadOfItsMotionFile(side: LivePhotoSide) async throws {
    let h = Harness()
    try await withCleanup {
      let edited = side == .edited
      let asset = TestAssetFactory.makeAsset(
        id: "live", creationDate: Self.june15, hasAdjustments: edited, isLivePhoto: true)
      let photo = TestAssetFactory.makeResource(type: .photo, originalFilename: "IMG_0001.HEIC")
      let render = TestAssetFactory.makeResource(
        type: .fullSizePhoto, originalFilename: "FullSizeRender.JPG")
      h.photos.assetsByYearMonth["2025-6"] = [asset]
      h.photos.resourcesByAssetId[asset.id] =
        [photo, TestAssetFactory.makeResource(type: .pairedVideo, originalFilename: "IMG_0001.MOV")]
        + (edited
          ? [
            render,
            TestAssetFactory.makeResource(
              type: .fullSizePairedVideo, originalFilename: "FullSizeRender.MOV"),
          ] : [])
      h.manager.versionSelection = .edited
      h.manager.livePhotosPairedExport = true
      let folder = try h.destination.urlForMonth(year: 2025, month: 6, createIfNeeded: true)
      let imageName = edited ? "IMG_0001.JPG" : "IMG_0001.HEIC"
      let imageBytes = FakeAssetResourceWriter.content(
        for: edited ? render : photo, assetId: asset.id)
      if edited {
        // The original is recorded, so the edit inherits its stem.
        h.timeline.markVariantExported(
          assetId: asset.id, variant: .original, year: 2025, month: 6, relPath: "2025/06/",
          filename: "IMG_0001.HEIC", exportedAt: Date())
        try Data("original".utf8).write(to: folder.appendingPathComponent("IMG_0001.HEIC"))
      }
      // The image's own copy is on disk without a record; a different file holds the
      // motion file's name.
      try imageBytes.write(to: folder.appendingPathComponent(imageName))
      try Data("third-party".utf8).write(to: folder.appendingPathComponent("IMG_0001.MOV"))

      await h.exportMonth()

      let variants = h.timeline.exportInfo(assetId: asset.id)?.variants
      let image: ExportVariant = edited ? .edited : .original
      let video: ExportVariant = edited ? .editedPairedVideo : .originalPairedVideo
      #expect(variants?[image]?.filename == (edited ? "IMG_0001 (1).JPG" : "IMG_0001 (1).HEIC"))
      #expect(variants?[video]?.filename == "IMG_0001 (1).MOV")
      #expect(try Data(contentsOf: folder.appendingPathComponent(imageName)) == imageBytes)
      #expect(
        try Data(contentsOf: folder.appendingPathComponent("IMG_0001.MOV"))
          == Data("third-party".utf8))
    } cleanup: {
      await h.cleanup()
    }
  }

  @Test func pairedVideoFollowsItsImageOnEachSide() {
    let all: [ExportVariant] = [.original, .originalPairedVideo, .edited, .editedPairedVideo]
    #expect(ExportManager.pairedVideoFollows(.original, in: [.original, .originalPairedVideo]))
    #expect(ExportManager.pairedVideoFollows(.edited, in: [.edited, .editedPairedVideo]))
    #expect(!ExportManager.pairedVideoFollows(.original, in: [.original, .edited]))
    #expect(!ExportManager.pairedVideoFollows(.edited, in: [.original, .originalPairedVideo]))
    #expect(!ExportManager.pairedVideoFollows(.originalPairedVideo, in: all))
    #expect(!ExportManager.pairedVideoFollows(.editedPairedVideo, in: all))
  }

  /// A lookup error at the commit's recheck counts as a change: the export plans again,
  /// finds the same identical file and adopts it.
  @Test func lookupErrorAtTheCommitRecheckPlansAgain() async throws {
    let h = Harness()
    try await withCleanup {
      let asset = TestAssetFactory.makeAsset(id: "asset", creationDate: Self.june15)
      h.photos.assetsByYearMonth["2025-6"] = [asset]
      h.photos.resourcesByAssetId[asset.id] = [
        TestAssetFactory.makeResource(originalFilename: "IMG_0001.JPG")
      ]
      await h.exportMonth()
      let folder = try h.monthFolder()
      let natural = folder.appendingPathComponent("IMG_0001.JPG")
      try await h.loseRecords()
      // The first planning walk looks the natural name up once; the commit's recheck is the
      // second lookup, then a second walk and a second recheck follow.
      let lookups = LockedBox(0)
      h.files.identityHook = { url in
        guard url == natural else { return }
        lookups.mutate { $0 += 1 }
        if lookups.value == 2 { throw NSError(domain: NSPOSIXErrorDomain, code: Int(EIO)) }
      }

      await h.exportMonth()

      #expect(lookups.value == 4)
      let variant = h.timeline.exportInfo(assetId: asset.id)?.variants[.original]
      #expect(variant?.status == .done)
      #expect(variant?.filename == "IMG_0001.JPG")
      #expect(try h.contents(of: folder) == ["IMG_0001.JPG"])
      #expect(h.files.moveCalls.count == 1)
    } cleanup: {
      await h.cleanup()
    }
  }

  /// An error looking up a candidate while planning fails that variant with the error's own
  /// signature and category, as the same error from the commit would. An unreachable
  /// destination or denied access stops the run before the next asset; other errors fail
  /// only that asset.
  @Test(arguments: [
    (EIO, AutoSyncFailureCategory.unknown, false), (ENOENT, .unknown, false),
    (ENOTCONN, .destinationUnavailable, true), (EACCES, .destinationPermission, true),
  ])
  func lookupErrorWhilePlanningKeepsItsClassification(
    code: Int32, category: AutoSyncFailureCategory, stops: Bool
  ) async throws {
    let h = Harness()
    try await withCleanup {
      let first = TestAssetFactory.makeAsset(id: "asset", creationDate: Self.june15)
      let second = TestAssetFactory.makeAsset(id: "second", creationDate: Self.june15)
      h.photos.yearCounts = [(2025, 2)]
      h.photos.assetsByYearMonth["2025-6"] = [first, second]
      h.photos.resourcesByAssetId[first.id] = [
        TestAssetFactory.makeResource(originalFilename: "IMG_0001.JPG")
      ]
      h.photos.resourcesByAssetId[second.id] = [
        TestAssetFactory.makeResource(originalFilename: "IMG_0002.JPG")
      ]
      h.files.identityHook = { url in
        if url.lastPathComponent == "IMG_0001.JPG" {
          throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
        }
      }

      let summary = await h.manager.runExport(
        context: ExportRunContext(
          source: .autoSync, visibility: .background, scope: .timelineFullLibrary,
          selection: .edited))

      #expect(summary.failures.map(\.errorSignature) == ["NSPOSIXErrorDomain:\(code)"])
      #expect(summary.failures.map(\.category) == [category])
      #expect(h.timeline.exportInfo(assetId: first.id)?.variants[.original]?.status == .failed)
      let folder = try h.monthFolder()
      if stops {
        #expect(summary.stoppedBy == category)
        #expect(h.timeline.exportInfo(assetId: second.id) == nil)
        #expect(h.files.moveCalls.isEmpty)
        #expect(try h.contents(of: folder) == [])
      } else {
        #expect(summary.stoppedBy == nil)
        #expect(h.timeline.exportInfo(assetId: second.id)?.variants[.original]?.status == .done)
        #expect(h.files.moveCalls.count == 1)
        #expect(try h.contents(of: folder) == ["IMG_0002.JPG"])
      }
    } cleanup: {
      await h.cleanup()
    }
  }

  // MARK: - Claimed names with nothing on disk

  /// A name another record names is taken even when nothing is at it, whatever that record's
  /// status. The export lands at ` (1)`, is never marked under the claimed name, and the
  /// other record keeps its name.
  @Test(arguments: Claim.allCases)
  func claimedNameWithNoFileIsSkipped(claim: Claim) async throws {
    let h = Harness()
    try await withCleanup {
      let asset = TestAssetFactory.makeAsset(id: "asset", creationDate: Self.june15)
      h.photos.assetsByYearMonth["2025-6"] = [asset]
      h.photos.resourcesByAssetId[asset.id] = [
        TestAssetFactory.makeResource(originalFilename: "IMG_0001.JPG")
      ]
      h.recordOther(named: "IMG_0001.JPG", as: claim)

      await h.exportMonth()

      let folder = try h.monthFolder()
      let variant = h.timeline.exportInfo(assetId: asset.id)?.variants[.original]
      #expect(variant?.status == .done)
      #expect(variant?.filename == "IMG_0001 (1).JPG")
      #expect(try h.contents(of: folder) == ["IMG_0001 (1).JPG"])
      #expect(
        h.timeline.exportInfo(assetId: "other")?.variants[.original]?.filename == "IMG_0001.JPG")
      #expect(try await h.inProgressNames(of: asset.id) == ["IMG_0001 (1).JPG"])
    } cleanup: {
      await h.cleanup()
    }
  }

  enum ClaimSpelling: String, CaseIterable, CustomTestStringConvertible {
    case lowerCase, otherNormalization, videosSubfolder
    var testDescription: String { rawValue }
  }

  /// A claim matches however its name is spelled in case or Unicode normalization, and
  /// claims in a timeline month's `videos/` are kept apart from the month itself.
  @Test(arguments: ClaimSpelling.allCases)
  func claimedNameWithNoFileIsSkippedInAnySpelling(spelling: ClaimSpelling) async throws {
    let h = Harness()
    try await withCleanup {
      let resourceName: String
      let claimedName: String
      let expected: String
      var subfolder: String?
      let asset: AssetDescriptor
      switch spelling {
      case .lowerCase:
        asset = TestAssetFactory.makeAsset(id: "asset", creationDate: Self.june15)
        (resourceName, claimedName, expected) = ("IMG_0001.JPG", "img_0001.jpg", "IMG_0001 (1).JPG")
      case .otherNormalization:
        asset = TestAssetFactory.makeAsset(id: "asset", creationDate: Self.june15)
        (resourceName, claimedName, expected) =
          ("Caf\u{E9}.JPG", "Cafe\u{301}.JPG", "Caf\u{E9} (1).JPG")
      case .videosSubfolder:
        asset = TestAssetFactory.makeAsset(
          id: "asset", creationDate: Self.june15, mediaType: .video)
        (resourceName, claimedName, expected) = ("CLIP.MOV", "CLIP.MOV", "CLIP (1).MOV")
        subfolder = "videos"
        h.manager.videoLayout = .subfolder
      }
      h.photos.assetsByYearMonth["2025-6"] = [asset]
      h.photos.resourcesByAssetId[asset.id] = [
        TestAssetFactory.makeResource(
          type: asset.mediaType == .video ? .video : .photo, originalFilename: resourceName)
      ]
      h.recordOther(named: claimedName, subfolder: subfolder)

      await h.exportMonth()

      let variant = h.timeline.exportInfo(assetId: asset.id)?.variants[.original]
      #expect(variant?.status == .done)
      // String equality is canonical, so either normalization of the name passes.
      #expect(variant?.filename == expected)
      #expect(variant?.subfolder == subfolder)
      let folder = try h.destination.urlForRelativeDirectory(
        "2025/06/" + (subfolder.map { "\($0)/" } ?? ""), createIfNeeded: false)
      #expect(try h.contents(of: folder).count == 1)
      #expect(try await h.inProgressNames(of: asset.id).count == 1)
      #expect(try await h.inProgressNames(of: asset.id).first == expected)
    } cleanup: {
      await h.cleanup()
    }
  }

  /// An album's claims work as a month's: the album's earlier asset was exported as
  /// `IMG_0001.JPG`, its file deleted and the asset removed from the album. A new asset with
  /// the same filename lands at ` (1)`.
  @Test func claimedNameWithNoFileIsSkippedInAnAlbum() async throws {
    let h = Harness()
    try await withCleanup {
      let other = TestAssetFactory.makeAsset(id: "other", creationDate: Self.june15)
      let asset = TestAssetFactory.makeAsset(id: "asset", creationDate: Self.june15)
      let resource = TestAssetFactory.makeResource(originalFilename: "IMG_0001.JPG")
      h.photos.resourcesByAssetId[other.id] = [resource]
      h.photos.resourcesByAssetId[asset.id] = [resource]
      h.photos.collectionTree = [
        PhotoCollectionDescriptor(
          id: "album:trip", localIdentifier: "trip", title: "Trip", kind: .album,
          pathComponents: [], children: [])
      ]
      h.photos.assetsByAlbumLocalId["trip"] = [other]
      h.manager.startExportAlbum(collectionId: "trip")
      await h.manager.waitForQueueDrained()
      let placement = try #require(h.collections.placements(matching: .album).first)
      let folder = try h.destination.urlForRelativeDirectory(
        placement.relativePath, createIfNeeded: false)
      try FileManager.default.removeItem(at: folder.appendingPathComponent("IMG_0001.JPG"))
      h.photos.assetsByAlbumLocalId["trip"] = [asset]

      h.manager.startExportAlbum(collectionId: "trip")
      await h.manager.waitForQueueDrained()

      #expect(h.collections.placements(matching: .album).map(\.id) == [placement.id])
      let variants = { (id: String) in
        h.collections.exportInfo(assetId: id, placement: placement)?.variants[.original]
      }
      #expect(variants(asset.id)?.status == .done)
      #expect(variants(asset.id)?.filename == "IMG_0001 (1).JPG")
      #expect(variants(other.id)?.filename == "IMG_0001.JPG")
      #expect(try h.contents(of: folder) == ["IMG_0001 (1).JPG"])
      #expect(try await h.inProgressNames(of: asset.id, inCollection: true) == ["IMG_0001 (1).JPG"])
    } cleanup: {
      await h.cleanup()
    }
  }

  enum OtherFolder: String, CaseIterable, CustomTestStringConvertible {
    case otherMonth, videosSubfolder
    var testDescription: String { rawValue }
  }

  /// A guard: a claim in another folder, another month or the month's `videos/`, leaves the
  /// name free here.
  @Test(arguments: OtherFolder.allCases)
  func claimInAnotherFolderLeavesTheNameFree(folder other: OtherFolder) async throws {
    let h = Harness()
    try await withCleanup {
      let asset = TestAssetFactory.makeAsset(id: "asset", creationDate: Self.june15)
      h.photos.assetsByYearMonth["2025-6"] = [asset]
      h.photos.resourcesByAssetId[asset.id] = [
        TestAssetFactory.makeResource(originalFilename: "IMG_0001.JPG")
      ]
      switch other {
      case .otherMonth: h.recordOther(named: "IMG_0001.JPG", month: 7)
      case .videosSubfolder: h.recordOther(named: "IMG_0001.JPG", subfolder: "videos")
      }

      await h.exportMonth()

      let folder = try h.monthFolder()
      #expect(
        h.timeline.exportInfo(assetId: asset.id)?.variants[.original]?.filename
          == "IMG_0001.JPG")
      #expect(try h.contents(of: folder) == ["IMG_0001.JPG"])
    } cleanup: {
      await h.cleanup()
    }
  }

  /// The walk goes past every claimed or occupied candidate: with ` (1)` claimed, the natural
  /// name claimed too or holding a different file, the export lands at ` (2)`.
  @Test(arguments: [false, true])
  func walkSkipsEveryClaimedOrOccupiedName(naturalHoldsAFile: Bool) async throws {
    let h = Harness()
    try await withCleanup {
      let asset = TestAssetFactory.makeAsset(id: "asset", creationDate: Self.june15)
      h.photos.assetsByYearMonth["2025-6"] = [asset]
      h.photos.resourcesByAssetId[asset.id] = [
        TestAssetFactory.makeResource(originalFilename: "IMG_0001.JPG")
      ]
      let folder = try h.destination.urlForMonth(year: 2025, month: 6, createIfNeeded: true)
      if naturalHoldsAFile {
        try Data("different".utf8).write(to: folder.appendingPathComponent("IMG_0001.JPG"))
      } else {
        h.recordOther(named: "IMG_0001.JPG")
      }
      h.timeline.markVariantExported(
        assetId: "third", variant: .original, year: 2025, month: 6, relPath: "2025/06/",
        filename: "IMG_0001 (1).JPG", exportedAt: Date())

      await h.exportMonth()

      #expect(
        h.timeline.exportInfo(assetId: asset.id)?.variants[.original]?.filename
          == "IMG_0001 (2).JPG")
      #expect(
        try h.contents(of: folder)
          == (naturalHoldsAFile ? ["IMG_0001 (2).JPG", "IMG_0001.JPG"] : ["IMG_0001 (2).JPG"]))
      #expect(try await h.inProgressNames(of: asset.id) == ["IMG_0001 (2).JPG"])
    } cleanup: {
      await h.cleanup()
    }
  }

  /// A guard: the asset's own interrupted record names `IMG_0001.JPG` and nothing is there.
  /// Its own claim does not count, so the retry commits at that name and is never marked
  /// under ` (1)`.
  @Test func ownClaimedNameIsReclaimed() async throws {
    let h = Harness()
    try await withCleanup {
      let asset = TestAssetFactory.makeAsset(id: "asset", creationDate: Self.june15)
      h.photos.assetsByYearMonth["2025-6"] = [asset]
      h.photos.resourcesByAssetId[asset.id] = [
        TestAssetFactory.makeResource(originalFilename: "IMG_0001.JPG")
      ]
      h.timeline.markVariantInProgress(
        assetId: asset.id, variant: .original, year: 2025, month: 6, relPath: "2025/06/",
        filename: "IMG_0001.JPG")
      h.timeline.markVariantFailed(
        assetId: asset.id, variant: .original, error: "Interrupted", reason: .interrupted,
        at: Date())

      await h.exportMonth()

      let folder = try h.monthFolder()
      let variant = h.timeline.exportInfo(assetId: asset.id)?.variants[.original]
      #expect(variant?.status == .done)
      #expect(variant?.filename == "IMG_0001.JPG")
      #expect(try h.contents(of: folder) == ["IMG_0001.JPG"])
      #expect(try await !h.inProgressNames(of: asset.id).contains("IMG_0001 (1).JPG"))
    } cleanup: {
      await h.cleanup()
    }
  }

  /// An edit on its original's inherited stem gets the original's name. With the original's
  /// file deleted that name is free on disk but still the original's, so the edit lands at
  /// ` (1)` and the original's record keeps its name.
  @Test func editSharingItsOriginalsNameSkipsItAfterTheFileIsDeleted() async throws {
    let h = Harness()
    try await withCleanup {
      let unedited = TestAssetFactory.makeAsset(id: "asset", creationDate: Self.june15)
      let edited = TestAssetFactory.makeAsset(
        id: "asset", creationDate: Self.june15, hasAdjustments: true)
      let original = TestAssetFactory.makeResource(type: .photo, originalFilename: "IMG_0001.JPG")
      let render = TestAssetFactory.makeResource(
        type: .fullSizePhoto, originalFilename: "FullSizeRender.JPG")
      h.manager.versionSelection = .editedWithOriginals
      h.photos.assetsByYearMonth["2025-6"] = [unedited]
      h.photos.resourcesByAssetId[edited.id] = [original]
      await h.exportMonth()
      let folder = try h.monthFolder()
      try FileManager.default.removeItem(at: folder.appendingPathComponent("IMG_0001.JPG"))
      h.photos.assetsByYearMonth["2025-6"] = [edited]
      h.photos.resourcesByAssetId[edited.id] = [original, render]

      await h.exportMonth()

      let variants = h.timeline.exportInfo(assetId: edited.id)?.variants
      #expect(variants?[.original]?.status == .done)
      #expect(variants?[.original]?.filename == "IMG_0001.JPG")
      #expect(variants?[.edited]?.status == .done)
      #expect(variants?[.edited]?.filename == "IMG_0001 (1).JPG")
      #expect(try h.contents(of: folder) == ["IMG_0001 (1).JPG"])
      #expect(try await h.inProgressNames(of: edited.id, variant: .edited) == ["IMG_0001 (1).JPG"])
    } cleanup: {
      await h.cleanup()
    }
  }

  /// A deleted file's name stays reserved until Import Existing Backup drops its record:
  /// another asset with the same filename lands at ` (1)`, the import finds the first
  /// asset's file missing and drops its record, and the next export writes that asset back
  /// at its own name.
  @Test func missingFileReturnsAfterReconcile() async throws {
    let h = Harness()
    try await withCleanup {
      let first = TestAssetFactory.makeAsset(id: "first", creationDate: Self.june15)
      let second = TestAssetFactory.makeAsset(id: "second", creationDate: Self.june15)
      let resource = TestAssetFactory.makeResource(originalFilename: "IMG_0001.JPG")
      h.photos.assetsByYearMonth["2025-6"] = [first]
      h.photos.resourcesByAssetId[first.id] = [resource]
      h.photos.resourcesByAssetId[second.id] = [resource]
      await h.exportMonth()
      let folder = try h.monthFolder()
      try FileManager.default.removeItem(at: folder.appendingPathComponent("IMG_0001.JPG"))
      h.photos.assetsByYearMonth["2025-6"] = [first, second]

      await h.exportMonth()
      let filename = { (id: String) in
        h.timeline.exportInfo(assetId: id)?.variants[.original]?.filename
      }
      try #require(filename(second.id) == "IMG_0001 (1).JPG")

      h.manager.startImport()
      await h.manager.waitForImportCompletion()
      try #require(h.timeline.exportInfo(assetId: first.id)?.variants[.original] == nil)
      await h.exportMonth()

      #expect(try h.contents(of: folder) == ["IMG_0001 (1).JPG", "IMG_0001.JPG"])
      #expect(h.timeline.exportInfo(assetId: first.id)?.variants[.original]?.status == .done)
      #expect(filename(first.id) == "IMG_0001.JPG")
      #expect(filename(second.id) == "IMG_0001 (1).JPG")
      for (asset, name) in [(first, "IMG_0001.JPG"), (second, "IMG_0001 (1).JPG")] {
        #expect(
          try Data(contentsOf: folder.appendingPathComponent(name))
            == FakeAssetResourceWriter.content(for: resource, assetId: asset.id))
      }
    } cleanup: {
      await h.cleanup()
    }
  }

  enum PairedClaim: String, CaseIterable, CustomTestStringConvertible {
    case editedName, originalCompanion, motionFile, fallbackCompanion
    var testDescription: String { rawValue }
  }

  /// A group whose stem is chosen before staging moves past a stem with any claimed name, so
  /// its files stay on one stem:
  /// - an edit with its `_orig` companion, the edit's or the companion's name claimed;
  /// - an unedited Live Photo, its motion file's name claimed;
  /// - an edit Photos can't provide, whose original falls back to `_orig`, that name claimed.
  @Test(arguments: PairedClaim.allCases)
  func pairedStemMovesPastAClaimedName(claim: PairedClaim) async throws {
    let h = Harness()
    try await withCleanup {
      let photo = TestAssetFactory.makeResource(type: .photo, originalFilename: "IMG_0001.HEIC")
      let render = TestAssetFactory.makeResource(
        type: .fullSizePhoto, originalFilename: "FullSizeRender.JPG")
      let asset: AssetDescriptor
      let claimedName: String
      let expected: [ExportVariant: String]
      switch claim {
      case .editedName, .originalCompanion:
        asset = TestAssetFactory.makeAsset(
          id: "asset", creationDate: Self.june15, hasAdjustments: true)
        h.photos.resourcesByAssetId[asset.id] = [photo, render]
        h.manager.versionSelection = .editedWithOriginals
        claimedName = claim == .editedName ? "IMG_0001.JPG" : "IMG_0001_orig.HEIC"
        expected = [.original: "IMG_0001 (1)_orig.HEIC", .edited: "IMG_0001 (1).JPG"]
      case .motionFile:
        asset = TestAssetFactory.makeAsset(
          id: "asset", creationDate: Self.june15, isLivePhoto: true)
        h.photos.resourcesByAssetId[asset.id] = [
          photo, TestAssetFactory.makeResource(type: .pairedVideo, originalFilename: "IMG_0001.MOV"),
        ]
        h.manager.versionSelection = .edited
        h.manager.livePhotosPairedExport = true
        claimedName = "IMG_0001.MOV"
        expected = [.original: "IMG_0001 (1).HEIC", .originalPairedVideo: "IMG_0001 (1).MOV"]
      case .fallbackCompanion:
        asset = TestAssetFactory.makeAsset(
          id: "asset", creationDate: Self.june15, hasAdjustments: true)
        h.photos.resourcesByAssetId[asset.id] = [photo]
        h.manager.versionSelection = .edited
        claimedName = "IMG_0001_orig.HEIC"
        expected = [.original: "IMG_0001 (1)_orig.HEIC"]
      }
      h.photos.assetsByYearMonth["2025-6"] = [asset]
      h.recordOther(named: claimedName)

      await h.exportMonth()

      let folder = try h.monthFolder()
      let variants = h.timeline.exportInfo(assetId: asset.id)?.variants ?? [:]
      for (variant, name) in expected {
        #expect(variants[variant]?.status == .done, "\(variant)")
        #expect(variants[variant]?.filename == name, "\(variant)")
        #expect(try await !h.inProgressNames(of: asset.id, variant: variant).contains(claimedName))
      }
      #expect(try h.contents(of: folder) == expected.values.sorted())
    } cleanup: {
      await h.cleanup()
    }
  }

  /// A guard: names the asset's own failed records hold do not move its group. An interrupted
  /// edit and `_orig` companion are written again under their own names.
  @Test func pairedStemKeepsTheAssetsOwnNames() async throws {
    let h = Harness()
    try await withCleanup {
      let asset = TestAssetFactory.makeAsset(
        id: "asset", creationDate: Self.june15, hasAdjustments: true)
      h.photos.assetsByYearMonth["2025-6"] = [asset]
      h.photos.resourcesByAssetId[asset.id] = [
        TestAssetFactory.makeResource(type: .photo, originalFilename: "IMG_0001.HEIC"),
        TestAssetFactory.makeResource(type: .fullSizePhoto, originalFilename: "FullSizeRender.JPG"),
      ]
      h.manager.versionSelection = .editedWithOriginals
      for (variant, name) in [(ExportVariant.original, "IMG_0001_orig.HEIC"), (.edited, "IMG_0001.JPG")] {
        h.timeline.markVariantInProgress(
          assetId: asset.id, variant: variant, year: 2025, month: 6, relPath: "2025/06/",
          filename: name)
        h.timeline.markVariantFailed(
          assetId: asset.id, variant: variant, error: "Interrupted", reason: .interrupted,
          at: Date())
      }

      await h.exportMonth()

      let folder = try h.monthFolder()
      let variants = h.timeline.exportInfo(assetId: asset.id)?.variants
      #expect(variants?[.original]?.status == .done)
      #expect(variants?[.original]?.filename == "IMG_0001_orig.HEIC")
      #expect(variants?[.edited]?.status == .done)
      #expect(variants?[.edited]?.filename == "IMG_0001.JPG")
      #expect(try h.contents(of: folder) == ["IMG_0001.JPG", "IMG_0001_orig.HEIC"])
    } cleanup: {
      await h.cleanup()
    }
  }
}
