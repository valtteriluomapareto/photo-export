import AppKit
import ServiceManagement

@MainActor
struct SystemLoginItemService: LoginItemService {
  var status: LoginItemController.Status { Self.map(SMAppService.mainApp.status) }
  func register() throws { try SMAppService.mainApp.register() }
  func unregister() throws { try SMAppService.mainApp.unregister() }
  func openSystemLoginItems() {
    if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
      NSWorkspace.shared.open(url)
    }
  }

  static func map(_ status: SMAppService.Status) -> LoginItemController.Status {
    switch status {
    case .enabled: return .enabled
    case .requiresApproval: return .requiresApproval
    case .notRegistered: return .notRegistered
    case .notFound: return .notFound
    @unknown default: return .unknown
    }
  }
}
