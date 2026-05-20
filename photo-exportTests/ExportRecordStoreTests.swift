import Foundation
import Testing

@testable import Photo_Export

@MainActor
struct ExportRecordStoreTests {
    @Test func testLoadEmptyStore() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString, isDirectory: true)
        let store = ExportRecordStore(baseDirectoryURL: tempDir)
        store.configure(for: "destA")
        #expect(store.recordsById.isEmpty)
    }

    @Test func testUpsertAndQuery() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString, isDirectory: true)
        let store = ExportRecordStore(baseDirectoryURL: tempDir)
        store.configure(for: "destA")
        let id = "asset-1"
        store.markExported(
            assetId: id, year: 2025, month: 2, relPath: "2025/02/", filename: "IMG_0001.JPG",
            exportedAt: Date())
        store.flushForTesting()
        #expect(store.isExported(assetId: id))
        let info = store.exportInfo(assetId: id)
        #expect(info?.variants[.original]?.filename == "IMG_0001.JPG")
        #expect(info?.year == 2025)
        #expect(info?.month == 2)
    }

    @Test func testMonthSummary() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString, isDirectory: true)
        let store = ExportRecordStore(baseDirectoryURL: tempDir)
        store.configure(for: "destA")
        store.markExported(
            assetId: "a1", year: 2025, month: 1, relPath: "2025/01/", filename: "A.jpg",
            exportedAt: Date())
        store.markExported(
            assetId: "a2", year: 2025, month: 1, relPath: "2025/01/", filename: "B.jpg",
            exportedAt: Date())
        store.markFailed(assetId: "a3", error: "disk full", at: Date())  // wrong year/month defaults
        store.flushForTesting()
        let s1 = store.monthSummary(year: 2025, month: 1, totalAssets: 5)
        #expect(s1.exportedCount == 2)
        #expect(s1.totalCount == 5)
        #expect(s1.status == .partial)
        let s2 = store.monthSummary(year: 2025, month: 2, totalAssets: 3)
        #expect(s2.exportedCount == 0)
        #expect(s2.status == .notExported)
    }

    @Test func testFailureUpsert() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString, isDirectory: true)
        let store = ExportRecordStore(baseDirectoryURL: tempDir)
        store.configure(for: "destA")
        let id = "asset-fail"
        store.markFailed(assetId: id, error: "network", at: Date())
        store.flushForTesting()
        let info = store.exportInfo(assetId: id)
        #expect(info?.variants[.original]?.status == .failed)
        #expect(info?.variants[.original]?.lastError == "network")
    }

    @Test func testPersistenceAcrossLaunchesAndDeletion() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString, isDirectory: true)
        let store1 = ExportRecordStore(baseDirectoryURL: tempDir)
        store1.configure(for: "destA")
        store1.markInProgress(
            assetId: "x1", year: 2025, month: 3, relPath: "2025/03/", filename: nil)
        store1.markExported(
            assetId: "x2", year: 2025, month: 3, relPath: "2025/03/", filename: "X2.jpg",
            exportedAt: Date())
        store1.remove(assetId: "x1")
        store1.flushForTesting()

        // New instance, same root and destination id
        let store2 = ExportRecordStore(baseDirectoryURL: tempDir)
        store2.configure(for: "destA")
        #expect(store2.exportInfo(assetId: "x2")?.variants[.original]?.status == .done)
        #expect(store2.exportInfo(assetId: "x1") == nil)
    }

    @Test func testInProgressToDoneTransition() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString, isDirectory: true)
        let store = ExportRecordStore(baseDirectoryURL: tempDir)
        store.configure(for: "destA")
        store.markInProgress(
            assetId: "t1", year: 2025, month: 4, relPath: "2025/04/", filename: "tmp.mov")
        store.flushForTesting()
        #expect(store.exportInfo(assetId: "t1")?.variants[.original]?.status == .inProgress)
        store.markExported(
            assetId: "t1", year: 2025, month: 4, relPath: "2025/04/", filename: "final.mov",
            exportedAt: Date())
        store.flushForTesting()
        let rec = store.exportInfo(assetId: "t1")
        #expect(rec?.variants[.original]?.status == .done)
        #expect(rec?.variants[.original]?.filename == "final.mov")
    }

    @Test func testCorruptedLogLineIsSkipped() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString, isDirectory: true)
        let store = ExportRecordStore(baseDirectoryURL: tempDir)
        let destId = "destA"
        store.configure(for: destId)
        store.markExported(
            assetId: "ok", year: 2025, month: 5, relPath: "2025/05/", filename: "OK.jpg",
            exportedAt: Date())
        store.flushForTesting()
        // Append an invalid line to the destination-specific log
        let logURL = tempDir.appendingPathComponent(destId, isDirectory: true)
            .appendingPathComponent("export-records.jsonl")
        let invalid = "{ this is not valid json }\n".data(using: .utf8)!
        try invalid.append(to: logURL)

        // Reload - invalid line should be skipped, valid records preserved
        let store2 = ExportRecordStore(baseDirectoryURL: tempDir)
        store2.configure(for: destId)
        #expect(store2.exportInfo(assetId: "ok")?.variants[.original]?.status == .done)
    }

    @Test func testPerDestinationIsolation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString, isDirectory: true)
        let store = ExportRecordStore(baseDirectoryURL: root)

        store.configure(for: "destA")
        store.markExported(
            assetId: "a1", year: 2025, month: 6, relPath: "2025/06/", filename: "A1.jpg",
            exportedAt: Date())
        store.flushForTesting()
        #expect(store.isExported(assetId: "a1"))

        store.configure(for: "destB")
        #expect(!store.isExported(assetId: "a1"))
        store.markExported(
            assetId: "b1", year: 2025, month: 6, relPath: "2025/06/", filename: "B1.jpg",
            exportedAt: Date())
        store.flushForTesting()
        #expect(store.isExported(assetId: "b1"))

        store.configure(for: "destA")
        #expect(store.isExported(assetId: "a1"))
        #expect(!store.isExported(assetId: "b1"))
    }

    @Test func testNilDestinationShowsEmpty() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString, isDirectory: true)
        let store = ExportRecordStore(baseDirectoryURL: root)

        store.configure(for: "destA")
        store.markExported(
            assetId: "a1", year: 2025, month: 7, relPath: "2025/07/", filename: "A1.jpg",
            exportedAt: Date())
        store.flushForTesting()
        #expect(store.isExported(assetId: "a1"))

        store.configure(for: nil)
        #expect(!store.isExported(assetId: "a1"))
        #expect(store.monthSummary(year: 2025, month: 7, totalAssets: 1).exportedCount == 0)
    }

    @Test func testMutationCounterCoalescedNotifications() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString, isDirectory: true)
        let store = ExportRecordStore(baseDirectoryURL: tempDir)
        store.configure(for: "destC")
        let baseline = store.mutationCounter
        // Burst of mutations
        for i in 0..<5 {
            store.markInProgress(
                assetId: "c\(i)", year: 2025, month: 8, relPath: "2025/08/", filename: nil)
        }
        // Wait for debounce (200ms) to fire once
        try await Task.sleep(nanoseconds: 600_000_000)
        let delta = store.mutationCounter - baseline
        #expect(delta == 1)
    }

    // MARK: - Strict, asset-aware isExported

    @Test func strictIsExportedDefaultModeUneditedAsset() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString, isDirectory: true)
        let store = ExportRecordStore(baseDirectoryURL: tempDir)
        store.configure(for: "destStrict")
        let asset = TestAssetFactory.makeAsset(id: "u", hasAdjustments: false)
        // .original.done at any filename satisfies an unedited asset's requirement.
        store.markVariantExported(
            assetId: asset.id, variant: .original, year: 2025, month: 1,
            relPath: "2025/01/", filename: "vacation_orig.JPG", exportedAt: Date())
        store.flushForTesting()
        #expect(store.isExported(asset: asset, selection: .edited))
        #expect(store.isExported(asset: asset, selection: .editedWithOriginals))
    }

    @Test func strictIsExportedDefaultModeAdjustedAsset() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString, isDirectory: true)
        let store = ExportRecordStore(baseDirectoryURL: tempDir)
        store.configure(for: "destStrict2")
        let asset = TestAssetFactory.makeAsset(id: "a", hasAdjustments: true)
        // Only .original.done — adjusted asset requires .edited under default mode.
        store.markVariantExported(
            assetId: asset.id, variant: .original, year: 2025, month: 1,
            relPath: "2025/01/", filename: "IMG_0001.JPG", exportedAt: Date())
        store.flushForTesting()
        #expect(!store.isExported(asset: asset, selection: .edited))

        store.markVariantExported(
            assetId: asset.id, variant: .edited, year: 2025, month: 1,
            relPath: "2025/01/", filename: "IMG_0001 (1).JPG", exportedAt: Date())
        store.flushForTesting()
        #expect(store.isExported(asset: asset, selection: .edited))
    }

    @Test func strictIsExportedIncludeOriginalsAdjustedAssetRequiresBoth() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString, isDirectory: true)
        let store = ExportRecordStore(baseDirectoryURL: tempDir)
        store.configure(for: "destStrict3")
        let asset = TestAssetFactory.makeAsset(id: "a", hasAdjustments: true)
        store.markVariantExported(
            assetId: asset.id, variant: .edited, year: 2025, month: 1,
            relPath: "2025/01/", filename: "IMG_0001.JPG", exportedAt: Date())
        store.flushForTesting()
        #expect(!store.isExported(asset: asset, selection: .editedWithOriginals))

        store.markVariantExported(
            assetId: asset.id, variant: .original, year: 2025, month: 1,
            relPath: "2025/01/", filename: "IMG_0001_orig.JPG", exportedAt: Date())
        store.flushForTesting()
        #expect(store.isExported(asset: asset, selection: .editedWithOriginals))
    }

    /// Per-thumbnail badge and header summary use the same `isExported(asset:selection:livePhotosPaired:)`
    /// overload. With the toggle on, a Live Photo whose `.original` is `.done` but
    /// `.originalPairedVideo` is `.pending` must NOT be reported as exported — otherwise the grid
    /// shows a green check while the header still reads partial. Pins the call-site contract that
    /// MonthContentView's thumbnail grid forwards `livePhotosPaired`.
    @Test func strictIsExportedLivePhotoPairedPendingNotComplete() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString, isDirectory: true)
        let store = ExportRecordStore(baseDirectoryURL: tempDir)
        store.configure(for: "destLivePair")
        let live = TestAssetFactory.makeAsset(id: "live", isLivePhoto: true)
        store.markVariantExported(
            assetId: live.id, variant: .original, year: 2025, month: 1,
            relPath: "2025/01/", filename: "IMG_0001.HEIC", exportedAt: Date())
        store.markVariantInProgress(
            assetId: live.id, variant: .originalPairedVideo, year: 2025, month: 1,
            relPath: "2025/01/", filename: nil)
        store.flushForTesting()

        // Toggle off → legacy behaviour: still-only is exported.
        #expect(store.isExported(asset: live, selection: .edited, livePhotosPaired: false))
        // Toggle on → paired video pending blocks completion.
        #expect(!store.isExported(asset: live, selection: .edited, livePhotosPaired: true))

        // Mark the paired video done → both modes agree.
        store.markVariantExported(
            assetId: live.id, variant: .originalPairedVideo, year: 2025, month: 1,
            relPath: "2025/01/", filename: "IMG_0001.MOV", exportedAt: Date())
        store.flushForTesting()
        #expect(store.isExported(asset: live, selection: .edited, livePhotosPaired: true))
    }

    // MARK: - Sidebar approximation: cap behaviour

    @Test func sidebarSummaryCapsOriginalOnlyContributionAtUneditedCount() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString, isDirectory: true)
        let store = ExportRecordStore(baseDirectoryURL: tempDir)
        store.configure(for: "destCap")
        let now = Date()
        // 10 records, all `.original.done` at natural stem (post-import case where the
        // scanner couldn't tell same-extension edits apart from originals).
        for i in 0..<10 {
            store.markVariantExported(
                assetId: "asset-\(i)", variant: .original, year: 2025, month: 5,
                relPath: "2025/05/", filename: "IMG_\(i).JPG", exportedAt: now)
        }
        store.flushForTesting()

        // 30 of 100 are adjusted; the cap pins original-only contribution at 70.
        // editedDone is 0; exported = 0 + min(10, 70) = 10.
        let summary = store.sidebarSummary(
            year: 2025, month: 5, totalCount: 100, adjustedCount: 30,
            selection: .edited)
        #expect(summary?.exportedCount == 10)
    }

    @Test func sidebarSummaryReturnsNilWhileAdjustedCountLoading() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString, isDirectory: true)
        let store = ExportRecordStore(baseDirectoryURL: tempDir)
        store.configure(for: "destLoading")
        let summary = store.sidebarSummary(
            year: 2025, month: 5, totalCount: 100, adjustedCount: nil,
            selection: .edited)
        #expect(summary == nil)
    }

    /// R2-6: documented mixed-partial overcount limitation. 10 assets, 5 currently
    /// adjusted; 3 unedited originals exported plus 5 same-extension imports
    /// mis-recorded as natural-stem `.original.done`. Asset-aware truth = 3, but the
    /// records-only formula returns 5 because `min(8, 5) = 5`. Asserting the documented
    /// over-count protects the invariant: future "fix" attempts that drop the cap or
    /// reach for asset descriptors must update this test deliberately.
    @Test func sidebarSummaryDocumentedMixedPartialOvercount() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString, isDirectory: true)
        let store = ExportRecordStore(baseDirectoryURL: tempDir)
        store.configure(for: "destMixed")
        let now = Date()
        // 8 records, all `.original.done` at natural stem. 3 belong to unedited assets;
        // 5 are same-extension edits mis-classified by an earlier import.
        for i in 0..<8 {
            store.markVariantExported(
                assetId: "asset-\(i)", variant: .original, year: 2025, month: 6,
                relPath: "2025/06/", filename: "IMG_\(i).JPG", exportedAt: now)
        }
        store.flushForTesting()

        // 10 assets total, 5 adjusted → uneditedCount = 5. origOnlyAtStem = 8.
        // exported = 0 (editedDone) + min(8, 5) = 5. Asset-aware truth would be 3.
        let summary = store.sidebarSummary(
            year: 2025, month: 6, totalCount: 10, adjustedCount: 5,
            selection: .edited)
        #expect(summary?.exportedCount == 5)
    }

    /// R2-7: documented `vacation_orig.JPG` undercount. The shape-only `isOrigCompanion`
    /// excludes a record for an unedited asset whose actual filename ends with `_orig`
    /// from `origOnlyAtStem`, so the sidebar under-counts by 1. Asserting the documented
    /// under-count rather than the asset-aware truth — the asset-aware path remains
    /// correct via `MonthContentView.exportSummaryView`.
    @Test func sidebarSummaryUnderCountsForUserOrigFilename() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString, isDirectory: true)
        let store = ExportRecordStore(baseDirectoryURL: tempDir)
        store.configure(for: "destUserOrig")
        store.markVariantExported(
            assetId: "user-orig", variant: .original, year: 2025, month: 7,
            relPath: "2025/07/", filename: "vacation_orig.JPG", exportedAt: Date())
        store.flushForTesting()

        // 1 asset, 0 adjusted → uneditedCount = 1. origOnlyAtStem excludes the record
        // because `vacation_orig.JPG` matches `isOrigCompanion` shape-only.
        let summary = store.sidebarSummary(
            year: 2025, month: 7, totalCount: 1, adjustedCount: 0,
            selection: .edited)
        #expect(summary?.exportedCount == 0)  // Documented under-count.
        #expect(summary?.status == .notExported)
    }

    /// R2-8: year-scope sidebar aggregation. Sums per-month sidebarSummary results,
    /// skips months with zero assets, propagates nil from any month whose
    /// adjustedCount hasn't loaded.
    @Test func sidebarYearExportedCountAggregatesAcrossMonths() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString, isDirectory: true)
        let store = ExportRecordStore(baseDirectoryURL: tempDir)
        store.configure(for: "destYear")
        let now = Date()
        // March: 2 unedited assets, both exported.
        store.markVariantExported(
            assetId: "m3-a", variant: .original, year: 2025, month: 3,
            relPath: "2025/03/", filename: "M3A.JPG", exportedAt: now)
        store.markVariantExported(
            assetId: "m3-b", variant: .original, year: 2025, month: 3,
            relPath: "2025/03/", filename: "M3B.JPG", exportedAt: now)
        // July: 1 adjusted asset, edit done.
        store.markVariantExported(
            assetId: "m7-a", variant: .edited, year: 2025, month: 7,
            relPath: "2025/07/", filename: "M7A.JPG", exportedAt: now)
        store.flushForTesting()

        let totals = [3: 2, 7: 1]
        let adjusted: [Int: Int?] = [3: 0, 7: 1]
        let count = store.sidebarYearExportedCount(
            year: 2025,
            totalCountsByMonth: totals,
            adjustedCountsByMonth: adjusted,
            selection: .edited)
        #expect(count == 3)

        // A month whose adjustedCount is still loading contributes 0 to the total —
        // the YearRow suppresses the badge while any populated month is nil so the
        // user never sees this partial sum.
        let adjustedLoading: [Int: Int?] = [3: nil, 7: 1]
        let countWithLoading = store.sidebarYearExportedCount(
            year: 2025,
            totalCountsByMonth: totals,
            adjustedCountsByMonth: adjustedLoading,
            selection: .edited)
        #expect(countWithLoading == 1)
    }

    /// R2-10: explicit standalone case for an unedited asset under
    /// `editedWithOriginals`. The asset has only `.original.done`; that's all that's
    /// required for an unedited asset under either selection.
    @Test func strictIsExportedIncludeOriginalsUneditedAssetSatisfiedByOriginalDone() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString, isDirectory: true)
        let store = ExportRecordStore(baseDirectoryURL: tempDir)
        store.configure(for: "destUnedited")
        let asset = TestAssetFactory.makeAsset(id: "u", hasAdjustments: false)
        store.markVariantExported(
            assetId: asset.id, variant: .original, year: 2025, month: 1,
            relPath: "2025/01/", filename: "IMG_0001.JPG", exportedAt: Date())
        store.flushForTesting()
        #expect(store.isExported(asset: asset, selection: .editedWithOriginals))
    }

    @Test func testDoneCountTracksTransitionsAndMoves() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString, isDirectory: true)
        let store = ExportRecordStore(baseDirectoryURL: tempDir)
        store.configure(for: "destD")
        // Export to month 9
        store.markExported(
            assetId: "t", year: 2025, month: 9, relPath: "2025/09/", filename: "A.jpg",
            exportedAt: Date())
        store.flushForTesting()
        #expect(store.monthSummary(year: 2025, month: 9, totalAssets: 10).exportedCount == 1)
        // Mark failed -> should decrement month 9
        store.markFailed(assetId: "t", error: "oops", at: Date())
        store.flushForTesting()
        #expect(store.monthSummary(year: 2025, month: 9, totalAssets: 10).exportedCount == 0)
        // Re-export same id to month 10 -> counts move
        store.markExported(
            assetId: "t", year: 2025, month: 10, relPath: "2025/10/", filename: "B.jpg",
            exportedAt: Date())
        store.flushForTesting()
        #expect(store.monthSummary(year: 2025, month: 9, totalAssets: 10).exportedCount == 0)
        #expect(store.monthSummary(year: 2025, month: 10, totalAssets: 10).exportedCount == 1)
    }
}

extension Data {
    fileprivate func append(to url: URL) throws {
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: self)
        try handle.synchronize()
    }
}
