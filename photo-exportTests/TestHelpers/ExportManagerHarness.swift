import Foundation

@testable import Photo_Export

/// Common export dependencies. Each suite keeps its scenario's explicit teardown order.
@MainActor
final class ExportManagerHarness {
  let photoLib: FakePhotoLibraryService
  let dest: FakeExportDestination
  let writer: FakeAssetResourceWriter
  let fileSystem: FakeFileSystem
  let storeRoot: URL
  let store: ExportRecordStore
  var timelineStore: ExportRecordStore { store }
  let collectionStore: CollectionExportRecordStore
  let defaults: UserDefaults
  let manager: ExportManager

  init(
    label: String,
    destinationId: String = "test",
    storeRootURL: URL? = nil,
    userDefaults: UserDefaults? = nil,
    photoLib: FakePhotoLibraryService? = nil,
    dest: FakeExportDestination? = nil,
    writer: FakeAssetResourceWriter = FakeAssetResourceWriter(),
    fileSystem: FakeFileSystem = FakeFileSystem(),
    mediaRenderer: (any MediaRenderer)? = nil,
    imageConverter: any ImageConverter = ProductionImageConverter(),
    runActivity: (any ExportRunActivity)? = nil
  ) {
    self.photoLib = photoLib ?? FakePhotoLibraryService()
    self.dest = dest ?? FakeExportDestination()
    self.writer = writer
    self.fileSystem = fileSystem
    storeRoot = storeRootURL ?? TestScratch.directory(label)
    store = ExportRecordStore(baseDirectoryURL: storeRoot)
    store.configure(for: destinationId)
    collectionStore = CollectionExportRecordStore(baseDirectoryURL: storeRoot)
    collectionStore.configure(for: destinationId)
    defaults = userDefaults ?? TestScratch.defaults(label)
    manager = ExportManager(
      photoLibraryService: self.photoLib,
      exportDestination: self.dest,
      exportRecordStore: store,
      collectionExportRecordStore: collectionStore,
      assetResourceWriter: writer,
      mediaRenderer: mediaRenderer,
      imageConverter: imageConverter,
      fileSystem: fileSystem,
      runActivity: runActivity,
      userDefaults: defaults)
  }
}
