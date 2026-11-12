import Combine
import Foundation
import Testing

@testable import Photo_Export

/// A single-scope export (one month, year, Favorites or album) is busy from the click,
/// not only once its scan has queued jobs. While its Photos scan runs, Import Existing
/// Backup and an Auto Export run must be refused exactly as they are during a bulk scan,
/// so an import and an export never change the history at the same time.
@MainActor
@Suite(.timeLimit(.minutes(2)))
struct ExportPreparationAdmissionTests {

  private static let july2025 = Calendar.current.date(
    from: DateComponents(year: 2025, month: 7, day: 15))!

  /// Starts a year export whose Photos scan stays held, runs `body` while it is held, then
  /// releases the scan and checks that only the year's asset was written.
  private func whileYearScanIsHeld(
    label: String, _ body: (ExportManagerHarness) async throws -> Void
  ) async throws {
    let harness = await ExportManagerHarness(label: label)
    harness.photoLib.assetsByYearMonth["2025-7"] = [
      TestAssetFactory.makeAsset(id: "a1", creationDate: Self.july2025)
    ]
    harness.photoLib.resourcesByAssetId["a1"] = [
      TestAssetFactory.makeResource(originalFilename: "A1.JPG")
    ]
    let scanGate = AsyncCheckpoint()
    harness.photoLib.fetchAssetsCheckpointByYear[2025] = scanGate
    try await withCleanup {
      harness.manager.startExportYear(year: 2025)
      let scanning = await scanGate.waitForEnter(count: 1)
      try #require(scanning)

      try await body(harness)

      await scanGate.releaseAll()
      await harness.manager.waitForQueueDrained()
      #expect(harness.writer.writeCalls.map(\.assetId) == ["a1"])
    } cleanup: {
      harness.manager.cancelAndClear()
      await scanGate.releaseAll()
      await harness.manager.waitForImportCompletion()
      await harness.store.waitUntilSettled()
      await harness.collectionStore.waitUntilSettled()
      try? FileManager.default.removeItem(at: harness.storeRoot)
      harness.dest.cleanup()
    }
  }

  @Test func importIsRefusedWhileSingleScopeScanRuns() async throws {
    try await whileYearScanIsHeld(label: "ImportDuringYearScan") { harness in
      #expect(harness.manager.hasActiveExportWork, "a running scan is active export work")
      harness.manager.startImport()
      #expect(!harness.manager.isImporting, "Import must not start while an export is scanning")
    }
  }

  @Test func autoExportRunIsRefusedWhileSingleScopeScanRuns() async throws {
    try await whileYearScanIsHeld(label: "AutoExportDuringYearScan") { harness in
      harness.photoLib.favoritesAssets = [TestAssetFactory.makeAsset(id: "fav")]
      harness.photoLib.resourcesByAssetId["fav"] = [
        TestAssetFactory.makeResource(originalFilename: "FAV.JPG")
      ]
      var runStates: [ExportRunState] = []
      let subscription = harness.manager.exportRunStatePublisher.sink { runStates.append($0) }
      defer { subscription.cancel() }
      #expect(runStates.last?.isManualActive == true, "Auto Export must see the scan as busy")

      let autoRun = Task {
        await harness.manager.runExport(
          context: ExportRunContext(
            source: .autoSync, visibility: .background, scope: .favoritesFull,
            selection: .edited))
      }
      let resolved = await finished(autoRun)
      try #require(resolved)
      #expect(await autoRun.value.result == .failed)
    }
  }
}
