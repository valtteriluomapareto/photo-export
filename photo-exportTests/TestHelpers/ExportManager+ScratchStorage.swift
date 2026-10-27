import Foundation

@testable import Photo_Export

@MainActor
extension ExportManager {
  /// Supplies isolated HEIC storage for existing shared-dependency fixtures.
  convenience init(
    photoLibraryService: any PhotoLibraryService,
    exportDestination: any ExportDestination,
    exportRecordStore: ExportRecordStore,
    collectionExportRecordStore: CollectionExportRecordStore,
    assetResourceWriter: any AssetResourceWriter,
    fileSystem: any FileSystemService,
    userDefaults: UserDefaults
  ) {
    self.init(
      photoLibraryService: photoLibraryService,
      exportDestination: exportDestination,
      exportRecordStore: exportRecordStore,
      collectionExportRecordStore: collectionExportRecordStore,
      assetResourceWriter: assetResourceWriter,
      localHEICStorage: LocalHEICStorage(root: TestScratch.directory("FixtureHEIC")),
      fileSystem: fileSystem,
      userDefaults: userDefaults)
  }
}
