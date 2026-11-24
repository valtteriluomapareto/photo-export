import Foundation
import Observation
import os

/// Wraps `SMAppService.mainApp` so the Settings UI can present "Open Photo
/// Export at login" as a single toggle without touching `SMAppService`
/// directly. Status reporting and the System Settings deep link let the user
/// resolve registration or approval problems without hiding system state.
/// See docs/reference/auto-export-behavior.md#run-ownership-and-presentation.
///
/// Status semantics (mirroring `SMAppService.Status`):
///   - `enabled`: registered and approved by the user
///   - `requiresApproval`: registered but waiting on the user to flip the
///     switch in System Settings → Login Items
///   - `notRegistered`: not in the user's login-items list
///   - `notFound`: app isn't installed where SMAppService can locate it
///     (running from Xcode's DerivedData, /private/var/folders, etc.)
@Observable
@MainActor
final class LoginItemController {
  /// Current status. SwiftUI views observe to drive the toggle + the
  /// "Open System Settings…" hint. Refreshed in `refresh()` and after each
  /// register/unregister.
  private(set) var status: Status = .notRegistered

  @ObservationIgnored private let log: Logger
  @ObservationIgnored private let service: any LoginItemService

  enum Status: Equatable, Sendable {
    case enabled
    case requiresApproval
    case notRegistered
    case notFound
    case unknown

    var footerText: String {
      switch self {
      case .enabled:
        return "Photo Export will start automatically when you log in."
      case .requiresApproval:
        return
          "macOS is waiting for you to confirm in System Settings → Login Items."
      case .notRegistered:
        return "Photo Export won't auto-start at login."
      case .notFound:
        return
          "Move Photo Export into your Applications folder to enable launch at login."
      case .unknown:
        return "Status unknown — check System Settings → Login Items."
      }
    }
  }

  init(
    service: (any LoginItemService)? = nil,
    log: Logger = Logger.app(.loginItem)
  ) {
    self.log = log
    self.service = service ?? SystemLoginItemService()
    refresh()
  }

  /// Re-read `SMAppService.mainApp.status`. Call from `.onAppear` / window-
  /// becoming-key so the UI reflects out-of-band changes (user opened
  /// System Settings → Login Items and toggled the entry).
  func refresh() {
    status = service.status
  }

  /// User flipped the toggle on. Attempts to register the app. If the
  /// service was already registered, this is a no-op-with-success.
  func register() {
    do {
      try service.register()
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
  /// so Settings refreshes status when its window becomes key.
  func unregister() {
    do {
      try service.unregister()
      log.info("Unregistered login item")
    } catch {
      log.error(
        "Failed to unregister login item: \(error.localizedDescription, privacy: .public)"
      )
    }
    refresh()
  }

  /// Opens System Settings → Login Items so the user can resolve approval
  /// or a registration entry that still appears after unregistering.
  func openSystemLoginItems() {
    service.openSystemLoginItems()
  }

}
