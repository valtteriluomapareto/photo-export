import Foundation
import Testing

@testable import Photo_Export

struct ExportRunContextTests {
  @Test func roundTripsThroughCodable() throws {
    let ctx = ExportRunContext(
      runId: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
      source: .autoSync,
      visibility: .background,
      reason: .photosChanged,
      scope: .timelineAssets(["asset-1", "asset-2"]),
      selection: .editedWithOriginals,
      startedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )

    let data = try JSONEncoder().encode(ctx)
    let decoded = try JSONDecoder().decode(ExportRunContext.self, from: data)

    #expect(decoded == ctx)
  }

  @Test func summaryDurationIsEndMinusStart() {
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    let end = start.addingTimeInterval(42)
    let summary = ExportRunSummary(
      context: ExportRunContext(
        source: .manual, visibility: .userVisible, scope: .timelineFullLibrary,
        selection: .edited, startedAt: start),
      endedAt: end,
      enqueuedCount: 5,
      completedCount: 4,
      failedCount: 1,
      skippedCount: 0,
      cancelReason: nil,
      result: .completed
    )

    #expect(summary.duration == 42)
  }

  @Test func runStateIdleHasNoActiveRun() {
    let state = ExportRunState.idle

    #expect(state.activeContext == nil)
    #expect(state.isManualActive == false)
    #expect(state.isAutoSyncActive == false)
  }

  @Test func summaryRoundTripsThroughCodable() throws {
    let summary = ExportRunSummary(
      context: ExportRunContext(
        source: .autoSync,
        visibility: .background,
        reason: .destinationBecameAvailable,
        scope: .autoExport(
          AutoExportScopeSelection(timeline: true, favorites: true, albums: false)),
        selection: .edited
      ),
      endedAt: Date(timeIntervalSince1970: 1_700_000_100),
      enqueuedCount: 10,
      completedCount: 10,
      failedCount: 0,
      skippedCount: 0,
      cancelReason: nil,
      result: .completed
    )

    let data = try JSONEncoder().encode(summary)
    let decoded = try JSONDecoder().decode(ExportRunSummary.self, from: data)

    #expect(decoded == summary)
  }
}
