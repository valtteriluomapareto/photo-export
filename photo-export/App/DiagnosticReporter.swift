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
  /// Latest iCloud-Photos catch-up summary — surfaced so a reporter hitting
  /// the issue #92 launch beachball can attach the diagnostic report and the
  /// maintainer can see exactly how long the fetch took / how many changes
  /// were processed without needing Console snippets.
  let lastCatchUpSummary: PhotoLibraryPersistentChangeAdapter.CatchUpSummary?
  /// In-flight AutoSync run journal, if any. Read once at panel-open time
  /// from `FileBackedAutoSyncCurrentRunStore`. Present means the previous
  /// session's AutoSync fan-out was killed mid-flight (the manager deletes
  /// the file on clean exit). Surfaced near the top of the report so the
  /// abnormal-exit signal is visible before the record-count summaries.
  /// Absent → the report omits the section entirely, keeping reports
  /// byte-identical to today for users not hitting the issue.
  let previousRunJournal: AutoSyncRunJournal?
  private let now: () -> Date

  init(
    timelineStore: ExportRecordStore,
    collectionStore: CollectionExportRecordStore,
    destinationId: String?,
    appVersion: String,
    buildNumber: String,
    lastCatchUpSummary: PhotoLibraryPersistentChangeAdapter.CatchUpSummary? = nil,
    previousRunJournal: AutoSyncRunJournal? = nil,
    now: @escaping () -> Date = Date.init
  ) {
    self.timelineStore = timelineStore
    self.collectionStore = collectionStore
    self.destinationId = destinationId
    self.appVersion = appVersion
    self.buildNumber = buildNumber
    self.lastCatchUpSummary = lastCatchUpSummary
    self.previousRunJournal = previousRunJournal
    self.now = now
  }

  func makeReport() -> String {
    var lines: [String] = []
    lines.append("photo-export diagnostic report")
    lines.append("Generated: \(Self.formatter.string(from: now()))")
    lines.append("App version: \(appVersion) (\(buildNumber))")
    lines.append("Destination ID: \(destinationId ?? "<none>")")
    lines.append("")
    lines.append(contentsOf: previousRunSection())
    lines.append(contentsOf: catchUpSection())

    let timelineFailed = collectTimelineProblems(status: .failed)
    let timelineInProgress = collectTimelineProblems(status: .inProgress)
    let collectionFailed = collectCollectionProblems(status: .failed)
    let collectionInProgress = collectCollectionProblems(status: .inProgress)

    let timelineFallbacks = timelineFailed.filter { $0.fallbackFilename != nil }.count
    let collectionFallbacks = collectionFailed.filter { $0.fallbackFilename != nil }.count

    lines.append("== Summary ==")
    lines.append("Timeline store state: \(String(describing: timelineStore.state))")
    lines.append("  Total records:        \(timelineStore.recordsById.count)")
    lines.append("  Failed variants:      \(timelineFailed.count)")
    if timelineFallbacks > 0 {
      lines.append(
        "    of which fallback-covered (original written as _orig): \(timelineFallbacks)"
      )
    }
    lines.append("  In-progress variants: \(timelineInProgress.count)")
    lines.append("Collection store state: \(String(describing: collectionStore.state))")
    lines.append("  Placements:           \(collectionStore.placements.count)")
    let collectionTotalRecords = collectionStore.recordBodies.values
      .reduce(0) { $0 + $1.count }
    lines.append("  Total records:        \(collectionTotalRecords)")
    lines.append("  Failed variants:      \(collectionFailed.count)")
    if collectionFallbacks > 0 {
      lines.append(
        "    of which fallback-covered (original written as _orig): \(collectionFallbacks)"
      )
    }
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
    /// When this is a `.failed` `.edited` variant covered by the issue #22
    /// `_orig` fallback (matching record has `.original` `.done`), this holds
    /// the on-disk filename of that fallback so the report can call it out.
    let fallbackFilename: String?
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
            exportDate: variantRecord.exportDate,
            fallbackFilename: editedFallbackFilename(
              variant: variant, variantRecord: variantRecord,
              originalRecord: record.variants[.original])))
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
          let variant = ExportVariant(rawValue: variantKey) ?? .original
          problems.append(
            Problem(
              scope: scope, assetId: assetId,
              variant: variant,
              filename: variantRecord.filename,
              lastError: variantRecord.lastError,
              exportDate: variantRecord.exportDate,
              fallbackFilename: editedFallbackFilename(
                variant: variant, variantRecord: variantRecord,
                originalRecord: body.variants[ExportVariant.original.rawValue])))
        }
      }
    }
    return problems.sorted { $0.scope < $1.scope }
  }

  /// Returns the original-side filename when this `.failed` `.edited`
  /// variant is covered by the `_orig` fallback. Otherwise nil.
  ///
  /// Keys on `editedUnavailableOriginalBackedUpMessage` — the explicit
  /// sentinel `runEditedFallbackOriginal` writes only after a successful
  /// `_orig` write. The previous filename-shape check (`isOrigCompanion`)
  /// was ambiguous for real user filenames like `vacation_orig.JPG`.
  private func editedFallbackFilename(
    variant: ExportVariant,
    variantRecord: ExportVariantRecord,
    originalRecord: ExportVariantRecord?
  ) -> String? {
    guard variant == .edited,
      variantRecord.status == .failed,
      variantRecord.lastError
        == ExportVariantRecovery.editedUnavailableOriginalBackedUpMessage,
      let original = originalRecord,
      original.status == .done,
      let filename = original.filename
    else { return nil }
    return filename
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
      if let fallback = problem.fallbackFilename {
        lines.append("  fallback: original exported as \(fallback)")
      }
    }
    lines.append("")
    return lines
  }

  /// Previous AutoSync run journal block. Emitted **only when a journal
  /// exists** on disk for the active destination — i.e. when the previous
  /// session's AutoSync fan-out was killed mid-flight (the manager deletes
  /// the journal on clean exit). Omitted entirely (no "(none)" placeholder)
  /// when absent, so reports for healthy users stay byte-identical to today.
  private func previousRunSection() -> [String] {
    guard let journal = previousRunJournal else { return [] }
    var lines: [String] = []
    lines.append("== Previous Auto-Export Run ==")
    lines.append("Started:        \(Self.formatter.string(from: journal.startedAt))")
    lines.append("Trigger:        \(journal.trigger)")
    lines.append("Planned scopes: \(journal.scopes.joined(separator: ", "))")
    if let currentScope = journal.currentScope {
      if let startedAt = journal.currentScopeStartedAt {
        lines.append(
          "Current scope:  \(currentScope) (since \(Self.formatter.string(from: startedAt)))"
        )
      } else {
        lines.append("Current scope:  \(currentScope)")
      }
    } else {
      lines.append("Current scope:  (none — killed before first sub-scope started)")
    }
    lines.append("Status:         in-flight on launch (previous session did not finish cleanly)")
    lines.append("")
    return lines
  }

  /// Catch-up summary block. Always emitted (with "(none recorded)" when no
  /// summary is available) so a reporter who attaches the diagnostic file
  /// without running into the issue #92 hang still tells us "the off-main
  /// catch-up never ran on this launch."
  private func catchUpSection() -> [String] {
    var lines: [String] = []
    lines.append("== Last iCloud Library Catch-Up ==")
    guard let summary = lastCatchUpSummary else {
      lines.append("(none recorded this launch)")
      lines.append("")
      return lines
    }
    let durationMs = Int(summary.duration * 1000)
    lines.append("Started:   \(Self.formatter.string(from: summary.startedAt))")
    lines.append("Finished:  \(Self.formatter.string(from: summary.finishedAt))")
    lines.append("Duration:  \(durationMs) ms")
    lines.append("Trigger:   \(summary.trigger)")
    switch summary.result {
    case .capturedBaseline:
      lines.append("Result:    captured baseline (first launch / no prior token)")
    case .emittedChanges(let count):
      lines.append("Result:    emitted \(count) change(s)")
    case .detailsUnavailable(let failures):
      lines.append("Result:    per-change details unavailable (\(failures) failure(s)); token rebased")
    case .fetchError(let description):
      lines.append("Result:    fetch error: \(description); token rebased")
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
