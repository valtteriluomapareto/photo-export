import Testing

@testable import Photo_Export

struct ImportPresentationTests {
  @Test func stagesPreserveProgressAndMatchingCounts() {
    let rows: [(BackupScanner.ImportStage?, String)] = [
      (nil, "Preparing…"), (.scanningBackupFolder, "Scanning backup folder…"),
      (.readingPhotosLibrary, "Reading Photos library…"),
      (.matchingAssets(matched: 4, total: 9), "Matching assets… 4 found of 9 files"),
      (.rebuildingLocalState, "Rebuilding local state…"),
      (.reconcilingDiskState, "Pruning records for missing files…"), (.done, "Done"),
    ]
    for (stage, expected) in rows { #expect(ImportPresentation.stageLabel(stage) == expected) }
  }

  @Test func retryRequiresTimelineAndDestinationButAllowsUnreadyCollectionWithoutRecovery() {
    func canRetry(
      destination: Bool = true, timeline: RecordStoreState = .ready,
      collections: RecordStoreState = .ready, importing: Bool = false, active: Bool = false
    ) -> Bool {
      ImportPresentation.canRetry(
        destinationCanImport: destination, timeline: timeline, collections: collections,
        importing: importing, activeExport: active)
    }
    #expect(canRetry())
    #expect(canRetry(collections: .loading))
    #expect(canRetry(collections: .unconfigured))
    #expect(!canRetry(destination: false))
    #expect(!canRetry(timeline: .loading))
    #expect(!canRetry(timeline: .unconfigured))
    #expect(!canRetry(collections: .failed))
    #expect(!canRetry(collections: .persistenceFailed))
    #expect(!canRetry(importing: true))
    #expect(!canRetry(active: true))
  }

  @Test func recoveryGuidancePrioritizesUnsavedHistoryOverDriveRecovery() {
    let drive =
      "Check that your backup drive is connected. Close this sheet to reselect the export folder if access needs renewing, then try again."
    let history =
      "Close this sheet and resolve the export history alert before retrying. Keep the app open to preserve unsaved progress."
    #expect(ImportPresentation.recoveryGuidance(timeline: .ready, collections: .ready) == drive)
    #expect(ImportPresentation.recoveryGuidance(timeline: .loading, collections: .loading) == drive)
    #expect(
      ImportPresentation.recoveryGuidance(timeline: .persistenceFailed, collections: .ready)
        == history)
    #expect(ImportPresentation.recoveryGuidance(timeline: .ready, collections: .failed) == history)
  }

  @Test func reportRowsKeepTimelineCollectionsAmbiguitiesAndPruningDistinct() {
    let report = ImportReport(
      matchedCount: 1, ambiguousCount: 2, unmatchedCount: 3, totalScanned: 6,
      prunedVariants: 5, prunedRecords: 4, collectionFilesScanned: 7, collectionMatchedCount: 6,
      unrecognizedCollectionFolders: ["Collections/Albums/Trips/Old/", "Collections/Favorites/"])
    let rows = ImportPresentation.rows(report)
    #expect(
      rows.map(\.label) == [
        "Timeline files scanned", "Matched to Photos library", "Ambiguous (skipped)",
        "No matching asset found", "Album and Favorites files scanned",
        "Album and Favorites files matched", "Album folders not linked to an album",
        "Records pruned (file missing)",
      ])
    #expect(rows.map(\.value) == ["6", "1", "2", "3", "7", "6", "2", "4 records, 5 variants"])
    #expect(
      rows[6].caption
        == "“Trips/Old”, “Favorites”. These are usually albums renamed, moved or deleted in Photos since they were exported. Their files are left as they are."
    )
    let empty = ImportReport(matchedCount: 0, ambiguousCount: 0, unmatchedCount: 0, totalScanned: 0)
    #expect(
      ImportPresentation.rows(empty).map(\.label) == [
        "Timeline files scanned", "Matched to Photos library",
      ])
    let prune = ImportReport(
      matchedCount: 0, ambiguousCount: 0, unmatchedCount: 0, totalScanned: 0, prunedVariants: 2,
      prunedRecords: 2)
    #expect(ImportPresentation.rows(prune).last?.value == "2")
  }

  @Test func unlinkedFoldersLimitNamesButPreserveRelativePaths() {
    #expect(
      ImportPresentation.unlinkedFoldersCaption([
        "Collections/Albums/Trips/Paris/", "Collections/Favorites/", "Collections/Albums/Old/",
        "Collections/Albums/Omitted/",
      ])
        == "“Trips/Paris”, “Favorites”, “Old” and 1 more. These are usually albums renamed, moved or deleted in Photos since they were exported. Their files are left as they are."
    )
  }
}
