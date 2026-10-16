import Foundation
import Testing

@testable import Photo_Export

struct AutoSyncRetryRecoveryMergeTests {
  private let first = Date(timeIntervalSince1970: 1000)

  private func entry(
    count: Int, last: TimeInterval, signature: String = "same",
    category: AutoSyncFailureCategory = .photoKitTransient, deadline: TimeInterval? = nil
  ) -> RetryEntry {
    RetryEntry(
      category: category, errorSignature: signature, attemptCount: count,
      firstFailedAt: first, lastFailedAt: first.addingTimeInterval(last),
      nextEligibleAt: deadline.map { first.addingTimeInterval($0) })
  }

  private func state(_ entry: RetryEntry) -> AutoSyncRetryState {
    AutoSyncRetryState(entriesByPlacement: ["future-scope": ["asset": ["future-variant": entry]]])
  }

  @Test func mergeRetainsMaximumKnownHistoryAndDoesNotPostponeOnRepeatedRecovery() {
    let saved = state(entry(count: 3, last: 10, deadline: 1200))
    var memory = state(entry(count: 1, last: 100, deadline: 130))
    memory.entriesByPlacement["new"] = ["other": ["edited": entry(count: 1, last: 20)]]
    let merged = saved.mergingRecovery(memory)
    let result = merged.entriesByPlacement["future-scope"]?["asset"]?["future-variant"]
    #expect(result?.attemptCount == 3)
    #expect(result?.firstFailedAt == first)
    #expect(result?.lastFailedAt == first.addingTimeInterval(100))
    #expect(result?.nextEligibleAt == first.addingTimeInterval(1200))
    #expect(merged.entriesByPlacement["new"] == memory.entriesByPlacement["new"])
    #expect(merged.mergingRecovery(memory) == merged)
    #expect(saved.mergingRecovery(merged) == merged)
  }

  @Test func mergedDeadlineUsesLatestFailureTimeAndRetainsHardFailurePolicy() {
    let saved = state(entry(count: 3, last: 0))
    let memory = state(entry(count: 1, last: 100))
    let merged = saved.mergingRecovery(memory)
    #expect(
      merged.entriesByPlacement["future-scope"]?["asset"]?["future-variant"]?.nextEligibleAt
        == first.addingTimeInterval(700))
    let hard = state(entry(count: 3, last: 100, category: .destinationPermission))
      .mergingRecovery(state(entry(count: 1, last: 200, category: .destinationPermission)))
    #expect(
      hard.entriesByPlacement["future-scope"]?["asset"]?["future-variant"]?.nextEligibleAt == nil)
  }

  @Test func differentFailuresPreferLatestWithMemoryWinningTies() {
    let saved = state(entry(count: 4, last: 100, signature: "old"))
    let newer = state(entry(count: 1, last: 101, signature: "new"))
    #expect(saved.mergingRecovery(newer) == newer)
    #expect(newer.mergingRecovery(saved) == newer)
    let tied = state(entry(count: 1, last: 100, signature: "new"))
    #expect(saved.mergingRecovery(tied) == tied)
  }
}
