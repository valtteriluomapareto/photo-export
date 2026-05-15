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
    #expect(
      AutoSyncRetryScopeKey.sharedAlbum(placementId: "abc123").rawValue
        == "shared-album:abc123")
  }

  @Test func scopeKeyRoundTripsThroughRawValue() {
    let original: [AutoSyncRetryScopeKey] = [
      .timeline, .favorites,
      .album(placementId: "abc"), .album(placementId: "x:y"),
      .sharedAlbum(placementId: "stream-1"), .sharedAlbum(placementId: "x:y"),
    ]

    for key in original {
      #expect(AutoSyncRetryScopeKey(rawValue: key.rawValue) == key)
    }
  }

  @Test func scopeKeyInitRejectsUnknownAndEmptyAlbumIds() {
    #expect(AutoSyncRetryScopeKey(rawValue: "garbage") == nil)
    #expect(AutoSyncRetryScopeKey(rawValue: "album:") == nil)
    #expect(AutoSyncRetryScopeKey(rawValue: "shared-album:") == nil)
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

  @Test func differentCategoryResetsAttemptCountEvenWithSameSignature() {
    var state = AutoSyncRetryState()
    let firstAt = Date(timeIntervalSince1970: 1_700_000_000)
    let secondAt = firstAt.addingTimeInterval(60)

    state.recordFailure(
      scope: .timeline, assetId: "a", variant: .original,
      category: .iCloudTransient, errorSignature: "E:5",
      at: firstAt, nextEligibleAt: nil
    )
    state.recordFailure(
      scope: .timeline, assetId: "a", variant: .original,
      category: .destinationNoSpace, errorSignature: "E:5",
      at: secondAt, nextEligibleAt: nil
    )

    let entry = state.entry(scope: .timeline, assetId: "a", variant: .original)
    #expect(entry?.attemptCount == 1)
    #expect(entry?.firstFailedAt == secondAt)
    #expect(entry?.category == .destinationNoSpace)
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

  /// Oscillation A → B → A: the third call sees a category-mismatch with the existing
  /// (B-categorized) entry and resets attempt count to 1. Documents that flapping
  /// categories restart the budget every time — there is no per-category sub-bucket. If
  /// future product feedback wants accumulating retries across category flaps, this is
  /// the test that codifies the current decision.
  @Test func categoryOscillationResetsEachTransition() {
    var state = AutoSyncRetryState()
    let firstAt = Date(timeIntervalSince1970: 1_700_000_000)
    let secondAt = firstAt.addingTimeInterval(60)
    let thirdAt = firstAt.addingTimeInterval(120)

    state.recordFailure(
      scope: .timeline, assetId: "a", variant: .original,
      category: .iCloudTransient, errorSignature: "sig",
      at: firstAt, nextEligibleAt: nil
    )
    state.recordFailure(
      scope: .timeline, assetId: "a", variant: .original,
      category: .destinationNoSpace, errorSignature: "sig",
      at: secondAt, nextEligibleAt: nil
    )
    state.recordFailure(
      scope: .timeline, assetId: "a", variant: .original,
      category: .iCloudTransient, errorSignature: "sig",
      at: thirdAt, nextEligibleAt: nil
    )

    let entry = state.entry(scope: .timeline, assetId: "a", variant: .original)
    #expect(entry?.attemptCount == 1)
    #expect(entry?.firstFailedAt == thirdAt)
    #expect(entry?.category == .iCloudTransient)
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

  @Test func inMemoryStoreSaveThrowsWhenNextSaveErrorIsSet() {
    let store = InMemoryAutoSyncRetryStateStore()
    store.nextSaveError = InMemoryAutoSyncStoreError("disk-full")

    #expect(throws: InMemoryAutoSyncStoreError.self) {
      try store.save(.empty, destinationId: "dest-A")
    }
    // Cleared after one throw.
    #expect(throws: Never.self) {
      try store.save(.empty, destinationId: "dest-A")
    }
  }

  @Test func inMemoryStoreDeleteRemovesEntry() throws {
    let store = InMemoryAutoSyncRetryStateStore()
    try store.save(.empty, destinationId: "dest-A")
    try store.save(.empty, destinationId: "dest-B")

    try store.deleteState(destinationId: "dest-A")

    #expect(store.savedDestinationIds == ["dest-B"])
  }
}
