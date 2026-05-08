import Foundation
import Testing

@testable import Photo_Export

@MainActor
struct TestClockTests {
  @Test func nowReturnsConfiguredStart() {
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    let clock = TestClock(start: start)

    #expect(clock.now() == start)
  }

  @Test func advanceMovesNowForwardWithoutPendingWork() {
    let clock = TestClock()
    let start = clock.now()

    clock.advance(by: 60)

    #expect(clock.now() == start.addingTimeInterval(60))
  }

  @Test func scheduledWorkFiresOnceItsDelayElapses() {
    let clock = TestClock()
    var fired = 0
    clock.schedule(after: 30) { fired += 1 }

    clock.advance(by: 10)
    #expect(fired == 0)

    clock.advance(by: 20)
    #expect(fired == 1)
  }

  @Test func scheduledWorkDoesNotFireTwice() {
    let clock = TestClock()
    var fired = 0
    clock.schedule(after: 30) { fired += 1 }

    clock.advance(by: 60)
    clock.advance(by: 60)

    #expect(fired == 1)
  }

  @Test func multipleScheduledWorksFireInDeadlineOrder() {
    let clock = TestClock()
    var order: [String] = []
    clock.schedule(after: 30) { order.append("late") }
    clock.schedule(after: 5) { order.append("early") }
    clock.schedule(after: 15) { order.append("middle") }

    clock.advance(by: 60)

    #expect(order == ["early", "middle", "late"])
  }

  @Test func cancelledWorkDoesNotFire() {
    let clock = TestClock()
    var fired = false
    let token = clock.schedule(after: 10) { fired = true }
    token.cancel()

    clock.advance(by: 60)

    #expect(fired == false)
    #expect(clock.pendingCount == 0)
  }

  @Test func cancelIsIdempotent() {
    let clock = TestClock()
    let token = clock.schedule(after: 10) {}
    token.cancel()
    token.cancel()  // must not crash

    #expect(clock.pendingCount == 0)
  }

  @Test func workScheduledFromFiringClosureWaitsForNextAdvance() {
    let clock = TestClock()
    var stage1Fired = false
    var stage2Fired = false

    clock.schedule(after: 5) {
      stage1Fired = true
      clock.schedule(after: 5) { stage2Fired = true }
    }

    clock.advance(by: 5)
    #expect(stage1Fired)
    #expect(stage2Fired == false)  // stage2 is now pending; advance again to fire

    clock.advance(by: 5)
    #expect(stage2Fired)
  }

  @Test func zeroDelayFiresOnNextAdvance() {
    let clock = TestClock()
    var fired = false
    clock.schedule(after: 0) { fired = true }

    #expect(fired == false)
    clock.advance(by: 0)

    #expect(fired)
  }

  @Test func advanceFiresAllDueWorkAtomicallyBeforeReturning() {
    let clock = TestClock()
    var firingsAtCheck = 0
    clock.schedule(after: 1) {}
    clock.schedule(after: 2) {}
    clock.schedule(after: 3) { firingsAtCheck = 3 }

    clock.advance(by: 5)

    #expect(firingsAtCheck == 3)  // all three fired during the single advance call
    #expect(clock.pendingCount == 0)
  }
}
