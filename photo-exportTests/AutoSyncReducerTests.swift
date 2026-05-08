import Foundation
import Testing

@testable import Photo_Export

/// Phase 2 (auto-sync plan): pure reducer for the AutoSync state machine. Tests are
/// single-event-in / state+effects-out — call `AutoSyncReducer.reduce`, assert the
/// returned `State` and effect list. No timers, no actor isolation, no I/O.
///
/// First slice: input-gating events (enabled, destination, scope, version, import).
/// Subsequent slices add `photosChanged` / `debounceFired` / run-lifecycle / retry
/// scheduling.
struct AutoSyncReducerTests {

  // MARK: - Helpers

  private let now = Date(timeIntervalSince1970: 1_700_000_000)

  private func safeDestination(_ tag: String = "dest-A") -> DestinationSnapshot {
    DestinationSnapshot(
      fingerprint: .makeHigh(
        volumeUUIDString: "uuid-\(tag)",
        volumeRootPath: nil,
        relativePathFromVolumeRoot: "/\(tag)",
        standardizedPath: "/Volumes/\(tag)"
      ),
      isAvailable: true,
      safety: .safe
    )
  }

  private func enabledStateWithSafeDestinationAndScope() -> AutoSyncReducer.State {
    var state = AutoSyncReducer.State.initial
    state.enabled = true
    state.destination = safeDestination()
    state.scopeSelection = AutoExportScopeSelection(timeline: true)
    return state
  }

  // MARK: - Initial state

  @Test func initialStateIsDisabled() {
    #expect(AutoSyncReducer.State.initial.current == .disabled)
  }

  // MARK: - enabledChanged

  @Test func enableWithNoDestinationBlocksOnDestinationMissing() {
    var state = AutoSyncReducer.State.initial
    state.scopeSelection = AutoExportScopeSelection(timeline: true)

    let (next, effects) = AutoSyncReducer.reduce(.enabledChanged(true), in: state, now: now)

    #expect(next.current == .blocked(.destinationMissing))
    #expect(effects.isEmpty)
  }

  @Test func enableWithNoScopesBlocksOnNoScopesSelected() {
    var state = AutoSyncReducer.State.initial
    state.destination = safeDestination()

    let (next, _) = AutoSyncReducer.reduce(.enabledChanged(true), in: state, now: now)

    #expect(next.current == .blocked(.noScopesSelected))
  }

  @Test func enableWithSafeDestinationAndScopeSchedulesAppLaunch() {
    var state = AutoSyncReducer.State.initial
    state.destination = safeDestination()
    state.scopeSelection = AutoExportScopeSelection(timeline: true, favorites: true)

    let (next, effects) = AutoSyncReducer.reduce(.enabledChanged(true), in: state, now: now)

    let fireAt = now.addingTimeInterval(10)
    #expect(next.current == .scheduled(reason: .appLaunch, fireAt: fireAt))
    #expect(effects == [.scheduleDebounce(.appLaunch, fireAt: fireAt)])
  }

  @Test func disableFromAnyStateReturnsToDisabled() {
    let state = enabledStateWithSafeDestinationAndScope()

    let (next, _) = AutoSyncReducer.reduce(.enabledChanged(false), in: state, now: now)

    #expect(next.enabled == false)
    #expect(next.current == .disabled)
  }

  // MARK: - destinationChanged

  @Test func destinationUnmountWhileEnabledTransitionsToWaiting() {
    var state = enabledStateWithSafeDestinationAndScope()
    state.current = .idle

    let unmounted = DestinationSnapshot(
      fingerprint: state.destination.fingerprint,
      isAvailable: false,
      safety: .safe
    )
    let (next, _) = AutoSyncReducer.reduce(.destinationChanged(unmounted), in: state, now: now)

    #expect(next.current == .waiting(.destinationUnavailable))
  }

  @Test func destinationClearedTransitionsToBlockedDestinationMissing() {
    var state = enabledStateWithSafeDestinationAndScope()
    state.current = .idle

    let (next, _) = AutoSyncReducer.reduce(
      .destinationChanged(.none), in: state, now: now)

    #expect(next.current == .blocked(.destinationMissing))
  }

  @Test func unsafeDestinationTransitionsToBlockedUnsafe() {
    var state = enabledStateWithSafeDestinationAndScope()

    let unsafe = DestinationSnapshot(
      fingerprint: state.destination.fingerprint,
      isAvailable: true,
      safety: .unsafeNeedsConfirmation
    )
    let (next, _) = AutoSyncReducer.reduce(.destinationChanged(unsafe), in: state, now: now)

    #expect(next.current == .blocked(.destinationUnsafe))
  }

  @Test func migrationConflictAlsoBlocksUnsafe() {
    var state = enabledStateWithSafeDestinationAndScope()

    let conflicted = DestinationSnapshot(
      fingerprint: state.destination.fingerprint,
      isAvailable: true,
      safety: .unsafeMigrationConflict
    )
    let (next, _) = AutoSyncReducer.reduce(
      .destinationChanged(conflicted), in: state, now: now)

    #expect(next.current == .blocked(.destinationUnsafe))
  }

  // MARK: - scopeSelectionChanged

  @Test func clearingAllScopesBlocksOnNoScopesSelected() {
    var state = enabledStateWithSafeDestinationAndScope()
    state.current = .idle

    let (next, _) = AutoSyncReducer.reduce(
      .scopeSelectionChanged(AutoExportScopeSelection()), in: state, now: now)

    #expect(next.current == .blocked(.noScopesSelected))
  }

  @Test func enablingNewScopeSchedulesScopeChange() {
    var state = AutoSyncReducer.State.initial
    state.enabled = true
    state.destination = safeDestination()
    state.scopeSelection = AutoExportScopeSelection()
    state.current = .blocked(.noScopesSelected)

    let (next, effects) = AutoSyncReducer.reduce(
      .scopeSelectionChanged(AutoExportScopeSelection(albums: true)),
      in: state, now: now)

    let fireAt = now.addingTimeInterval(2)
    #expect(next.current == .scheduled(reason: .scopeSelectionChanged, fireAt: fireAt))
    #expect(effects == [.scheduleDebounce(.scopeSelectionChanged, fireAt: fireAt)])
    #expect(next.scopeSelection.includes(.albums))
  }

  // MARK: - importStateChanged

  @Test func importActiveTransitionsToWaiting() {
    let state = enabledStateWithSafeDestinationAndScope()

    let (next, _) = AutoSyncReducer.reduce(
      .importStateChanged(isImporting: true), in: state, now: now)

    #expect(next.current == .waiting(.importActive))
    #expect(next.importActive)
  }

  @Test func importDoneReturnsToIdle() {
    var state = enabledStateWithSafeDestinationAndScope()
    state.importActive = true
    state.current = .waiting(.importActive)

    let (next, _) = AutoSyncReducer.reduce(
      .importStateChanged(isImporting: false), in: state, now: now)

    #expect(next.current == .idle)
    #expect(next.importActive == false)
  }

  // MARK: - versionSelectionChanged

  @Test func versionSelectionChangeSchedulesDebounce() {
    let state = enabledStateWithSafeDestinationAndScope()

    let (next, effects) = AutoSyncReducer.reduce(
      .versionSelectionChanged(.editedWithOriginals), in: state, now: now)

    let fireAt = now.addingTimeInterval(2)
    #expect(next.versionSelection == .editedWithOriginals)
    #expect(next.current == .scheduled(reason: .versionSelectionChanged, fireAt: fireAt))
    #expect(effects == [.scheduleDebounce(.versionSelectionChanged, fireAt: fireAt)])
  }

  @Test func versionSelectionUnchangedIsNoOp() {
    var state = enabledStateWithSafeDestinationAndScope()
    state.versionSelection = .editedWithOriginals
    state.current = .idle

    let (next, effects) = AutoSyncReducer.reduce(
      .versionSelectionChanged(.editedWithOriginals), in: state, now: now)

    #expect(next.current == .idle)
    #expect(effects.isEmpty)
  }

  // MARK: - debounceFired → running → idle

  @Test func debounceFiredFromScheduledStartsRun() {
    var state = enabledStateWithSafeDestinationAndScope()
    let fireAt = now.addingTimeInterval(10)
    state.current = .scheduled(reason: .appLaunch, fireAt: fireAt)

    let (next, effects) = AutoSyncReducer.reduce(
      .debounceFired(.appLaunch), in: state, now: fireAt)

    #expect(next.current == .running(reason: .appLaunch))
    #expect(effects.count == 1)
    if case .startRun(let spec) = effects[0] {
      #expect(spec.source == .autoSync)
      #expect(spec.visibility == .background)
      #expect(spec.reason == .appLaunch)
      #expect(spec.selection == .edited)
      // .autoExport scope carries the current selection.
      if case .autoExport(let scopes) = spec.scope {
        #expect(scopes == state.scopeSelection)
      } else {
        Issue.record("Expected .autoExport scope, got \(spec.scope)")
      }
    } else {
      Issue.record("Expected .startRun effect, got \(effects[0])")
    }
  }

  @Test func staleDebounceFiredIsIgnored() {
    // Scheduled with .appLaunch, but the firing event names a different reason —
    // typical of a debounce that was cancelled and replaced after the user toggled
    // a scope. Honor only the reason matching the current schedule.
    var state = enabledStateWithSafeDestinationAndScope()
    let fireAt = now.addingTimeInterval(10)
    state.current = .scheduled(reason: .appLaunch, fireAt: fireAt)

    let (next, effects) = AutoSyncReducer.reduce(
      .debounceFired(.scopeSelectionChanged), in: state, now: fireAt)

    #expect(next.current == .scheduled(reason: .appLaunch, fireAt: fireAt))
    #expect(effects.isEmpty)
  }

  @Test func runCompletionReturnsToIdle() {
    var state = enabledStateWithSafeDestinationAndScope()
    state.current = .running(reason: .appLaunch)
    state.exportRunState = .idle  // Run finished — exporter signals idle.

    let (next, effects) = AutoSyncReducer.reduce(
      .exportRunStateChanged(.idle), in: state, now: now)

    #expect(next.current == .idle)
    // No re-schedule on run completion — only events that introduce new work do.
    #expect(effects.isEmpty)
  }

  // MARK: - Cancel-on-transition-out

  @Test func unmountWhileScheduledCancelsDebounce() {
    var state = enabledStateWithSafeDestinationAndScope()
    let fireAt = now.addingTimeInterval(2)
    state.current = .scheduled(reason: .scopeSelectionChanged, fireAt: fireAt)

    let unmounted = DestinationSnapshot(
      fingerprint: state.destination.fingerprint,
      isAvailable: false,
      safety: .safe
    )
    let (next, effects) = AutoSyncReducer.reduce(
      .destinationChanged(unmounted), in: state, now: now)

    #expect(next.current == .waiting(.destinationUnavailable))
    #expect(effects == [.cancelDebounce(.scopeSelectionChanged)])
  }

  @Test func remountAfterUnmountSchedulesDestinationBecameAvailable() {
    // Was scheduled when drive went away, transitioned to .waiting. When the same
    // drive comes back, schedule with .destinationBecameAvailable (the appropriate
    // 3s debounce).
    var state = enabledStateWithSafeDestinationAndScope()
    let unavailable = DestinationSnapshot(
      fingerprint: state.destination.fingerprint,
      isAvailable: false,
      safety: .safe
    )
    state.destination = unavailable
    state.current = .waiting(.destinationUnavailable)

    let restored = DestinationSnapshot(
      fingerprint: state.destination.fingerprint,
      isAvailable: true,
      safety: .safe
    )
    let (next, effects) = AutoSyncReducer.reduce(.destinationChanged(restored), in: state, now: now)

    let fireAt = now.addingTimeInterval(3)
    #expect(next.current == .scheduled(reason: .destinationBecameAvailable, fireAt: fireAt))
    #expect(effects == [.scheduleDebounce(.destinationBecameAvailable, fireAt: fireAt)])
  }

  @Test func disablingWhileScheduledCancelsDebounce() {
    var state = enabledStateWithSafeDestinationAndScope()
    state.current = .scheduled(reason: .appLaunch, fireAt: now.addingTimeInterval(10))

    let (next, effects) = AutoSyncReducer.reduce(.enabledChanged(false), in: state, now: now)

    #expect(next.current == .disabled)
    #expect(effects == [.cancelDebounce(.appLaunch)])
  }

  @Test func newTriggerDuringScheduledReplacesDebounce() {
    // Was scheduled with .appLaunch (10s); user changes scopes — replace with
    // .scopeSelectionChanged (2s). Plan: "the most recent scheduling wins" via
    // cancel-then-schedule.
    var state = enabledStateWithSafeDestinationAndScope()
    state.current = .scheduled(reason: .appLaunch, fireAt: now.addingTimeInterval(10))

    let newScopes = AutoExportScopeSelection(timeline: true, favorites: true)
    let (next, effects) = AutoSyncReducer.reduce(
      .scopeSelectionChanged(newScopes), in: state, now: now)

    let fireAt = now.addingTimeInterval(2)
    #expect(next.current == .scheduled(reason: .scopeSelectionChanged, fireAt: fireAt))
    #expect(
      effects == [
        .cancelDebounce(.appLaunch),
        .scheduleDebounce(.scopeSelectionChanged, fireAt: fireAt),
      ])
  }

  // MARK: - photosChanged

  @Test func photosChangedWhenDisabledIsIgnored() {
    let state = AutoSyncReducer.State.initial  // enabled = false
    let event = PhotoLibraryPersistentChangeEvent(
      insertedLocalIdentifiers: ["asset-1"], observedAt: now)

    let (next, effects) = AutoSyncReducer.reduce(.photosChanged(event), in: state, now: now)

    #expect(next.dirtyStateByDestination.isEmpty)
    #expect(effects.isEmpty)
  }

  @Test func photosChangedWithNoDestinationIsIgnored() {
    var state = AutoSyncReducer.State.initial
    state.enabled = true
    state.scopeSelection = AutoExportScopeSelection(timeline: true)
    let event = PhotoLibraryPersistentChangeEvent(
      insertedLocalIdentifiers: ["asset-1"], observedAt: now)

    let (next, effects) = AutoSyncReducer.reduce(.photosChanged(event), in: state, now: now)

    #expect(next.dirtyStateByDestination.isEmpty)
    #expect(effects.isEmpty)
  }

  @Test func photosChangedWithNoSelectedScopesIsIgnored() {
    var state = AutoSyncReducer.State.initial
    state.enabled = true
    state.destination = safeDestination()
    let event = PhotoLibraryPersistentChangeEvent(
      insertedLocalIdentifiers: ["asset-1"], observedAt: now)

    let (next, effects) = AutoSyncReducer.reduce(.photosChanged(event), in: state, now: now)

    #expect(next.dirtyStateByDestination.isEmpty)
    #expect(effects.isEmpty)
  }

  @Test func photosChangedAccumulatesDirtyAssetIds() {
    let state = enabledStateWithSafeDestinationAndScope()
    let event = PhotoLibraryPersistentChangeEvent(
      insertedLocalIdentifiers: ["a", "b"],
      updatedLocalIdentifiers: ["c"],
      observedAt: now
    )

    let (next, effects) = AutoSyncReducer.reduce(.photosChanged(event), in: state, now: now)

    let destId = state.destination.id!
    let dirty = next.dirtyStateByDestination[destId]
    #expect(dirty?.scope(.timeline).pendingAssetIds == ["a", "b", "c"])
    #expect(dirty?.lastUpdatedAt == now)

    let fireAt = now.addingTimeInterval(30)
    #expect(next.current == .scheduled(reason: .photosChanged, fireAt: fireAt))
    // persistDirtyState + scheduleDebounce expected. (No nextToken in event so no
    // advancePersistentChangeToken effect.)
    #expect(effects.contains(.scheduleDebounce(.photosChanged, fireAt: fireAt)))
    #expect(
      effects.contains(where: {
        if case .persistDirtyState(_, let did) = $0 { return did == destId }
        return false
      }))
  }

  @Test func photosChangedAccumulatesDirtyEvenWhenDestinationUnavailable() {
    var state = enabledStateWithSafeDestinationAndScope()
    state.destination = DestinationSnapshot(
      fingerprint: state.destination.fingerprint, isAvailable: false, safety: .safe)
    state.current = .waiting(.destinationUnavailable)

    let event = PhotoLibraryPersistentChangeEvent(
      insertedLocalIdentifiers: ["asset-x"], observedAt: now)

    let (next, _) = AutoSyncReducer.reduce(.photosChanged(event), in: state, now: now)

    let destId = state.destination.id!
    #expect(next.dirtyStateByDestination[destId]?.scope(.timeline).pendingAssetIds == ["asset-x"])
    // State stays .waiting — we accumulate dirty state but don't try to run.
    #expect(next.current == .waiting(.destinationUnavailable))
  }

  @Test func photosChangedRollsOverToFullReconciliationAtCostCap() {
    let state = enabledStateWithSafeDestinationAndScope()
    let cap = AutoSyncReducer.targetedAssetCostCap
    let ids = Set((0..<(cap + 1)).map { "asset-\($0)" })
    let event = PhotoLibraryPersistentChangeEvent(
      insertedLocalIdentifiers: ids, observedAt: now)

    let (next, _) = AutoSyncReducer.reduce(.photosChanged(event), in: state, now: now)

    let destId = state.destination.id!
    let dirty = next.dirtyStateByDestination[destId]
    let timelineScope = dirty?.scope(.timeline)
    #expect(timelineScope?.pendingFullReconciliation == true)
    #expect(timelineScope?.pendingAssetIds.isEmpty == true)
  }

  @Test func photosChangedWithCollectionChangesMarksAlbumsForPlacementReconciliation() {
    var state = enabledStateWithSafeDestinationAndScope()
    state.scopeSelection = AutoExportScopeSelection(timeline: true, albums: true)

    let event = PhotoLibraryPersistentChangeEvent(
      insertedLocalIdentifiers: ["a"],
      collectionChangesPresent: true,
      observedAt: now
    )

    let (next, _) = AutoSyncReducer.reduce(.photosChanged(event), in: state, now: now)

    let destId = state.destination.id!
    let dirty = next.dirtyStateByDestination[destId]
    #expect(dirty?.scope(.albums).pendingPlacementReconciliation == true)
    #expect(dirty?.scope(.timeline).pendingPlacementReconciliation == false)
  }

  @Test func photosChangedAdvancesTokenWhenEventCarriesOne() {
    let state = enabledStateWithSafeDestinationAndScope()
    let token = Data([0x01, 0x02, 0x03])
    let event = PhotoLibraryPersistentChangeEvent(
      insertedLocalIdentifiers: ["a"], observedAt: now, nextToken: token)

    let (_, effects) = AutoSyncReducer.reduce(.photosChanged(event), in: state, now: now)

    let destId = state.destination.id!
    #expect(effects.contains(.advancePersistentChangeToken(token, destinationId: destId)))
  }

  // MARK: - Idempotence (plan §"State Reducer" dispatch contract)

  @Test func sameEventAppliedTwiceIsIdempotentForCurrentState() {
    let state = enabledStateWithSafeDestinationAndScope()
    let event = AutoSyncEvent.scopeSelectionChanged(
      AutoExportScopeSelection(timeline: true, favorites: true))

    let (first, _) = AutoSyncReducer.reduce(event, in: state, now: now)
    let (second, _) = AutoSyncReducer.reduce(event, in: first, now: now)

    #expect(first.current == second.current)
    #expect(first.scopeSelection == second.scopeSelection)
  }

  // MARK: - Unhandled events do not crash

  @Test func eventsNotYetWiredDoNotCrash() {
    var state = enabledStateWithSafeDestinationAndScope()
    state.current = .idle  // Pin current so we can compare against the reducer's output.

    let unhandledEvents: [AutoSyncEvent] = [
      .retryTimerFired,
      .manualFullExportCompleted(
        ExportRunSummary(
          context: ExportRunContext(
            source: .manual, visibility: .userVisible,
            scope: .timelineFullLibrary, selection: .edited),
          endedAt: now,
          enqueuedCount: 0, completedCount: 0,
          failedCount: 0, skippedCount: 0,
          cancelReason: nil, result: .completed
        )),
    ]

    for event in unhandledEvents {
      let (next, effects) = AutoSyncReducer.reduce(event, in: state, now: now)
      #expect(next.current == .idle)
      #expect(effects.isEmpty)
    }
  }
}
