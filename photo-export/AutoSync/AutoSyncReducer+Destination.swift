import Foundation

extension AutoSyncReducer {
  static func applyDestinationChange(
    _ destination: DestinationSnapshot, to state: inout State
  ) -> AutoSyncReason? {
    let previous = state.destination
    guard destination != previous else { return nil }
    if destination.id != previous.id {
      // Work pending for the old destination cannot start against the new one.
      state.pendingTriggerReason = nil
      state.consumedRetryEntries.removeAll()
      if let boundary = state.runDirtyBoundary {
        state.invalidatedRunIds.insert(boundary.context.runId)
      }
      if let active = state.exportRunState.activeContext {
        state.invalidatedRunIds.insert(active.runId)
      }
      state.runDirtyBoundary = nil
    }
    state.destination = destination
    guard destination.id != nil && destination.isAvailable else { return nil }

    let sameId = destination.id == previous.id
    if sameId && destination.isAvailable == previous.isAvailable {
      // Writability recovery serves the work already waiting for this folder.
      guard destination.isWritable && !destination.isValidating else { return nil }
      if !previous.isWritable {
        return state.pendingTriggerReason ?? .destinationBecameAvailable
      }
      // Validation and safety checks serve what's pending. Fingerprint drift is
      // metadata refresh, so it doesn't schedule another run at the same ID.
      if previous.isValidating || previous.safety == .checking
        || previous.safety == destination.safety
      {
        return nil
      }
    }
    return sameId && !previous.isAvailable ? .destinationBecameAvailable : .destinationSelected
  }
}
