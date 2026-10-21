import Testing

@testable import Photo_Export

/// The one rule every manual export control reads: whether it can start, and the help it shows
/// when it can't, for each destination and history state.
struct ManualExportAvailabilityTests {
  private static let destinationHelp = "The destination can't take exports."
  private static let historyHelp =
    "Export history isn\u{2019}t available. Resolve the export history alert to export."

  struct Row: Sendable, CustomTestStringConvertible {
    let destinationCanExport: Bool
    let history: RecordStoreState
    let expected: ManualExportAvailability
    let help: String?

    var testDescription: String { "destination \(destinationCanExport), history \(history)" }
  }

  static let table: [Row] = [
    Row(destinationCanExport: true, history: .ready, expected: .available, help: nil),
    Row(
      destinationCanExport: true, history: .loading, expected: .loadingHistory,
      help: ManualExportAvailability.loadingHistoryText),
    Row(
      destinationCanExport: true, history: .unconfigured, expected: .historyUnavailable,
      help: historyHelp),
    Row(
      destinationCanExport: true, history: .failed, expected: .historyUnavailable,
      help: historyHelp),
    Row(
      destinationCanExport: true, history: .persistenceFailed, expected: .historyUnavailable,
      help: historyHelp),
    Row(
      destinationCanExport: false, history: .ready, expected: .destinationUnavailable,
      help: destinationHelp),
    Row(
      destinationCanExport: false, history: .loading, expected: .destinationUnavailable,
      help: destinationHelp),
    Row(
      destinationCanExport: false, history: .unconfigured, expected: .destinationUnavailable,
      help: destinationHelp),
    Row(
      destinationCanExport: false, history: .failed, expected: .destinationUnavailable,
      help: destinationHelp),
    Row(
      destinationCanExport: false, history: .persistenceFailed,
      expected: .destinationUnavailable, help: destinationHelp),
  ]

  @Test(arguments: table)
  func eachStateMapsToItsAvailabilityAndHelp(row: Row) {
    let availability = ManualExportAvailability(
      destinationCanExport: row.destinationCanExport, history: row.history)
    #expect(availability == row.expected)
    #expect(availability.canStart == (row.expected == .available))
    #expect(availability.unavailableHelp(destinationHelp: Self.destinationHelp) == row.help)
  }
}
