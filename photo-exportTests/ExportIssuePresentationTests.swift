import AppKit
import SwiftUI
import Testing

@testable import Photo_Export

@MainActor
@Suite(.timeLimit(.minutes(2)), .serialized)
struct ExportIssuePresentationTests {
  private let created = Date(timeIntervalSince1970: 1_710_244_800)  // March 2024, distinct from failure.
  private let failedAt = Date(timeIntervalSince1970: 1_800_000_000)

  private func failure(_ filename: String?) -> ExportVariantRecord {
    ExportVariantRecord(
      filename: filename, status: .failed, exportDate: failedAt, lastError: "Network failed")
  }

  @Test func timelineAndCollectionCarryActualFilenameAndCreationDate() throws {
    let metadata = [
      "asset": ExportIssue.AssetMetadata(creationDate: created, originalFilename: "PHOTOS.HEIC")
    ]
    let record = ExportRecord(
      id: "asset", year: 2026, month: 10, relPath: "2026/10/",
      variants: [.edited: failure("EDIT.JPG")])
    let timeline = try #require(
      ExportIssuesProjection.make(
        timeline: ["asset": record], assetMetadata: metadata
      ).first)
    #expect(timeline.filename == "EDIT.JPG")
    #expect(timeline.creationDate == created)
    #expect(timeline.failedAt == failedAt)
    let collection = try #require(
      ExportIssuesProjection.make(
        collections: [
          "album": ["asset": .init(variants: ["originalPairedVideo": failure("MOTION.MOV")])]
        ],
        assetMetadata: metadata
      ).first)
    #expect(collection.filename == "MOTION.MOV")
    #expect(collection.creationDate == created)
    #expect(collection.failedAt == failedAt)
  }

  @Test func filenameFallbackStaysWithinTheSameRecord() throws {
    let original = ExportVariantRecord(
      filename: "SAME_RECORD_orig.HEIC", status: .done, exportDate: created, lastError: nil)
    let metadata = [
      "asset": ExportIssue.AssetMetadata(creationDate: nil, originalFilename: "PHOTOS.HEIC")
    ]
    let record = ExportRecord(
      id: "asset", year: 2026, month: 10, relPath: "2026/10/",
      variants: [.original: original, .edited: failure(" \n ")])
    let row = try #require(
      ExportIssuesProjection.make(
        timeline: ["asset": record], assetMetadata: metadata
      ).first)
    #expect(row.filename == "SAME_RECORD_orig.HEIC")
    #expect(row.creationDate == nil, "Do not guess creation time from export/failure/month")
    let collection = try #require(
      ExportIssuesProjection.make(
        timeline: ["asset": record],
        collections: ["other": ["asset": .init(variants: ["future": failure(nil)])]],
        assetMetadata: metadata
      ).first { $0.id.variantRaw == "future" })
    #expect(collection.filename == "PHOTOS.HEIC", "Another placement is not a filename source")
    #expect(collection.creationDate == nil)
  }

  @Test func absentMetadataDoesNotInventDatesOrNames() throws {
    let record = ExportRecord(
      id: "deleted", year: 2026, month: 10, relPath: "2026/10/",
      variants: [.original: failure(nil)])
    let row = try #require(ExportIssuesProjection.make(timeline: ["deleted": record]).first)
    #expect(row.filename == nil && row.creationDate == nil)
    #expect(row.failedAt == failedAt)
  }

  @Test func versionLabelsDescribeKnownVariantsAndRetainUnknownKeys() throws {
    let labels: [ExportVariant: String] = [
      .original: "Original", .edited: "Edited", .originalPairedVideo: "Live Photo video",
      .editedPairedVideo: "Edited Live Photo video",
    ]
    let record = ExportRecord(
      id: "asset", year: 2026, month: 10, relPath: "2026/10/",
      variants: Dictionary(
        uniqueKeysWithValues: ExportVariant.allCases.map { ($0, failure("FILE")) }))
    let rows = ExportIssuesProjection.make(timeline: ["asset": record])
    #expect(rows.count == labels.count)
    for row in rows { #expect(row.variant.flatMap { labels[$0] } == row.variantLabel) }
    let unknown = try #require(
      ExportIssuesProjection.make(
        collections: ["unknown": ["asset": .init(variants: ["futureVersion": failure(nil)])]]).first
    )
    #expect(unknown.variantLabel == "Unknown version" && unknown.id.variantRaw == "futureVersion")
    #expect(unknown.variant == nil)
  }

  @Test(.timeLimit(.minutes(1)))
  func deletedAssetsKeepRecordedFilenameAndShowUnavailableDate() async throws {
    let f = try Fixture(created: created, failedAt: failedAt)
    defer { f.close() }
    f.service.missingAssetIds = ["asset"]
    f.window.orderFront(nil)
    try #require(await observe { f.counter.count(for: "issue-metadata:\(f.destinationId):0") > 0 })
    #expect(
      f.counter.renderedText["issue-row:asset"]?.first == "EDIT.JPG · Date unavailable · Edited")
  }

  @Test(.timeLimit(.minutes(1)))
  func destinationReplacementRejectsAnInFlightMetadataResult() async throws {
    let f = try Fixture(created: created, failedAt: failedAt)
    defer {
      f.service.descriptorFetchObserver = nil
      f.close()
    }
    let other = f.root.appendingPathComponent("Other")
    try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
    var replaced = false
    f.service.descriptorFetchObserver = { _ in
      guard !replaced else { return }
      replaced = true
      f.destination.persistSelectedFolderForTesting(other)
    }
    f.window.orderFront(nil)
    try #require(
      await observe {
        replaced && f.counter.renderedText["issue-visible-ids"] == []
          && f.counter.count(for: "issue-metadata:\(f.destination.destinationId ?? "none"):0") > 0
      })
    #expect(f.counter.count(for: "issue-metadata:\(f.destinationId):0") == 0)
  }

  @Test func metadataRequestsTrackFilenameDemandAndDeduplicateAssets() async throws {
    let record = ExportRecord(
      id: "asset", year: 2026, month: 10, relPath: "2026/10/",
      variants: [.edited: failure("EDIT.JPG"), .originalPairedVideo: failure("VIDEO.MOV")])
    let rows = ExportIssuesProjection.make(timeline: ["asset": record])
    let first = ExportIssueMetadataRequest(destinationId: "A", libraryRevision: 0, rows: rows)
    var missing = rows
    missing[0].filename = nil
    let second = ExportIssueMetadataRequest(destinationId: "A", libraryRevision: 0, rows: missing)
    #expect(first.assetIds == ["asset"] && first.filenameAssetIds.isEmpty)
    #expect(second.assetIds == first.assetIds && second != first)
    #expect(second.filenameAssetIds == ["asset"])
    let service = FakePhotoLibraryService()
    service.favoritesAssets = [TestAssetFactory.makeAsset(id: "asset", creationDate: created)]
    service.detailsByAssetId["asset"] = AssetDetails(
      originalFilename: "PHOTOS.HEIC", fileSize: nil, resources: [])
    let firstMetadata = try #require(await first.load(using: service))
    #expect(firstMetadata["asset"]?.creationDate == created)
    #expect(service.descriptorFetchCalls == ["asset"] && service.detailsFetchCalls.isEmpty)
    let secondMetadata = try #require(await second.load(using: service))
    #expect(secondMetadata["asset"]?.originalFilename == "PHOTOS.HEIC")
    #expect(service.detailsFetchCalls == ["asset"])
  }

  @Test func cancellingMetadataBetweenBatchesDiscardsPartialResults() async throws {
    let service = FakePhotoLibraryService()
    let records = Dictionary(
      uniqueKeysWithValues: (0..<65).map { index in
        let id = "asset-\(index)"
        return (
          id,
          ExportRecord(
            id: id, year: 2026, month: 10, relPath: "2026/10/",
            variants: [.original: failure("\(index).HEIC")])
        )
      })
    let request = ExportIssueMetadataRequest(
      destinationId: "A", libraryRevision: 0, rows: ExportIssuesProjection.make(timeline: records))
    var task: Task<[String: ExportIssue.AssetMetadata]?, Never>?
    service.descriptorFetchObserver = { _ in
      if service.descriptorFetchCalls.count == 32 { task?.cancel() }
    }
    defer {
      service.descriptorFetchObserver = nil
      task?.cancel()
    }
    task = Task { await request.load(using: service) }
    let running = try #require(task)
    #expect(await running.value == nil, "A dismissed/cancelled view cannot publish a partial batch")
    #expect(service.descriptorFetchCalls.count == 32)
  }

  @Test(.timeLimit(.minutes(1)))
  func sameAssetLosingItsRecordedFilenameLoadsTheFallback() async throws {
    let f = try Fixture(created: created, failedAt: failedAt)
    defer { f.close() }
    f.window.orderFront(nil)
    try #require(
      await observe { f.counter.renderedText["issue-row:asset"]?.first?.contains("2024") == true })
    #expect(f.service.detailsFetchCalls.isEmpty)
    f.timeline.markVariantInProgress(
      assetId: "asset", variant: .edited, year: 2026, month: 10,
      relPath: "2026/10/", filename: " ")
    f.timeline.markVariantFailed(
      assetId: "asset", variant: .edited, error: "Network failed", at: failedAt)
    #expect(
      await observe {
        f.counter.renderedText["issue-row:asset"]?.first?.contains("PHOTOS.HEIC") == true
      })
    #expect(f.service.detailsFetchCalls == ["asset"])
  }

  @Test(.timeLimit(.minutes(1)))
  func aRevisionReplacingAnInFlightRequestCannotPublishOldMetadata() async throws {
    let f = try Fixture(created: created, failedAt: failedAt)
    defer {
      f.service.descriptorFetchObserver = nil
      f.close()
    }
    var replaced = false
    f.service.descriptorFetchObserver = { _ in
      guard !replaced else { return }
      replaced = true
      f.service.favoritesAssets = [
        TestAssetFactory.makeAsset(
          id: "asset", creationDate: Date(timeIntervalSince1970: 1_930_000_000))
      ]
      f.library.invalidateCache()
    }
    f.window.orderFront(nil)
    try #require(await observe {
      f.counter.count(for: "issue-metadata:\(f.destinationId):1") == 1
        && f.counter.renderedText["issue-row:asset"]?.first?.contains("2031") == true
    })
    #expect(f.counter.count(for: "issue-metadata:\(f.destinationId):0") == 0)
  }

  @Test(.timeLimit(.minutes(1)), arguments: [false, true])
  func retainedRetryRejectsAChangedDestinationOrNewFailure(newFailure: Bool) async throws {
    let f = try Fixture(created: created, failedAt: failedAt)
    defer { f.close() }
    f.window.orderFront(nil)
    try #require(
      await observe { f.counter.renderedText["issue-row:asset"]?.first?.contains("2024") == true })
    let action = try #require(f.counter.renderedActions["issue-retry:asset"])
    if newFailure {
      f.timeline.markVariantFailed(
        assetId: "asset", variant: .edited, error: "New failure", at: failedAt.addingTimeInterval(1)
      )
    } else {
      let other = f.root.appendingPathComponent("Other")
      try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
      f.destination.persistSelectedFolderForTesting(other)
    }
    action()
    #expect(
      f.autoSync.currentRetryState.entry(scope: .timeline, assetId: "asset", variant: .edited)
        != nil)
  }

  @MainActor
  private final class Fixture {
    let root = TestScratch.directory("ExportIssuePresentation")
    let defaultsName = TestScratch.suiteName("IssuePresentation")
    let defaults: UserDefaults
    let destination: ExportDestinationManager
    let timeline: ExportRecordStore
    let collections: CollectionExportRecordStore
    let service = FakePhotoLibraryService()
    let library: PhotoLibraryManager
    let autoSync = AutoSyncManager()
    let builder = FakeAutoSyncEnvironmentBuilder()
    let counter = BodyInvalidationCounter()
    let window: NSWindow
    let destinationId: String

    init(created: Date, failedAt: Date) throws {
      defaults = TestScratch.defaults(suiteName: defaultsName)
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      destination = ExportDestinationManager(
        skipRestore: true, userDefaults: defaults,
        fingerprintProvider: {
          .makeLow(
            volumeRootPath: "/", relativePathFromVolumeRoot: $0.path, standardizedPath: $0.path)
        },
        bookmarkSaver: { _ in true }, volumeNotificationCenter: NotificationCenter(),
        validationScopeAcquirer: { _ in true }, validationScopeReleaser: { _ in })
      destination.persistSelectedFolderForTesting(root)
      destination.revalidateForTesting()
      destinationId = try #require(destination.destinationId)
      timeline = ExportRecordStore(baseDirectoryURL: root.appendingPathComponent("Records"))
      collections = CollectionExportRecordStore(
        baseDirectoryURL: root.appendingPathComponent("Records"))
      timeline.configure(for: destinationId)
      collections.configure(for: destinationId)
      timeline.markVariantInProgress(
        assetId: "asset", variant: .edited, year: 2026, month: 10, relPath: "2026/10/",
        filename: "EDIT.JPG")
      timeline.markVariantFailed(
        assetId: "asset", variant: .edited, error: "Network failed", at: failedAt)
      service.favoritesAssets = [TestAssetFactory.makeAsset(id: "asset", creationDate: created)]
      service.detailsByAssetId["asset"] = AssetDetails(
        originalFilename: "PHOTOS.HEIC", fileSize: nil, resources: [])
      library = PhotoLibraryManager(overrideService: service)
      var retry = AutoSyncRetryState.empty
      retry.recordFailure(
        scope: .timeline, assetId: "asset", variant: .edited, category: .iCloudTransient,
        errorSignature: "network", at: failedAt, nextEligibleAt: failedAt.addingTimeInterval(30))
      try builder.retryStore.save(retry, destinationId: destinationId)
      builder.userDefaults.set(true, forKey: AutoSyncManager.enabledDefaultsKey)
      builder.destination.subject.send(
        DestinationSnapshot(
          stableId: destinationId, fingerprint: nil, isAvailable: true, safety: .safe))
      autoSync.attach(to: builder.environment)
      let content = ExportIssuesView()
        .environmentObject(destination).environmentObject(timeline).environmentObject(collections)
        .environmentObject(library).environmentObject(autoSync)
        .environment(\.bodyInvalidationCounter, counter)
        .environment(\.locale, Locale(identifier: "en_US_POSIX"))
      window = NSWindow(
        contentRect: NSRect(x: -10_000, y: -10_000, width: 650, height: 500),
        styleMask: [.borderless], backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      window.contentView = NSHostingView(rootView: content)
    }

    func close() {
      window.orderOut(nil)
      window.contentView = nil
      window.close()
      counter.reset()
      autoSync.setEnabled(false)
      timeline.flushForTesting()
      collections.flushForTesting()
      defaults.removePersistentDomain(forName: defaultsName)
      try? FileManager.default.removeItem(at: root)
    }
  }

  private func observe(
    _ condition: () -> Bool, sourceLocation: SourceLocation = #_sourceLocation
  ) async -> Bool {
    await eventually("observed condition", sourceLocation: sourceLocation) { condition() }
  }

  @Test(.timeLimit(.minutes(1)))
  func actualSettingsRowShowsRecognizableMetadataAndRetryStillWorks() async throws {
    let f = try Fixture(created: created, failedAt: failedAt)
    defer { f.close() }
    f.window.orderFront(nil)
    try #require(await observe { f.counter.renderedText["issue-row:asset"] != nil })
    #expect(
      await observe {
        let text = f.counter.renderedText["issue-row:asset"]?.first ?? ""
        return text.contains("EDIT.JPG") && text.contains("2024") && text.contains("Edited")
      })
    #expect(f.counter.renderedText["issue-row:asset"]?.last == "asset")
    let action = try #require(f.counter.renderedActions["issue-retry:asset"])
    f.service.favoritesAssets = [
      TestAssetFactory.makeAsset(
        id: "asset", creationDate: Date(timeIntervalSince1970: 1_930_000_000))
    ]
    f.library.invalidateCache()
    try #require(
      await observe { f.counter.renderedText["issue-row:asset"]?.first?.contains("2031") == true })
    action()
    #expect(
      f.autoSync.currentRetryState.entry(scope: .timeline, assetId: "asset", variant: .edited)
        == nil)
  }
}
