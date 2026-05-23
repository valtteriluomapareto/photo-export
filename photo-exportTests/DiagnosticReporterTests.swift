import Foundation
import Testing

@testable import Photo_Export

/// Coverage for `DiagnosticReporter.makeReport()`. Verifies that the report includes
/// every `.failed` and `.inProgress` variant from both stores, surfaces `lastError`,
/// and produces stable output when there's nothing to report.
@MainActor
struct DiagnosticReporterTests {

  // MARK: - Harness

  private struct Harness {
    let timelineStore: ExportRecordStore
    let collectionStore: CollectionExportRecordStore
    let storeRoot: URL
  }

  private func makeHarness() -> Harness {
    let storeRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent("DiagnosticReporter-\(UUID().uuidString)", isDirectory: true)
    let timelineStore = ExportRecordStore(baseDirectoryURL: storeRoot)
    timelineStore.configure(for: "test")
    let collectionStore = CollectionExportRecordStore(baseDirectoryURL: storeRoot)
    collectionStore.configure(for: "test")
    return Harness(
      timelineStore: timelineStore, collectionStore: collectionStore, storeRoot: storeRoot)
  }

  private func makeReporter(_ h: Harness) -> DiagnosticReporter {
    DiagnosticReporter(
      timelineStore: h.timelineStore,
      collectionStore: h.collectionStore,
      destinationId: "test-destination-id",
      appVersion: "9.9.9",
      buildNumber: "42",
      now: { Date(timeIntervalSince1970: 1_800_000_000) }
    )
  }

  // MARK: - Tests

  @Test func reportHeaderContainsVersionAndDestination() {
    let h = makeHarness()
    defer { try? FileManager.default.removeItem(at: h.storeRoot) }

    let report = makeReporter(h).makeReport()

    #expect(report.contains("photo-export diagnostic report"))
    #expect(report.contains("App version: 9.9.9 (42)"))
    #expect(report.contains("Destination ID: test-destination-id"))
  }

  @Test func emptyStoresProduceCleanSummaryAndNoneSections() {
    let h = makeHarness()
    defer { try? FileManager.default.removeItem(at: h.storeRoot) }

    let report = makeReporter(h).makeReport()

    #expect(report.contains("Failed variants:      0"))
    #expect(report.contains("In-progress variants: 0"))
    // Each of the four problem sections renders "(none)" when empty.
    let noneCount = report.components(separatedBy: "(none)").count - 1
    #expect(noneCount == 4)
  }

  @Test func failedTimelineVariantAppearsWithErrorAndScope() {
    let h = makeHarness()
    defer { try? FileManager.default.removeItem(at: h.storeRoot) }

    h.timelineStore.markVariantInProgress(
      assetId: "fail-asset-1", variant: .original, year: 2024, month: 12,
      relPath: "2024/12/", filename: "IMG_0001.HEIC")
    h.timelineStore.markVariantFailed(
      assetId: "fail-asset-1", variant: .original,
      error: "Asset bytes not available from iCloud",
      at: Date(timeIntervalSince1970: 1_800_000_000))

    let report = makeReporter(h).makeReport()

    #expect(report.contains("Failed variants:      1"))
    #expect(report.contains("[Timeline 2024-12]"))
    #expect(report.contains("assetId=fail-asset-1"))
    #expect(report.contains("variant=original"))
    #expect(report.contains("error: Asset bytes not available from iCloud"))
  }

  @Test func inProgressTimelineVariantAppearsInItsOwnSection() {
    let h = makeHarness()
    defer { try? FileManager.default.removeItem(at: h.storeRoot) }

    h.timelineStore.markVariantInProgress(
      assetId: "stuck-asset", variant: .edited, year: 2025, month: 3,
      relPath: "2025/03/", filename: "IMG_0042.HEIC")

    let report = makeReporter(h).makeReport()

    #expect(report.contains("In-progress variants: 1"))
    let lines = report.split(separator: "\n").map(String.init)
    let inProgressHeaderIdx = lines.firstIndex(
      of: "== In-progress variants — Timeline ==")
    #expect(inProgressHeaderIdx != nil)
    if let idx = inProgressHeaderIdx {
      // The asset id appears after the section header, before the next section.
      let tail = lines[idx...].joined(separator: "\n")
      #expect(tail.contains("assetId=stuck-asset"))
      #expect(tail.contains("variant=edited"))
    }
  }

  // MARK: - Previous AutoSync run journal

  /// When no journal is on disk, the report omits the section *entirely*
  /// — no header, no "(none)" placeholder, and none of the per-field
  /// labels. Pins the byte-for-byte compatibility promise: a user with
  /// no in-flight run on launch sees the same report shape as before
  /// the journal feature shipped.
  ///
  /// The per-field-label asserts catch a regression that emits an empty
  /// section body (no header but field labels still rendered). Without
  /// them, a refactor that returned `["Trigger:        ", ...]` from
  /// `previousRunSection()` when `previousRunJournal == nil` would slip
  /// through.
  @Test func absentJournalOmitsTheSectionEntirely() {
    let h = makeHarness()
    defer { try? FileManager.default.removeItem(at: h.storeRoot) }

    let report = makeReporter(h).makeReport()

    #expect(!report.contains("== Previous Auto-Export Run =="))
    #expect(!report.contains("Previous Auto-Export"))
    // Per-field labels — pinned at the journal section's specific
    // 8-space gap so the assertions don't false-fail against the
    // catch-up section (which uses a 3-space gap for its own
    // `Started:` / `Trigger:` lines). "Planned scopes:" and the
    // "Status: in-flight" line are exclusive to the journal section
    // regardless of width.
    #expect(!report.contains("Trigger:        "))
    #expect(!report.contains("Planned scopes:"))
    #expect(!report.contains("Current scope:"))
    #expect(!report.contains("Status:         in-flight on launch"))
  }

  /// Populated journal renders all six fields and the load-bearing
  /// "previous session did not finish cleanly" status line. The status
  /// line is what tells a maintainer reading the .txt that the silent
  /// shutdown happened — without it the section reads like a status pill
  /// rather than a forensic signal.
  @Test func populatedJournalRendersAllFieldsAndAbnormalExitStatus() {
    let h = makeHarness()
    defer { try? FileManager.default.removeItem(at: h.storeRoot) }

    let journal = AutoSyncRunJournal(
      startedAt: Date(timeIntervalSince1970: 1_800_000_000),
      trigger: "appLaunch",
      scopes: ["timeline", "favorites", "albums", "sharedAlbums"],
      currentScope: "albums",
      currentScopeStartedAt: Date(timeIntervalSince1970: 1_800_000_300))
    let reporter = DiagnosticReporter(
      timelineStore: h.timelineStore, collectionStore: h.collectionStore,
      destinationId: "test-destination-id", appVersion: "9.9.9", buildNumber: "42",
      previousRunJournal: journal,
      now: { Date(timeIntervalSince1970: 1_800_000_500) }
    )

    let report = reporter.makeReport()

    #expect(report.contains("== Previous Auto-Export Run =="))
    // Pin the `Started:` line's field-label width (8 spaces between
    // "Started:" and the value). Locks in the layout so a refactor that
    // drops the padding doesn't silently change what users see. Exact
    // timestamp drift is uninteresting; the width pin catches the real
    // regression class.
    #expect(
      report.contains("Started:        "),
      "Started: line must use the 8-space label-to-value gap shared by all journal-section fields")
    #expect(report.contains("Trigger:        appLaunch"))
    #expect(report.contains("Planned scopes: timeline, favorites, albums, sharedAlbums"))
    #expect(report.contains("Current scope:  albums (since"))
    #expect(
      report.contains("Status:         in-flight on launch (previous session did not finish cleanly)"),
      "Status line is what tells the maintainer this is an abnormal-exit signal, not just a status snapshot"
    )
  }

  /// A journal that was written but never reached the first per-scope
  /// iteration — the OS killed the fan-out task before the loop body ran.
  /// The section must say so explicitly rather than render a confusing
  /// empty `Current scope:` field.
  @Test func journalWithNoCurrentScopeRendersExplicitMessage() {
    let h = makeHarness()
    defer { try? FileManager.default.removeItem(at: h.storeRoot) }

    let journal = AutoSyncRunJournal(
      startedAt: Date(timeIntervalSince1970: 1_800_000_000),
      trigger: "photosChanged",
      scopes: ["timeline"],
      currentScope: nil,
      currentScopeStartedAt: nil)
    let reporter = DiagnosticReporter(
      timelineStore: h.timelineStore, collectionStore: h.collectionStore,
      destinationId: "test-destination-id", appVersion: "9.9.9", buildNumber: "42",
      previousRunJournal: journal,
      now: { Date(timeIntervalSince1970: 1_800_000_500) }
    )

    let report = reporter.makeReport()

    #expect(
      report.contains("Current scope:  (none — killed before first sub-scope started)"),
      "Explicit message disambiguates 'before-first-await' kill from 'fields missing'")
  }

  /// The journal section appears **above** the existing catch-up section,
  /// not below. A maintainer reading the report top-to-bottom hits the
  /// abnormal-exit signal before the 80,000-record summary; this ordering
  /// is part of the slice's value proposition.
  @Test func journalSectionAppearsAboveCatchUpAndSummary() {
    let h = makeHarness()
    defer { try? FileManager.default.removeItem(at: h.storeRoot) }

    let journal = AutoSyncRunJournal(
      startedAt: Date(timeIntervalSince1970: 1_800_000_000),
      trigger: "appLaunch",
      scopes: ["timeline"],
      currentScope: "timeline",
      currentScopeStartedAt: Date(timeIntervalSince1970: 1_800_000_001))
    let reporter = DiagnosticReporter(
      timelineStore: h.timelineStore, collectionStore: h.collectionStore,
      destinationId: "test-destination-id", appVersion: "9.9.9", buildNumber: "42",
      previousRunJournal: journal,
      now: { Date(timeIntervalSince1970: 1_800_000_500) }
    )

    let report = reporter.makeReport()
    let lines = report.split(separator: "\n").map(String.init)
    let journalIdx = lines.firstIndex(of: "== Previous Auto-Export Run ==")
    let catchUpIdx = lines.firstIndex(of: "== Last iCloud Library Catch-Up ==")
    let summaryIdx = lines.firstIndex(of: "== Summary ==")
    #expect(journalIdx != nil && catchUpIdx != nil && summaryIdx != nil)
    if let j = journalIdx, let c = catchUpIdx, let s = summaryIdx {
      #expect(j < c, "Journal section must precede catch-up section")
      #expect(c < s, "Catch-up section must still precede the record-count summary")
    }
  }

  @Test func failedCollectionVariantIncludesPlacementDisplayName() {
    let h = makeHarness()
    defer { try? FileManager.default.removeItem(at: h.storeRoot) }

    let placement = ExportPlacement(
      kind: .album,
      id: "collections:album:abc:def",
      displayName: "Trip to Italy",
      collectionLocalIdentifier: "album-1",
      relativePath: "Collections/Albums/Trip to Italy/",
      createdAt: Date()
    )
    h.collectionStore.upsertPlacement(placement)
    h.collectionStore.markVariantFailed(
      assetId: "broken-asset", placement: placement, variant: .original,
      error: "Disk full", at: Date(timeIntervalSince1970: 1_800_000_000))

    let report = makeReporter(h).makeReport()

    #expect(report.contains("[album: Trip to Italy]"))
    #expect(report.contains("assetId=broken-asset"))
    #expect(report.contains("error: Disk full"))
  }
}
