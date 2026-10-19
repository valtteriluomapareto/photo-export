import Foundation

/// Runs `operation` in a detached task and forwards the caller's cancellation to it.
///
/// Awaiting `Task.detached { … }.value` alone never cancels the detached task, so its own
/// `Task.isCancelled` / `checkCancellation()` checks would never fire. The caller still
/// waits for the detached task to finish: work already in progress (a filesystem probe, a
/// directory read) completes, and the operation stops at its next cancellation check.
nonisolated func runDetached<T: Sendable>(
  priority: TaskPriority? = nil, operation: @escaping @Sendable () async throws -> T
) async throws -> T {
  // `onCancel` runs immediately when the caller is already cancelled, so the task it
  // cancels must already exist.
  let task = Task.detached(priority: priority, operation: operation)
  return try await withTaskCancellationHandler {
    try await task.value
  } onCancel: {
    task.cancel()
  }
}

/// Non-throwing variant of `runDetached(priority:operation:)` for operations that report
/// failure in their result.
nonisolated func runDetached<T: Sendable>(
  priority: TaskPriority? = nil, operation: @escaping @Sendable () async -> T
) async -> T {
  let task = Task.detached(priority: priority, operation: operation)
  return await withTaskCancellationHandler {
    await task.value
  } onCancel: {
    task.cancel()
  }
}
