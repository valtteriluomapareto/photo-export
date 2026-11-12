import Foundation

enum ImportPresentation {
  struct Row: Identifiable, Equatable {
    let label: String
    let value: String
    let icon: String
    var caption: String?
    var id: String { label }
  }

  static func stageLabel(_ stage: BackupScanner.ImportStage?) -> String {
    switch stage {
    case .scanningBackupFolder: return "Scanning backup folder…"
    case .readingPhotosLibrary: return "Reading Photos library…"
    case .matchingAssets(let matched, let total):
      return "Matching assets… \(matched) found of \(total) files"
    case .rebuildingLocalState: return "Rebuilding local state…"
    case .reconcilingDiskState: return "Pruning records for missing files…"
    case .done: return "Done"
    case .none: return "Preparing…"
    }
  }

  static func canRetry(
    destinationCanImport: Bool, timeline: RecordStoreState, collections: RecordStoreState,
    importing: Bool, activeExport: Bool
  ) -> Bool {
    destinationCanImport && timeline == .ready && !collections.needsRecovery
      && !importing && !activeExport
  }

  static func recoveryGuidance(timeline: RecordStoreState, collections: RecordStoreState) -> String
  {
    if timeline.needsRecovery || collections.needsRecovery {
      return
        "Close this sheet and resolve the export history alert before retrying. Keep the app open to preserve unsaved progress."
    }
    return
      "Check that your backup drive is connected. Close this sheet to reselect the export folder if access needs renewing, then try again."
  }

  static let collectionsSkippedGuidance =
    "Album and Favorites history wasn’t rebuilt because it isn’t available. Resolve the export history alert, then import again."

  static func rows(_ report: ImportReport) -> [Row] {
    var rows = [
      Row(label: "Timeline files scanned", value: "\(report.totalScanned)", icon: "doc.on.doc"),
      Row(
        label: "Matched to Photos library", value: "\(report.matchedCount)",
        icon: "checkmark.circle"),
    ]
    if report.ambiguousCount > 0 {
      rows.append(
        Row(
          label: "Ambiguous (skipped)", value: "\(report.ambiguousCount)",
          icon: "questionmark.circle"))
    }
    if report.unmatchedCount > 0 {
      rows.append(
        Row(
          label: "No matching asset found", value: "\(report.unmatchedCount)", icon: "xmark.circle")
      )
    }
    if report.collectionFilesScanned > 0 {
      rows += [
        Row(
          label: "Album and Favorites files scanned", value: "\(report.collectionFilesScanned)",
          icon: "rectangle.stack"),
        Row(
          label: "Album and Favorites files matched", value: "\(report.collectionMatchedCount)",
          icon: "checkmark.rectangle.stack"),
      ]
    }
    if !report.unrecognizedCollectionFolders.isEmpty {
      rows.append(
        Row(
          label: "Album folders not linked to an album",
          value: "\(report.unrecognizedCollectionFolders.count)",
          icon: "folder.badge.questionmark",
          caption: unlinkedFoldersCaption(report.unrecognizedCollectionFolders)))
    }
    if report.prunedRecords > 0 || report.prunedVariants > 0 {
      let value =
        report.prunedVariants == report.prunedRecords
        ? "\(report.prunedRecords)"
        : "\(report.prunedRecords) records, \(report.prunedVariants) variants"
      rows.append(Row(label: "Records pruned (file missing)", value: value, icon: "trash"))
    }
    return rows
  }

  static func unlinkedFoldersCaption(_ folders: [String]) -> String {
    let names = folders.prefix(3).map { path in
      let parts = path.split(separator: "/").map(String.init)
      let name = parts.count > 2 ? parts.dropFirst(2).joined(separator: "/") : parts.last ?? path
      return "“\(name)”"
    }
    let more = folders.count > 3 ? " and \(folders.count - 3) more" : ""
    return names.joined(separator: ", ") + more
      + ". These are usually albums renamed, moved or deleted in Photos since they were "
      + "exported. Their files are left as they are."
  }
}
