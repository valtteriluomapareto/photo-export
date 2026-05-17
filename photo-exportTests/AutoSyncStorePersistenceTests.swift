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
/// Each store gets three classes of test:
///   1. **Fixture decode** — a known-good JSON byte sequence (committed inline
///      below) must decode to the expected typed state. Catches accidental
///      field renames / removals during refactors. This is the strongest pin
///      because the fixture is independent of the current encoder.
///   2. **Round-trip via store** — `save → load` returns an equal value.
///      Catches load-side regression that produces `.empty` for a valid file
///      written by the current encoder. Asserts decoded equality only, not
///      raw bytes, so non-correctness encoder flags (`.sortedKeys`,
///      `.prettyPrinted`) are not pinned here — that's the byte-format pin's
///      job.
///   3. **File path pin** — the documented filename appears at the expected
///      location after `save`. Catches a refactor that renames the file and
///      silently orphans existing users' state.
///
/// Two `Data`-blob stores have no fixture (`PHPersistentChangeToken`'s
/// NSKeyedArchiver shape is Apple-owned), so they get path-pin + missing-file
/// + corrupt-blob coverage only.
@MainActor
struct AutoSyncStorePersistenceTests {

  // MARK: - Helpers

  /// Allocates a unique temp directory, runs `body` with it, and removes it
  /// on scope exit (including throws). Replaces 10 copies of the same
  /// allocate/defer pattern that the prior iteration of this file carried.
  private func withTempDirectory(_ body: (URL) throws -> Void) throws {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("AutoSyncStorePersistenceTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try body(dir)
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

  /// Round-trip via the store and pin the file path. Catches load-side
  /// regression that produces `.empty` for a valid file, and refactors that
  /// rename `dirtyState.json` (silently orphans existing users' state).
  @Test func dirtyStateRoundTripsAndLivesAtDocumentedPath() throws {
    try withTempDirectory { dir in
      let store = FileBackedAutoSyncDirtyStateStore(baseDirectoryURL: dir)
      var state = AutoSyncDirtyState()
      state.setScope(.timeline, ScopeDirtyState(pendingAssetIds: ["a", "b"]))
      state.setScope(.albums, ScopeDirtyState(pendingPlacementReconciliation: true))
      state.markUpdated(at: Date(timeIntervalSinceReferenceDate: 770000000))

      try store.save(state, destinationId: "dest-1")

      #expect(store.load(destinationId: "dest-1") == state)
      let expectedURL = dir
        .appendingPathComponent("dest-1", isDirectory: true)
        .appendingPathComponent("dirtyState.json")
      #expect(
        FileManager.default.fileExists(atPath: expectedURL.path),
        "dirtyState.json must live at <base>/<destId>/dirtyState.json — rename here orphans existing users' state")
    }
  }

  /// Missing file produces `.empty` rather than throwing — the on-launch
  /// "nothing to recover" path. Pins the no-file behavior so a future
  /// refactor doesn't accidentally throw and block AutoSync startup.
  @Test func dirtyStateReturnsEmptyForMissingFile() throws {
    try withTempDirectory { dir in
      let store = FileBackedAutoSyncDirtyStateStore(baseDirectoryURL: dir)
      #expect(store.load(destinationId: "never-written") == .empty)
    }
  }

  /// Production explicitly sets `.sortedKeys` and `.prettyPrinted` on the
  /// encoder so diffing tooling and any future "skip-write-if-equal"
  /// optimization stay meaningful (see the comment at
  /// `FileBackedAutoSyncDirtyStateStore.save`). A regression that drops
  /// either flag isn't caught by the round-trip test (which only asserts
  /// decoded equality), so this byte-format pin reads the file back and
  /// asserts: (a) keys are alphabetised, (b) the file is multi-line.
  @Test func dirtyStateEncodedBytesAreSortedAndPrettyPrinted() throws {
    try withTempDirectory { dir in
      let store = FileBackedAutoSyncDirtyStateStore(baseDirectoryURL: dir)
      var state = AutoSyncDirtyState()
      state.setScope(.timeline, ScopeDirtyState(pendingAssetIds: ["a"]))
      try store.save(state, destinationId: "dest-1")

      let url = dir.appendingPathComponent("dest-1", isDirectory: true)
        .appendingPathComponent("dirtyState.json")
      let raw = try String(contentsOf: url, encoding: .utf8)

      #expect(raw.contains("\n"), "encoder must keep .prettyPrinted")
      let lastUpdatedRange = raw.range(of: "\"lastUpdatedAt\"")
      let scopesRange = raw.range(of: "\"scopes\"")
      #expect(lastUpdatedRange != nil && scopesRange != nil)
      if let l = lastUpdatedRange, let s = scopesRange {
        #expect(
          l.lowerBound < s.lowerBound,
          "encoder must keep .sortedKeys — `lastUpdatedAt` must appear before `scopes` alphabetically")
      }
    }
  }

  // MARK: - Retry state

  /// Fixture: a populated `AutoSyncRetryState` with a single retry entry
  /// across the `timeline:<assetId>:<variant>` triple. Locks in the
  /// nested-dictionary shape `[scopeKey: [assetId: [variant: RetryEntry]]]`
  /// and every `RetryEntry` field, so a Codable change fails this test
  /// before existing users lose their retry backoff state.
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
    #expect(entry?.lastFailedAt == Date(timeIntervalSinceReferenceDate: 770000300))
    #expect(entry?.nextEligibleAt == Date(timeIntervalSinceReferenceDate: 770000600))
  }

  /// The `shared-album:` and `album:` scope-key prefixes are intentionally
  /// distinct so `AutoSyncRetryScopeKey.init?(rawValue:)` can disambiguate
  /// them. Production code parses the raw key only at read time (after
  /// JSON decode produces a plain `[String: …]`). This test pins the
  /// persisted form: an entry written under `shared-album:foo` survives
  /// decode and is recoverable via `.sharedAlbum(placementId:)`, NOT
  /// silently misclassified as `.album(...)` or dropped.
  ///
  /// A regression in the prefix-ordering check at
  /// `AutoSyncRetryScopeKey.init?(rawValue:)` would strand persisted
  /// shared-album retries; this test catches it.
  @Test func retryStateDecodesSharedAlbumScopeKey() throws {
    let fixture = """
      {
        "entriesByPlacement" : {
          "shared-album:stream-42" : {
            "asset-1" : {
              "original" : {
                "attemptCount" : 1,
                "category" : "iCloudTransient",
                "errorSignature" : "icloud:timeout",
                "firstFailedAt" : 770000000,
                "lastFailedAt" : 770000000,
                "nextEligibleAt" : 770000300
              }
            }
          }
        }
      }
      """.data(using: .utf8)!

    let decoded = try JSONDecoder().decode(AutoSyncRetryState.self, from: fixture)

    #expect(
      decoded.entriesByPlacement["shared-album:stream-42"] != nil,
      "the raw shared-album: key must survive decode unchanged")
    let key = AutoSyncRetryScopeKey(rawValue: "shared-album:stream-42")
    #expect(key == .sharedAlbum(placementId: "stream-42"))
    #expect(
      decoded.entry(scope: .sharedAlbum(placementId: "stream-42"),
        assetId: "asset-1", variant: .original) != nil,
      "shared-album entries must round-trip through entry() lookup")
  }

  /// Pins the rawValue strings used as outer dictionary keys on disk.
  /// The retry state's persisted JSON keys are these strings — renaming
  /// `AutoSyncRetryScopeKey.timeline` to `.allTimeline` today would
  /// silently switch new entries to the new key while orphaning all
  /// existing `"timeline"` entries on disk. The decode tests pass
  /// through plain `String` dictionary keys and don't catch this; this
  /// test does.
  @Test func retryScopeKeyRawValuesAreStable() {
    #expect(AutoSyncRetryScopeKey.timeline.rawValue == "timeline")
    #expect(AutoSyncRetryScopeKey.favorites.rawValue == "favorites")
    #expect(
      AutoSyncRetryScopeKey.album(placementId: "p").rawValue == "album:p",
      "album rawValue prefix must stay `album:` — used as a key on disk")
    #expect(
      AutoSyncRetryScopeKey.sharedAlbum(placementId: "p").rawValue == "shared-album:p",
      "shared-album rawValue prefix must stay `shared-album:` — distinct from `album:`")
  }

  @Test func retryStateRoundTripsAndLivesAtDocumentedPath() throws {
    try withTempDirectory { dir in
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

      #expect(store.load(destinationId: "dest-1") == state)
      let expectedURL = dir
        .appendingPathComponent("dest-1", isDirectory: true)
        .appendingPathComponent("retryState.json")
      #expect(
        FileManager.default.fileExists(atPath: expectedURL.path),
        "retryState.json must live at <base>/<destId>/retryState.json")
    }
  }

  @Test func retryStateReturnsEmptyForMissingFile() throws {
    try withTempDirectory { dir in
      let store = FileBackedAutoSyncRetryStateStore(baseDirectoryURL: dir)
      #expect(store.load(destinationId: "never-written") == .empty)
    }
  }

  // MARK: - Run summary

  /// Round-trip + file-path pin for the `lastRunSummary.json` store. Uses
  /// an empty `failures` array; the non-empty case is covered separately
  /// (see `runSummaryRoundTripsWithNonEmptyFailures`).
  @Test func runSummaryRoundTripsAndLivesAtDocumentedPath() throws {
    try withTempDirectory { dir in
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

      #expect(store.load(destinationId: "dest-1") == summary)
      let expectedURL = dir
        .appendingPathComponent("dest-1", isDirectory: true)
        .appendingPathComponent("lastRunSummary.json")
      #expect(
        FileManager.default.fileExists(atPath: expectedURL.path),
        "lastRunSummary.json must live at <base>/<destId>/lastRunSummary.json")
    }
  }

  /// Pins the non-empty `failures` round-trip — encodes a summary with one
  /// `ExportRunFailureDetail`, reloads, and asserts equality. Without this,
  /// the field's actual on-disk encoding (including nested
  /// `ExportPlacement`, `AutoSyncFailureCategory` rawValue, etc.) is
  /// unpinned. The Export Issues UI and AutoSync's retry reducer both
  /// consume this field; a refactor that quietly drops a sub-field would
  /// leave them blind.
  @Test func runSummaryRoundTripsWithNonEmptyFailures() throws {
    try withTempDirectory { dir in
      let store = FileBackedAutoSyncRunSummaryStore(baseDirectoryURL: dir)
      let context = ExportRunContext(
        runId: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
        source: .autoSync,
        visibility: .background,
        reason: nil,
        scope: .timelineFullLibrary,
        selection: .edited,
        startedAt: Date(timeIntervalSinceReferenceDate: 770000000))
      let failure = ExportRunFailureDetail(
        assetId: "asset-1",
        placement: ExportPlacement.timeline(
          year: 2025, month: 2,
          createdAt: Date(timeIntervalSinceReferenceDate: 770000000)),
        variant: .original,
        category: .photoKitTransient,
        errorSignature: "NSPOSIXErrorDomain:5",
        localizedDescription: "Input/output error",
        failedAt: Date(timeIntervalSinceReferenceDate: 770000200))
      let summary = ExportRunSummary(
        context: context,
        endedAt: Date(timeIntervalSinceReferenceDate: 770000300),
        enqueuedCount: 1, completedCount: 0, failedCount: 1, skippedCount: 0,
        cancelReason: nil,
        result: .failed,
        failures: [failure])

      try store.save(summary, destinationId: "dest-1")
      #expect(store.load(destinationId: "dest-1") == summary)
    }
  }

  /// Backward-compat: today's decoder must tolerate a `lastRunSummary.json`
  /// written by a build that predated the `failures` field. The custom
  /// `init(from:)` decoder at `ExportRunContext.swift:79` uses
  /// `(try? c.decode(...)) ?? []` to default missing → empty.
  ///
  /// **What this test does pin**: today's decoder handles a JSON whose
  /// top-level object has no `failures` key.
  ///
  /// **What this test does NOT pin**: the *exact byte shape* of a real
  /// shipped pre-`failures` build. We derive the "legacy" JSON from
  /// today's encoder by stripping the field — so a Codable shape change
  /// on `ExportRunContext` or `ExportRunSummary` itself could still
  /// silently break decode of an actually-shipped legacy file. Adding a
  /// hand-authored fixture from a real pre-`failures` build would close
  /// that gap; doing so requires the byte sequence from a shipped
  /// version we don't have here.
  @Test func runSummaryDecoderHandlesMissingFailuresField() throws {
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
    let strippedData = try JSONSerialization.data(withJSONObject: dict)

    let decoded = try JSONDecoder().decode(ExportRunSummary.self, from: strippedData)

    #expect(decoded.completedCount == 5)
    #expect(decoded.failures.isEmpty)
    #expect(decoded.context.source == .autoSync)
  }

  @Test func runSummaryReturnsNilForMissingFile() throws {
    try withTempDirectory { dir in
      let store = FileBackedAutoSyncRunSummaryStore(baseDirectoryURL: dir)
      #expect(store.load(destinationId: "never-written") == nil)
    }
  }

  // MARK: - Token blobs (opaque PHPersistentChangeToken)

  /// The per-destination token store treats the token as an opaque `Data`
  /// blob — Apple owns the `NSKeyedArchiver`-archived
  /// `PHPersistentChangeToken` shape. We can't fixture-test the payload,
  /// but we can pin the file path and write/read contract: arbitrary bytes
  /// round-trip through `save → load` byte-for-byte, and the file ends up
  /// at the documented location.
  @Test func perDestinationTokenRoundTripsAndLivesAtDocumentedPath() throws {
    try withTempDirectory { dir in
      let store = FileBackedAutoSyncPerDestinationTokenStore(baseDirectoryURL: dir)
      let blob = Data((0..<256).map { UInt8($0) })

      try store.save(blob, destinationId: "dest-1")

      #expect(store.load(destinationId: "dest-1") == blob)
      let expectedURL = dir
        .appendingPathComponent("dest-1", isDirectory: true)
        .appendingPathComponent("lastDurablyRecordedToken.data")
      #expect(
        FileManager.default.fileExists(atPath: expectedURL.path),
        "lastDurablyRecordedToken.data must live at the documented path — rename orphans existing users' tokens")
    }
  }

  @Test func perDestinationTokenReturnsNilForMissingFile() throws {
    try withTempDirectory { dir in
      let store = FileBackedAutoSyncPerDestinationTokenStore(baseDirectoryURL: dir)
      #expect(store.load(destinationId: "never-written") == nil)
    }
  }

  /// The global photo-change token store unarchives a `PHPersistentChangeToken`
  /// via `NSKeyedUnarchiver.unarchivedObject(ofClass:from:)`. We can't
  /// construct a valid synthetic token in a unit test (Apple owns the type),
  /// but we can:
  ///   1. Pin the documented file path — `<base>/photo-library-change-token.data`.
  ///   2. Exercise the decode-failure → nil path by writing non-archive bytes
  ///      to that path and asserting `load() == nil`. Without this, the
  ///      missing-file return-nil path was the only thing exercised and a
  ///      refactor that throws on decode failure (instead of logging + nil)
  ///      would silently crash the app on launch for users with corrupt
  ///      tokens.
  @Test func globalPhotoChangeTokenReturnsNilForCorruptFile() throws {
    try withTempDirectory { dir in
      let tokenURL = dir.appendingPathComponent("photo-library-change-token.data")
      let store = GlobalPhotoChangeTokenStore(fileURL: tokenURL)

      // Write a deliberately-not-NSKeyedArchiver byte sequence.
      try Data("not an archive blob".utf8).write(to: tokenURL)

      #expect(
        store.load() == nil,
        "load() must return nil on decode failure rather than throw — protects launch when on-disk token is corrupt")
    }
  }

  @Test func globalPhotoChangeTokenReturnsNilForMissingFile() throws {
    try withTempDirectory { dir in
      let tokenURL = dir.appendingPathComponent("photo-library-change-token.data")
      let store = GlobalPhotoChangeTokenStore(fileURL: tokenURL)
      #expect(store.load() == nil)
    }
  }
}
