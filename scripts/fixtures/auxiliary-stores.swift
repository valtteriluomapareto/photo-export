import Foundation

@main
struct AuxiliaryStoreFixtures {
  @MainActor static func main() throws {
    let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    let scratch = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    let base = output.appendingPathComponent("AutoSync/destinations")
    let date = Date(timeIntervalSinceReferenceDate: 700_000_000)
    let dirty = FileBackedAutoSyncDirtyStateStore(baseDirectoryURL: base)
    var state = AutoSyncDirtyState()
    state.setScope(.timeline, ScopeDirtyState(pendingAssetIds: ["asset-a", "asset-b"]))
    state.setScope(.favorites, ScopeDirtyState(pendingFullReconciliation: true))
    state.setScope(.albums, ScopeDirtyState(pendingPlacementReconciliation: true))
    state.markUpdated(at: date)
    try dirty.save(state, destinationId: "A")
    var other = AutoSyncDirtyState()
    other.setScope(.timeline, ScopeDirtyState(pendingAssetIds: ["asset-other"]))
    other.markUpdated(at: date.addingTimeInterval(100))
    try dirty.save(other, destinationId: "B")

    let retry = FileBackedAutoSyncRetryStateStore(baseDirectoryURL: base)
    let transient = RetryEntry(
      category: .photoKitTransient, errorSignature: "NSPOSIXErrorDomain:5", attemptCount: 3,
      firstFailedAt: date, lastFailedAt: date.addingTimeInterval(60),
      nextEligibleAt: date.addingTimeInterval(660))
    let hard = RetryEntry(
      category: .destinationPermission, errorSignature: "NSCocoaErrorDomain:513", attemptCount: 2,
      firstFailedAt: date, lastFailedAt: date.addingTimeInterval(30), nextEligibleAt: nil)
    var retries = AutoSyncRetryState()
    retries.entriesByPlacement["timeline"] = ["asset-a": ["original": transient]]
    retries.entriesByPlacement["favorites"] = ["asset-a": ["edited": hard]]
    retries.entriesByPlacement["album:album-a"] = ["asset-b": ["edited": transient]]
    #if RELEASE_MODERN
    retries.entriesByPlacement["shared-album:shared-a"] = ["asset-c": ["originalPairedVideo": hard]]
    #endif
    try retry.save(retries, destinationId: "A")
    var otherRetries = AutoSyncRetryState()
    otherRetries.entriesByPlacement["timeline"] = ["asset-other": ["original": hard]]
    try retry.save(otherRetries, destinationId: "B")

    let summaries = FileBackedAutoSyncRunSummaryStore(baseDirectoryURL: base)
    let context = ExportRunContext(
      runId: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
      source: .autoSync, visibility: .background, reason: .photosChanged,
      scope: .timelineAssets(["asset-a", "asset-b"]), selection: .editedWithOriginals,
      startedAt: date)
    let failure = ExportRunFailureDetail(
      assetId: "asset-a", placement: .favorites(createdAt: date), variant: .edited,
      category: .photoKitTransient, errorSignature: "NSPOSIXErrorDomain:5",
      localizedDescription: "Synthetic read failure", failedAt: date.addingTimeInterval(60))
    try summaries.save(
      ExportRunSummary(
        context: context, endedAt: date.addingTimeInterval(90), enqueuedCount: 8,
        completedCount: 4, failedCount: 1, skippedCount: 3, cancelReason: nil,
        result: .failed, failures: [failure]), destinationId: "A")
    try summaries.save(
      ExportRunSummary(
        context: ExportRunContext(
          runId: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
          source: .manual, visibility: .userVisible, reason: nil, scope: .favoritesFull,
          selection: .edited, startedAt: date.addingTimeInterval(100)),
        endedAt: date.addingTimeInterval(120), enqueuedCount: 2, completedCount: 1,
        failedCount: 0, skippedCount: 0, cancelReason: .userCancelled, result: .cancelled),
      destinationId: "B")

    let tokens = FileBackedAutoSyncPerDestinationTokenStore(baseDirectoryURL: base)
    try tokens.save(Data([0, 1, 127, 128, 254, 255]), destinationId: "A")
    try tokens.save(Data("synthetic-token-B".utf8), destinationId: "B")
    let safety = FileBackedDestinationSafetyConfirmationStore(baseDirectoryURL: base)
    try safety.confirm(destinationId: "A")
    precondition(safety.isConfirmed(destinationId: "A"))
    precondition(!safety.isConfirmed(destinationId: "B"))

    let suite = scratch.appendingPathComponent("preferences").path
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let scopes = UserDefaultsAutoExportScopeStore(userDefaults: defaults)
    #if RELEASE_MODERN
    scopes.setSelection(AutoExportScopeSelection(timeline: true, favorites: false, albums: true, sharedAlbums: true))
    let folder = scratch.appendingPathComponent("destination", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let fingerprint = DestinationFingerprint(
      schemaVersion: 1, volumeUUIDString: nil, volumeRootPath: nil,
      relativePathFromVolumeRoot: "synthetic/backup", standardizedPath: "/synthetic/backup",
      identityConfidence: .low)
    let manager = ExportDestinationManager(
      skipRestore: true, userDefaults: defaults, fingerprintProvider: { _ in fingerprint })
    manager.persistSelectedFolderForTesting(folder)
    precondition(manager.isAvailable)
    precondition(defaults.string(forKey: "ExportDestinationStableId") == fingerprint.id)
    precondition(manager.destinationId == fingerprint.id)
    try writeCurrentRunFixtures(to: output)
    #else
    scopes.setSelection(AutoExportScopeSelection(timeline: true, favorites: false, albums: true))
    #endif
    defaults.synchronize()
    let keys = ["AutoSync.scopeSelection", "ExportDestinationStableId"]
    let written = defaults.persistentDomain(forName: suite)!
    let transported = written.filter { keys.contains($0.key) }
    precondition(transported["AutoSync.scopeSelection"] is Data)
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    let envelope = try PropertyListSerialization.data(
      fromPropertyList: transported, format: .binary, options: 0)
    try envelope.write(to: output.appendingPathComponent("preferences.plist"))
  }
}
