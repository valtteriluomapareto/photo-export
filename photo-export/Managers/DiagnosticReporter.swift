import Foundation

/// Builds a plain-text diagnostic report listing every `.failed` and `.inProgress` variant
/// across the two record stores. Users save this file from the Help menu and attach it to
/// GitHub issues so we can see the actual `lastError` strings instead of guessing at why an
/// export stalled at 99%.
///
/// The report is line-oriented and stable — fields are labeled, not positional — so the
/// format can grow without breaking parsers people might write against it.
@MainActor
struct DiagnosticReporter {
  let timelineStore: ExportRecordStore
  let collectionStore: CollectionExportRecordStore
  let destinationId: String?
  let appVersion: String
  let buildNumber: String
  private let now: () -> Date

  init(
    timelineStore: ExportRecordStore,
    collectionStore: CollectionExportRecordStore,
    destinationId: String?,
    appVersion: String,
    buildNumber: String,
    now: @escaping () -> Date = Date.init
  ) {
    self.timelineStore = timelineStore
    self.collectionStore = collectionStore
    self.destinationId = destinationId
    self.appVersion = appVersion
    self.buildNumber = buildNumber
    self.now = now
  }

  func makeReport() -> String {
    var lines: [String] = []
    lines.append("photo-export diagnostic report")
    lines.append("Generated: \(Self.formatter.string(from: now()))")
    lines.append("App version: \(appVersion) (\(buildNumber))")
    lines.append("Destination ID: \(destinationId ?? "<none>")")
    lines.append("")

    let timelineFailed = collectTimelineProblems(status: .failed)
    let timelineInProgress = collectTimelineProblems(status: .inProgress)
    let collectionFailed = collectCollectionProblems(status: .failed)
    let collectionInProgress = collectCollectionProblems(status: .inProgress)

    lines.append("== Summary ==")
    lines.append("Timeline store state: \(String(describing: timelineStore.state))")
    lines.append("  Total records:        \(timelineStore.recordsById.count)")
    lines.append("  Failed variants:      \(timelineFailed.count)")
    lines.append("  In-progress variants: \(timelineInProgress.count)")
    lines.append("Collection store state: \(String(describing: collectionStore.state))")
    lines.append("  Placements:           \(collectionStore.placements.count)")
    let collectionTotalRecords = collectionStore.recordBodies.values
      .reduce(0) { $0 + $1.count }
    lines.append("  Total records:        \(collectionTotalRecords)")
    lines.append("  Failed variants:      \(collectionFailed.count)")
    lines.append("  In-progress variants: \(collectionInProgress.count)")
    lines.append("")

    lines.append(contentsOf: section("Failed variants — Timeline", timelineFailed))
    lines.append(contentsOf: section("Failed variants — Collections", collectionFailed))
    lines.append(contentsOf: section("In-progress variants — Timeline", timelineInProgress))
    lines.append(contentsOf: section("In-progress variants — Collections", collectionInProgress))
    return lines.joined(separator: "\n") + "\n"
  }

  // MARK: - Collection

  private struct Problem {
    let scope: String
    let assetId: String
    let variant: ExportVariant
    let filename: String?
    let lastError: String?
    let exportDate: Date?
  }

  private func collectTimelineProblems(status target: ExportStatus) -> [Problem] {
    var problems: [Problem] = []
    for record in timelineStore.recordsById.values {
      for (variant, variantRecord) in record.variants where variantRecord.status == target {
        problems.append(
          Problem(
            scope: "Timeline \(String(format: "%04d-%02d", record.year, record.month))",
            assetId: record.id, variant: variant,
            filename: variantRecord.filename,
            lastError: variantRecord.lastError,
            exportDate: variantRecord.exportDate))
      }
    }
    return problems.sorted { $0.scope < $1.scope }
  }

  private func collectCollectionProblems(status target: ExportStatus) -> [Problem] {
    var problems: [Problem] = []
    for (placementId, byAsset) in collectionStore.recordBodies {
      let placement = collectionStore.placements[placementId]
      let scope =
        placement.map { "\($0.kind.rawValue): \($0.displayName)" }
        ?? "Unknown placement \(placementId)"
      for (assetId, body) in byAsset {
        for (variantKey, variantRecord) in body.variants where variantRecord.status == target {
          problems.append(
            Problem(
              scope: scope, assetId: assetId,
              variant: ExportVariant(rawValue: variantKey) ?? .original,
              filename: variantRecord.filename,
              lastError: variantRecord.lastError,
              exportDate: variantRecord.exportDate))
        }
      }
    }
    return problems.sorted { $0.scope < $1.scope }
  }

  private func section(_ title: String, _ problems: [Problem]) -> [String] {
    var lines: [String] = []
    lines.append("== \(title) ==")
    if problems.isEmpty {
      lines.append("(none)")
      lines.append("")
      return lines
    }
    for problem in problems {
      lines.append(
        "[\(problem.scope)] assetId=\(problem.assetId) variant=\(problem.variant.rawValue)"
      )
      if let filename = problem.filename {
        lines.append("  filename: \(filename)")
      }
      lines.append("  error: \(problem.lastError ?? "<no error message>")")
      if let date = problem.exportDate {
        lines.append("  date: \(Self.formatter.string(from: date))")
      }
    }
    lines.append("")
    return lines
  }

  private static let formatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
  }()
}
