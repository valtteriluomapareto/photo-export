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

  /// One asset in July 2025 whose year scan stays held until the test releases it.
  private func makeHeldYearScan(label: String) async -> (ExportManagerHarness, AsyncCheckpoint) {
    let harness = await ExportManagerHarness(label: label)
    harness.photoLib.assetsByYearMonth["2025-7"] = [
      TestAssetFactory.makeAsset(id: "a1", creationDate: Self.july2025)
    ]
    harness.photoLib.resourcesByAssetId["a1"] = [
      TestAssetFactory.makeResource(originalFilename: "A1.JPG")
    ]
    let scanGate = AsyncCheckpoint()
    harness.photoLib.fetchAssetsCheckpointByYear[2025] = scanGate
    return (harness, scanGate)
  }

  private func cleanUp(_ harness: ExportManagerHarness, _ scanGate: AsyncCheckpoint) async {
    await scanGate.releaseAll()
    harness.manager.cancelAndClear()
    await harness.manager.waitForImportCompletion()
    await harness.store.waitUntilSettled()
    await harness.collectionStore.waitUntilSettled()
    try? FileManager.default.removeItem(at: harness.storeRoot)
    harness.dest.cleanup()
  }

  @Test func importIsRefusedWhileSingleScopeScanRuns() async throws {
    let (harness, scanGate) = await makeHeldYearScan(label: "ImportDuringYearScan")
    let manager = harness.manager

    manager.startExportYear(year: 2025)
    let scanning = await scanGate.waitForEnter(count: 1)
    try #require(scanning)

    #expect(manager.hasActiveExportWork, "a running scan is active export work")
    manager.startImport()
    #expect(!manager.isImporting, "Import must not start while an export is scanning")

    await scanGate.releaseAll()
    await manager.waitForQueueDrained()
    #expect(harness.writer.writeCalls.map(\.assetId) == ["a1"])

    await cleanUp(harness, scanGate)
  }

  @Test func autoExportRunIsRefusedWhileSingleScopeScanRuns() async throws {
    let (harness, scanGate) = await makeHeldYearScan(label: "AutoExportDuringYearScan")
    let manager = harness.manager
    harness.photoLib.favoritesAssets = [TestAssetFactory.makeAsset(id: "fav")]
    harness.photoLib.resourcesByAssetId["fav"] = [
      TestAssetFactory.makeResource(originalFilename: "FAV.JPG")
    ]
    var runStates: [ExportRunState] = []
    let subscription = manager.exportRunStatePublisher.sink { runStates.append($0) }
    defer { subscription.cancel() }

    manager.startExportYear(year: 2025)
    let scanning = await scanGate.waitForEnter(count: 1)
    try #require(scanning)

    #expect(runStates.last?.isManualActive == true, "Auto Export must see the scan as busy")
    let autoRun = await manager.runExport(
      context: ExportRunContext(
        source: .autoSync, visibility: .background, scope: .favoritesFull, selection: .edited))
    #expect(autoRun.result == .failed)

    await scanGate.releaseAll()
    await manager.waitForQueueDrained()
    #expect(harness.writer.writeCalls.map(\.assetId) == ["a1"])

    await cleanUp(harness, scanGate)
  }
}
