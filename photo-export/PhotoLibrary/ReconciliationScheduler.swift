import AppKit
import Foundation

/// Drives a recurring "check for library changes" tick on behalf of
/// `PhotoLibraryPersistentChangeAdapter`. Two triggers, one callback:
///
/// 1. **Periodic timer.** Fires `onReconcile` every `interval` seconds via the
///    injected `AutoSyncClock`. Each fire re-schedules the next one, so a slow
///    callback can't queue up overlapping fires — the next tick is anchored to
///    when the previous one returned.
/// 2. **App became active.** Observes `NSApplication.didBecomeActiveNotification`
///    and fires `onReconcile` as soon as the user Cmd-tabs back to the app.
///    Free win for the "I clicked over to check on it" pattern (issue #69): the
///    relaunch fixes the staleness because launch runs a forced catch-up; this
///    gives the same fix without the relaunch.
///
/// Extracted so the scheduling and observer logic can be unit-tested against
/// `TestClock` without involving `PHPhotoLibrary`. The adapter wires its own
/// `fetchAndEmit()` as the callback.
///
/// Lifecycle: `start()` arms both triggers; `stop()` cancels the timer and
/// removes the observer. Both are idempotent. After `stop()` the scheduler can
/// be re-`start()`-ed without re-creating it.
@MainActor
final class ReconciliationScheduler {
  private let clock: AutoSyncClock
  private let interval: TimeInterval
  private let onReconcile: @MainActor () -> Void
  private let notificationCenter: NotificationCenter

  private var pendingTick: AutoSyncCancellable?
  private var becomeActiveObserver: NSObjectProtocol?
  private var isStarted = false

  /// `notificationCenter` is injectable so tests can post the activation event
  /// against their own center and not race against the system's. Production
  /// passes `.default`.
  init(
    clock: AutoSyncClock,
    interval: TimeInterval,
    notificationCenter: NotificationCenter = .default,
    onReconcile: @MainActor @escaping () -> Void
  ) {
    self.clock = clock
    self.interval = interval
    self.notificationCenter = notificationCenter
    self.onReconcile = onReconcile
  }

  func start() {
    guard !isStarted else { return }
    isStarted = true
    scheduleNextTick()
    becomeActiveObserver = notificationCenter.addObserver(
      forName: NSApplication.didBecomeActiveNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      // `.main` queue + a hop into MainActor.assumeIsolated keeps the call
      // path on the main actor without spinning a Task.
      MainActor.assumeIsolated {
        self?.fire()
      }
    }
  }

  func stop() {
    guard isStarted else { return }
    isStarted = false
    pendingTick?.cancel()
    pendingTick = nil
    if let becomeActiveObserver {
      notificationCenter.removeObserver(becomeActiveObserver)
    }
    becomeActiveObserver = nil
  }

  // MARK: - Internal

  private func scheduleNextTick() {
    pendingTick = clock.schedule(after: interval) { [weak self] in
      self?.tickFired()
    }
  }

  private func tickFired() {
    pendingTick = nil
    // Re-arm before firing so the next tick is anchored to "tick handler started"
    // rather than "tick handler finished". With a 15-minute interval this keeps
    // the cadence stable even when `onReconcile` itself takes a moment.
    scheduleNextTick()
    onReconcile()
  }

  private func fire() {
    // Become-active fires don't reset the periodic schedule — the timer keeps
    // its own cadence so a Cmd-tab burst doesn't push the next periodic tick
    // out to "15 minutes from now," and a long focused session still gets the
    // safety-net check.
    onReconcile()
  }
}
