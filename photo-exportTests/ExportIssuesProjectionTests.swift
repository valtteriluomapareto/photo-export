import Foundation
import Testing

@testable import Photo_Export

@MainActor
struct ExportIssuesProjectionTests {
  private let date = Date(timeIntervalSince1970: 1_800_000_000.75)

  private func failed(_ date: Date?, reason: ExportVariantReason? = nil) -> ExportVariantRecord {
    ExportVariantRecord(
      filename: "x.heic", status: .failed, exportDate: date,
      lastError: "latest failure", reason: reason)
  }

  private func retry(at date: Date, assetId: String = "asset") -> AutoSyncRetryState {
    var state = AutoSyncRetryState.empty
    state.recordFailure(
      scope: .timeline, assetId: assetId, variant: .original,
      category: .iCloudTransient, errorSignature: "network", at: date,
      nextEligibleAt: date.addingTimeInterval(30))
    return state
  }

  @Test func manualFailureExistsWithoutRetryHistory() {
    let records = [
      "asset": ExportRecord(
        id: "asset", year: 2026, month: 10, relPath: "2026/10/",
        variants: [.original: failed(date)])
    ]
    let rows = ExportIssuesProjection.make(destinationId: "A", timeline: records)
    #expect(rows.count == 1)
    #expect(rows.first?.id == .init(source: .timeline, assetId: "asset", variantRaw: "original"))
    #expect(rows.first?.failedAt == date)
    #expect(rows.first?.message == "latest failure")
    #expect(rows.first?.retry == nil)
  }

  @Test func recordFailureReplacesStaleMetadataAndSuccessRemovesOrphan() {
    let record = ExportRecord(
      id: "asset", year: 2026, month: 10, relPath: "2026/10/",
      variants: [.original: failed(date)])
    let rows = ExportIssuesProjection.make(
      destinationId: "A", timeline: ["asset": record],
      retryState: retry(at: date.addingTimeInterval(-86_400)), retryDestinationId: "A")
    #expect(rows.first?.failedAt == date)
    #expect(rows.first?.retry == nil)
    #expect(
      ExportIssuesProjection.make(
        destinationId: "A", retryState: retry(at: date), retryDestinationId: "A"
      ).isEmpty)
  }

  @Test func knownAndUnknownCollectionVariantsAndMissingPlacementRemainDistinct() {
    let body = CollectionExportRecordStore.RecordBody(variants: [
      "original": failed(date), "future": failed(nil),
    ])
    let rows = ExportIssuesProjection.make(
      destinationId: "A", collections: ["missing": ["asset": body]])
    #expect(
      Set(rows.map(\.id))
        == Set([
          ExportIssue.Key(source: .collection("missing"), assetId: "asset", variantRaw: "original"),
          ExportIssue.Key(source: .collection("missing"), assetId: "asset", variantRaw: "future"),
        ]))
    #expect(rows.allSatisfy { $0.retry == nil && $0.scopeKey == nil })
  }

  @Test func retryMetadataSurvivesRealFractionalTimePersistence() async throws {
    let root = TestScratch.directory("ExportIssuesProjection")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ExportRecordStore(baseDirectoryURL: root)
    defer { store.drainSynchronously() }
    await store.configureAndWait(for: "A")
    store.markVariantInProgress(
      assetId: "asset", variant: .original, year: 2026, month: 10,
      relPath: "2026/10/", filename: "x.heic")
    store.markVariantFailed(assetId: "asset", variant: .original, error: "network", at: date)
    let retries = FileBackedAutoSyncRetryStateStore(
      baseDirectoryURL: root.appendingPathComponent("Retry"))
    try retries.save(retry(at: date), destinationId: "A")
    store.drainSynchronously()
    let reopened = ExportRecordStore(baseDirectoryURL: root)
    await reopened.configureAndWait(for: "A")
    let savedDate = reopened.recordsById["asset"]?.variants[.original]?.exportDate
    #expect(savedDate != date, "fixture must exercise existing whole-second record persistence")
    let rows = ExportIssuesProjection.make(
      destinationId: "A", timeline: reopened.recordsById,
      retryState: try retries.load(destinationId: "A"), retryDestinationId: "A")
    #expect(rows.count == 1)
    #expect(rows.first?.failedAt == savedDate)
    #expect(rows.first?.retry?.lastFailedAt == date)
  }

  @Test func recoveredInterruptionDoesNotBorrowEarlierSuccessfulTime() async throws {
    let root = TestScratch.directory("ExportIssuesProjection")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ExportRecordStore(baseDirectoryURL: root)
    defer { store.drainSynchronously() }
    await store.configureAndWait(for: "A")
    store.markVariantInProgress(
      assetId: "asset", variant: .original, year: 2026, month: 10,
      relPath: "2026/10/", filename: "x.heic")
    store.markVariantExported(
      assetId: "asset", variant: .original, year: 2026, month: 10, relPath: "2026/10/",
      filename: "x.heic", exportedAt: date)
    store.markVariantInProgress(
      assetId: "asset", variant: .original, year: 2026, month: 10,
      relPath: "2026/10/", filename: "x.heic")
    store.drainSynchronously()
    let reopened = ExportRecordStore(baseDirectoryURL: root)
    await reopened.configureAndWait(for: "A")
    let rows = ExportIssuesProjection.make(
      destinationId: "A", timeline: reopened.recordsById,
      retryState: retry(at: date), retryDestinationId: "A")
    #expect(rows.count == 1)
    #expect(rows.first?.reason == .interrupted)
    #expect(rows.first?.failedAt == nil)
    #expect(rows.first?.retry == nil)
  }
}

@MainActor
struct ExportIssuesIntegrationTests {
  private let date = Date(timeIntervalSince1970: 1_800_000_000)

  @Test func partialStoresKeepKnownFailuresAndDestinationSwitchesDoNotMix() async throws {
    let root = TestScratch.directory("ExportIssuesProjection")
    defer { try? FileManager.default.removeItem(at: root) }
    let timeline = ExportRecordStore(baseDirectoryURL: root)
    defer { timeline.drainSynchronously() }
    await timeline.configureAndWait(for: "A")
    timeline.markVariantInProgress(
      assetId: "same", variant: .original, year: 2026, month: 10,
      relPath: "2026/10/", filename: "x")
    timeline.markVariantFailed(
      assetId: "same", variant: .original, error: "manual failure", at: date)
    try Data("corrupt".utf8).write(to: root.appendingPathComponent("A/collection-records.json"))
    let collections = CollectionExportRecordStore(baseDirectoryURL: root)
    await collections.configureAndWait(for: "A")
    let partial = ExportIssuesProjection.snapshot(
      destinationId: "A", timeline: timeline, collections: collections,
      retryState: .empty, retryDestinationId: nil)
    #expect(partial.rows.count == 1)
    #expect(partial.unavailableStores == ["Collections"])
    let switching = ExportIssuesProjection.snapshot(
      destinationId: "B", timeline: timeline, collections: collections,
      retryState: .empty, retryDestinationId: "A")
    #expect(switching.rows.isEmpty)
    await timeline.configureAndWait(for: "B")
    #expect(
      ExportIssuesProjection.snapshot(
        destinationId: "B", timeline: timeline, collections: collections,
        retryState: .empty, retryDestinationId: "A"
      ).rows.isEmpty)
    await timeline.configureAndWait(for: "A")
    let back = ExportIssuesProjection.snapshot(
      destinationId: "A", timeline: timeline, collections: collections,
      retryState: .empty, retryDestinationId: "B")
    #expect(back.rows.first?.assetId == "same")
    #expect(back.rows.first?.retry == nil)
    timeline.markVariantExported(
      assetId: "same", variant: .original, year: 2026, month: 10,
      relPath: "2026/10/", filename: "x", exportedAt: date)
    #expect(
      ExportIssuesProjection.snapshot(
        destinationId: "A", timeline: timeline, collections: collections,
        retryState: .empty, retryDestinationId: nil
      ).rows.isEmpty)
  }

  @Test func scopesVariantsAndCoveredFailuresHaveLiteralIdentities() {
    let failed = ExportVariantRecord(
      filename: nil, status: .failed, exportDate: date, lastError: "error")
    let covered = ExportVariantRecord(
      filename: nil, status: .failed, exportDate: date,
      lastError: ExportVariantRecovery.editedUnavailableOriginalBackedUpMessage,
      reason: .editedUnavailableOriginalBackedUp)
    let done = ExportVariantRecord(
      filename: "x_orig.heic", status: .done, exportDate: date, lastError: nil)
    let timeline = [
      "same": ExportRecord(
        id: "same", year: 2026, month: 10, relPath: "2026/10/",
        variants: [.original: done, .edited: covered, .originalPairedVideo: failed])
    ]
    let body = CollectionExportRecordStore.RecordBody(variants: ["original": failed])
    func album(_ id: String, _ kind: ExportPlacement.Kind = .album) -> ExportPlacement {
      ExportPlacement(
        kind: kind, id: id, displayName: id, collectionLocalIdentifier: id,
        relativePath: id, createdAt: date)
    }
    let rows = ExportIssuesProjection.make(
      destinationId: "A", timeline: timeline,
      collections: [
        "favorites": ["same": body], "one": ["same": body], "two": ["same": body],
        "shared": ["same": body],
      ],
      placements: [
        "favorites": album("favorites", .favorites), "one": album("one"), "two": album("two"),
        "shared": album("shared", .sharedAlbum),
      ])
    #expect(
      Set(rows.map(\.id))
        == Set([
          ExportIssue.Key(source: .timeline, assetId: "same", variantRaw: "edited"),
          ExportIssue.Key(source: .timeline, assetId: "same", variantRaw: "originalPairedVideo"),
          ExportIssue.Key(
            source: .collection("favorites"), assetId: "same", variantRaw: "original"),
          ExportIssue.Key(source: .collection("one"), assetId: "same", variantRaw: "original"),
          ExportIssue.Key(source: .collection("two"), assetId: "same", variantRaw: "original"),
          ExportIssue.Key(source: .collection("shared"), assetId: "same", variantRaw: "original"),
        ]))
    #expect(rows.first { $0.id.variantRaw == "edited" }?.isCovered == true)
    #expect(
      rows.first { $0.id.source == .collection("shared") }?.scopeKey
        == .sharedAlbum(placementId: "shared"))
  }

  @Test func staleRetryActionCannotChangeAnotherDestinationOrNewerEntry() throws {
    let builder = FakeAutoSyncEnvironmentBuilder()
    var retry = AutoSyncRetryState.empty
    retry.recordFailure(
      scope: .timeline, assetId: "same", variant: .original,
      category: .iCloudTransient, errorSignature: "network", at: date, nextEligibleAt: date)
    try builder.retryStore.save(retry, destinationId: "B")
    builder.destination.subject.send(
      DestinationSnapshot(stableId: "B", fingerprint: nil, isAvailable: true, safety: .safe))
    let manager = AutoSyncManager()
    manager.attach(to: builder.environment)
    let original = try #require(retry.entry(scope: .timeline, assetId: "same", variant: .original))
    manager.retryFailedVariant(
      scope: .timeline, assetId: "same", variant: .original,
      expectedDestinationId: "A", expectedEntry: original)
    #expect(try builder.retryStore.load(destinationId: "B") == retry)
    let stale = RetryEntry(
      category: original.category, errorSignature: "older", attemptCount: 1,
      firstFailedAt: date, lastFailedAt: date, nextEligibleAt: date)
    manager.retryFailedVariant(
      scope: .timeline, assetId: "same", variant: .original,
      expectedDestinationId: "B", expectedEntry: stale)
    #expect(try builder.retryStore.load(destinationId: "B") == retry)
    #expect(builder.exportRunner.receivedContexts.isEmpty)
  }
}
