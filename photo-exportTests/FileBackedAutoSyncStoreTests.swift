import Foundation
import Testing

@testable import Photo_Export

@MainActor
struct FileBackedAutoSyncDirtyStateStoreTests {
  private func makeRoot() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("AutoSyncDirty-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  @Test func loadReturnsEmptyWhenNoFileExists() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = FileBackedAutoSyncDirtyStateStore(baseDirectoryURL: root)

    #expect(store.load(destinationId: "dest-A") == .empty)
  }

  @Test func saveAndLoadRoundTripPreservesState() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = FileBackedAutoSyncDirtyStateStore(baseDirectoryURL: root)

    var scope = ScopeDirtyState()
    scope.recordPendingAssetId("asset-1", costCap: 10)
    scope.pendingPlacementReconciliation = true
    var state = AutoSyncDirtyState()
    state.setScope(.timeline, scope)
    state.markUpdated(at: Date(timeIntervalSince1970: 1_700_000_000))

    try store.save(state, destinationId: "dest-A")

    let loaded = store.load(destinationId: "dest-A")
    #expect(loaded == state)
  }

  @Test func saveCreatesPerDestinationDirectoryStructure() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = FileBackedAutoSyncDirtyStateStore(baseDirectoryURL: root)

    try store.save(AutoSyncDirtyState(), destinationId: "dest-A")

    let expected =
      root
      .appendingPathComponent("dest-A", isDirectory: true)
      .appendingPathComponent("dirtyState.json")
    #expect(FileManager.default.fileExists(atPath: expected.path))
  }

  @Test func deleteRemovesFile() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = FileBackedAutoSyncDirtyStateStore(baseDirectoryURL: root)

    try store.save(AutoSyncDirtyState(), destinationId: "dest-A")
    try store.deleteState(destinationId: "dest-A")

    #expect(store.load(destinationId: "dest-A") == .empty)
  }

  @Test func deleteIsNoOpWhenFileMissing() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = FileBackedAutoSyncDirtyStateStore(baseDirectoryURL: root)

    #expect(throws: Never.self) {
      try store.deleteState(destinationId: "never-saved")
    }
  }

  @Test func corruptFileDecodesAsEmpty() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = FileBackedAutoSyncDirtyStateStore(baseDirectoryURL: root)

    let dir = root.appendingPathComponent("dest-A", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try Data("not valid json".utf8).write(
      to: dir.appendingPathComponent("dirtyState.json"))

    #expect(store.load(destinationId: "dest-A") == .empty)
  }

  @Test func twoDestinationsAreIsolated() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = FileBackedAutoSyncDirtyStateStore(baseDirectoryURL: root)

    var scopeA = ScopeDirtyState()
    scopeA.recordPendingAssetId("a", costCap: 10)
    var stateA = AutoSyncDirtyState()
    stateA.setScope(.timeline, scopeA)

    var scopeB = ScopeDirtyState()
    scopeB.recordPendingAssetId("b", costCap: 10)
    var stateB = AutoSyncDirtyState()
    stateB.setScope(.favorites, scopeB)

    try store.save(stateA, destinationId: "dest-A")
    try store.save(stateB, destinationId: "dest-B")

    #expect(store.load(destinationId: "dest-A") == stateA)
    #expect(store.load(destinationId: "dest-B") == stateB)
  }
}

@MainActor
struct FileBackedAutoSyncRetryStateStoreTests {
  private func makeRoot() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("AutoSyncRetry-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  @Test func loadReturnsEmptyWhenNoFileExists() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = FileBackedAutoSyncRetryStateStore(baseDirectoryURL: root)

    #expect(store.load(destinationId: "dest-A") == .empty)
  }

  @Test func saveAndLoadRoundTripPreservesState() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = FileBackedAutoSyncRetryStateStore(baseDirectoryURL: root)

    var state = AutoSyncRetryState()
    state.recordFailure(
      scope: .album(placementId: "alpha"), assetId: "asset-1", variant: .original,
      category: .photoKitTransient, errorSignature: "sig",
      at: Date(timeIntervalSince1970: 1_700_000_000),
      nextEligibleAt: Date(timeIntervalSince1970: 1_700_000_060)
    )

    try store.save(state, destinationId: "dest-A")

    #expect(store.load(destinationId: "dest-A") == state)
  }

  @Test func deleteRemovesFile() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = FileBackedAutoSyncRetryStateStore(baseDirectoryURL: root)

    try store.save(AutoSyncRetryState(), destinationId: "dest-A")
    try store.deleteState(destinationId: "dest-A")

    #expect(store.load(destinationId: "dest-A") == .empty)
  }

  @Test func corruptFileDecodesAsEmpty() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = FileBackedAutoSyncRetryStateStore(baseDirectoryURL: root)

    let dir = root.appendingPathComponent("dest-A", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try Data("garbage".utf8).write(
      to: dir.appendingPathComponent("retryState.json"))

    #expect(store.load(destinationId: "dest-A") == .empty)
  }
}
