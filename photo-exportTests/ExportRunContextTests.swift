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

  /// Guard: a summary saved before `stoppedBy` existed decodes with no stop category, and
  /// one with it round-trips.
  @Test func summaryStoppedByIsOptionalInSavedJSON() throws {
    let summary = ExportRunSummary(
      context: ExportRunContext(
        runId: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
        source: .autoSync, visibility: .background, scope: .timelineFullLibrary,
        selection: .edited, startedAt: Date(timeIntervalSince1970: 1_700_000_000)),
      endedAt: Date(timeIntervalSince1970: 1_700_000_060),
      enqueuedCount: 3, completedCount: 1, failedCount: 1, skippedCount: 0,
      cancelReason: .destinationUnavailable, result: .interrupted,
      stoppedBy: .destinationUnavailable)
    let data = try JSONEncoder().encode(summary)
    #expect(try JSONDecoder().decode(ExportRunSummary.self, from: data) == summary)

    var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(object["stoppedBy"] as? String == "destinationUnavailable")
    object.removeValue(forKey: "stoppedBy")
    let legacy = try JSONDecoder().decode(
      ExportRunSummary.self, from: JSONSerialization.data(withJSONObject: object))
    #expect(legacy.stoppedBy == nil)
    #expect(legacy.result == .interrupted && legacy.cancelReason == .destinationUnavailable)
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
