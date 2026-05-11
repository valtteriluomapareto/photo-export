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

  private let userDefaults: UserDefaults

  /// `UserDefaults` key under which the most recently dismissed version is
  /// stored. Stable across launches; resetting it via
  /// `defaults delete com.valtteriluoma.photo-export WhatsNew.lastSeenVersion`
  /// re-triggers the sheet for testing.
  static let lastSeenVersionKey = "WhatsNew.lastSeenVersion"

  init(userDefaults: UserDefaults = .standard, bundle: Bundle = .main) {
    self.userDefaults = userDefaults
    self.currentVersion =
      (bundle.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "?"
    self.lastSeenVersion = userDefaults.string(forKey: Self.lastSeenVersionKey)
    self.shouldShow = (self.lastSeenVersion != self.currentVersion)
  }

  var isFirstLaunch: Bool { lastSeenVersion == nil }

  /// Called from the sheet's "Got It" button. Persists the current version
  /// so subsequent launches don't re-show until the bundle bumps.
  func markAsSeen() {
    userDefaults.set(currentVersion, forKey: Self.lastSeenVersionKey)
    if shouldShow { shouldShow = false }
  }
}
