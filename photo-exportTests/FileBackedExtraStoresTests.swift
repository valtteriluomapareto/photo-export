import Foundation
import Photos
import Testing

@testable import Photo_Export

/// Coverage for the file-backed stores that landed alongside Phase 2/0b
/// but didn't get a round-trip test suite at the time:
/// `FileBackedAutoSyncRunSummaryStore`,
/// `FileBackedAutoSyncPerDestinationTokenStore`,
/// `FileBackedDestinationSafetyConfirmationStore`, and
/// `GlobalPhotoChangeTokenStore`. Mirrors the matrix the dirty / retry
/// stores already have: empty-load, round-trip, delete, two-destinations-
/// isolated, plus a corrupt-decode case where applicable.

@MainActor
struct FileBackedAutoSyncRunSummaryStoreTests {
  private func makeRoot() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("RunSummary-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func makeSummary(scope: ExportRunScope = .timelineFullLibrary) -> ExportRunSummary {
    ExportRunSummary(
      context: ExportRunContext(
        source: .autoSync, visibility: .background, reason: .appLaunch,
        scope: scope, selection: .edited),
      endedAt: Date(timeIntervalSince1970: 1_700_000_000),
      enqueuedCount: 5, completedCount: 4,
      failedCount: 1, skippedCount: 0,
      cancelReason: nil, result: .failed
    )
  }

  @Test func loadReturnsNilWhenNoFileExists() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = FileBackedAutoSyncRunSummaryStore(baseDirectoryURL: root)

    #expect(store.load(destinationId: "dest-A") == nil)
  }

  @Test func saveAndLoadRoundTripPreservesSummary() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = FileBackedAutoSyncRunSummaryStore(baseDirectoryURL: root)
    let summary = makeSummary()

    try store.save(summary, destinationId: "dest-A")
    #expect(store.load(destinationId: "dest-A") == summary)
  }

  @Test func deleteRemovesTheStoredSummary() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = FileBackedAutoSyncRunSummaryStore(baseDirectoryURL: root)
    try store.save(makeSummary(), destinationId: "dest-A")

    try store.deleteSummary(destinationId: "dest-A")

    #expect(store.load(destinationId: "dest-A") == nil)
  }

  @Test func deleteIsNoOpWhenFileMissing() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = FileBackedAutoSyncRunSummaryStore(baseDirectoryURL: root)

    try store.deleteSummary(destinationId: "never-saved")  // does not throw
  }

  @Test func corruptFileLoadsAsNil() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = FileBackedAutoSyncRunSummaryStore(baseDirectoryURL: root)
    // Write a malformed JSON file directly to the expected path.
    let dest = root.appendingPathComponent("dest-A", isDirectory: true)
    try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
    try Data("{not valid json".utf8).write(
      to: dest.appendingPathComponent("lastRunSummary.json"))

    #expect(store.load(destinationId: "dest-A") == nil)
  }

  @Test func twoDestinationsAreIsolated() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = FileBackedAutoSyncRunSummaryStore(baseDirectoryURL: root)
    let a = makeSummary(scope: .timelineFullLibrary)
    let b = makeSummary(scope: .favoritesFull)

    try store.save(a, destinationId: "dest-A")
    try store.save(b, destinationId: "dest-B")

    #expect(store.load(destinationId: "dest-A")?.context.scope == .timelineFullLibrary)
    #expect(store.load(destinationId: "dest-B")?.context.scope == .favoritesFull)
  }
}

@MainActor
struct FileBackedAutoSyncPerDestinationTokenStoreTests {
  private func makeRoot() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("PerDestToken-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  @Test func loadReturnsNilWhenNoFileExists() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = FileBackedAutoSyncPerDestinationTokenStore(baseDirectoryURL: root)

    #expect(store.load(destinationId: "dest-A") == nil)
  }

  @Test func saveAndLoadRoundTripPreservesData() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = FileBackedAutoSyncPerDestinationTokenStore(baseDirectoryURL: root)
    let token = Data([0xDE, 0xAD, 0xBE, 0xEF, 0x42])

    try store.save(token, destinationId: "dest-A")
    #expect(store.load(destinationId: "dest-A") == token)
  }

  @Test func deleteRemovesTheStoredToken() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = FileBackedAutoSyncPerDestinationTokenStore(baseDirectoryURL: root)
    try store.save(Data([0x01]), destinationId: "dest-A")

    try store.deleteToken(destinationId: "dest-A")

    #expect(store.load(destinationId: "dest-A") == nil)
  }

  @Test func twoDestinationsAreIsolated() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = FileBackedAutoSyncPerDestinationTokenStore(baseDirectoryURL: root)

    try store.save(Data([0xAA]), destinationId: "dest-A")
    try store.save(Data([0xBB]), destinationId: "dest-B")

    #expect(store.load(destinationId: "dest-A") == Data([0xAA]))
    #expect(store.load(destinationId: "dest-B") == Data([0xBB]))
  }

  @Test func saveCreatesIntermediateDirectories() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    // Use a non-existent destinationsRoot child to verify creation.
    let store = FileBackedAutoSyncPerDestinationTokenStore(
      baseDirectoryURL: root.appendingPathComponent("nested/deep/path"))

    try store.save(Data([0xFF]), destinationId: "dest-X")
    #expect(store.load(destinationId: "dest-X") == Data([0xFF]))
  }
}

@MainActor
struct FileBackedDestinationSafetyConfirmationStoreTests {
  private func makeRoot() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("SafetyConfirm-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  @Test func unconfirmedByDefault() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = FileBackedDestinationSafetyConfirmationStore(baseDirectoryURL: root)

    #expect(store.isConfirmed(destinationId: "dest-A") == false)
  }

  @Test func confirmThenIsConfirmedReturnsTrue() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = FileBackedDestinationSafetyConfirmationStore(baseDirectoryURL: root)

    try store.confirm(destinationId: "dest-A")
    #expect(store.isConfirmed(destinationId: "dest-A"))
  }

  @Test func unconfirmRemovesTheMarker() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = FileBackedDestinationSafetyConfirmationStore(baseDirectoryURL: root)
    try store.confirm(destinationId: "dest-A")

    try store.unconfirm(destinationId: "dest-A")

    #expect(store.isConfirmed(destinationId: "dest-A") == false)
  }

  @Test func unconfirmIsNoOpWhenNotConfirmed() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = FileBackedDestinationSafetyConfirmationStore(baseDirectoryURL: root)

    try store.unconfirm(destinationId: "never-confirmed")  // does not throw
  }

  @Test func twoDestinationsAreIsolated() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = FileBackedDestinationSafetyConfirmationStore(baseDirectoryURL: root)

    try store.confirm(destinationId: "dest-A")

    #expect(store.isConfirmed(destinationId: "dest-A"))
    #expect(store.isConfirmed(destinationId: "dest-B") == false)
  }

  @Test func confirmationSurvivesNewStoreInstance() throws {
    // Persistence check: a fresh store instance pointed at the same root
    // sees the prior confirmation. Guards the launch-flow contract that
    // "confirmed destinations stay confirmed across launches."
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store1 = FileBackedDestinationSafetyConfirmationStore(baseDirectoryURL: root)
    try store1.confirm(destinationId: "dest-A")

    let store2 = FileBackedDestinationSafetyConfirmationStore(baseDirectoryURL: root)

    #expect(store2.isConfirmed(destinationId: "dest-A"))
  }
}

@MainActor
struct GlobalPhotoChangeTokenStoreTests {
  private func makeFile() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("GlobalToken-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent("photo-library-change-token.data")
  }

  @Test func loadReturnsNilWhenNoFileExists() throws {
    let url = try makeFile()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let store = GlobalPhotoChangeTokenStore(fileURL: url)

    #expect(store.load() == nil)
  }

  @Test func corruptFileLoadsAsNil() throws {
    let url = try makeFile()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    try Data("not a valid archive".utf8).write(to: url)
    let store = GlobalPhotoChangeTokenStore(fileURL: url)

    #expect(store.load() == nil)
  }

  @Test func loadHandlesMissingParentDirectoryGracefully() throws {
    // load() should return nil without crashing when the parent path
    // doesn't exist — normal first-launch state. The bug-magnet cleanup
    // walks below have been removed: rooting everything under a single
    // UUID-prefixed temp dir keeps cleanup honest.
    let topLevelDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("GlobalToken-nested-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: topLevelDir) }
    let store = GlobalPhotoChangeTokenStore(
      fileURL:
        topLevelDir
        .appendingPathComponent("very", isDirectory: true)
        .appendingPathComponent("deep", isDirectory: true)
        .appendingPathComponent("token.data")
    )

    #expect(store.load() == nil)
  }
}
