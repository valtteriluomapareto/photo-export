import AppKit
import Combine
import Photos

/// "Open in the menu bar": a launch opens no window, and while no window is open the app has
/// no Dock icon. Off by default; independent of launch at login.
enum MenuBarMode {
  /// The setting's preferences key.
  static let defaultsKey = "runsInMenuBar"

  /// Whether this launch opens without a window. First run still opens one for onboarding,
  /// and screenshot captures always do.
  static func opensWithoutWindow(defaults: UserDefaults, isScreenshotMode: Bool) -> Bool {
    defaults.bool(forKey: defaultsKey)
      && defaults.bool(forKey: ContentView.onboardingCompletedDefaultsKey)
      && !isScreenshotMode
  }

  /// `.accessory` (no Dock icon) only with the setting on, no window open, and Photos access
  /// already decided, so a permission prompt can always come to the front. `authorization`
  /// is nil until it has been read after the core started.
  static func activationPolicy(
    isEnabled: Bool, hasWindow: Bool, authorization: PHAuthorizationStatus?
  ) -> NSApplication.ActivationPolicy {
    guard isEnabled, !hasWindow, authorization != .notDetermined else { return .regular }
    return .accessory
  }

  struct WindowState: Equatable {
    var isTitled: Bool
    var isVisible: Bool
    var isMiniaturized = false
    var isClosing = false
  }

  /// Main, Settings and About windows are titled; the menu bar item's window is not. A
  /// minimized window still counts, so it keeps its Dock icon.
  static func hasUserWindow(_ windows: [WindowState]) -> Bool {
    windows.contains { $0.isTitled && !$0.isClosing && ($0.isVisible || $0.isMiniaturized) }
  }
}

/// Applies menu-bar mode for one launch: the windowless core start, the activation policy
/// as windows open and close, and freeing the window caches when the last one closes. The
/// app delegate feeds it AppKit window events; the menu bar shows windows through
/// `showWindow`.
@MainActor
final class MenuBarModeController {
  /// How long a window requested from the menu bar counts as open before one appears.
  static let showWindowTimeout: TimeInterval = 3

  let core: AppCore
  let opensWithoutWindow: Bool
  private let activationPolicy: @MainActor () -> NSApplication.ActivationPolicy
  private let setActivationPolicy: @MainActor (NSApplication.ActivationPolicy) -> Void
  /// Whether a user window was open at the last window event while the app was not hidden.
  private var windowsOpen: Bool
  /// Pending from `willShowWindow` until a window appears or `showWindowTimeout` passes.
  private var showRequest: AutoSyncCancellable?
  private var hasWindow: Bool
  private var authorization: PHAuthorizationStatus?
  private var authorizationSubscription: AnyCancellable?

  init(
    core: AppCore, opensWithoutWindow: Bool,
    activationPolicy: @escaping @MainActor () -> NSApplication.ActivationPolicy,
    setActivationPolicy: @escaping @MainActor (NSApplication.ActivationPolicy) -> Void
  ) {
    self.core = core
    self.opensWithoutWindow = opensWithoutWindow
    self.activationPolicy = activationPolicy
    self.setActivationPolicy = setActivationPolicy
    windowsOpen = !opensWithoutWindow
    hasWindow = windowsOpen
  }

  /// Before AppKit finishes launching, so a windowless launch never shows a Dock icon.
  func launchWillFinish() {
    applyPolicy()
  }

  /// A windowed launch starts the core from its window's `.task`, after the window has
  /// rendered. A windowless launch starts it one main-queue turn after launch finishes, so
  /// no PhotoKit call runs during launch, where it has hung macOS 15.7. Photos access is
  /// followed only from then: before `start()` the library reports `.notDetermined` without
  /// having asked.
  func launchDidFinish() {
    guard opensWithoutWindow else {
      followAuthorization()
      return
    }
    DispatchQueue.main.async { [self] in
      core.start()
      followAuthorization()
    }
  }

  /// After any window event. A hidden app's windows all report not visible, so while hidden
  /// the app keeps whatever it had before hiding: Cmd-H keeps the Dock icon, and Hide Others
  /// doesn't give a windowless app one.
  func windowsChanged(_ windows: [MenuBarMode.WindowState], appIsHidden: Bool) {
    if !appIsHidden { windowsOpen = MenuBarMode.hasUserWindow(windows) }
    if windowsOpen {
      showRequest?.cancel()
      showRequest = nil
    }
    update()
  }

  /// Before a window opens from the menu bar or the quit prompt: the app becomes regular
  /// first, so the window comes to the front with the app's menu bar. It counts as having a
  /// window until one appears or `showWindowTimeout` passes, so a window event that arrives
  /// before the new window does doesn't take the Dock icon away again.
  func willShowWindow() {
    showRequest?.cancel()
    showRequest = core.composition.clock.schedule(after: Self.showWindowTimeout) {
      [weak self] in
      self?.showRequest = nil
      self?.update()
    }
    update()
  }

  /// Shows a window from the menu bar: `willShowWindow`, unhide, `open`, then activate.
  func showWindow(_ open: () -> Void) {
    willShowWindow()
    if NSApp.isHidden { NSApp.unhide(nil) }
    open()
    NSApp.activate()
  }

  private func update() {
    let hasWindow = windowsOpen || showRequest != nil
    let closedLastWindow = self.hasWindow && !hasWindow
    self.hasWindow = hasWindow
    applyPolicy()
    if closedLastWindow { core.photoLibraryManager.releaseWindowCaches() }
  }

  private func followAuthorization() {
    authorizationSubscription = core.photoLibraryManager.authorizationStatusPublisher
      .sink { [weak self] status in
        self?.authorization = status
        self?.applyPolicy()
      }
  }

  /// Compares with the app's real policy, which can change outside the controller.
  private func applyPolicy() {
    let policy = MenuBarMode.activationPolicy(
      isEnabled: core.composition.defaults.bool(forKey: MenuBarMode.defaultsKey),
      hasWindow: hasWindow, authorization: authorization)
    guard policy != activationPolicy() else { return }
    setActivationPolicy(policy)
  }
}
