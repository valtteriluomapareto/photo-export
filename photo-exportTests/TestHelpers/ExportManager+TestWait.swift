import Foundation

@testable import Photo_Export

/// Deterministic completion helpers that replace the `Task.sleep` polling loops
/// each test file used to carry a private copy of. The helpers `await` the
/// actual in-flight `Task` exposed by `ExportManager` (via `private(set)`) so
/// the test resumes the moment the export pipeline really finishes — not after
/// some wall-clock deadline that races against slow CI VMs.
///
/// `safetyTimeout` is a backstop against a test bug that would otherwise hang
/// the suite forever. It should never fire on a healthy run; the default is
/// large enough that the slowest CI VM will not legitimately hit it.
extension ExportManager {
  /// Blocks until the export queue is fully drained: any in-flight job's `Task`
  /// has completed and no further work is queued or in flight.
  ///
  /// The exit check runs **before** the `await currentTask?.value` for a
  /// load-bearing reason: when the last job's `processNext()` runs (inside the
  /// finishing job's `MainActor.run` block) and finds the queue empty, it sets
  /// `isRunning = false` but does **not** nil `currentTask` — that field stays
  /// pointing at the just-resolved Task. If the loop awaited `currentTask`
  /// first it would re-await the resolved Task on every iteration (each await
  /// returning instantly), starving the actual export work that's running on
  /// the same `@MainActor` and causing every test to hit the safety timeout.
  /// Checking `pendingJobs.isEmpty && !isRunning && !hasActiveExportWork`
  /// first means we exit on the iteration *after* the final job lands, before
  /// re-awaiting the stale handle.
  ///
  /// The brief sleep at the start is kept from the original polling helper:
  /// `startExport*()` spawns an unstored Task that performs the asynchronous
  /// enqueue; before that Task has run, `currentTask` is `nil`, `pendingJobs`
  /// is empty, and the exit check would return immediately. 50 ms is enough
  /// for the enqueue Task to land on the main actor and either populate the
  /// queue or signal an empty run. The 5-second deadline that used to wrap
  /// *the whole helper* is what made tests flaky on slow CI VMs; only the
  /// input-side preamble survives, with a much larger safety timeout.
  func waitForQueueDrained(safetyTimeout: Duration = .seconds(60)) async {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: safetyTimeout)
    await Task.yield()
    try? await Task.sleep(for: .milliseconds(50))
    while clock.now < deadline {
      if pendingJobs.isEmpty, !isRunning, !hasActiveExportWork {
        return
      }
      if let task = currentTask {
        _ = await task.value
      } else {
        await Task.yield()
      }
    }
  }

  /// Blocks until the current import (if any) has finished. `importTask` holds
  /// the in-flight import; awaiting its `.value` is sufficient for the import
  /// case because there is no per-job queue to drain — the whole import runs
  /// inside that single Task.
  func waitForImportCompletion(safetyTimeout: Duration = .seconds(60)) async {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: safetyTimeout)
    if let task = importTask {
      _ = await task.value
    }
    while isImporting, clock.now < deadline {
      await Task.yield()
    }
  }
}
