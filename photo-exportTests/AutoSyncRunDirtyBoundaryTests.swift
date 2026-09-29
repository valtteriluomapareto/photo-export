import Foundation
import Testing

@testable import Photo_Export

struct AutoSyncRunDirtyBoundaryTests {
  private let now = Date(timeIntervalSince1970: 1_700_000_000)

  private func initialState() -> AutoSyncReducer.State {
    var state = AutoSyncReducer.State.initial
    state.enabled = true
    state.destination = DestinationSnapshot(
      fingerprint: .makeHigh(
        volumeUUIDString: "boundary", volumeRootPath: nil,
        relativePathFromVolumeRoot: "/backup", standardizedPath: "/Volumes/backup"),
      isAvailable: true, safety: .safe)
    state.scopeSelection = AutoExportScopeSelection(
      timeline: true, favorites: true, albums: true, sharedAlbums: true)
    state.current = .idle
    return state
  }

  private func change(_ state: AutoSyncReducer.State, collectionOnly: Bool = false)
    -> AutoSyncReducer.State
  {
    AutoSyncReducer.reduce(
      .photosChanged(
        PhotoLibraryPersistentChangeEvent(
          updatedLocalIdentifiers: collectionOnly ? [] : ["same-asset"],
          collectionChangesPresent: collectionOnly, observedAt: now)),
      in: state, now: now
    ).0
  }

  private func start(_ context: ExportRunContext, in state: AutoSyncReducer.State)
    -> AutoSyncReducer.State
  {
    var state = state
    if context.source == .autoSync { state.current = .running(reason: .photosChanged) }
    return AutoSyncReducer.reduce(
      .exportRunStateChanged(
        ExportRunState(
          activeContext: context, isManualActive: context.source == .manual,
          isAutoSyncActive: context.source == .autoSync)), in: state, now: now
    ).0
  }

  private func finish(
    _ context: ExportRunContext, in state: AutoSyncReducer.State,
    result: ExportRunResult = .completed
  ) -> AutoSyncReducer.State {
    let idle = AutoSyncReducer.reduce(.exportRunStateChanged(.idle), in: state, now: now).0
    let summary = ExportRunSummary(
      context: context, endedAt: now, enqueuedCount: 0, completedCount: 0,
      failedCount: 0, skippedCount: 0, cancelReason: nil, result: result)
    return AutoSyncReducer.reduce(
      context.source == .manual
        ? .manualFullExportCompleted(summary) : .autoSyncRunCompleted(summary),
      in: idle, now: now
    ).0
  }

  @Test(arguments: [ExportRunSource.autoSync, .manual])
  func repeatedAssetChangeSurvivesCompletionAndNextRunClearsIt(source: ExportRunSource) {
    var state = change(initialState())
    let context = ExportRunContext(
      source: source, visibility: .userVisible, scope: .timelineFullLibrary, selection: .edited)
    state = start(context, in: state)
    state = change(state)  // Same ID and timestamp: set equality cannot detect this work.
    state = start(context, in: state)  // Repeated publication must not move the boundary.
    state = finish(context, in: state)
    let destinationId = state.destination.id!
    #expect(
      state.dirtyStateByDestination[destinationId]?.scope(.timeline).pendingAssetIds == [
        "same-asset"
      ])
    #expect(state.current == .scheduled(reason: .photosChanged, fireAt: now.addingTimeInterval(30)))

    let followUp = ExportRunContext(
      source: .autoSync, visibility: .background,
      scope: .autoExport(state.scopeSelection), selection: .edited)
    state = finish(followUp, in: start(followUp, in: state))
    #expect(state.dirtyStateByDestination[destinationId]?.isEmpty == true)
    #expect(state.current == .idle, "A quiet successful follow-up must not loop")
  }

  @Test func collectionOnlyChangeInvalidatesOnlyAlbumScopes() {
    var state = change(initialState())
    let context = ExportRunContext(
      source: .autoSync, visibility: .background,
      scope: .autoExport(state.scopeSelection), selection: .edited)
    state = start(context, in: state)
    state = change(state, collectionOnly: true)
    state = finish(context, in: state)
    let dirty = state.dirtyStateByDestination[state.destination.id!]!
    #expect(dirty.scope(.timeline).isEmpty)
    #expect(dirty.scope(.favorites).isEmpty)
    #expect(dirty.scope(.albums).pendingPlacementReconciliation)
    #expect(dirty.scope(.sharedAlbums).pendingPlacementReconciliation)
  }

  @Test func repeatedFallbackDuringRunPreservesFullReconciliation() {
    var state = initialState()
    state = AutoSyncReducer.reduce(.photosChangeFetchFailed(.tokenExpired), in: state, now: now).0
    let context = ExportRunContext(
      source: .autoSync, visibility: .background,
      scope: .autoExport(state.scopeSelection), selection: .edited)
    state = start(context, in: state)
    state = AutoSyncReducer.reduce(.photosChangeFetchFailed(.tokenExpired), in: state, now: now).0
    state = finish(context, in: state)
    for scope in state.scopeSelection.enabledScopes {
      #expect(
        state.dirtyStateByDestination[state.destination.id!]?.scope(scope).pendingFullReconciliation
          == true)
    }
  }

  @Test(arguments: [ExportRunResult.failed, .cancelled, .interrupted])
  func unsuccessfulRunNeverAcknowledgesDirtyWork(result: ExportRunResult) {
    var state = change(initialState())
    let context = ExportRunContext(
      source: .autoSync, visibility: .background,
      scope: .autoExport(state.scopeSelection), selection: .edited)
    state = finish(context, in: start(context, in: state), result: result)
    #expect(state.dirtyStateByDestination[state.destination.id!]?.isEmpty == false)
  }

  @Test func completionWithoutObservedStartCannotClearDirty() {
    let state = change(initialState())
    let context = ExportRunContext(
      source: .autoSync, visibility: .background,
      scope: .autoExport(state.scopeSelection), selection: .edited)
    let next = finish(context, in: state)
    #expect(next.dirtyStateByDestination == state.dirtyStateByDestination)
  }

  @Test func destinationChangeCannotAcknowledgeOtherDestinationsWork() {
    var state = change(initialState())
    let context = ExportRunContext(
      source: .autoSync, visibility: .background,
      scope: .autoExport(state.scopeSelection), selection: .edited)
    state = start(context, in: state)
    let other = DestinationSnapshot(
      fingerprint: .makeHigh(
        volumeUUIDString: "other", volumeRootPath: nil,
        relativePathFromVolumeRoot: "/other", standardizedPath: "/Volumes/other"),
      isAvailable: true, safety: .safe)
    state = AutoSyncReducer.reduce(.destinationChanged(other), in: state, now: now).0
    state = change(state)
    let before = state.dirtyStateByDestination
    state = finish(context, in: state)
    #expect(state.dirtyStateByDestination == before)
  }
  @Test func assetChangeWhileFullReconciliationIsAlreadyPendingStillInvalidatesRun() {
    var state = initialState()
    state = AutoSyncReducer.reduce(.photosChangeFetchFailed(.tokenExpired), in: state, now: now).0
    let context = ExportRunContext(
      source: .autoSync, visibility: .background,
      scope: .autoExport(state.scopeSelection), selection: .edited)
    state = change(start(context, in: state))
    state = finish(context, in: state)
    #expect(
      state.dirtyStateByDestination[state.destination.id!]?.scope(.timeline)
        .pendingFullReconciliation == true)
  }

  @Test func lateSummaryDoesNotConsumeReplacementRunBoundary() {
    var state = change(initialState())
    let old = ExportRunContext(
      source: .autoSync, visibility: .background,
      scope: .autoExport(state.scopeSelection), selection: .edited)
    let replacement = ExportRunContext(
      source: .autoSync, visibility: .background,
      scope: .autoExport(state.scopeSelection), selection: .edited)
    state = start(replacement, in: start(old, in: state))
    let dirty = state.dirtyStateByDestination
    state = finish(old, in: state)
    #expect(state.dirtyStateByDestination == dirty)
    state = finish(replacement, in: state)
    #expect(state.dirtyStateByDestination[state.destination.id!]?.isEmpty == true)
  }

  @Test func loadingPersistedDirtyStateDuringRunRequiresAnotherScan() {
    var state = change(initialState())
    let context = ExportRunContext(
      source: .autoSync, visibility: .background,
      scope: .autoExport(state.scopeSelection), selection: .edited)
    state = start(context, in: state)
    let destinationId = state.destination.id!
    let dirty = state.dirtyStateByDestination[destinationId]!
    state =
      AutoSyncReducer.reduce(
        .destinationDirtyStateLoaded(destinationId: destinationId, dirtyState: dirty),
        in: state, now: now
      ).0
    state = finish(context, in: state)
    #expect(state.dirtyStateByDestination[destinationId] == dirty)
  }

}
