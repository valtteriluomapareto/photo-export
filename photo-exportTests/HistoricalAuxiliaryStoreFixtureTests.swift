import CryptoKit
import Foundation
import Testing

@testable import Photo_Export

@MainActor
struct HistoricalAuxiliaryStoreFixtureTests {
  private static let checkout = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent()
  private static let fixtureRoot = checkout.appendingPathComponent("test-fixtures/persistence")
  private static let metadataTags = ["v1.3.0", "v1.6.5"]
  private static let journalTags = ["v1.6.1", "v1.6.5"]
  private let date = Date(timeIntervalSinceReferenceDate: 700_000_000)

  private struct Manifest: Decodable {
    struct Generation: Decodable {
      let commit: String
      let releaseURL: String
      let toolchain: String
      let hostRuntime: String
      let target: String
      let sources: [String: String]
      let harnesses: [String: String]
      let defines: [String]
      let preferencesTransport: String
      let files: [String: String]
    }
    let auxiliaryGenerations: [String: Generation]
  }

  private static func digest(_ bytes: Data) -> String {
    SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
  }

  private static func manifest() throws -> Manifest {
    try JSONDecoder().decode(
      Manifest.self, from: Data(contentsOf: fixtureRoot.appendingPathComponent("manifest.json")))
  }

  @MainActor
  private struct Fixture {
    let root: URL
    let originals: [URL: Data]

    init(tag: String) throws {
      let generation = try #require(
        try HistoricalAuxiliaryStoreFixtureTests.manifest().auxiliaryGenerations[tag])
      let source = HistoricalAuxiliaryStoreFixtureTests.fixtureRoot.appendingPathComponent(tag)
      var originals: [URL: Data] = [:]
      for (relative, expected) in generation.files {
        let url = source.appendingPathComponent(relative)
        let bytes = try Data(contentsOf: url)
        try #require(HistoricalAuxiliaryStoreFixtureTests.digest(bytes) == expected)
        originals[url] = bytes
      }
      self.originals = originals
      root = TestScratch.directory("HistoricalAuxiliary")
      try FileManager.default.copyItem(at: source.appendingPathComponent("auxiliary"), to: root)
    }

    var destinations: URL { root.appendingPathComponent("AutoSync/destinations") }

    func preferences() throws -> [String: Any] {
      try #require(
        PropertyListSerialization.propertyList(
          from: Data(contentsOf: root.appendingPathComponent("preferences.plist")),
          format: nil) as? [String: Any])
    }

    func cleanup() {
      for (url, bytes) in originals {
        #expect(
          (try? Data(contentsOf: url)) == bytes, "Immutable released fixture changed: \(url.path)")
      }
      try? FileManager.default.removeItem(at: root)
    }
  }

  @Test func additionalWriterProvenanceAndCompleteInventoryArePinned() throws {
    let generations = try Self.manifest().auxiliaryGenerations
    let commits = [
      "v1.3.0": "63e3b0f7f934054781b96f68190900f00b316144",
      "v1.6.1": "93e0b8035f7b31c19ca89537be26ba77387068c0",
      "v1.6.5": "0b0eb9b786311a961f9051d14e2e93cb0ecca135",
    ]
    #expect(Set(generations.keys) == Set(commits.keys))
    let metadataFiles: Set<String> = [
      "A/dirtyState.json", "B/dirtyState.json", "A/retryState.json", "B/retryState.json",
      "A/lastRunSummary.json", "B/lastRunSummary.json", "A/lastDurablyRecordedToken.data",
      "B/lastDurablyRecordedToken.data", "A/safetyRecord.json",
    ]
    for (tag, generation) in generations {
      #expect(generation.commit == commits[tag])
      #expect(
        generation.releaseURL
          == "https://github.com/valtteriluomapareto/photo-export/releases/tag/\(tag)")
      #expect(!generation.toolchain.isEmpty && !generation.hostRuntime.isEmpty)
      #expect(generation.target.hasSuffix("-apple-macos15.0"))
      #expect(!generation.sources.isEmpty)
      #expect(generation.sources.values.allSatisfy { $0.count == 64 })
      #expect(generation.preferencesTransport.contains("bookmarks excluded"))
      #expect(generation.defines == (tag == "v1.6.5" ? ["RELEASE_MODERN"] : []))
      let harnessNames: Set<String> =
        tag == "v1.3.0"
        ? ["auxiliary-stores.swift"]
        : tag == "v1.6.1"
          ? ["current-run.swift"]
          : ["auxiliary-stores.swift", "current-run.swift"]
      #expect(Set(generation.harnesses.keys) == harnessNames)
      for (name, hash) in generation.harnesses {
        let harness = Self.checkout.appendingPathComponent("scripts/fixtures/\(name)")
        #expect(Self.digest(try Data(contentsOf: harness)) == hash)
      }
      var expected: Set<String> = []
      if Self.metadataTags.contains(tag) {
        expected.formUnion(metadataFiles.map { "auxiliary/AutoSync/destinations/" + $0 })
        expected.insert("auxiliary/preferences.plist")
      }
      if Self.journalTags.contains(tag) {
        expected.formUnion(
          ["A", "B"].map { "auxiliary/AutoSync/destinations/\($0)/currentRun.json" })
      }
      #expect(Set(generation.files.keys) == expected)
      let releaseRoot = Self.fixtureRoot.appendingPathComponent(tag)
      let auxiliaryRoot = releaseRoot.appendingPathComponent("auxiliary")
      let paths = try FileManager.default.subpathsOfDirectory(atPath: auxiliaryRoot.path)
      let actual = Set(
        paths.filter {
          (try? auxiliaryRoot.appendingPathComponent($0).resourceValues(forKeys: [.isRegularFileKey]
          )
          .isRegularFile) == true
        }.map { "auxiliary/" + $0 })
      #expect(actual == expected)
      for (relative, hash) in generation.files {
        #expect(
          Self.digest(try Data(contentsOf: releaseRoot.appendingPathComponent(relative))) == hash)
      }
    }
  }

  @Test(arguments: metadataTags)
  func dirtyRetrySummaryTokenAndSafetyLoadReleasedStateTwice(tag: String) throws {
    let fixture = try Fixture(tag: tag)
    defer { fixture.cleanup() }
    for _ in 0..<2 {
      let dirty = FileBackedAutoSyncDirtyStateStore(baseDirectoryURL: fixture.destinations)
      let a = try dirty.load(destinationId: "A")
      #expect(Set(a.scopes.keys) == ["timeline", "favorites", "albums"])
      #expect(a.lastUpdatedAt == date)
      #expect(a.scope(.timeline) == ScopeDirtyState(pendingAssetIds: ["asset-a", "asset-b"]))
      #expect(a.scope(.favorites) == ScopeDirtyState(pendingFullReconciliation: true))
      #expect(a.scope(.albums) == ScopeDirtyState(pendingPlacementReconciliation: true))
      let b = try dirty.load(destinationId: "B")
      #expect(Set(b.scopes.keys) == ["timeline"])
      #expect(b.scope(.timeline) == ScopeDirtyState(pendingAssetIds: ["asset-other"]))
      #expect(b.lastUpdatedAt == date.addingTimeInterval(100))

      let retries = FileBackedAutoSyncRetryStateStore(baseDirectoryURL: fixture.destinations)
      let retryA = try retries.load(destinationId: "A")
      let transient = RetryEntry(
        category: .photoKitTransient, errorSignature: "NSPOSIXErrorDomain:5", attemptCount: 3,
        firstFailedAt: date, lastFailedAt: date.addingTimeInterval(60),
        nextEligibleAt: date.addingTimeInterval(660))
      let hard = RetryEntry(
        category: .destinationPermission, errorSignature: "NSCocoaErrorDomain:513", attemptCount: 2,
        firstFailedAt: date, lastFailedAt: date.addingTimeInterval(30), nextEligibleAt: nil)
      #expect(retryA.entry(scope: .timeline, assetId: "asset-a", variant: .original) == transient)
      #expect(retryA.entry(scope: .favorites, assetId: "asset-a", variant: .edited) == hard)
      #expect(
        retryA.entry(scope: .album(placementId: "album-a"), assetId: "asset-b", variant: .edited)
          == transient)
      #expect(
        Set(retryA.entriesByPlacement.keys)
          == (tag == "v1.6.5"
            ? ["timeline", "favorites", "album:album-a", "shared-album:shared-a"]
            : ["timeline", "favorites", "album:album-a"]))
      if tag == "v1.6.5" {
        #expect(
          retryA.entry(
            scope: .sharedAlbum(placementId: "shared-a"), assetId: "asset-c",
            variant: .originalPairedVideo) == hard)
      }
      let retryB = try retries.load(destinationId: "B")
      #expect(retryB.entriesByPlacement == ["timeline": ["asset-other": ["original": hard]]])
      #expect(retryB.entry(scope: .timeline, assetId: "asset-a", variant: .original) == nil)

      let summaries = FileBackedAutoSyncRunSummaryStore(baseDirectoryURL: fixture.destinations)
      let summary = try #require(summaries.load(destinationId: "A"))
      #expect(summary.context.runId == UUID(uuidString: "11111111-2222-3333-4444-555555555555"))
      #expect(summary.context.source == .autoSync && summary.context.visibility == .background)
      #expect(summary.context.reason == .photosChanged)
      #expect(summary.context.scope == .timelineAssets(["asset-a", "asset-b"]))
      #expect(summary.context.selection == .editedWithOriginals)
      #expect(summary.context.startedAt == date)
      #expect(summary.endedAt == date.addingTimeInterval(90))
      #expect(summary.enqueuedCount == 8 && summary.completedCount == 4)
      #expect(summary.failedCount == 1 && summary.skippedCount == 3)
      #expect(summary.cancelReason == nil && summary.result == .failed)
      #expect(summary.stoppedBy == nil)
      let failure = try #require(summary.failures.first)
      #expect(summary.failures.count == 1)
      #expect(failure.assetId == "asset-a" && failure.variant == .edited)
      #expect(
        failure.placement.id == "collections:favorites" && failure.placement.kind == .favorites)
      #expect(failure.placement.createdAt == date)
      #expect(failure.placement.displayName == "Favorites")
      #expect(failure.placement.relativePath == "Collections/Favorites/")
      #expect(failure.placement.collectionLocalIdentifier == nil)
      #expect(
        failure.category == .photoKitTransient && failure.errorSignature == "NSPOSIXErrorDomain:5")
      #expect(failure.localizedDescription == "Synthetic read failure")
      #expect(failure.failedAt == date.addingTimeInterval(60))
      let other = try #require(summaries.load(destinationId: "B"))
      #expect(other.context.runId == UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"))
      #expect(other.context.source == .manual && other.context.visibility == .userVisible)
      #expect(other.context.reason == nil && other.context.scope == .favoritesFull)
      #expect(other.context.selection == .edited)
      #expect(other.context.startedAt == date.addingTimeInterval(100))
      #expect(other.endedAt == date.addingTimeInterval(120))
      #expect(other.enqueuedCount == 2 && other.completedCount == 1)
      #expect(other.failedCount == 0 && other.skippedCount == 0)
      #expect(other.cancelReason == .userCancelled && other.result == .cancelled)
      #expect(other.failures.isEmpty && other.stoppedBy == nil)

      let tokens = FileBackedAutoSyncPerDestinationTokenStore(
        baseDirectoryURL: fixture.destinations)
      #expect(tokens.load(destinationId: "A") == Data([0, 1, 127, 128, 254, 255]))
      #expect(tokens.load(destinationId: "B") == Data("synthetic-token-B".utf8))
      let safety = FileBackedDestinationSafetyConfirmationStore(
        baseDirectoryURL: fixture.destinations)
      #expect(safety.isConfirmed(destinationId: "A"))
      #expect(!safety.isConfirmed(destinationId: "B"))
    }
  }

  @Test(arguments: journalTags)
  func journalsPreserveActiveAndNotYetStartedScopesOnTwoOpens(tag: String) throws {
    let fixture = try Fixture(tag: tag)
    defer { fixture.cleanup() }
    for _ in 0..<2 {
      let store = FileBackedAutoSyncCurrentRunStore(baseDirectoryURL: fixture.destinations)
      #expect(
        store.load(destinationId: "A")
          == AutoSyncRunJournal(
            startedAt: date, trigger: "photosChanged", scopes: ["timeline", "favorites", "albums"],
            currentScope: "favorites", currentScopeStartedAt: date.addingTimeInterval(30)))
      #expect(
        store.load(destinationId: "B")
          == AutoSyncRunJournal(
            startedAt: date.addingTimeInterval(100), trigger: "appLaunch", scopes: ["albums"],
            currentScope: nil, currentScopeStartedAt: nil))
    }
  }

  @Test(arguments: metadataTags)
  func scopePreferenceLoadsReleasedPayloadOnTwoOpens(tag: String) throws {
    let fixture = try Fixture(tag: tag)
    defer { fixture.cleanup() }
    let payload = try fixture.preferences()
    let keys: Set<String> =
      tag == "v1.6.5"
      ? ["AutoSync.scopeSelection", "ExportDestinationStableId"] : ["AutoSync.scopeSelection"]
    #expect(Set(payload.keys) == keys)
    let suite = TestScratch.suiteName("HistoricalScopes")
    let defaults = TestScratch.defaults(suiteName: suite)
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.setPersistentDomain(payload, forName: suite)
    for _ in 0..<2 {
      let reopened = TestScratch.defaults(suiteName: suite)
      let store = UserDefaultsAutoExportScopeStore(userDefaults: reopened)
      #expect(store.selection.timeline)
      #expect(!store.selection.favorites)
      #expect(store.selection.albums)
      #expect(store.selection.sharedAlbums == (tag == "v1.6.5"))
      #expect(
        reopened.data(forKey: "AutoSync.scopeSelection") == payload["AutoSync.scopeSelection"]
          as? Data)
    }
  }

  @Test func stableIdWrittenByReleasedManagerSurvivesFingerprintDriftAndReopen() async throws {
    let fixture = try Fixture(tag: "v1.6.5")
    defer { fixture.cleanup() }
    let payload = try fixture.preferences()
    let expected = "80762ef2ffdb41934b5c56ed352709048977a0ff129a3efaabc07b88d73f0234"
    #expect(payload["ExportDestinationStableId"] as? String == expected)
    let suite = TestScratch.suiteName("HistoricalDestination")
    let defaults = TestScratch.defaults(suiteName: suite)
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.setPersistentDomain(payload, forName: suite)
    let folder = fixture.root.appendingPathComponent("current-destination", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    for path in ["/synthetic/remounted-A", "/synthetic/remounted-B"] {
      let fingerprint = DestinationFingerprint.makeLow(
        volumeRootPath: nil, relativePathFromVolumeRoot: path, standardizedPath: path)
      let manager = ExportDestinationManager(
        skipRestore: true, userDefaults: TestScratch.defaults(suiteName: suite),
        fingerprintProvider: { _ in fingerprint }, bookmarkSaver: { _ in true },
        volumeNotificationCenter: NotificationCenter(), validationScopeAcquirer: { _ in true },
        validationScopeReleaser: { _ in })
      #expect(manager.applyFolderSelection(folder, decision: .sameDestination))
      await manager.waitForValidation()
      #expect(manager.isAvailable)
      #expect(manager.destinationId == expected)
      #expect(manager.destinationId != fingerprint.id)
      #expect(defaults.string(forKey: "ExportDestinationStableId") == expected)
    }
  }
}
