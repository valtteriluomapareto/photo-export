import AppKit
import SwiftUI
import Testing

@testable import Photo_Export

@MainActor
@Suite(.timeLimit(.minutes(2)), .serialized)
struct ExportIssuePresentationTests {
  // March 2024, distinct from failure.
  private let created = Date(timeIntervalSince1970: 1_710_244_800)
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
    #expect(
      timeline.primaryLine(locale: Locale(identifier: "en_US_POSIX"))
        == "EDIT.JPG · Mar 12, 2024 · Edited")
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
    let locale = Locale(identifier: "en_US_POSIX")
    #expect(row.primaryLine(locale: locale) == "Filename unavailable · Date unavailable · Original")
    var recorded = row
    recorded.filename = "EDIT.JPG"
    #expect(
      recorded.enriched(with: nil).primaryLine(locale: locale)
        == "EDIT.JPG · Date unavailable · Original")
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
    #expect(!unknown.showsRetry && unknown.retrySelection(in: [unknown]) == nil)
  }

  @Test(.timeLimit(.minutes(1)))
  func clearingDestinationRejectsAnInFlightMetadataResult() async throws {
    let f = try await Fixture(created: created, failedAt: failedAt)
    defer {
      f.service.descriptorFetchObserver = nil
      f.close()
    }
    var replaced = false
    f.service.descriptorFetchObserver = { _ in
      guard !replaced else { return }
      replaced = true
      f.destination.clearSelection()
    }
    f.window.orderFront(nil)
    try #require(
      await observe {
        replaced
          && NativeViewAccess.containsText("Export issue information is unavailable.", in: f.window)
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
    let f = try await Fixture(created: created, failedAt: failedAt)
    defer { f.close() }
    f.window.orderFront(nil)
    try #require(await observe { f.counter.count(for: "issue-metadata:\(f.destinationId):0") == 1 })
    let before = try #require(pixels(in: f.window))
    #expect(f.service.detailsFetchCalls.isEmpty)
    f.timeline.markVariantInProgress(
      assetId: "asset", variant: .edited, year: 2026, month: 10,
      relPath: "2026/10/", filename: " ")
    f.timeline.markVariantFailed(
      assetId: "asset", variant: .edited, error: "Network failed", at: failedAt)
    try #require(await observe { f.counter.count(for: "issue-metadata:\(f.destinationId):0") >= 2 })
    #expect(await observe(in: f.window) { pixels(in: f.window) != before })
    #expect(f.service.detailsFetchCalls == ["asset"])
  }

  @Test(.timeLimit(.minutes(1)))
  func aRevisionReplacingAnInFlightRequestCannotPublishOldMetadata() async throws {
    let f = try await Fixture(created: created, failedAt: failedAt)
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
    try #require(
      await observe {
        f.counter.count(for: "issue-metadata:\(f.destinationId):1") == 1
      })
    #expect(f.counter.count(for: "issue-metadata:\(f.destinationId):0") == 0)
    let before = try #require(pixels(in: f.window))
    // Change only creation metadata: the mounted Form must install the new date too.
    f.service.favoritesAssets = [TestAssetFactory.makeAsset(id: "asset", creationDate: created)]
    f.library.invalidateCache()
    try #require(
      await observe(in: f.window) {
        f.counter.count(for: "issue-metadata:\(f.destinationId):2") == 1
      })
    #expect(await observe(in: f.window) { pixels(in: f.window) != before })
    #expect(f.counter.count(for: "issue-metadata:\(f.destinationId):0") == 0)
  }

  @Test func retrySelectionRequiresTheCurrentFailedAttempt() throws {
    let current = issue(.iCloudTransient)
    #expect(current.showsRetry)
    #expect(!issue(nil).showsRetry)
    #expect(!issue(.iCloudTransient, reason: .pairedVideoUnavailable).showsRetry)
    let selected = try #require(current.retrySelection(in: [current]))
    #expect(selected.scope == .timeline && selected.variant == .original)
    #expect(selected.retry == current.retry)
    let enriched = current.enriched(
      with: .init(creationDate: created, originalFilename: "PHOTO.HEIC"))
    #expect(enriched.retrySelection(in: [current])?.retry == current.retry)
    #expect(current.retrySelection(in: []) == nil)
    #expect(current.retrySelection(in: [issue(.iCloudTransient, destinationId: "other")]) == nil)
    #expect(
      current.retrySelection(in: [
        issue(.iCloudTransient, failureTime: failedAt.addingTimeInterval(1))
      ]) == nil)
    #expect(current.retrySelection(in: [issue(.destinationPermission)]) == nil)
    #expect(issue(nil).retrySelection(in: [issue(nil)]) == nil)
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

    var rows: [ExportIssue] {
      ExportIssuesProjection.snapshot(
        destinationId: destination.destinationId, timeline: timeline, collections: collections,
        retryState: autoSync.currentRetryState,
        retryDestinationId: autoSync.currentRetryDestinationId
      ).rows
    }

    init(created: Date, failedAt: Date, rowOnly: Bool = false) async throws {
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
      await destination.persistSelectionAndWait(root)
      destinationId = try #require(destination.destinationId)
      timeline = ExportRecordStore(baseDirectoryURL: root.appendingPathComponent("Records"))
      collections = CollectionExportRecordStore(
        baseDirectoryURL: root.appendingPathComponent("Records"))
      await timeline.configureAndWait(for: destinationId)
      await collections.configureAndWait(for: destinationId)
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
      window = NSWindow(
        contentRect: NSRect(x: -10_000, y: -10_000, width: 650, height: 500),
        styleMask: [.borderless], backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      let content = Group {
        if rowOnly {
          ExportIssueRow(
            autoSyncManager: autoSync, exportDestinationManager: destination,
            entry: ExportIssuesProjection.snapshot(
              destinationId: destinationId, timeline: timeline, collections: collections,
              retryState: autoSync.currentRetryState,
              retryDestinationId: autoSync.currentRetryDestinationId
            ).rows[0]
              .enriched(with: .init(creationDate: created, originalFilename: nil)),
            canRetry: true, autoExportEnabled: true)
        } else {
          ExportIssuesView()
        }
      }
      .environmentObject(destination).environment(timeline).environment(collections)
      .environment(library).environmentObject(autoSync)
      .environment(\.bodyInvalidationCounter, counter)
      .environment(\.locale, Locale(identifier: "en_US_POSIX"))
      .environment(\.accessibilityEnabled, true)
      window.contentView = NSHostingView(rootView: content)
    }

    func close() {
      window.orderOut(nil)
      window.contentView = nil
      window.close()
      counter.reset()
      autoSync.setEnabled(false)
      timeline.drainSynchronously()
      collections.drainSynchronously()
      defaults.removePersistentDomain(forName: defaultsName)
      try? FileManager.default.removeItem(at: root)
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func actualSettingsRowShowsRecognizableMetadataAndRetryStillWorks() async throws {
    let f = try await Fixture(created: created, failedAt: failedAt, rowOnly: true)
    defer { f.close() }
    f.window.orderFront(nil)
    try #require(
      await observe(in: f.window) {
        NativeViewAccess.texts(in: f.window).contains {
          $0.contains("EDIT.JPG") && $0.contains("2024") && $0.contains("Edited")
        }
      })
    #expect(NativeViewAccess.containsText("asset", in: f.window))
    let button = try #require(NativeViewAccess.button("Retry", in: f.window))
    #expect(button.isAccessibilityEnabled?() == true)
    let press = try #require(button.accessibilityPerformPress)
    _ = press()
    #expect(
      f.autoSync.currentRetryState.entry(scope: .timeline, assetId: "asset", variant: .edited)
        == nil)
  }

  /// Passes before: a new failed variant appears while the issue list is already mounted.
  @Test(.timeLimit(.minutes(1)), arguments: [false, true])
  func failureRecordedWhileShownAppears(collection: Bool) async throws {
    let f = try await Fixture(created: created, failedAt: failedAt)
    defer { f.close() }
    f.window.orderFront(nil)
    try #require(
      await observe(in: f.window) {
        f.counter.count(for: "issue-metadata:\(f.destinationId):0") == 1
      })
    let before = try #require(pixels(in: f.window))
    if collection {
      let placement = ExportPlacement.favorites()
      f.collections.upsertPlacement(placement)
      f.collections.markVariantInProgress(
        assetId: "new-failure", placement: placement, variant: .original, filename: "NEW.JPG")
      f.collections.markVariantFailed(
        assetId: "new-failure", placement: placement, variant: .original,
        error: "New failure while shown", at: failedAt)
      f.collections.flushPendingNotifications()
    } else {
      f.timeline.markVariantInProgress(
        assetId: "new-failure", variant: .original, year: 2026, month: 10,
        relPath: "2026/10/", filename: "NEW.JPG")
      f.timeline.markVariantFailed(
        assetId: "new-failure", variant: .original, error: "New failure while shown", at: failedAt)
      f.timeline.flushPendingNotifications()
    }
    try #require(await observe { f.counter.count(for: "issue-metadata:\(f.destinationId):0") >= 2 })
    #expect(await observe(in: f.window) { pixels(in: f.window) != before })
  }

  private func pixels(in window: NSWindow) -> Data? {
    guard let view = window.contentView else { return nil }
    view.layoutSubtreeIfNeeded()
    let rect = view.bounds
    guard let bitmap = view.bitmapImageRepForCachingDisplay(in: rect) else { return nil }
    view.cacheDisplay(in: rect, to: bitmap)
    return bitmap.representation(using: .png, properties: [:])
  }

  // MARK: - Retry footer

  private func issue(
    _ category: AutoSyncFailureCategory?, deadline: Date? = nil,
    reason: ExportVariantReason? = nil, destinationId: String = "dest", failureTime: Date? = nil
  ) -> ExportIssue {
    ExportIssue(
      id: .init(source: .timeline, assetId: "asset", variantRaw: "original"),
      destinationId: destinationId, scopeLabel: "Timeline 2026-10", scopeKey: .timeline,
      message: "Socket is not connected", reason: reason, failedAt: failureTime ?? failedAt,
      retry: category.map {
        RetryEntry(
          category: $0, errorSignature: "sig", attemptCount: 1, firstFailedAt: failedAt,
          lastFailedAt: failedAt, nextEligibleAt: deadline)
      })
  }

  /// An unreachable destination's item has no timer: it is tried again by the next Auto
  /// Export run. "Auto Export is off" takes precedence, and other nil deadlines still need
  /// action.
  @Test func retryFooterSaysWhatHappensNext() {
    let now = failedAt.addingTimeInterval(120)
    func suffix(_ issue: ExportIssue, enabled: Bool = true) -> String {
      let footer = issue.timeFooter(autoExportEnabled: enabled, now: now)
      guard let range = footer.range(of: " · ") else { return "" }
      return String(footer[range.lowerBound...])
    }
    #expect(suffix(issue(.destinationUnavailable)) == " · retries on the next Auto Export run")
    #expect(suffix(issue(.destinationUnavailable), enabled: false) == " · Auto Export is off")
    #expect(suffix(issue(.destinationPermission)) == " · needs action")
    #expect(
      suffix(issue(.unknown, deadline: now.addingTimeInterval(-1))) == " · eligible to retry now")
    #expect(suffix(issue(nil)) == "")
    #expect(suffix(issue(.destinationUnavailable, reason: .pairedVideoUnavailable)) == "")
  }
}
