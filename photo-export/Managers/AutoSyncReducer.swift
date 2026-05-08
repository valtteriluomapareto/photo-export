import Foundation

/// Pure reducer for the AutoSync state machine. Plan §"State Reducer" — single
/// event-in / state+effects-out signature, no I/O, no timers, no actor isolation.
/// Tests pass `now: Date` directly; the runner reads `clock.now()` before calling
/// `reduce`.
///
/// `State` carries the full reducer environment (current AutoSyncState plus the inputs
/// — enabled flag, destination snapshot, scope selection — that drive transitions).
/// History fields like `lastRunSummary` live on `AutoSyncManager`, not the reducer
/// state, since they're persisted via effects rather than computed.
enum AutoSyncReducer {
  struct State: Equatable, Sendable {
    var current: AutoSyncState
    var enabled: Bool
    var destination: DestinationSnapshot
    var scopeSelection: AutoExportScopeSelection
    var versionSelection: ExportVersionSelection
    var importActive: Bool
    var exportRunState: ExportRunState

    static let initial = State(
      current: .disabled,
      enabled: false,
      destination: .none,
      scopeSelection: AutoExportScopeSelection(),
      versionSelection: .edited,
      importActive: false,
      exportRunState: .idle
    )
  }

  /// Single entry point. Plan §"State Reducer" dispatch contract:
  /// - Invoked synchronously, once per event, with no mutation in flight.
  /// - Effects are returned as a list and dispatched by the runner *after* `reduce`
  ///   returns. Events produced by an effect (e.g. `exportRunStateChanged` from a
  ///   `startRun`) are queued behind the current event's effects.
  /// - Timer cancellation is an effect (`cancelDebounce` / `cancelRetryTimer`); the
  ///   reducer never side-effects timers.
  static func reduce(
    _ event: AutoSyncEvent,
    in state: State,
    now: Date
  ) -> (State, [AutoSyncEffect]) {
    var newState = state
    let effects: [AutoSyncEffect] = []

    switch event {
    case .enabledChanged(let enabled):
      newState.enabled = enabled

    case .destinationChanged(let destination):
      newState.destination = destination

    case .scopeSelectionChanged(let scopes):
      newState.scopeSelection = scopes

    case .versionSelectionChanged(let selection):
      newState.versionSelection = selection

    case .importStateChanged(let isImporting):
      newState.importActive = isImporting

    case .exportRunStateChanged(let runState):
      newState.exportRunState = runState

    case .photosChanged, .debounceFired, .retryTimerFired, .manualFullExportCompleted:
      // Handled by subsequent slices that wire timers, dirty-state, and run lifecycle
      // into the reducer. Plan §"State Reducer" lists these events; the slice that
      // implements each will append the corresponding `case` here.
      break
    }

    newState.current = computeCurrentState(from: newState)
    return (newState, effects)
  }

  /// Maps the reducer's input environment to an `AutoSyncState`. Pure function of the
  /// state's input fields — no event history. Subsequent slices that introduce
  /// timers, run lifecycle, and dirty-state will keep `.scheduled` / `.running` cases
  /// outside this function (they're driven by explicit transitions, not by re-deriving
  /// from inputs).
  private static func computeCurrentState(from state: State) -> AutoSyncState {
    if !state.enabled {
      return .disabled
    }
    if state.importActive {
      return .waiting(.importActive)
    }
    if state.scopeSelection.isEmpty {
      return .blocked(.noScopesSelected)
    }
    if state.destination.id == nil {
      return .blocked(.destinationMissing)
    }
    if !state.destination.isAvailable {
      return .waiting(.destinationUnavailable)
    }
    switch state.destination.safety {
    case .safe:
      return .idle
    case .unsafeNeedsConfirmation, .unsafeMigrationConflict:
      return .blocked(.destinationUnsafe)
    }
  }
}
