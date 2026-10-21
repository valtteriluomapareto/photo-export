import os

extension Logger {
  static let appSubsystem = "com.valtteriluoma.photo-export"

  /// Stable category names keep saved Console and Instruments filters useful.
  enum AppCategory: String, Sendable {
    case autoSync = "AutoSync"
    case autoSyncCurrentRunStore = "AutoSyncCurrentRunStore"
    case autoSyncDirtyStore = "AutoSyncDirtyStore"
    case autoSyncPerDestTokenStore = "AutoSyncPerDestTokenStore"
    case autoSyncRetryStore = "AutoSyncRetryStore"
    case autoSyncRunSummaryStore = "AutoSyncRunSummaryStore"
    case autoSyncScopes = "AutoSyncScopes"
    case backupScanner = "BackupScanner"
    case collectionExportRecords = "CollectionExportRecords"
    case destinationFingerprint = "DestinationFingerprint"
    case destinationSafety = "DestinationSafety"
    case exportOperations = "Export"
    case exportDestination = "ExportDestination"
    case exportQueueCoordinator = "ExportQueueCoordinator"
    case exportRecords = "ExportRecords"
    case exportRecordsDirectory = "ExportRecordsDirectory"
    case failureClassification = "FailureClassification"
    case fileIO = "FileIO"
    case finalNamePlanner = "FinalNamePlanner"
    case imageConverter = "ImageConverter"
    case importCoordinator = "ImportCoordinator"
    case lifecycle = "Lifecycle"
    case loginItem = "LoginItem"
    case mediaRenderer = "MediaRenderer"
    case photoChangeToken = "PhotoChangeToken"
    case photoLibraryChanges = "PhotoLibraryChanges"
    case photos = "Photos"
    case placementResolver = "PlacementResolver"
    case resourceWriter = "ResourceWriter"
    case screenshot = "Screenshot"
    case detailPreview = "UI.Detail"
    case variantExporter = "VariantExporter"
  }

  static func app(_ category: AppCategory) -> Logger {
    Logger(subsystem: appSubsystem, category: category.rawValue)
  }
}
