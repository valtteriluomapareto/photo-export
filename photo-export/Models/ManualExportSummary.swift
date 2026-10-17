import Foundation

/// Manual placement-job outcomes; variant failures within one job count once.
struct ManualExportSummary: Equatable, Sendable {
  let id = UUID()
  let completedCount: Int
  let failedCount: Int
  let failureMessage: String?
  var isDismissed = false

  var exportedCount: Int { max(0, completedCount - failedCount) }
  var result: ExportRunResult {
    failedCount == 0 && failureMessage == nil ? .completed : .failed
  }
  var message: String {
    if result == .completed { return "Export complete" }
    if failedCount > 0 { return "\(exportedCount) exported · \(failedCount) failed" }
    return "Export incomplete"
  }
}
