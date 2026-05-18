import AppKit
import Foundation
import Testing

@testable import Photo_Export

/// Covers `ReconciliationScheduler`'s periodic timer + become-active observer
/// (issue #69). Tests the scheduler in isolation against `TestClock`; the
/// adapter's `fetchAndEmit` integration with PhotoKit is intentionally not
/// covered here (no PHPhotoLibrary test double).
@MainActor
struct ReconciliationSchedulerTests {

  /// The scheduler arms a tick `interval` seconds after `start()` — not at
  /// `start()` itself. Re-arms after each fire so the cadence keeps going.
  @Test func firesPeriodicallyOnAdvance() {
    let clock = TestClock()
    let center = NotificationCenter()
    var fireCount = 0
    let scheduler = ReconciliationScheduler(
      clock: clock, interval: 900, notificationCenter: center
    ) {
      fireCount += 1
    }

    scheduler.start()
    #expect(fireCount == 0, "no fire until time passes")

    clock.advance(by: 899)
    #expect(fireCount == 0, "not yet at the interval boundary")

    clock.advance(by: 1)
    #expect(fireCount == 1, "fires exactly once at the boundary")

    clock.advance(by: 900)
    #expect(fireCount == 2, "re-arms automatically after each fire")

    // 30-minute jump: covers two more interval boundaries (at +900 and +1800
    // from the start of the advance). Per `TestClock`'s contract, work
    // scheduled by a fired closure only runs on the *next* `advance` call, so
    // the tick scheduled by the second fire inside this advance is queued but
    // not invoked — fires 3 then 4 land on the two subsequent advances.
    clock.advance(by: 1800)
    #expect(fireCount == 3)
    clock.advance(by: 900)
    #expect(fireCount == 4)
  }

  /// `stop()` cancels the pending timer — no fire after it returns, regardless
  /// of how far the clock advances. Idempotent: calling stop() twice is safe.
  @Test func stopCancelsPendingTimer() {
    let clock = TestClock()
    let center = NotificationCenter()
    var fireCount = 0
    let scheduler = ReconciliationScheduler(
      clock: clock, interval: 900, notificationCenter: center
    ) {
      fireCount += 1
    }

    scheduler.start()
    clock.advance(by: 400)
    scheduler.stop()
    clock.advance(by: 10_000)

    #expect(fireCount == 0)

    scheduler.stop()  // second call must not crash
  }

  /// `start()` is idempotent — calling it twice in a row doesn't queue up
  /// two parallel timers. A regression here would manifest as 2× firings per
  /// interval and is exactly the kind of bug the issue #69 timer must avoid.
  @Test func startIsIdempotent() {
    let clock = TestClock()
    let center = NotificationCenter()
    var fireCount = 0
    let scheduler = ReconciliationScheduler(
      clock: clock, interval: 900, notificationCenter: center
    ) {
      fireCount += 1
    }

    scheduler.start()
    scheduler.start()
    scheduler.start()
    clock.advance(by: 900)

    #expect(fireCount == 1)
  }

  /// Become-active fires the callback synchronously (via the injected
  /// `NotificationCenter`'s `.main` queue + a `MainActor.assumeIsolated` hop).
  /// The notification center is per-test so production's `.default` center
  /// is untouched.
  @Test func becomeActiveTriggersFire() async {
    let clock = TestClock()
    let center = NotificationCenter()
    var fireCount = 0
    let scheduler = ReconciliationScheduler(
      clock: clock, interval: 900, notificationCenter: center
    ) {
      fireCount += 1
    }
    scheduler.start()

    center.post(name: NSApplication.didBecomeActiveNotification, object: nil)
    // The notification is delivered on `.main` — yield once to let the
    // runloop process it.
    await Task.yield()

    #expect(fireCount == 1)
  }

  /// Become-active firings do NOT reset the periodic timer's cadence. A user
  /// who Cmd-tabs in and out every two minutes still gets the periodic
  /// safety-net check on schedule.
  @Test func becomeActiveDoesNotResetPeriodicCadence() async {
    let clock = TestClock()
    let center = NotificationCenter()
    var fireCount = 0
    let scheduler = ReconciliationScheduler(
      clock: clock, interval: 900, notificationCenter: center
    ) {
      fireCount += 1
    }
    scheduler.start()

    clock.advance(by: 800)
    center.post(name: NSApplication.didBecomeActiveNotification, object: nil)
    await Task.yield()
    #expect(fireCount == 1, "become-active fired once")

    clock.advance(by: 100)
    #expect(fireCount == 2, "periodic still fires at the 900s boundary")
  }

  /// After `stop()` the become-active observer is removed; posting the
  /// notification no longer fires the callback.
  @Test func stopRemovesBecomeActiveObserver() async {
    let clock = TestClock()
    let center = NotificationCenter()
    var fireCount = 0
    let scheduler = ReconciliationScheduler(
      clock: clock, interval: 900, notificationCenter: center
    ) {
      fireCount += 1
    }
    scheduler.start()
    scheduler.stop()

    center.post(name: NSApplication.didBecomeActiveNotification, object: nil)
    await Task.yield()

    #expect(fireCount == 0)
  }
}
