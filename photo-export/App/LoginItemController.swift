import AppKit
import Foundation
import ServiceManagement
import os

/// Wraps `SMAppService.mainApp` so the Settings UI can present "Open Photo
/// Export at login" as a single toggle without touching `SMAppService`
/// directly. Plan §"Phase 4":
///   "Add the `Open Photo Export at login` setting via `SMAppService.mainApp`
///   with `.enabled`/`.requiresApproval`/`.notRegistered`/`.notFound` status
///   reporting and a deep link to System Settings → Login Items."
///
/// Status semantics (mirroring `SMAppService.Status`):
///   - `enabled`: registered and approved by the user
///   - `requiresApproval`: registered but waiting on the user to flip the
///     switch in System Settings → Login Items
///   - `notRegistered`: not in the user's login-items list
///   - `notFound`: app isn't installed where SMAppService can locate it
///     (running from Xcode's DerivedData, /private/var/folders, etc.)
@MainActor
final class LoginItemController: ObservableObject {
  /// Current status. SwiftUI views observe to drive the toggle + the
  /// "Open System Settings…" hint. Refreshed in `refresh()` and after each
  /// register/unregister.
  @Published private(set) var status: Status = .notRegistered

  private let log: Logger

  enum Status: Equatable, Sendable {
    case enabled
    case requiresApproval
    case notRegistered
    case notFound
    case unknown
  }

  init(
    log: Logger = Logger(subsystem: "com.valtteriluoma.photo-export", category: "LoginItem")
  ) {
    self.log = log
    refresh()
  }

  /// Re-read `SMAppService.mainApp.status`. Call from `.onAppear` / window-
  /// becoming-key so the UI reflects out-of-band changes (user opened
  /// System Settings → Login Items and toggled the entry).
  func refresh() {
    status = Self.map(SMAppService.mainApp.status)
  }

  /// User flipped the toggle on. Attempts to register the app. If the
  /// service was already registered, this is a no-op-with-success.
  func register() {
    do {
      try SMAppService.mainApp.register()
      log.info("Registered for login items")
    } catch {
      log.error(
        "Failed to register login item: \(error.localizedDescription, privacy: .public)"
      )
    }
    refresh()
  }

  /// User flipped the toggle off. The system may keep the entry in Login
  /// Items but disabled — `refresh()` afterward will still show
  /// `.enabled` until the user manually removes via System Settings,
  /// which is why the plan also calls for "poll status when the Settings
  /// window becomes key."
  func unregister() {
    do {
      try SMAppService.mainApp.unregister()
      log.info("Unregistered login item")
    } catch {
      log.error(
        "Failed to unregister login item: \(error.localizedDescription, privacy: .public)"
      )
    }
    refresh()
  }

  /// Deep-link to System Settings → Login Items. Plan: "On `unregister()`,
  /// poll status when the Settings window becomes key; if status remains
  /// `.enabled`, surface a 'Still showing in Login Items? Open Login
  /// Items…' hint because System Settings does not notify the app."
  func openSystemLoginItems() {
    if let url = URL(
      string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")
    {
      NSWorkspace.shared.open(url)
    }
  }

  private static func map(_ status: SMAppService.Status) -> Status {
    switch status {
    case .enabled: return .enabled
    case .requiresApproval: return .requiresApproval
    case .notRegistered: return .notRegistered
    case .notFound: return .notFound
    @unknown default: return .unknown
    }
  }
}
