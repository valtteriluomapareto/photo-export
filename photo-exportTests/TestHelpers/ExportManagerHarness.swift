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
    photoKitReader: (any PhotoKitReading)? = nil,
    dest: FakeExportDestination? = nil,
    writer: FakeAssetResourceWriter = FakeAssetResourceWriter(),
    fileSystem: FakeFileSystem = FakeFileSystem(),
    mediaRenderer: (any MediaRenderer)? = nil,
    imageConverter: any ImageConverter = ProductionImageConverter(),
    runActivity: (any ExportRunActivity)? = nil,
    exportMeasurements: ExportMeasurements? = nil,
    destinationIOFactory: @escaping @MainActor (String?) -> any DestinationIOExecuting = {
      _ in
      DestinationIO()
    }
  ) async {
    self.photoLib = photoLib ?? FakePhotoLibraryService()
    self.dest = dest ?? FakeExportDestination()
    self.writer = writer
    self.fileSystem = fileSystem
    storeRoot = storeRootURL ?? TestScratch.directory(label)
    store = ExportRecordStore(baseDirectoryURL: storeRoot)
    await store.configureAndWait(for: destinationId)
    collectionStore = CollectionExportRecordStore(baseDirectoryURL: storeRoot)
    await collectionStore.configureAndWait(for: destinationId)
    defaults = userDefaults ?? TestScratch.defaults(label)
    manager = ExportManager(
      photoLibraryService: self.photoLib,
      photoKitReader: photoKitReader,
      exportDestination: self.dest,
      exportRecordStore: store,
      collectionExportRecordStore: collectionStore,
      assetResourceWriter: writer,
      mediaRenderer: mediaRenderer,
      imageConverter: imageConverter,
      fileSystem: fileSystem,
      runActivity: runActivity, exportMeasurements: exportMeasurements,
      destinationIOFactory: destinationIOFactory,
      userDefaults: defaults)
  }
}
