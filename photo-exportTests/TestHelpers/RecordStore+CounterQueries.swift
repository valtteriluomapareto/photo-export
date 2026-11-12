import Foundation

@testable import Photo_Export

/// Per-month counts read straight from the store's incremental `monthCounters`, so tests that
/// use them also check that every mutation keeps those counters right. They do not register
/// observation and do not hide a history whose replacement is still pending.
@MainActor
extension ExportRecordStore {
  private func counters(year: Int, month: Int) -> MonthCounters {
    monthCounters[MonthKey(year: year, month: month)] ?? .zero
  }

  func recordCount(year: Int, month: Int, variant: ExportVariant, status: ExportStatus) -> Int {
    counters(year: year, month: month).variantStatus[variant]?[status] ?? 0
  }

  func recordCountBothVariantsDone(year: Int, month: Int) -> Int {
    counters(year: year, month: month).bothVariantsDone
  }

  func recordCountEditedDone(year: Int, month: Int) -> Int {
    recordCount(year: year, month: month, variant: .edited, status: .done)
  }

  func recordCountOriginalDoneAtNaturalStem(year: Int, month: Int) -> Int {
    counters(year: year, month: month).originalDoneAtNaturalStem
  }

  func recordCountEditedFallback(year: Int, month: Int) -> Int {
    counters(year: year, month: month).editedFallbackCovered
  }

  func recordCountPairedVideoIncomplete(year: Int, month: Int) -> Int {
    counters(year: year, month: month).pairedVideoIncomplete
  }

  /// Records in `year` whose original is done.
  func yearExportedCount(year: Int) -> Int {
    (1...12).reduce(0) {
      $0 + recordCount(year: year, month: $1, variant: .original, status: .done)
    }
  }

  /// A month's original-done records against `totalAssets`.
  func monthSummary(year: Int, month: Int, totalAssets: Int) -> MonthStatusSummary {
    let exported = recordCount(year: year, month: month, variant: .original, status: .done)
    let status: MonthExportStatus =
      exported == 0 || totalAssets == 0
      ? .notExported : exported < totalAssets ? .partial : .complete
    return MonthStatusSummary(
      year: year, month: month, exportedCount: exported, totalCount: totalAssets, status: status)
  }
}

@MainActor
extension CollectionExportRecordStore {
  func placements(matching kind: ExportPlacement.Kind) -> [ExportPlacement] {
    placements.values.filter { $0.kind == kind }
  }
}
