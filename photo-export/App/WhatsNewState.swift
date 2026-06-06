import Foundation
import Observation

/// Tracks whether the user has seen the "What's New" sheet for the current
/// app version. Stores the last-seen `CFBundleShortVersionString` in
/// `UserDefaults`; the sheet appears once whenever the stored value differs
/// from the current bundle version.
///
/// Two cases are distinguished in the copy:
/// - **Fresh install** (`lastSeenVersion == nil`): shown as a brief welcome
///   *after* onboarding completes (the sheet is attached to
///   `LibraryRootView`, so it only renders once routing leaves
///   `OnboardingView`).
/// - **Upgrade** (`lastSeenVersion` is non-nil and differs): shown as a
///   "What's new in this version" summary, with pointers to the Auto
///   Export guide and reassurance about file safety on upgrade.
@Observable
@MainActor
final class WhatsNewState {
  private(set) var shouldShow: Bool

  let currentVersion: String
  /// Mutable so `markAsSeen()` can refresh the in-memory snapshot to
  /// match what was just written to `UserDefaults`. Without this any
  /// future surface that reads `upgradeNotes` or `isUnknownUpgrade`
  /// *after* dismissal would see stale values.
  private(set) var lastSeenVersion: String?

  /// Per-version `ReleaseNote`s to display in the upgrade flavor of the
  /// sheet, oldest-version first. Empty for fresh installs (those use
  /// `freshInstallContent`) and for upgrades where
  /// `ReleaseNotesCatalog.all` has no entry covering the user's jump —
  /// in the latter case `WhatsNewView` falls back to a generic
  /// "Photo Export has been updated" message.
  private(set) var upgradeNotes: [ReleaseNote]

  private let catalog: [ReleaseNote]
  private let userDefaults: UserDefaults

  /// `UserDefaults` key under which the most recently dismissed version is
  /// stored. Stable across launches; resetting it via
  /// `defaults delete com.valtteriluoma.photo-export WhatsNew.lastSeenVersion`
  /// re-triggers the sheet for testing.
  static let lastSeenVersionKey = "WhatsNew.lastSeenVersion"

  convenience init(
    userDefaults: UserDefaults = .standard,
    bundle: Bundle = .main,
    catalog: [ReleaseNote] = ReleaseNotesCatalog.all
  ) {
    let version =
      (bundle.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "?"
    self.init(userDefaults: userDefaults, currentVersion: version, catalog: catalog)
  }

  /// Designated init. Tests pass `currentVersion` directly so they can
  /// exercise multi-version-jump and unknown-upgrade scenarios without
  /// having to fake `Bundle.main`.
  init(
    userDefaults: UserDefaults,
    currentVersion: String,
    catalog: [ReleaseNote]
  ) {
    self.userDefaults = userDefaults
    self.currentVersion = currentVersion
    self.catalog = catalog
    let stored = userDefaults.string(forKey: Self.lastSeenVersionKey)
    self.lastSeenVersion = stored
    self.upgradeNotes = ReleaseNotesCatalog.notesForUpgrade(
      lastSeen: stored, current: currentVersion, catalog: catalog)
    // shouldShow rules:
    //   - Fresh install (stored == nil): show the welcome flavor.
    //   - Upgrade (stored < current): show the upgrade flavor.
    //   - Same version (stored == current): do not show.
    //   - Downgrade (stored > current): do not show. The user installed an
    //     older build (TestFlight rollback, sideload, channel swap with
    //     incompatible state) — the new build hasn't introduced anything
    //     to highlight, and showing "Photo Export has been updated to
    //     version X" would be factually wrong.
    if let stored {
      self.shouldShow =
        ReleaseNotesCatalog.compare(stored, currentVersion) == .orderedAscending
    } else {
      self.shouldShow = true
    }
  }

  var isFirstLaunch: Bool { lastSeenVersion == nil }

  /// True when the modal should fire but no per-version notes are available
  /// for the user's jump — the rendering view shows a generic message
  /// keyed on the current bundle version rather than stale per-version
  /// copy. Always false on fresh installs (those have their own welcome
  /// content).
  var isUnknownUpgrade: Bool {
    !isFirstLaunch && upgradeNotes.isEmpty
  }

  /// Called from the sheet's "Got It" button. Persists the current version
  /// and updates the in-memory snapshot so all derived state
  /// (`isFirstLaunch`, `upgradeNotes`, `isUnknownUpgrade`) reflects the
  /// post-dismissal world.
  func markAsSeen() {
    userDefaults.set(currentVersion, forKey: Self.lastSeenVersionKey)
    lastSeenVersion = currentVersion
    upgradeNotes = ReleaseNotesCatalog.notesForUpgrade(
      lastSeen: currentVersion, current: currentVersion, catalog: catalog)
    if shouldShow { shouldShow = false }
  }
}
