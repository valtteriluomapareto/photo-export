import Foundation
import Testing

@testable import Photo_Export

/// #127 / destination-identity-simplification: the keying id is a **stable logical id**,
/// persisted beside the bookmark, seeded once from the fingerprint and reused verbatim
/// afterwards so a network-share remount that drifts the fingerprint does not re-key (and so
/// re-export) the destination. These tests drive `ExportDestinationManager` through its
/// injected `fingerprintProvider` / `sameFolderEvidenceProvider` seams.
///
/// They materialise a real folder under the sandbox temp dir and exercise the security-scope
/// path in `validate(url:)`, so they share the `BareTmpScopeProbe` disable guard with
/// `ExportDestinationManagerIdentityTests` — the CI macOS runner runs them.
@MainActor
struct StableDestinationIdentityTests {

  private func lowConfidence(_ path: String) -> DestinationFingerprint {
    .makeLow(volumeRootPath: nil, relativePathFromVolumeRoot: path, standardizedPath: path)
  }

  private func makeTempDir() throws -> URL {
    let dir = TestScratch.directory("StableId")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }

  private func makeDefaults() -> (
    UserDefaults, suite: String, bookmarkKey: String, stableKey: String
  ) {
    let suite = TestScratch.suiteName("StableId")
    return (
      TestScratch.defaults(suiteName: suite), suite,
      "Bookmark-\(UUID().uuidString)", "StableId-\(UUID().uuidString)"
    )
  }

  // MARK: - Reuse across remount drift

  @Test(
    .disabled(
      if: BareTmpScopeProbe.bareTmpRejectsScopeStart(),
      "Local macOS quirk: startAccessingSecurityScopedResource() returns false for bare container tmp URLs, tripping the #92 bail-out in validate(). The CI macOS runner returns true so this runs there."
    ))
  func stableIdReusedAcrossSimulatedRemountDrift() async throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let (defaults, suite, bookmarkKey, stableKey) = makeDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }

    var currentFP: DestinationFingerprint? = lowConfidence("/Volumes/mount-A/backup")
    let manager = ExportDestinationManager(
      skipRestore: true, userDefaults: defaults, bookmarkDefaultsKey: bookmarkKey,
      stableIdDefaultsKey: stableKey, fingerprintProvider: { _ in currentFP })

    await manager.persistSelectionAndWait(dir)
    let seeded = manager.destinationId
    #expect(seeded == currentFP?.id)  // seed == the fingerprint id at first validate
    #expect(defaults.string(forKey: stableKey) == seeded)  // frozen to defaults

    // Remount drift: same folder, different (low-confidence) fingerprint id.
    currentFP = lowConfidence("/Volumes/mount-B/backup")
    #expect(currentFP?.id != seeded)
    await manager.revalidateAndWait()

    #expect(manager.destinationId == seeded)  // reused verbatim, NOT re-derived — the #127 fix
    #expect(manager.identity.fingerprint == currentFP)  // advisory fingerprint refreshed
    #expect(defaults.string(forKey: stableKey) == seeded)  // persisted id unchanged
  }

  // MARK: - Upgrade seeding

  @Test(
    .disabled(
      if: BareTmpScopeProbe.bareTmpRejectsScopeStart(),
      "Local macOS scope quirk; runs on the CI macOS runner."))
  func highConfidenceAbsentIdSeedsToFingerprintId() async throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let (defaults, suite, bookmarkKey, stableKey) = makeDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }

    let highFP = DestinationFingerprint.makeHigh(
      volumeUUIDString: "uuid-ext-drive", volumeRootPath: "/Volumes/Ext",
      relativePathFromVolumeRoot: "/backup", standardizedPath: "/Volumes/Ext/backup")
    let manager = ExportDestinationManager(
      skipRestore: true, userDefaults: defaults, bookmarkDefaultsKey: bookmarkKey,
      stableIdDefaultsKey: stableKey, fingerprintProvider: { _ in highFP })

    await manager.persistSelectionAndWait(dir)

    #expect(manager.destinationId == highFP.id)
    #expect(defaults.string(forKey: stableKey) == highFP.id)
  }

  @Test(
    .disabled(
      if: BareTmpScopeProbe.bareTmpRejectsScopeStart(),
      "Local macOS scope quirk; runs on the CI macOS runner."))
  func nilFingerprintAtValidateDefersSeedingThenSeedsWhenReadable() async throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let (defaults, suite, bookmarkKey, stableKey) = makeDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }

    // Drive reachable but resource keys unreadable → fingerprint nil → no seed.
    var currentFP: DestinationFingerprint?
    let manager = ExportDestinationManager(
      skipRestore: true, userDefaults: defaults, bookmarkDefaultsKey: bookmarkKey,
      stableIdDefaultsKey: stableKey, fingerprintProvider: { _ in currentFP })

    await manager.persistSelectionAndWait(dir)
    #expect(manager.destinationId == nil)  // seeding deferred
    #expect(defaults.string(forKey: stableKey) == nil)  // nothing persisted

    // Fingerprint becomes readable → seeds now.
    currentFP = lowConfidence("/Volumes/mount-A/backup")
    await manager.revalidateAndWait()
    #expect(manager.destinationId == currentFP?.id)
    #expect(defaults.string(forKey: stableKey) == currentFP?.id)
  }

  // MARK: - Unavailable invariant

  /// The load-bearing unplug→remount path: while unavailable the *published active* id is `nil`
  /// (so the lifecycle coordinator runs its destination-unavailable handling) but the persisted
  /// id is kept privately — so the SAME id returns on remount, even under a drifted path, rather
  /// than a fresh seed.
  @Test(
    .disabled(
      if: BareTmpScopeProbe.bareTmpRejectsScopeStart(),
      "Local macOS scope quirk; runs on the CI macOS runner."))
  func remountAfterUnavailableReusesSameStableIdWithoutReseeding() async throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let (defaults, suite, bookmarkKey, stableKey) = makeDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }

    var currentFP: DestinationFingerprint? = lowConfidence("/Volumes/mount-A/backup")
    let manager = ExportDestinationManager(
      skipRestore: true, userDefaults: defaults, bookmarkDefaultsKey: bookmarkKey,
      stableIdDefaultsKey: stableKey, fingerprintProvider: { _ in currentFP })
    await manager.persistSelectionAndWait(dir)
    let seeded = try #require(manager.destinationId)

    // Drive becomes unavailable (resource keys unreadable) → active id nil, persisted retained.
    currentFP = nil
    await manager.revalidateAndWait()
    #expect(manager.destinationId == nil)
    #expect(defaults.string(forKey: stableKey) == seeded)

    // Returns under a drifted path → the same id is reused, not re-seeded.
    currentFP = lowConfidence("/Volumes/mount-B/backup")
    await manager.revalidateAndWait()
    #expect(manager.destinationId == seeded)
  }

  /// `clearSelection` truly forgets the stable id — proven by re-selecting with a drifted
  /// fingerprint and observing a fresh seed (if clear had merely hidden it, the old id would be
  /// reused).
  @Test(
    .disabled(
      if: BareTmpScopeProbe.bareTmpRejectsScopeStart(),
      "Local macOS scope quirk; runs on the CI macOS runner."))
  func clearSelectionDropsStableIdSoNextSelectionReseeds() async throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let (defaults, suite, bookmarkKey, stableKey) = makeDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }

    var currentFP = lowConfidence("/Volumes/mount-A/backup")
    let manager = ExportDestinationManager(
      skipRestore: true, userDefaults: defaults, bookmarkDefaultsKey: bookmarkKey,
      stableIdDefaultsKey: stableKey, fingerprintProvider: { _ in currentFP })
    await manager.persistSelectionAndWait(dir)
    let seeded = try #require(manager.destinationId)
    #expect(defaults.string(forKey: stableKey) == seeded)

    manager.clearSelection()
    #expect(manager.destinationId == nil)
    #expect(defaults.string(forKey: stableKey) == nil)
    #expect(defaults.data(forKey: bookmarkKey) == nil)  // bookmark dropped too
    #expect(manager.isAvailable == false)
    #expect(manager.currentLegacyDestinationId() == nil)  // stashed legacy id cleared

    currentFP = lowConfidence("/Volumes/mount-Z/backup")
    await manager.persistSelectionAndWait(dir)
    #expect(manager.destinationId == currentFP.id)
    #expect(manager.destinationId != seeded)
  }

  // MARK: - Re-selection trap (bookmark equivalence, not path)

  /// Re-granting access to the **same** folder keeps the id — driven through the *real*
  /// `defaultSameFolderEvidence` (no injected evidence), so the `fileResourceIdentifier`
  /// comparison (not path) is what classifies it. The fingerprint is drifted between selections
  /// to prove the decision ignores the path entirely. This is the picker-path guard against the
  /// #127 duplicate re-export.
  @Test(
    .disabled(
      if: BareTmpScopeProbe.bareTmpRejectsScopeStart(),
      "Local macOS scope quirk; runs on the CI macOS runner."))
  func sameFolderReSelectionViaRealEvidenceKeepsStableId() async throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let (defaults, suite, bookmarkKey, stableKey) = makeDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }

    var currentFP = lowConfidence("/Volumes/mount-A/backup")
    // No injected evidence provider — exercise the real bookmark-identity comparison.
    let manager = ExportDestinationManager(
      skipRestore: true, userDefaults: defaults, bookmarkDefaultsKey: bookmarkKey,
      stableIdDefaultsKey: stableKey, fingerprintProvider: { _ in currentFP })
    await manager.persistSelectionAndWait(dir)
    let seeded = try #require(manager.destinationId)

    currentFP = lowConfidence("/Volumes/mount-B/backup")  // path drift between selections
    await manager.selectFolderAndWait(dir)

    #expect(manager.destinationId == seeded)
  }

  /// Re-selecting a **genuinely different** folder mints a fresh id — also through the real
  /// evidence path (stored bookmark resolves to dirA, pick is dirB → different file identity).
  @Test(
    .disabled(
      if: BareTmpScopeProbe.bareTmpRejectsScopeStart(),
      "Local macOS scope quirk; runs on the CI macOS runner."))
  func differentFolderReSelectionViaRealEvidenceMintsNewId() async throws {
    let dirA = try makeTempDir()
    let dirB = try makeTempDir()
    defer {
      try? FileManager.default.removeItem(at: dirA)
      try? FileManager.default.removeItem(at: dirB)
    }
    let (defaults, suite, bookmarkKey, stableKey) = makeDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }

    // Path-derived fingerprint so dirA and dirB seed distinct ids.
    let manager = ExportDestinationManager(
      skipRestore: true, userDefaults: defaults, bookmarkDefaultsKey: bookmarkKey,
      stableIdDefaultsKey: stableKey,
      fingerprintProvider: { url in self.lowConfidence(url.path) })
    await manager.persistSelectionAndWait(dirA)
    let seededA = try #require(manager.destinationId)

    await manager.selectFolderAndWait(dirB)

    #expect(manager.destinationId != seededA)
  }

  // MARK: - Ambiguous selection (injected resolver)

  /// When the stored bookmark won't resolve, the decision is delegated to the injected
  /// resolver (production shows an `NSAlert`). Resolving as "same" keeps the id even under a
  /// drifted fingerprint.
  @Test(
    .disabled(
      if: BareTmpScopeProbe.bareTmpRejectsScopeStart(),
      "Local macOS scope quirk; runs on the CI macOS runner."))
  func ambiguousSelectionResolvedAsSameKeepsStableId() async throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let (defaults, suite, bookmarkKey, stableKey) = makeDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }

    var currentFP = lowConfidence("/Volumes/mount-A/backup")
    let manager = ExportDestinationManager(
      skipRestore: true, userDefaults: defaults, bookmarkDefaultsKey: bookmarkKey,
      stableIdDefaultsKey: stableKey, fingerprintProvider: { _ in currentFP },
      sameFolderEvidenceProvider: { _ in .ambiguous },
      ambiguityResolver: { _ in .sameDestination })
    await manager.persistSelectionAndWait(dir)
    let seeded = try #require(manager.destinationId)

    currentFP = lowConfidence("/Volumes/mount-B/backup")
    await manager.selectFolderAndWait(dir)

    #expect(manager.destinationId == seeded)
  }

  /// Resolving an ambiguous pick as "different" mints a fresh id.
  @Test(
    .disabled(
      if: BareTmpScopeProbe.bareTmpRejectsScopeStart(),
      "Local macOS scope quirk; runs on the CI macOS runner."))
  func ambiguousSelectionResolvedAsNewMintsStableId() async throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let (defaults, suite, bookmarkKey, stableKey) = makeDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }

    var currentFP = lowConfidence("/Volumes/mount-A/backup")
    let manager = ExportDestinationManager(
      skipRestore: true, userDefaults: defaults, bookmarkDefaultsKey: bookmarkKey,
      stableIdDefaultsKey: stableKey, fingerprintProvider: { _ in currentFP },
      sameFolderEvidenceProvider: { _ in .ambiguous },
      ambiguityResolver: { _ in .newDestination })
    await manager.persistSelectionAndWait(dir)
    let seeded = try #require(manager.destinationId)

    currentFP = lowConfidence("/Volumes/mount-B/backup")
    await manager.selectFolderAndWait(dir)

    #expect(manager.destinationId == currentFP.id)
    #expect(manager.destinationId != seeded)
  }

  /// When the stored bookmark **won't resolve**, the real `defaultSameFolderEvidence` must report
  /// `.ambiguous` and delegate to the resolver rather than silently path-comparing (which on a
  /// remounted share would fork the id). Uses the real evidence path (no injected provider);
  /// corrupt bookmark bytes force the unresolvable case deterministically.
  @Test(
    .disabled(
      if: BareTmpScopeProbe.bareTmpRejectsScopeStart(),
      "Local macOS scope quirk; runs on the CI macOS runner."))
  func unresolvableStoredBookmarkIsAmbiguousAndDelegatesToResolver() async throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let (defaults, suite, bookmarkKey, stableKey) = makeDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }

    let fp = lowConfidence("/Volumes/mount-A/backup")
    var resolverCalls = 0
    let manager = ExportDestinationManager(
      skipRestore: true, userDefaults: defaults, bookmarkDefaultsKey: bookmarkKey,
      stableIdDefaultsKey: stableKey, fingerprintProvider: { _ in fp },
      ambiguityResolver: { _ in
        resolverCalls += 1
        return .sameDestination
      })
    await manager.persistSelectionAndWait(dir)
    let seeded = try #require(manager.destinationId)

    // Corrupt the stored bookmark so `URL(resolvingBookmarkData:)` throws → `.ambiguous`.
    defaults.set(Data("not-a-bookmark".utf8), forKey: bookmarkKey)
    await manager.selectFolderAndWait(dir)

    #expect(resolverCalls == 1)  // routed through the ambiguity resolver
    #expect(manager.destinationId == seeded)  // resolver chose .sameDestination → id kept
  }

  /// First-ever selection through the **real** evidence path (no injected provider): empty
  /// defaults → `.noStoredBookmark` → `.newDestination` → seeds a fresh id.
  @Test(
    .disabled(
      if: BareTmpScopeProbe.bareTmpRejectsScopeStart(),
      "Local macOS scope quirk; runs on the CI macOS runner."))
  func firstEverSelectionViaRealEvidenceSeedsFreshId() async throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let (defaults, suite, bookmarkKey, stableKey) = makeDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }

    let fp = lowConfidence("/Volumes/mount-A/backup")
    let manager = ExportDestinationManager(
      skipRestore: true, userDefaults: defaults, bookmarkDefaultsKey: bookmarkKey,
      stableIdDefaultsKey: stableKey, fingerprintProvider: { _ in fp })

    await manager.selectFolderAndWait(dir)  // real evidence → .noStoredBookmark → seed

    #expect(manager.destinationId == fp.id)
    #expect(defaults.string(forKey: stableKey) == fp.id)
  }

  // MARK: - Restore (launch) reuse

  /// The launch path proves *reuse*, not re-derivation: a fresh manager restoring the bookmark
  /// reuses the persisted id verbatim even when the recomputed fingerprint has drifted. (The
  /// older restore tests reuse the same fingerprint, so they can't distinguish reuse from an
  /// identical re-seed.)
  @Test(
    .disabled(
      if: BareTmpScopeProbe.bareTmpRejectsScopeStart(),
      "Local macOS scope quirk; runs on the CI macOS runner."))
  func restoredManagerReusesPersistedStableIdUnderDriftedFingerprint() async throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let (defaults, suite, bookmarkKey, stableKey) = makeDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }

    let writer = ExportDestinationManager(
      skipRestore: true, userDefaults: defaults, bookmarkDefaultsKey: bookmarkKey,
      stableIdDefaultsKey: stableKey,
      fingerprintProvider: { _ in self.lowConfidence("/Volumes/mount-A/backup") })
    await writer.persistSelectionAndWait(dir)
    let seeded = try #require(writer.destinationId)

    // Fresh manager restores on launch (skipRestore defaults false) with a DRIFTED fingerprint.
    let driftedId = lowConfidence("/Volumes/mount-B/backup").id
    #expect(driftedId != seeded)
    let restored = ExportDestinationManager(
      userDefaults: defaults, bookmarkDefaultsKey: bookmarkKey, stableIdDefaultsKey: stableKey,
      fingerprintProvider: { _ in self.lowConfidence("/Volumes/mount-B/backup") })
    await restored.waitForValidation()

    #expect(restored.destinationId == seeded)  // reused, not re-derived from the drifted fp
  }

  // MARK: - Save-failure (P2) and scope-failure (P1)

  /// A failed `saveBookmark` on a `.newDestination` pick must NOT drop the prior destination's
  /// stable id — the clear happens only after a successful save. Otherwise a later
  /// validate/relaunch would reseed the old destination from a drifted fingerprint and re-key.
  @Test(
    .disabled(
      if: BareTmpScopeProbe.bareTmpRejectsScopeStart(),
      "Local macOS scope quirk; runs on the CI macOS runner."))
  func failedBookmarkSaveOnNewDestinationKeepsPriorStableId() async throws {
    let dirA = try makeTempDir()
    let dirB = try makeTempDir()
    defer {
      try? FileManager.default.removeItem(at: dirA)
      try? FileManager.default.removeItem(at: dirB)
    }
    let (defaults, suite, bookmarkKey, stableKey) = makeDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }

    var failSave = false
    let manager = ExportDestinationManager(
      skipRestore: true, userDefaults: defaults, bookmarkDefaultsKey: bookmarkKey,
      stableIdDefaultsKey: stableKey,
      fingerprintProvider: { _ in self.lowConfidence("/Volumes/mount-A/backup") },
      sameFolderEvidenceProvider: { _ in .differentFromStored },
      bookmarkSaver: { _ in !failSave })
    await manager.persistSelectionAndWait(dirA)
    let seeded = try #require(manager.destinationId)

    failSave = true
    await manager.selectFolderAndWait(dirB)  // .differentFromStored → .newDestination → save fails

    #expect(manager.destinationId == seeded)  // prior id NOT dropped
    #expect(defaults.string(forKey: stableKey) == seeded)
    #expect(manager.statusMessage == "Failed to save access to selected folder")
    #expect(manager.selectedFolderURL == dirA)  // still the old destination
  }

  /// P1: a stored bookmark that resolves but can't acquire scoped access (unplugged / stale /
  /// sandbox-denied) is `.ambiguous` — it must NOT fall through to a path comparison (which on a
  /// remounted share would fork the id). Delegates to the resolver.
  @Test(
    .disabled(
      if: BareTmpScopeProbe.bareTmpRejectsScopeStart(),
      "Local macOS scope quirk; runs on the CI macOS runner."))
  func resolvedButUnscopableStoredBookmarkIsAmbiguous() async throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let (defaults, suite, bookmarkKey, stableKey) = makeDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }

    var resolverCalls = 0
    let manager = ExportDestinationManager(
      skipRestore: true, userDefaults: defaults, bookmarkDefaultsKey: bookmarkKey,
      stableIdDefaultsKey: stableKey,
      fingerprintProvider: { _ in self.lowConfidence("/Volumes/mount-A/backup") },
      ambiguityResolver: { _ in
        resolverCalls += 1
        return .sameDestination
      },
      storedBookmarkScopeAcquirer: { _ in false })  // resolves, but scope can't be acquired
    await manager.persistSelectionAndWait(dir)
    let seeded = try #require(manager.destinationId)

    await manager.selectFolderAndWait(dir)  // real evidence: resolves but unscopable → .ambiguous

    #expect(resolverCalls == 1)
    #expect(manager.destinationId == seeded)  // resolver chose .sameDestination → kept
  }

  /// When file identity is unreadable (despite scoped access), an equal canonical path still
  /// keeps the id, but a *differing* path is `.ambiguous` (could be the same destination reached
  /// through a different path) and goes through the resolver — it must NOT silently mint a new id
  /// on a path difference, which would reintroduce the #127 duplicate re-export.
  @Test(
    .disabled(
      if: BareTmpScopeProbe.bareTmpRejectsScopeStart(),
      "Local macOS scope quirk; runs on the CI macOS runner."))
  func fileIdentityUnreadableKeepsIdOnSamePathAndIsAmbiguousOnDifferentPath() async throws {
    let dir = try makeTempDir()
    let other = try makeTempDir()
    defer {
      try? FileManager.default.removeItem(at: dir)
      try? FileManager.default.removeItem(at: other)
    }
    let (defaults, suite, bookmarkKey, stableKey) = makeDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }

    var resolverCalls = 0
    let manager = ExportDestinationManager(
      skipRestore: true, userDefaults: defaults, bookmarkDefaultsKey: bookmarkKey,
      stableIdDefaultsKey: stableKey,
      fingerprintProvider: { url in self.lowConfidence(url.path) },
      ambiguityResolver: { _ in
        resolverCalls += 1
        return .newDestination
      },
      fileIdentifierProvider: { _ in nil })  // force the path fallback
    await manager.persistSelectionAndWait(dir)
    let seeded = try #require(manager.destinationId)

    // Same canonical path → still `.sameAsStored`, no confirmation → keep id.
    await manager.selectFolderAndWait(dir)
    #expect(resolverCalls == 0)
    #expect(manager.destinationId == seeded)

    // Different canonical path with unreadable file ids → `.ambiguous` → resolver decides.
    await manager.selectFolderAndWait(other)
    #expect(resolverCalls == 1)
    #expect(manager.destinationId != seeded)  // resolver chose .newDestination
  }

  // MARK: - Failed-restore legacy-id retention (#127 upgrade)

  /// An upgrader's old bookmark fails to resolve on launch (drive unplugged / stale). The legacy
  /// hash (`stashedLegacyDestinationId`) must survive the failed restore so that when the user
  /// re-selects the SAME folder (resolved as `.sameDestination` through the ambiguity prompt),
  /// `currentLegacyDestinationId()` still returns the old bookmark hash and `configureRecordStores`
  /// migrates the existing `ExportRecords/<oldHash>/` to the stable id instead of orphaning it.
  @Test(
    .disabled(
      if: BareTmpScopeProbe.bareTmpRejectsScopeStart(),
      "Local macOS scope quirk; runs on the CI macOS runner."),
    .timeLimit(.minutes(2)))
  func failedRestoreKeepsLegacyHashSoSameFolderReselectMigrates() async throws {
    let dir = try makeTempDir()
    let recordsRoot = TestScratch.directory("StableId-Records")
    defer {
      try? FileManager.default.removeItem(at: dir)
      try? FileManager.default.removeItem(at: recordsRoot)
    }
    let (defaults, suite, bookmarkKey, stableKey) = makeDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }

    // Upgrader's stored bookmark that won't resolve, and its legacy record dir on disk.
    let oldBookmarkBytes = Data("old-upgrader-bookmark-\(UUID().uuidString)".utf8)
    defaults.set(oldBookmarkBytes, forKey: bookmarkKey)
    let oldLegacyId = ExportDestinationManager.legacyDestinationId(from: oldBookmarkBytes)
    let timelineStore = ExportRecordStore(baseDirectoryURL: recordsRoot)
    let collectionStore = CollectionExportRecordStore(baseDirectoryURL: recordsRoot)
    let legacyDir = recordsRoot.appendingPathComponent(oldLegacyId, isDirectory: true)
    try FileManager.default.createDirectory(at: legacyDir, withIntermediateDirectories: true)
    try Data("{}".utf8).write(to: legacyDir.appendingPathComponent("export-records.json"))

    // Launch: restore resolves the (garbage) bookmark → throws → the catch must keep the stash.
    let fp = lowConfidence("/Volumes/mount-A/backup")
    let manager = ExportDestinationManager(
      userDefaults: defaults, bookmarkDefaultsKey: bookmarkKey, stableIdDefaultsKey: stableKey,
      fingerprintProvider: { _ in fp },
      ambiguityResolver: { _ in .sameDestination })
    #expect(manager.currentLegacyDestinationId() == oldLegacyId)  // survived failed restore

    // User re-selects the same folder; the stored bookmark won't resolve → `.ambiguous` →
    // resolver chooses "Same folder" → `.sameDestination` keeps the stash.
    await manager.selectFolderAndWait(dir)
    #expect(manager.currentLegacyDestinationId() == oldLegacyId)

    // configureRecordStores migrates ExportRecords/<oldLegacyId>/ → ExportRecords/<stableId>/.
    let stableId = try #require(manager.destinationId)
    #expect(stableId != oldLegacyId)
    let result = AppCore.configureRecordStores(
      for: stableId, destinationManager: manager,
      timelineStore: timelineStore, collectionStore: collectionStore)
    #expect(result == .success)
    // The stores load the migrated history off the main actor before the folders are removed.
    await timelineStore.waitUntilSettled()
    await collectionStore.waitUntilSettled()
    #expect(timelineStore.state == .ready)
    #expect(collectionStore.state == .ready)
    let migratedDir = recordsRoot.appendingPathComponent(stableId, isDirectory: true)
    #expect(FileManager.default.fileExists(atPath: migratedDir.path))
    #expect(!FileManager.default.fileExists(atPath: legacyDir.path))  // renamed away, not orphaned
  }

  // MARK: - Value types (no filesystem)

  @Test func unavailableIdentityEqualsNilNil() {
    #expect(DestinationIdentity.unavailable == DestinationIdentity(stableId: nil, fingerprint: nil))
  }

  @Test func identitySnapshotIdSourcesFromStableIdNotFingerprint() {
    let fp = lowConfidence("/Volumes/mount-A/backup")
    let snapshot = DestinationIdentitySnapshot(
      identity: DestinationIdentity(stableId: "stable-S", fingerprint: fp))
    #expect(snapshot.id == "stable-S")
    #expect(snapshot.id != fp.id)
    #expect(snapshot.fingerprint == fp)
  }
}
