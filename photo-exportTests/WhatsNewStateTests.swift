import Foundation
import Testing

@testable import Photo_Export

@MainActor
struct WhatsNewStateTests {
  private func makeDefaults() -> UserDefaults {
    let suite = "test-WhatsNew-\(UUID().uuidString)"
    return UserDefaults(suiteName: suite)!
  }

  private func makeBundle(version: String) -> Bundle {
    // Bundle.main is hard to mock; instead, use a real Bundle with overridden
    // info via a temporary plist. For the WhatsNewState tests we only care
    // about the `CFBundleShortVersionString` value reaching the state, so
    // construct a thin wrapper that uses `Bundle.main` but overrides the
    // value through a custom Bundle subclass would be cleaner — but
    // WhatsNewState's init accepts `Bundle`, and Bundle.main always returns
    // the test bundle's actual version. Since we cannot control that
    // value at test time, exercise behavior through the UserDefaults path
    // instead.
    Bundle.main
  }

  @Test func freshInstallReportsShouldShowAndIsFirstLaunch() {
    let defaults = makeDefaults()
    let state = WhatsNewState(userDefaults: defaults, bundle: .main)

    #expect(state.shouldShow == true)
    #expect(state.isFirstLaunch == true)
    #expect(state.lastSeenVersion == nil)
  }

  @Test func sameVersionAfterMarkAsSeenDoesNotShowAgain() {
    let defaults = makeDefaults()
    let state = WhatsNewState(userDefaults: defaults, bundle: .main)
    state.markAsSeen()

    let again = WhatsNewState(userDefaults: defaults, bundle: .main)
    #expect(again.shouldShow == false)
    #expect(again.isFirstLaunch == false)
  }

  @Test func differentStoredVersionTriggersShow() {
    let defaults = makeDefaults()
    // Pre-seed an old version string.
    defaults.set("0.0.1-test-prior", forKey: WhatsNewState.lastSeenVersionKey)

    let state = WhatsNewState(userDefaults: defaults, bundle: .main)

    #expect(state.shouldShow == true)
    #expect(state.isFirstLaunch == false)
    #expect(state.lastSeenVersion == "0.0.1-test-prior")
  }

  @Test func markAsSeenFlipsShouldShowSynchronously() {
    let defaults = makeDefaults()
    let state = WhatsNewState(userDefaults: defaults, bundle: .main)
    #expect(state.shouldShow == true)

    state.markAsSeen()

    #expect(state.shouldShow == false)
    #expect(defaults.string(forKey: WhatsNewState.lastSeenVersionKey) == state.currentVersion)
  }

  // MARK: - Release-notes catalog

  private func makeNote(_ version: String) -> ReleaseNote {
    ReleaseNote(
      version: version, summary: "Summary for \(version)",
      bullets: [.init(title: "Title \(version)", body: "Body \(version)")],
      learnMore: nil)
  }

  @Test func freshInstallHasEmptyUpgradeNotes() {
    let defaults = makeDefaults()
    let state = WhatsNewState(
      userDefaults: defaults, currentVersion: "1.3.0",
      catalog: [makeNote("1.3.0")])

    #expect(state.upgradeNotes.isEmpty)
    #expect(state.isUnknownUpgrade == false)
  }

  @Test func upgradeWithMatchingCatalogEntryExposesNote() {
    let defaults = makeDefaults()
    defaults.set("1.2.3", forKey: WhatsNewState.lastSeenVersionKey)
    let state = WhatsNewState(
      userDefaults: defaults, currentVersion: "1.4.0",
      catalog: [makeNote("1.3.0"), makeNote("1.4.0")])

    #expect(state.upgradeNotes.map(\.version) == ["1.3.0", "1.4.0"])
    #expect(state.isUnknownUpgrade == false)
  }

  @Test func upgradeWithoutCatalogEntryFlagsUnknownUpgrade() {
    let defaults = makeDefaults()
    defaults.set("1.2.3", forKey: WhatsNewState.lastSeenVersionKey)
    let state = WhatsNewState(
      userDefaults: defaults, currentVersion: "1.4.0", catalog: [])

    #expect(state.upgradeNotes.isEmpty)
    #expect(state.isUnknownUpgrade == true)
    #expect(state.shouldShow == true)  // generic message path
  }

  @Test func multiVersionUpgradeReturnsAllNotesInOrder() {
    let result = ReleaseNotesCatalog.notesForUpgrade(
      lastSeen: "1.2.3", current: "1.5.0",
      catalog: [makeNote("1.3.0"), makeNote("1.4.0"), makeNote("1.5.0")])

    #expect(result.map(\.version) == ["1.3.0", "1.4.0", "1.5.0"])
  }

  @Test func upgradeBoundsExcludeLastSeenAndIncludeCurrent() {
    let catalog = [makeNote("1.2.0"), makeNote("1.3.0"), makeNote("1.4.0")]
    let result = ReleaseNotesCatalog.notesForUpgrade(
      lastSeen: "1.2.0", current: "1.3.0", catalog: catalog)

    #expect(result.map(\.version) == ["1.3.0"])
  }

  @Test func numericVersionComparisonHandlesMinorAboveNine() {
    // "1.10.0" must rank above "1.9.0" — naive string compare puts
    // "1.10.0" below "1.9.0".
    let catalog = [makeNote("1.9.0"), makeNote("1.10.0")]
    let result = ReleaseNotesCatalog.notesForUpgrade(
      lastSeen: "1.9.0", current: "1.10.0", catalog: catalog)

    #expect(result.map(\.version) == ["1.10.0"])
  }

  @Test func downgradeDoesNotTriggerTheSheet() {
    // User installs 1.4.0, dismisses it, then rolls back to 1.3.0. The
    // older build hasn't introduced anything to highlight; "Photo Export
    // has been updated to version 1.3.0" would be wrong copy.
    let defaults = makeDefaults()
    defaults.set("1.4.0", forKey: WhatsNewState.lastSeenVersionKey)
    let state = WhatsNewState(
      userDefaults: defaults, currentVersion: "1.3.0",
      catalog: [makeNote("1.3.0"), makeNote("1.4.0")])

    #expect(state.shouldShow == false)
  }

  @Test func firstLaunchInvariantHolds() {
    // `isFirstLaunch == true` must imply `upgradeNotes.isEmpty` — otherwise
    // the view would render upgrade content under the "Welcome" title.
    let defaults = makeDefaults()
    let state = WhatsNewState(
      userDefaults: defaults, currentVersion: "5.0.0",
      catalog: [makeNote("1.0.0"), makeNote("2.0.0"), makeNote("5.0.0")])

    #expect(state.isFirstLaunch == true)
    #expect(state.upgradeNotes.isEmpty)
  }

  @Test func markAsSeenRefreshesDerivedState() {
    // After dismissing, `lastSeenVersion`, `upgradeNotes`, and
    // `isUnknownUpgrade` should reflect the post-dismissal world — a
    // subsequent observer reading `state.upgradeNotes` must not see the
    // pre-dismissal value.
    let defaults = makeDefaults()
    defaults.set("1.2.3", forKey: WhatsNewState.lastSeenVersionKey)
    let state = WhatsNewState(
      userDefaults: defaults, currentVersion: "1.3.0",
      catalog: [makeNote("1.3.0")])
    #expect(state.upgradeNotes.count == 1)

    state.markAsSeen()

    #expect(state.shouldShow == false)
    #expect(state.lastSeenVersion == "1.3.0")
    #expect(state.upgradeNotes.isEmpty)
    #expect(state.isFirstLaunch == false)
  }

  @Test func lastSeenEqualToCurrentReturnsEmptyNotes() {
    let result = ReleaseNotesCatalog.notesForUpgrade(
      lastSeen: "1.3.0", current: "1.3.0",
      catalog: [makeNote("1.3.0")])
    #expect(result.isEmpty)
  }

  @Test func productionCatalogIsCurrentOrAheadOfBundleVersion() {
    // Guard against forgetting to update the catalog before bumping
    // MARKETING_VERSION. Two acceptable states:
    //
    //   - Catalog's newest entry == bundle version (we've shipped and
    //     the catalog includes the current build).
    //   - Catalog's newest entry > bundle version (we've added the
    //     entry for the upcoming release, before bumping
    //     MARKETING_VERSION via bump-version.sh).
    //
    // The failure case — catalog's newest is older than the bundle —
    // means a release shipped without its catalog entry, so users on
    // the upgrade path see the generic fallback message instead of the
    // release highlights.
    let bundleVersion =
      (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? ""
    let newest = ReleaseNotesCatalog.all
      .map(\.version)
      .max(by: { ReleaseNotesCatalog.compare($0, $1) == .orderedAscending })
    #expect(newest != nil, "ReleaseNotesCatalog.all is empty")
    if let newest {
      let isCurrentOrAhead =
        ReleaseNotesCatalog.compare(newest, bundleVersion) != .orderedAscending
      #expect(
        isCurrentOrAhead,
        "Catalog newest entry is \(newest) but bundle is \(bundleVersion). Add a ReleaseNote(version: \"\(bundleVersion)\", …) before shipping."
      )
    }
  }
}
