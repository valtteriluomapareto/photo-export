import Foundation
import Testing

@testable import Photo_Export

/// The waits tests use instead of wall-clock deadlines must return when the waiting test is
/// cancelled, because a `.timeLimit` cancels the test and then waits for its body to return.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct TestWaitTests {
  @Test func checkpointWaitReturnsWhenCountIsReached() async {
    let gate = AsyncCheckpoint()
    let waiter = Task { await gate.waitForEnter(count: 2) }
    let writers = (0..<2).map { _ in Task { await gate.enter() } }
    #expect(await waiter.value)
    await gate.releaseAll()
    for writer in writers { await writer.value }
  }

  @Test func checkpointWaitReturnsFalseWhenCancelledWhileWaiting() async {
    let gate = AsyncCheckpoint()
    let waiter = Task { await gate.waitForEnter(count: 1) }
    while await gate.observerCountForTesting == 0 { await Task.yield() }
    waiter.cancel()
    #expect(await waiter.value == false)
    #expect(await gate.observerCountForTesting == 0)
  }

  @Test func checkpointWaitReturnsFalseWhenCancelledBeforeRegistering() async {
    let gate = AsyncCheckpoint()
    let waiter = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return await gate.waitForEnter(count: 1)
    }
    #expect(await waiter.value == false)
    #expect(await gate.observerCountForTesting == 0)
  }

  @Test func checkpointWaitReturnsWhenReleasedAll() async {
    let gate = AsyncCheckpoint()
    let waiter = Task { await gate.waitForEnter(count: 1) }
    while await gate.observerCountForTesting == 0 { await Task.yield() }
    await gate.releaseAll()
    #expect(await waiter.value == false)
  }

  @Test func finishedReturnsFalseWhenTheWaiterIsCancelledWhileTheTaskIsHeld() async {
    let gate = AsyncCheckpoint()
    let held = Task { await gate.enter() }
    #expect(await gate.waitForEnter(count: 1))
    let waiter = Task { await finished(held) }
    waiter.cancel()
    #expect(await waiter.value == false)
    await gate.releaseAll()
    #expect(await finished(held))
  }

  @Test func eventuallyReturnsWhenThePredicateHolds() async {
    var turns = 0
    let reached = await eventually("three turns") {
      turns += 1
      return turns >= 3
    }
    #expect(reached)
  }

  @Test func eventuallyRecordsThePendingConditionWhenCancelled() async {
    let waiter = Task { @MainActor in
      await withKnownIssue("A cancelled wait names its pending condition") {
        let reached = await eventually("a condition that never holds") { false }
        #expect(!reached)
      }
    }
    try? await Task.sleep(for: .milliseconds(50))
    waiter.cancel()
    await waiter.value
  }
}
