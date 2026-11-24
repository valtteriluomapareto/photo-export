import Testing

@testable import Photo_Export

struct ImportPresentationTests {
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
