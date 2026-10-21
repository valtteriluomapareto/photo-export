import Testing

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
  /// load-bearing reason: when the last job's `processNext()` finds the queue
  /// empty it sets `isRunning = false` but does **not** nil `currentTask` —
  /// that field keeps pointing at the just-resolved Task on the empty-queue
  /// edge. (In the recursion path the field is reassigned to the next job's
  /// Task before the previous one's `MainActor.run` returns, so the loop
  /// observes the new live Task on the next iteration.) Awaiting `currentTask`
  /// before checking exit conditions would re-await the resolved Task on every
  /// final iteration, starving the actual export work that runs on the same
  /// `@MainActor` and forcing every test to hit the safety timeout.
  ///
  /// Preparation handles replace the old 500 ms startup guess. Await only the
  /// current generation, rechecking after each snapshot. Every await stops when
  /// the waiting test is cancelled (for example by its `.timeLimit`), so a held
  /// export cannot keep the test from reaching the teardown that releases it.
  func waitForQueueDrained(
    safetyTimeout: Duration = .seconds(150), sourceLocation: SourceLocation = #_sourceLocation
  ) async {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: safetyTimeout)
    while clock.now < deadline {
      let preparations = currentPreparationTasks
      if preparations.isEmpty, pendingJobs.isEmpty, !isRunning, !hasActiveExportWork {
        return
      }
      if Task.isCancelled { break }
      if !preparations.isEmpty {
        for task in preparations {
          guard await finished(task) else { break }
        }
        continue
      }
      if let task = currentTask {
        _ = await finished(task)
      } else {
        await Task.yield()
      }
    }
    if Task.isCancelled {
      Issue.record(
        "Cancelled while waiting for the export queue to drain", sourceLocation: sourceLocation)
    } else {
      Issue.record(
        "Export queue did not drain before the safety deadline", sourceLocation: sourceLocation)
    }
  }

  /// Blocks until the current import (if any) has finished. `importTask` is
  /// assigned synchronously inside `startImport()` (after `isImporting = true`)
  /// and the import body sets `isImporting = false` before returning, so once
  /// `await importTask?.value` resolves the manager is observably idle.
  func waitForImportCompletion(sourceLocation: SourceLocation = #_sourceLocation) async {
    if let task = importTask, !(await finished(task)) {
      Issue.record(
        "Cancelled while waiting for the import to complete", sourceLocation: sourceLocation)
    }
  }
}
