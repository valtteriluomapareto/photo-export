import Foundation
import Testing

@testable import Photo_Export

@MainActor
struct AutoSyncDirtyStateTests {

  // MARK: - ScopeDirtyState

  @Test func scopeIsEmptyByDefault() {
    let scope = ScopeDirtyState()

    #expect(scope.isEmpty)
    #expect(scope.pendingAssetIds.isEmpty)
    #expect(scope.pendingFullReconciliation == false)
    #expect(scope.pendingPlacementReconciliation == false)
  }

  @Test func recordPendingAssetIdAddsToTargetedSetBelowCap() {
    var scope = ScopeDirtyState()

    let rolledOver = scope.recordPendingAssetId("asset-1", costCap: 5)

    #expect(rolledOver == false)
    #expect(scope.pendingAssetIds == ["asset-1"])
    #expect(scope.pendingFullReconciliation == false)
  }

  @Test func recordPendingAssetIdAtCapRollsOverToFullReconciliation() {
    var scope = ScopeDirtyState(pendingAssetIds: ["a", "b", "c"])

    let rolledOver = scope.recordPendingAssetId("d", costCap: 3)

    #expect(rolledOver)
    #expect(scope.pendingAssetIds.isEmpty)
    #expect(scope.pendingFullReconciliation)
  }

  @Test func recordPendingAssetIdIsIdempotentForExistingId() {
    var scope = ScopeDirtyState(pendingAssetIds: ["a", "b"])

    let rolledOver = scope.recordPendingAssetId("a", costCap: 2)

    #expect(rolledOver == false)
    #expect(scope.pendingAssetIds == ["a", "b"])
  }

  @Test func recordPendingAssetIdNoOpsWhenFullReconciliationAlreadyPending() {
    var scope = ScopeDirtyState(pendingFullReconciliation: true)

    let rolledOver = scope.recordPendingAssetId("a", costCap: 100)

    #expect(rolledOver)
    #expect(scope.pendingFullReconciliation)
    #expect(scope.pendingAssetIds.isEmpty)
  }

  @Test func clearAfterSuccessfulFullReconciliationResetsAllFlags() {
    var scope = ScopeDirtyState(
      pendingAssetIds: ["a", "b"],
      pendingFullReconciliation: true,
      pendingPlacementReconciliation: true
    )

    scope.clearAfterSuccessfulFullReconciliation()

    #expect(scope.isEmpty)
  }

  @Test func removeCompletedAssetIdsSubtractsTheSet() {
    var scope = ScopeDirtyState(pendingAssetIds: ["a", "b", "c", "d"])

    scope.removeCompletedAssetIds(["a", "c", "z"])

    #expect(scope.pendingAssetIds == ["b", "d"])
  }

  // MARK: - AutoSyncDirtyState

  @Test func emptyDirtyStateHasNoScopes() {
    let state = AutoSyncDirtyState.empty

    #expect(state.scopes.isEmpty)
    #expect(state.isEmpty)
  }

  @Test func scopeReturnsEmptyForUnknownKey() {
    let state = AutoSyncDirtyState()

    #expect(state.scope(.timeline).isEmpty)
    #expect(state.scope(.favorites).isEmpty)
    #expect(state.scope(.albums).isEmpty)
  }

  @Test func setScopeStoresValue() {
    var state = AutoSyncDirtyState()
    var scope = ScopeDirtyState()
    scope.recordPendingAssetId("asset-1", costCap: 10)

    state.setScope(.timeline, scope)

    #expect(state.scope(.timeline).pendingAssetIds == ["asset-1"])
    #expect(state.isEmpty == false)
  }

  @Test func setScopeRemovesEmptyValueToKeepShapeSparse() {
    var state = AutoSyncDirtyState(scopes: [
      AutoExportLibraryScope.timeline.rawValue: ScopeDirtyState(pendingAssetIds: ["a"])
    ])

    state.setScope(.timeline, .empty)

    #expect(state.scopes.isEmpty)
    #expect(state.isEmpty)
  }

  @Test func dirtyStateRoundTripsThroughCodable() throws {
    var scope = ScopeDirtyState()
    scope.recordPendingAssetId("asset-1", costCap: 10)
    scope.pendingPlacementReconciliation = true
    let original = AutoSyncDirtyState(
      scopes: [
        AutoExportLibraryScope.timeline.rawValue: scope,
        AutoExportLibraryScope.favorites.rawValue: ScopeDirtyState(
          pendingFullReconciliation: true),
      ],
      lastUpdatedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )

    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(AutoSyncDirtyState.self, from: data)

    #expect(decoded == original)
  }

  // MARK: - InMemoryAutoSyncDirtyStateStore

  @Test func storeReturnsEmptyForUnknownDestination() {
    let store = InMemoryAutoSyncDirtyStateStore()

    #expect(store.load(destinationId: "dest-A") == .empty)
  }

  @Test func storeRoundTripsSaveAndLoad() throws {
    let store = InMemoryAutoSyncDirtyStateStore()
    var scope = ScopeDirtyState()
    scope.recordPendingAssetId("asset-1", costCap: 10)
    let state = AutoSyncDirtyState(
      scopes: [AutoExportLibraryScope.timeline.rawValue: scope],
      lastUpdatedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )

    try store.save(state, destinationId: "dest-A")

    #expect(store.load(destinationId: "dest-A") == state)
    #expect(store.savedDestinationIds == ["dest-A"])
  }

  @Test func storeDeleteRemovesEntry() throws {
    let store = InMemoryAutoSyncDirtyStateStore()
    try store.save(.empty, destinationId: "dest-A")
    try store.save(.empty, destinationId: "dest-B")

    try store.deleteState(destinationId: "dest-A")

    #expect(store.savedDestinationIds == ["dest-B"])
    #expect(store.load(destinationId: "dest-A") == .empty)
  }
}
