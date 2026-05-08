import Foundation
import Testing

@testable import Photo_Export

@MainActor
struct AutoSyncRetryStateTests {

  // MARK: - Scope key

  @Test func scopeKeyRawValueMatchesDocumentedFormat() {
    #expect(AutoSyncRetryScopeKey.timeline.rawValue == "timeline")
    #expect(AutoSyncRetryScopeKey.favorites.rawValue == "favorites")
    #expect(AutoSyncRetryScopeKey.album(placementId: "abc123").rawValue == "album:abc123")
  }

  @Test func scopeKeyRoundTripsThroughRawValue() {
    let original: [AutoSyncRetryScopeKey] = [
      .timeline, .favorites, .album(placementId: "abc"), .album(placementId: "x:y"),
    ]

    for key in original {
      #expect(AutoSyncRetryScopeKey(rawValue: key.rawValue) == key)
    }
  }

  @Test func scopeKeyInitRejectsUnknownAndEmptyAlbumIds() {
    #expect(AutoSyncRetryScopeKey(rawValue: "garbage") == nil)
    #expect(AutoSyncRetryScopeKey(rawValue: "album:") == nil)
  }

  // MARK: - recordFailure

  @Test func recordFailureCreatesEntryAtAttemptOne() {
    var state = AutoSyncRetryState()
    let now = Date(timeIntervalSince1970: 1_700_000_000)

    state.recordFailure(
      scope: .timeline, assetId: "asset-1", variant: .original,
      category: .photoKitTransient, errorSignature: "PHKit:42",
      at: now, nextEligibleAt: now.addingTimeInterval(60)
    )

    let entry = state.entry(scope: .timeline, assetId: "asset-1", variant: .original)
    #expect(entry?.attemptCount == 1)
    #expect(entry?.firstFailedAt == now)
    #expect(entry?.lastFailedAt == now)
    #expect(entry?.errorSignature == "PHKit:42")
    #expect(entry?.category == .photoKitTransient)
  }

  @Test func sameSignatureIncrementsAttemptCount() {
    var state = AutoSyncRetryState()
    let firstAt = Date(timeIntervalSince1970: 1_700_000_000)
    let secondAt = firstAt.addingTimeInterval(60)

    state.recordFailure(
      scope: .timeline, assetId: "a", variant: .original,
      category: .photoKitTransient, errorSignature: "sig",
      at: firstAt, nextEligibleAt: nil
    )
    state.recordFailure(
      scope: .timeline, assetId: "a", variant: .original,
      category: .photoKitTransient, errorSignature: "sig",
      at: secondAt, nextEligibleAt: nil
    )

    let entry = state.entry(scope: .timeline, assetId: "a", variant: .original)
    #expect(entry?.attemptCount == 2)
    #expect(entry?.firstFailedAt == firstAt)
    #expect(entry?.lastFailedAt == secondAt)
  }

  @Test func differentSignatureResetsAttemptCount() {
    var state = AutoSyncRetryState()
    let firstAt = Date(timeIntervalSince1970: 1_700_000_000)
    let secondAt = firstAt.addingTimeInterval(60)

    state.recordFailure(
      scope: .timeline, assetId: "a", variant: .original,
      category: .destinationNoSpace, errorSignature: "ENOSPC",
      at: firstAt, nextEligibleAt: nil
    )
    state.recordFailure(
      scope: .timeline, assetId: "a", variant: .original,
      category: .photoKitTransient, errorSignature: "PHKit:42",
      at: secondAt, nextEligibleAt: nil
    )

    let entry = state.entry(scope: .timeline, assetId: "a", variant: .original)
    #expect(entry?.attemptCount == 1)
    #expect(entry?.firstFailedAt == secondAt)
    #expect(entry?.errorSignature == "PHKit:42")
    #expect(entry?.category == .photoKitTransient)
  }

  // MARK: - Scope independence

  @Test func failuresInDifferentAlbumsDoNotShareCounts() {
    var state = AutoSyncRetryState()
    let now = Date(timeIntervalSince1970: 1_700_000_000)

    state.recordFailure(
      scope: .album(placementId: "alpha"), assetId: "a", variant: .original,
      category: .photoKitTransient, errorSignature: "sig",
      at: now, nextEligibleAt: nil
    )
    state.recordFailure(
      scope: .album(placementId: "alpha"), assetId: "a", variant: .original,
      category: .photoKitTransient, errorSignature: "sig",
      at: now, nextEligibleAt: nil
    )
    state.recordFailure(
      scope: .album(placementId: "beta"), assetId: "a", variant: .original,
      category: .photoKitTransient, errorSignature: "sig",
      at: now, nextEligibleAt: nil
    )

    #expect(
      state.entry(scope: .album(placementId: "alpha"), assetId: "a", variant: .original)?
        .attemptCount == 2)
    #expect(
      state.entry(scope: .album(placementId: "beta"), assetId: "a", variant: .original)?
        .attemptCount == 1)
    #expect(
      state.entry(scope: .timeline, assetId: "a", variant: .original) == nil)
    #expect(
      state.entry(scope: .favorites, assetId: "a", variant: .original) == nil)
  }

  @Test func failuresOnDifferentVariantsDoNotShareCounts() {
    var state = AutoSyncRetryState()
    let now = Date(timeIntervalSince1970: 1_700_000_000)

    state.recordFailure(
      scope: .timeline, assetId: "a", variant: .original,
      category: .photoKitTransient, errorSignature: "sig",
      at: now, nextEligibleAt: nil
    )
    state.recordFailure(
      scope: .timeline, assetId: "a", variant: .edited,
      category: .photoKitTransient, errorSignature: "sig",
      at: now, nextEligibleAt: nil
    )

    #expect(
      state.entry(scope: .timeline, assetId: "a", variant: .original)?.attemptCount == 1)
    #expect(state.entry(scope: .timeline, assetId: "a", variant: .edited)?.attemptCount == 1)
  }

  // MARK: - Removal

  @Test func removeEntryDropsBucketsThatBecomeEmpty() {
    var state = AutoSyncRetryState()
    let now = Date(timeIntervalSince1970: 1_700_000_000)

    state.recordFailure(
      scope: .timeline, assetId: "a", variant: .original,
      category: .photoKitTransient, errorSignature: "sig",
      at: now, nextEligibleAt: nil
    )

    state.removeEntry(scope: .timeline, assetId: "a", variant: .original)

    #expect(state.isEmpty)
    #expect(state.entriesByPlacement.isEmpty)
  }

  @Test func removeEntryPreservesOtherVariantsForSameAsset() {
    var state = AutoSyncRetryState()
    let now = Date(timeIntervalSince1970: 1_700_000_000)

    state.recordFailure(
      scope: .timeline, assetId: "a", variant: .original,
      category: .photoKitTransient, errorSignature: "sig",
      at: now, nextEligibleAt: nil
    )
    state.recordFailure(
      scope: .timeline, assetId: "a", variant: .edited,
      category: .photoKitTransient, errorSignature: "sig",
      at: now, nextEligibleAt: nil
    )

    state.removeEntry(scope: .timeline, assetId: "a", variant: .original)

    #expect(state.entry(scope: .timeline, assetId: "a", variant: .original) == nil)
    #expect(state.entry(scope: .timeline, assetId: "a", variant: .edited)?.attemptCount == 1)
  }

  // MARK: - Failure category

  @Test func failureCategoryAutomaticRetrySetMatchesPlan() {
    let retryable = AutoSyncFailureCategory.allCases.filter(\.isAutomaticallyRetryable)
    #expect(Set(retryable) == [.photoKitTransient, .iCloudTransient, .unknown])

    // destinationUnavailable is retried only on availability transition (state-driven)
    #expect(AutoSyncFailureCategory.destinationUnavailable.isAutomaticallyRetryable == false)
  }

  // MARK: - Codable

  @Test func retryStateRoundTripsThroughCodable() throws {
    var state = AutoSyncRetryState()
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    state.recordFailure(
      scope: .album(placementId: "alpha"), assetId: "asset-1", variant: .edited,
      category: .iCloudTransient, errorSignature: "sig",
      at: now, nextEligibleAt: now.addingTimeInterval(120)
    )
    state.recordFailure(
      scope: .timeline, assetId: "asset-1", variant: .original,
      category: .destinationNoSpace, errorSignature: "ENOSPC",
      at: now, nextEligibleAt: nil
    )

    let data = try JSONEncoder().encode(state)
    let decoded = try JSONDecoder().decode(AutoSyncRetryState.self, from: data)

    #expect(decoded == state)
  }

  // MARK: - In-memory store

  @Test func inMemoryStoreReturnsEmptyForUnknownDestination() {
    let store = InMemoryAutoSyncRetryStateStore()

    #expect(store.load(destinationId: "dest-A") == .empty)
  }

  @Test func inMemoryStoreRoundTripsSaveAndLoad() throws {
    let store = InMemoryAutoSyncRetryStateStore()
    var state = AutoSyncRetryState()
    state.recordFailure(
      scope: .timeline, assetId: "a", variant: .original,
      category: .photoKitTransient, errorSignature: "sig",
      at: Date(timeIntervalSince1970: 1_700_000_000), nextEligibleAt: nil
    )

    try store.save(state, destinationId: "dest-A")

    #expect(store.load(destinationId: "dest-A") == state)
    #expect(store.savedDestinationIds == ["dest-A"])
  }

  @Test func inMemoryStoreDeleteRemovesEntry() throws {
    let store = InMemoryAutoSyncRetryStateStore()
    try store.save(.empty, destinationId: "dest-A")
    try store.save(.empty, destinationId: "dest-B")

    try store.deleteState(destinationId: "dest-A")

    #expect(store.savedDestinationIds == ["dest-B"])
  }
}
