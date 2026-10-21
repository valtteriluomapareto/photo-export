import Testing
import os

struct ContinuationResumeTests {

  /// Simulates the OSAllocatedUnfairLock resume-once pattern used in PHImageManager callbacks.
  /// Returns the number of successful (first) resumes out of `callCount` concurrent attempts.
  private func simulateConcurrentResumes(callCount: Int) async -> Int {
    let lock = OSAllocatedUnfairLock(initialState: false)
    let count = OSAllocatedUnfairLock(initialState: 0)

    await withTaskGroup(of: Void.self) { group in
      for _ in 0..<callCount {
        group.addTask {
          let didResume = lock.withLock { (state: inout Bool) -> Bool in
            let was = state
            state = true
            return !was
          }
          if didResume {
            count.withLock { $0 += 1 }
          }
        }
      }
    }

    return count.withLock { $0 }
  }

  @Test func resumeOnceFromTwoConcurrentCallbacks() async {
    let resumeCount = await simulateConcurrentResumes(callCount: 2)
    #expect(resumeCount == 1)
  }

  @Test func resumeOnceFromManyConcurrentCallbacks() async {
    let resumeCount = await simulateConcurrentResumes(callCount: 100)
    #expect(resumeCount == 1)
  }

  @Test func degradedThenFinalProducesOneResume() async {
    // Simulates requestFullImage pattern: degraded callback is skipped, final resumes once
    let lock = OSAllocatedUnfairLock(initialState: false)
    var resumeCount = 0

    // Degraded callback — should be skipped (not hitting the lock at all)
    let isDegraded = true
    if !isDegraded {
      let didResume = lock.withLock { (state: inout Bool) -> Bool in
        let was = state
        state = true
        return !was
      }
      if didResume { resumeCount += 1 }
    }

    // Final callback — should resume
    let didResume = lock.withLock { (state: inout Bool) -> Bool in
      let was = state
      state = true
      return !was
    }
    if didResume { resumeCount += 1 }

    // Second final callback (shouldn't happen but guarding) — should NOT resume
    let didResume2 = lock.withLock { (state: inout Bool) -> Bool in
      let was = state
      state = true
      return !was
    }
    if didResume2 { resumeCount += 1 }

    #expect(resumeCount == 1)
  }

  @Test func errorBeforeFinalProducesOneResume() async {
    // Simulates error path resuming before the final image callback
    let lock = OSAllocatedUnfairLock(initialState: false)
    var resumeCount = 0

    // Error callback resumes first
    let didResume1 = lock.withLock { (state: inout Bool) -> Bool in
      let was = state
      state = true
      return !was
    }
    if didResume1 { resumeCount += 1 }

    // Final callback arrives late — should be blocked
    let didResume2 = lock.withLock { (state: inout Bool) -> Bool in
      let was = state
      state = true
      return !was
    }
    if didResume2 { resumeCount += 1 }

    #expect(resumeCount == 1)
  }
}
