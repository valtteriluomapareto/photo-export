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

  @Test func enableWithSafeDestinationAndScopeReachesIdle() {
    var state = AutoSyncReducer.State.initial
    state.destination = safeDestination()
    state.scopeSelection = AutoExportScopeSelection(timeline: true, favorites: true)

    let (next, effects) = AutoSyncReducer.reduce(.enabledChanged(true), in: state, now: now)

    #expect(next.current == .idle)
    #expect(effects.isEmpty)
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

  @Test func enablingNewScopeReachesIdle() {
    var state = AutoSyncReducer.State.initial
    state.enabled = true
    state.destination = safeDestination()
    state.scopeSelection = AutoExportScopeSelection()
    state.current = .blocked(.noScopesSelected)

    let (next, _) = AutoSyncReducer.reduce(
      .scopeSelectionChanged(AutoExportScopeSelection(albums: true)),
      in: state, now: now)

    #expect(next.current == .idle)
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

  @Test func versionSelectionChangeUpdatesStateButDoesNotTransition() {
    let state = enabledStateWithSafeDestinationAndScope()

    let (next, effects) = AutoSyncReducer.reduce(
      .versionSelectionChanged(.editedWithOriginals), in: state, now: now)

    #expect(next.versionSelection == .editedWithOriginals)
    #expect(next.current == .idle)
    #expect(effects.isEmpty)
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
      .photosChanged(PhotoLibraryPersistentChangeEvent()),
      .debounceFired(.appLaunch),
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
