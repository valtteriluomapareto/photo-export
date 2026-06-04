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
/// `ExportDestinationManagerIdentityTests` — CI's `macos-15` runner runs them.
@MainActor
struct StableDestinationIdentityTests {

  private func lowConfidence(_ path: String) -> DestinationFingerprint {
    .makeLow(volumeRootPath: nil, relativePathFromVolumeRoot: path, standardizedPath: path)
  }

  private func makeTempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("StableId-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }

  private func makeDefaults() -> (UserDefaults, suite: String, bookmarkKey: String, stableKey: String) {
    let suite = "StableId-\(UUID().uuidString)"
    return (
      UserDefaults(suiteName: suite)!, suite,
      "Bookmark-\(UUID().uuidString)", "StableId-\(UUID().uuidString)"
    )
  }

  // MARK: - Reuse across remount drift

  @Test(
    .disabled(
      if: BareTmpScopeProbe.bareTmpRejectsScopeStart(),
      "Local macOS quirk: startAccessingSecurityScopedResource() returns false for bare container tmp URLs, tripping the #92 bail-out in validate(). CI's macos-15 runner returns true so this runs there."
    ))
  func stableIdReusedAcrossSimulatedRemountDrift() throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let (defaults, suite, bookmarkKey, stableKey) = makeDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }

    var currentFP: DestinationFingerprint? = lowConfidence("/Volumes/mount-A/backup")
    let manager = ExportDestinationManager(
      skipRestore: true, userDefaults: defaults, bookmarkDefaultsKey: bookmarkKey,
      stableIdDefaultsKey: stableKey, fingerprintProvider: { _ in currentFP })

    manager.persistSelectedFolderForTesting(dir)
    let seeded = manager.destinationId
    #expect(seeded == currentFP?.id)  // seed == the fingerprint id at first validate
    #expect(defaults.string(forKey: stableKey) == seeded)  // frozen to defaults

    // Remount drift: same folder, different (low-confidence) fingerprint id.
    currentFP = lowConfidence("/Volumes/mount-B/backup")
    #expect(currentFP?.id != seeded)
    manager.revalidateForTesting()

    #expect(manager.destinationId == seeded)  // reused verbatim, NOT re-derived — the #127 fix
    #expect(manager.identity.fingerprint == currentFP)  // advisory fingerprint refreshed
    #expect(defaults.string(forKey: stableKey) == seeded)  // persisted id unchanged
  }

  // MARK: - Upgrade seeding

  @Test(
    .disabled(
      if: BareTmpScopeProbe.bareTmpRejectsScopeStart(),
      "Local macOS scope quirk; runs on CI's macos-15 runner."))
  func highConfidenceAbsentIdSeedsToFingerprintId() throws {
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

    manager.persistSelectedFolderForTesting(dir)

    #expect(manager.destinationId == highFP.id)
    #expect(defaults.string(forKey: stableKey) == highFP.id)
  }

  @Test(
    .disabled(
      if: BareTmpScopeProbe.bareTmpRejectsScopeStart(),
      "Local macOS scope quirk; runs on CI's macos-15 runner."))
  func nilFingerprintAtValidateDefersSeedingThenSeedsWhenReadable() throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let (defaults, suite, bookmarkKey, stableKey) = makeDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }

    // Drive reachable but resource keys unreadable → fingerprint nil → no seed.
    var currentFP: DestinationFingerprint?
    let manager = ExportDestinationManager(
      skipRestore: true, userDefaults: defaults, bookmarkDefaultsKey: bookmarkKey,
      stableIdDefaultsKey: stableKey, fingerprintProvider: { _ in currentFP })

    manager.persistSelectedFolderForTesting(dir)
    #expect(manager.destinationId == nil)  // seeding deferred
    #expect(defaults.string(forKey: stableKey) == nil)  // nothing persisted

    // Fingerprint becomes readable → seeds now.
    currentFP = lowConfidence("/Volumes/mount-A/backup")
    manager.revalidateForTesting()
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
      "Local macOS scope quirk; runs on CI's macos-15 runner."))
  func remountAfterUnavailableReusesSameStableIdWithoutReseeding() throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let (defaults, suite, bookmarkKey, stableKey) = makeDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }

    var currentFP: DestinationFingerprint? = lowConfidence("/Volumes/mount-A/backup")
    let manager = ExportDestinationManager(
      skipRestore: true, userDefaults: defaults, bookmarkDefaultsKey: bookmarkKey,
      stableIdDefaultsKey: stableKey, fingerprintProvider: { _ in currentFP })
    manager.persistSelectedFolderForTesting(dir)
    let seeded = try #require(manager.destinationId)

    // Drive becomes unavailable (resource keys unreadable) → active id nil, persisted retained.
    currentFP = nil
    manager.revalidateForTesting()
    #expect(manager.destinationId == nil)
    #expect(defaults.string(forKey: stableKey) == seeded)

    // Returns under a drifted path → the same id is reused, not re-seeded.
    currentFP = lowConfidence("/Volumes/mount-B/backup")
    manager.revalidateForTesting()
    #expect(manager.destinationId == seeded)
  }

  /// `clearSelection` truly forgets the stable id — proven by re-selecting with a drifted
  /// fingerprint and observing a fresh seed (if clear had merely hidden it, the old id would be
  /// reused).
  @Test(
    .disabled(
      if: BareTmpScopeProbe.bareTmpRejectsScopeStart(),
      "Local macOS scope quirk; runs on CI's macos-15 runner."))
  func clearSelectionDropsStableIdSoNextSelectionReseeds() throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let (defaults, suite, bookmarkKey, stableKey) = makeDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }

    var currentFP = lowConfidence("/Volumes/mount-A/backup")
    let manager = ExportDestinationManager(
      skipRestore: true, userDefaults: defaults, bookmarkDefaultsKey: bookmarkKey,
      stableIdDefaultsKey: stableKey, fingerprintProvider: { _ in currentFP })
    manager.persistSelectedFolderForTesting(dir)
    let seeded = try #require(manager.destinationId)
    #expect(defaults.string(forKey: stableKey) == seeded)

    manager.clearSelection()
    #expect(manager.destinationId == nil)
    #expect(defaults.string(forKey: stableKey) == nil)

    currentFP = lowConfidence("/Volumes/mount-Z/backup")
    manager.persistSelectedFolderForTesting(dir)
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
      "Local macOS scope quirk; runs on CI's macos-15 runner."))
  func sameFolderReSelectionViaRealEvidenceKeepsStableId() throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let (defaults, suite, bookmarkKey, stableKey) = makeDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }

    var currentFP = lowConfidence("/Volumes/mount-A/backup")
    // No injected evidence provider — exercise the real bookmark-identity comparison.
    let manager = ExportDestinationManager(
      skipRestore: true, userDefaults: defaults, bookmarkDefaultsKey: bookmarkKey,
      stableIdDefaultsKey: stableKey, fingerprintProvider: { _ in currentFP })
    manager.persistSelectedFolderForTesting(dir)
    let seeded = try #require(manager.destinationId)

    currentFP = lowConfidence("/Volumes/mount-B/backup")  // path drift between selections
    manager.selectFolderForTesting(dir)

    #expect(manager.destinationId == seeded)
  }

  /// Re-selecting a **genuinely different** folder mints a fresh id — also through the real
  /// evidence path (stored bookmark resolves to dirA, pick is dirB → different file identity).
  @Test(
    .disabled(
      if: BareTmpScopeProbe.bareTmpRejectsScopeStart(),
      "Local macOS scope quirk; runs on CI's macos-15 runner."))
  func differentFolderReSelectionViaRealEvidenceMintsNewId() throws {
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
    manager.persistSelectedFolderForTesting(dirA)
    let seededA = try #require(manager.destinationId)

    manager.selectFolderForTesting(dirB)

    #expect(manager.destinationId != seededA)
  }

  // MARK: - Ambiguous selection (injected resolver)

  /// When the stored bookmark won't resolve, the decision is delegated to the injected
  /// resolver (production shows an `NSAlert`). Resolving as "same" keeps the id even under a
  /// drifted fingerprint.
  @Test(
    .disabled(
      if: BareTmpScopeProbe.bareTmpRejectsScopeStart(),
      "Local macOS scope quirk; runs on CI's macos-15 runner."))
  func ambiguousSelectionResolvedAsSameKeepsStableId() throws {
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
    manager.persistSelectedFolderForTesting(dir)
    let seeded = try #require(manager.destinationId)

    currentFP = lowConfidence("/Volumes/mount-B/backup")
    manager.selectFolderForTesting(dir)

    #expect(manager.destinationId == seeded)
  }

  /// Resolving an ambiguous pick as "different" mints a fresh id.
  @Test(
    .disabled(
      if: BareTmpScopeProbe.bareTmpRejectsScopeStart(),
      "Local macOS scope quirk; runs on CI's macos-15 runner."))
  func ambiguousSelectionResolvedAsNewMintsStableId() throws {
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
    manager.persistSelectedFolderForTesting(dir)
    let seeded = try #require(manager.destinationId)

    currentFP = lowConfidence("/Volumes/mount-B/backup")
    manager.selectFolderForTesting(dir)

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
      "Local macOS scope quirk; runs on CI's macos-15 runner."))
  func unresolvableStoredBookmarkIsAmbiguousAndDelegatesToResolver() throws {
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
    manager.persistSelectedFolderForTesting(dir)
    let seeded = try #require(manager.destinationId)

    // Corrupt the stored bookmark so `URL(resolvingBookmarkData:)` throws → `.ambiguous`.
    defaults.set(Data("not-a-bookmark".utf8), forKey: bookmarkKey)
    manager.selectFolderForTesting(dir)

    #expect(resolverCalls == 1)  // routed through the ambiguity resolver
    #expect(manager.destinationId == seeded)  // resolver chose .sameDestination → id kept
  }
}
