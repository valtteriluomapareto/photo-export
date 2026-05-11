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
}
