import Foundation
import Photos
import Testing

@testable import Photo_Export

/// Closes a P0 coverage gap in `ExportManager`'s reuse-source copy path
/// (`ExportManager.swift:907-937`). The path classifies copy errors via
/// `isSourceSideCopyError(_:)`:
///
/// - **Source-side errors** (`NSFileReadNoSuchFileError`, etc.) ⇒ fall through to
///   the PhotoKit writer; the prior `.done` record is stale.
/// - **Destination-side errors** (out-of-space, write permission denied, etc.) ⇒
///   throw without falling back. Retrying via PhotoKit would hit the same
///   destination problem.
///
/// `ReuseSourceCopyPathTests.swift` covers the source-side fallback
/// (`missingReuseSourceFallsBackToPhotoKit`) and the no-reuse path. The
/// destination-side bucket has zero direct coverage. A regression that
/// misclassifies (e.g. adding `NSFileWriteOutOfSpaceError` to the source-side
/// switch in `isSourceSideCopyError`) would silently retry destination problems
/// via PhotoKit — doubling work and never surfacing the real error to the user.
@MainActor
struct ReuseSourceDestinationErrorTests {

  // MARK: - Fixtures

  private func makeManager() throws -> (
    ExportManager, FakePhotoLibraryService, FakeExportDestination, FakeAssetResourceWriter,
    FakeFileSystem, ExportRecordStore, CollectionExportRecordStore, URL
  ) {
    let photoLib = FakePhotoLibraryService()
    let dest = FakeExportDestination()
    let writer = FakeAssetResourceWriter()
    let fileSystem = FakeFileSystem()
    let storeRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent("ReuseSourceDestErr-\(UUID().uuidString)", isDirectory: true)
    let timelineStore = ExportRecordStore(baseDirectoryURL: storeRoot)
    timelineStore.configure(for: "test")
    let collectionStore = CollectionExportRecordStore(baseDirectoryURL: storeRoot)
    collectionStore.configure(for: "test")
    let defaults = UserDefaults(
      suiteName: "test-ReuseDestErr-\(UUID().uuidString)")!
    let manager = ExportManager(
      photoLibraryService: photoLib,
      exportDestination: dest,
      exportRecordStore: timelineStore,
      collectionExportRecordStore: collectionStore,
      assetResourceWriter: writer,
      fileSystem: fileSystem,
      userDefaults: defaults
    )
    return (manager, photoLib, dest, writer, fileSystem, timelineStore, collectionStore, storeRoot)
  }

  private func makeAsset(id: String) -> AssetDescriptor {
    AssetDescriptor(
      id: id,
      creationDate: Date(timeIntervalSince1970: 1_700_000_000),
      mediaType: .image,
      pixelWidth: 100,
      pixelHeight: 100,
      duration: 0,
      hasAdjustments: false
    )
  }

  private func waitForQueueDrained(_ manager: ExportManager, timeout: TimeInterval = 5) async {
    let deadline = Date().addingTimeInterval(timeout)
    await Task.yield()
    try? await Task.sleep(nanoseconds: 50_000_000)
    while !manager.isRunning && manager.queueCount == 0 && manager.totalJobsEnqueued == 0
      && Date() < deadline
    {
      try? await Task.sleep(nanoseconds: 10_000_000)
    }
    while (manager.isRunning || manager.queueCount > 0 || manager.hasActiveExportWork)
      && Date() < deadline
    {
      try? await Task.sleep(nanoseconds: 10_000_000)
    }
  }

  // MARK: - Out-of-space (destination-side)

  /// `NSFileWriteOutOfSpaceError` is a destination-side error: the source file
  /// exists, but writing to the destination fails because the volume is full.
  /// `findReuseSource` finds a valid reuse candidate and `copyItem` is called —
  /// then the FakeFileSystem injects `NSFileWriteOutOfSpaceError`. The variant
  /// must be marked `.failed` and the PhotoKit writer must NOT be invoked
  /// (PhotoKit would hit the same out-of-space situation).
  @Test func destinationOutOfSpaceFailsVariantWithoutPhotoKitFallback() async throws {
    let (
      manager, photoLib, dest, writer, fileSystem, _, collectionStore, storeRoot
    ) = try makeManager()
    defer { try? FileManager.default.removeItem(at: storeRoot); dest.cleanup() }

    let asset = makeAsset(id: "shared")
    photoLib.assetsByYearMonth["2025-3"] = [asset]
    photoLib.resourcesByAssetId[asset.id] = [
      ResourceDescriptor(type: .photo, originalFilename: "IMG.HEIC")
    ]

    // Pre-stage a favorites export with a real file at the destination, so a
    // reuse-source candidate exists when the timeline export starts.
    let favorites = ExportPlacement.favorites()
    let favDir = try dest.urlForRelativeDirectory(
      favorites.relativePath, createIfNeeded: true)
    let favFile = favDir.appendingPathComponent("IMG.HEIC")
    try Data("favorited".utf8).write(to: favFile)
    collectionStore.upsertPlacement(favorites)
    collectionStore.markVariantExported(
      assetId: asset.id, placement: favorites, variant: .original,
      filename: "IMG.HEIC", exportedAt: Date())

    // Inject a destination-side error on the copy.
    fileSystem.copyError = NSError(
      domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError,
      userInfo: [NSLocalizedDescriptionKey: "The volume is out of space."])

    let writeCallsBefore = writer.writeCalls.count
    manager.startExportMonth(year: 2025, month: 3)
    await waitForQueueDrained(manager)

    // The copy was attempted (proves reuse path was taken) but PhotoKit was NOT
    // invoked as fallback (proves the destination-side classification rejected the
    // fallthrough).
    #expect(fileSystem.copyCalls.count == 1, "reuse copy must have been attempted")
    #expect(writer.writeCalls.count == writeCallsBefore, "PhotoKit writer must not run")

    // The variant is recorded as `.failed`.
    let info = manager.exportRecordStore.exportInfo(assetId: asset.id)
    #expect(info?.variants[.original]?.status == .failed)
    let lastError = info?.variants[.original]?.lastError ?? ""
    #expect(
      lastError.contains("out of space") || lastError.contains("Out of space"),
      "failure should preserve the out-of-space error message: \(lastError)"
    )
  }

  /// Symmetric case for write-permission errors (e.g. `NSFileWriteNoPermissionError`).
  /// Same destination-side classification — must fail without PhotoKit fallback.
  @Test func destinationPermissionDeniedFailsVariantWithoutPhotoKitFallback() async throws {
    let (
      manager, photoLib, dest, writer, fileSystem, _, collectionStore, storeRoot
    ) = try makeManager()
    defer { try? FileManager.default.removeItem(at: storeRoot); dest.cleanup() }

    let asset = makeAsset(id: "shared")
    photoLib.assetsByYearMonth["2025-4"] = [asset]
    photoLib.resourcesByAssetId[asset.id] = [
      ResourceDescriptor(type: .photo, originalFilename: "IMG.HEIC")
    ]

    let favorites = ExportPlacement.favorites()
    let favDir = try dest.urlForRelativeDirectory(
      favorites.relativePath, createIfNeeded: true)
    let favFile = favDir.appendingPathComponent("IMG.HEIC")
    try Data("favorited".utf8).write(to: favFile)
    collectionStore.upsertPlacement(favorites)
    collectionStore.markVariantExported(
      assetId: asset.id, placement: favorites, variant: .original,
      filename: "IMG.HEIC", exportedAt: Date())

    fileSystem.copyError = NSError(
      domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError,
      userInfo: [NSLocalizedDescriptionKey: "You don't have permission to save."])

    let writeCallsBefore = writer.writeCalls.count
    manager.startExportMonth(year: 2025, month: 4)
    await waitForQueueDrained(manager)

    #expect(fileSystem.copyCalls.count == 1)
    #expect(writer.writeCalls.count == writeCallsBefore)

    let info = manager.exportRecordStore.exportInfo(assetId: asset.id)
    #expect(info?.variants[.original]?.status == .failed)
  }
}
