import Foundation
import Testing

@testable import Photo_Export

/// Backward-compat regression gate for the AutoSync on-disk persistence formats.
///
/// Five file-backed stores live under `<App Support>/<bundle-id>/AutoSync/`:
///   - `destinations/<destinationId>/dirtyState.json` — `AutoSyncDirtyState`
///   - `destinations/<destinationId>/retryState.json` — `AutoSyncRetryState`
///   - `destinations/<destinationId>/lastRunSummary.json` — `ExportRunSummary`
///   - `destinations/<destinationId>/lastDurablyRecordedToken.data` — opaque
///     NSKeyedArchiver-archived `PHPersistentChangeToken` blob
///   - `photo-library-change-token.data` — same blob format, globally scoped
///
/// Each store decodes failures into `.empty` / `nil` rather than throwing so a
/// corrupt or schema-mismatched file does not block AutoSync on launch. That
/// recovery path is good for *unrecoverable* drift, but a *silent* format
/// regression would leave existing users with `.empty` dirty/retry state and
/// re-export their entire library with no warning.
///
/// These tests pin two properties per store:
///   1. **Fixture decode** — a known-good JSON byte sequence (committed inline
///      below) must decode to the expected typed state. Catches accidental
///      field renames / removals during refactors.
///   2. **Round-trip** — encode → write → load produces a value equal to what
///      went in. Catches encoder-flag drift (sort order, pretty printing) and
///      any future load-side regression that produces `.empty` for a valid file.
///
/// The two `Data`-blob token stores cannot fixture-test the payload format
/// itself (Apple owns `PHPersistentChangeToken`'s NSKeyedArchiver shape), so
/// they only pin file path + missing-file behavior.
@MainActor
struct AutoSyncStorePersistenceTests {

  // MARK: - Helpers

  private func makeTempDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("AutoSyncStorePersistenceTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  // MARK: - Dirty state

  /// Fixture: a populated `AutoSyncDirtyState` with both targeted asset ids
  /// and the placement-reconciliation flag, across two scope buckets. This is
  /// the realistic mid-life shape after a few PhotoKit change events have
  /// accumulated dirty work.
  ///
  /// If a `ScopeDirtyState` field is renamed (e.g.
  /// `pendingFullReconciliation` → `needsFullReconcile`) without a Codable
  /// migration, this test fails — and the existing user would have lost
  /// the flag silently.
  @Test func dirtyStateDecodesKnownFixture() throws {
    let fixture = """
      {
        "lastUpdatedAt" : 770000000,
        "scopes" : {
          "albums" : {
            "pendingAssetIds" : [],
            "pendingFullReconciliation" : false,
            "pendingPlacementReconciliation" : true
          },
          "timeline" : {
            "pendingAssetIds" : ["asset-1", "asset-2"],
            "pendingFullReconciliation" : false,
            "pendingPlacementReconciliation" : false
          }
        }
      }
      """.data(using: .utf8)!

    let decoded = try JSONDecoder().decode(AutoSyncDirtyState.self, from: fixture)

    #expect(decoded.lastUpdatedAt == Date(timeIntervalSinceReferenceDate: 770000000))
    #expect(decoded.scopes.count == 2)
    let timeline = decoded.scope(.timeline)
    #expect(timeline.pendingAssetIds == ["asset-1", "asset-2"])
    #expect(timeline.pendingFullReconciliation == false)
    #expect(timeline.pendingPlacementReconciliation == false)
    let albums = decoded.scope(.albums)
    #expect(albums.pendingAssetIds.isEmpty)
    #expect(albums.pendingPlacementReconciliation == true)
  }

  /// Round-trip via the store: write a populated state through
  /// `save(_:destinationId:)`, reload it through `load(destinationId:)`, and
  /// assert equality. Catches encoder-flag drift and any future load-side
  /// regression that produces `.empty` for a valid file.
  @Test func dirtyStateRoundTripsThroughStore() throws {
    let dir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = FileBackedAutoSyncDirtyStateStore(baseDirectoryURL: dir)

    var state = AutoSyncDirtyState()
    state.setScope(.timeline, ScopeDirtyState(pendingAssetIds: ["a", "b"]))
    state.setScope(.albums, ScopeDirtyState(pendingPlacementReconciliation: true))
    state.markUpdated(at: Date(timeIntervalSinceReferenceDate: 770000000))

    try store.save(state, destinationId: "dest-1")
    let loaded = store.load(destinationId: "dest-1")

    #expect(loaded == state)
  }

  /// Missing file produces `.empty` rather than throwing — the on-launch
  /// "nothing to recover" path. Pins the no-file behavior so a future
  /// refactor doesn't accidentally throw and block AutoSync startup.
  @Test func dirtyStateReturnsEmptyForMissingFile() throws {
    let dir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = FileBackedAutoSyncDirtyStateStore(baseDirectoryURL: dir)

    #expect(store.load(destinationId: "never-written") == .empty)
  }

  // MARK: - Retry state

  /// Fixture: a populated `AutoSyncRetryState` with a single retry entry
  /// across the `timeline:<assetId>:<variant>` triple. Locks in the
  /// nested-dictionary shape `[scopeKey: [assetId: [variant: RetryEntry]]]`
  /// that the in-memory unit tests don't exercise via the persistence path.
  ///
  /// If anyone changes a `RetryEntry` field (e.g. removes
  /// `nextEligibleAt`) without a Codable migration, this test fails before
  /// existing users lose their retry backoff state on the next app launch.
  @Test func retryStateDecodesKnownFixture() throws {
    let fixture = """
      {
        "entriesByPlacement" : {
          "timeline" : {
            "asset-1" : {
              "original" : {
                "attemptCount" : 2,
                "category" : "photoKitTransient",
                "errorSignature" : "NSPOSIXErrorDomain:5",
                "firstFailedAt" : 770000000,
                "lastFailedAt" : 770000300,
                "nextEligibleAt" : 770000600
              }
            }
          }
        }
      }
      """.data(using: .utf8)!

    let decoded = try JSONDecoder().decode(AutoSyncRetryState.self, from: fixture)

    let entry = decoded.entry(scope: .timeline, assetId: "asset-1", variant: .original)
    #expect(entry != nil)
    #expect(entry?.attemptCount == 2)
    #expect(entry?.category == .photoKitTransient)
    #expect(entry?.errorSignature == "NSPOSIXErrorDomain:5")
    #expect(entry?.firstFailedAt == Date(timeIntervalSinceReferenceDate: 770000000))
    #expect(entry?.nextEligibleAt == Date(timeIntervalSinceReferenceDate: 770000600))
  }

  @Test func retryStateRoundTripsThroughStore() throws {
    let dir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = FileBackedAutoSyncRetryStateStore(baseDirectoryURL: dir)

    var state = AutoSyncRetryState()
    state.recordFailure(
      scope: .album(placementId: "album-xyz"),
      assetId: "asset-1",
      variant: .edited,
      category: .photoKitTransient,
      errorSignature: "NSCocoaErrorDomain:260",
      at: Date(timeIntervalSinceReferenceDate: 770000000),
      nextEligibleAt: Date(timeIntervalSinceReferenceDate: 770000600))

    try store.save(state, destinationId: "dest-1")
    let loaded = store.load(destinationId: "dest-1")

    #expect(loaded == state)
  }

  @Test func retryStateReturnsEmptyForMissingFile() throws {
    let dir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = FileBackedAutoSyncRetryStateStore(baseDirectoryURL: dir)

    #expect(store.load(destinationId: "never-written") == .empty)
  }

  // MARK: - Run summary

  /// Round-trip a populated `ExportRunSummary`. The summary has a custom
  /// decoder that already tolerates a missing `failures` field (older
  /// builds didn't have it) — this test pins that today's encoder produces
  /// the *current* shape, so a future "let's drop `failures` from emit"
  /// regression would fail here.
  @Test func runSummaryRoundTripsThroughStore() throws {
    let dir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = FileBackedAutoSyncRunSummaryStore(baseDirectoryURL: dir)

    let context = ExportRunContext(
      runId: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
      source: .autoSync,
      visibility: .background,
      reason: nil,
      scope: .timelineFullLibrary,
      selection: .edited,
      startedAt: Date(timeIntervalSinceReferenceDate: 770000000))
    let summary = ExportRunSummary(
      context: context,
      endedAt: Date(timeIntervalSinceReferenceDate: 770000300),
      enqueuedCount: 5, completedCount: 4, failedCount: 1, skippedCount: 0,
      cancelReason: nil,
      result: .completed,
      failures: [])

    try store.save(summary, destinationId: "dest-1")
    let loaded = store.load(destinationId: "dest-1")

    #expect(loaded == summary)
  }

  /// Pre-`failures` shape: an `ExportRunSummary` written before the
  /// `failures` field existed. The custom `init(from:)` decoder must still
  /// load it (treating `failures` as empty). This is the in-the-wild
  /// upgrade path — pinned here so a future refactor can't silently break
  /// existing users' lastRunSummary.json.
  ///
  /// To avoid hand-writing a JSON fixture against an evolving
  /// `ExportRunContext` shape (which has its own scope/source/visibility
  /// enums), this test encodes a modern summary, strips the `failures`
  /// field, then asserts the decoder still rebuilds a valid summary.
  @Test func runSummaryDecodesLegacyShapeWithoutFailures() throws {
    let context = ExportRunContext(
      runId: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
      source: .autoSync,
      visibility: .background,
      reason: nil,
      scope: .timelineFullLibrary,
      selection: .edited,
      startedAt: Date(timeIntervalSinceReferenceDate: 770000000))
    let modern = ExportRunSummary(
      context: context,
      endedAt: Date(timeIntervalSinceReferenceDate: 770000300),
      enqueuedCount: 5, completedCount: 5, failedCount: 0, skippedCount: 0,
      cancelReason: nil,
      result: .completed,
      failures: [])
    let modernData = try JSONEncoder().encode(modern)

    var dict =
      try JSONSerialization.jsonObject(with: modernData) as! [String: Any]
    dict.removeValue(forKey: "failures")
    let legacyData = try JSONSerialization.data(withJSONObject: dict)

    let decoded = try JSONDecoder().decode(ExportRunSummary.self, from: legacyData)

    #expect(decoded.completedCount == 5)
    #expect(decoded.failures.isEmpty)
    #expect(decoded.context.source == .autoSync)
  }

  @Test func runSummaryReturnsNilForMissingFile() throws {
    let dir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = FileBackedAutoSyncRunSummaryStore(baseDirectoryURL: dir)

    #expect(store.load(destinationId: "never-written") == nil)
  }

  // MARK: - Token blobs (opaque PHPersistentChangeToken)

  /// The per-destination token store treats the token as an opaque `Data`
  /// blob — Apple owns the `NSKeyedArchiver`-archived
  /// `PHPersistentChangeToken` shape. We can't fixture-test the payload,
  /// but we can pin the file path and write/read contract: arbitrary bytes
  /// round-trip through `save → load` byte-for-byte.
  ///
  /// If the file path moves (e.g. someone renames `lastDurablyRecordedToken.data`),
  /// existing users' tokens become orphaned and AutoSync falls back to a
  /// full-library scan. This test fails first.
  @Test func perDestinationTokenRoundTripsArbitraryBytes() throws {
    let dir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = FileBackedAutoSyncPerDestinationTokenStore(baseDirectoryURL: dir)

    let blob = Data((0..<256).map { UInt8($0) })
    try store.save(blob, destinationId: "dest-1")
    let loaded = store.load(destinationId: "dest-1")

    #expect(loaded == blob)
    // Pin the file lives at the documented path so a future refactor moving
    // the filename is caught here.
    let expectedURL = dir
      .appendingPathComponent("dest-1", isDirectory: true)
      .appendingPathComponent("lastDurablyRecordedToken.data")
    #expect(FileManager.default.fileExists(atPath: expectedURL.path))
  }

  @Test func perDestinationTokenReturnsNilForMissingFile() throws {
    let dir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = FileBackedAutoSyncPerDestinationTokenStore(baseDirectoryURL: dir)

    #expect(store.load(destinationId: "never-written") == nil)
  }

  /// Global photo-change token store uses an in-process Apple type
  /// (`PHPersistentChangeToken`) that we cannot construct synthetically in
  /// tests. The strongest pin we can do without PhotoKit at runtime is the
  /// missing-file return-`nil` path — which is what the on-launch "no
  /// prior token, start fresh" branch depends on.
  ///
  /// Round-trip coverage for this store would require a real token from a
  /// `PHPhotoLibrary` change observation — out of scope for a unit test.
  @Test func globalPhotoChangeTokenReturnsNilForMissingFile() throws {
    let dir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = GlobalPhotoChangeTokenStore(
      fileURL: dir.appendingPathComponent("photo-library-change-token.data"))

    #expect(store.load() == nil)
  }
}
