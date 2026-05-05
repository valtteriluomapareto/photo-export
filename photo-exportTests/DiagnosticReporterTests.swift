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
