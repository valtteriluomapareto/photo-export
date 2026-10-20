import Foundation
import Photos
import Testing

@testable import Photo_Export

/// A real `ExportManager` over fake Photos, writer and file system, with both record stores on
/// disk, for exporting to and importing from collection folders.
@MainActor
final class CollectionImportHarness {
  let library = FakePhotoLibraryService()
  let destination = FakeExportDestination()
  let writer = FakeAssetResourceWriter()
  let fileSystem = FakeFileSystem()
  let storeRoot: URL
  let timeline: ExportRecordStore
  let collections: CollectionExportRecordStore
  let manager: ExportManager
  private(set) var destinationId = "dest"

  init(_ label: String, videoLayout: ExportVideoLayout = .subfolder) {
    storeRoot = TestScratch.directory(label)
    timeline = ExportRecordStore(baseDirectoryURL: storeRoot)
    collections = CollectionExportRecordStore(baseDirectoryURL: storeRoot)
    timeline.configure(for: destinationId)
    collections.configure(for: destinationId)
    manager = ExportManager(
      photoLibraryService: library, exportDestination: destination,
      exportRecordStore: timeline, collectionExportRecordStore: collections,
      assetResourceWriter: writer, fileSystem: fileSystem,
      userDefaults: TestScratch.defaults(label))
    manager.videoLayout = videoLayout
  }

  var root: URL { destination.rootURL }

  /// Starts both stores on an empty history for the same folder, as after a reinstall.
  func wipeHistory() {
    timeline.flushForTesting()
    collections.flushForTesting()
    destinationId += "-wiped"
    timeline.configure(for: destinationId)
    collections.configure(for: destinationId)
  }

  func importBackup() async {
    manager.startImport()
    await manager.waitForImportCompletion()
  }

  /// Adds `asset` with a single original resource named `filename`.
  @discardableResult
  func addAsset(
    _ id: String, _ filename: String, date: Date, mediaType: PHAssetMediaType = .image
  ) -> AssetDescriptor {
    let asset = TestAssetFactory.makeAsset(
      id: id, creationDate: date, mediaType: mediaType, pixelWidth: 100, pixelHeight: 100)
    library.resourcesByAssetId[id] = [
      TestAssetFactory.makeResource(
        type: mediaType == .video ? .video : .photo, originalFilename: filename)
    ]
    return asset
  }

  /// The folder a fresh export of `selection` writes `asset` to.
  func exportDirectory(for selection: LibrarySelection, asset: AssetDescriptor) throws -> String {
    let placement = try ExportPlacementResolver().placement(
      for: selection, collections: library.collectionTree,
      existingPlacements: Array(collections.placements.values))
    let subfolder = ExportPlacementPathPolicy.subfolder(
      for: asset.mediaType, layout: manager.videoLayout)
    return ExportPlacementPathPolicy.relativePath(placement: placement, subfolder: subfolder)
  }

  /// The byte-level record files of the current history.
  func historyBytes() -> [String: Data] {
    timeline.flushForTesting()
    collections.flushForTesting()
    var result: [String: Data] = [:]
    let dir = storeRoot.appendingPathComponent(destinationId, isDirectory: true)
    for name in [
      "export-records.json", "export-records.jsonl", "collection-records.json",
      "collection-records.jsonl",
    ] {
      result[name] = try? Data(contentsOf: dir.appendingPathComponent(name))
    }
    return result
  }

  func cleanup() async {
    var running = manager.currentPreparationTasks + [manager.currentTask].compactMap { $0 }
    manager.cancelAndClear()
    running += manager.currentPreparationTasks + [manager.currentTask].compactMap { $0 }
    for task in running { _ = await finished(task) }
    if let task = manager.importTask { _ = await finished(task) }
    timeline.flushForTesting()
    collections.flushForTesting()
    try? FileManager.default.removeItem(at: storeRoot)
    destination.cleanup()
  }
}
