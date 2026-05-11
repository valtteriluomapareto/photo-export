import Foundation

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
///
/// `shouldShow` is `@Published` so the sheet's `isPresented` binding flips
/// to false synchronously on `markAsSeen()`, avoiding any flash of stale
/// state if the same `WhatsNewState` instance is observed by multiple
/// views.
@MainActor
final class WhatsNewState: ObservableObject {
  @Published private(set) var shouldShow: Bool

  let currentVersion: String
  let lastSeenVersion: String?

  /// Per-version `ReleaseNote`s to display in the upgrade flavor of the
  /// sheet, oldest-version first. Empty for fresh installs (those use
  /// `freshInstallContent`) and for upgrades where
  /// `ReleaseNotesCatalog.all` has no entry covering the user's jump —
  /// in the latter case `WhatsNewView` falls back to a generic
  /// "Photo Export has been updated" message.
  let upgradeNotes: [ReleaseNote]

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
    self.lastSeenVersion = userDefaults.string(forKey: Self.lastSeenVersionKey)
    self.shouldShow = (self.lastSeenVersion != self.currentVersion)
    self.upgradeNotes = ReleaseNotesCatalog.notesForUpgrade(
      lastSeen: self.lastSeenVersion, current: self.currentVersion, catalog: catalog)
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
  /// so subsequent launches don't re-show until the bundle bumps.
  func markAsSeen() {
    userDefaults.set(currentVersion, forKey: Self.lastSeenVersionKey)
    if shouldShow { shouldShow = false }
  }
}
