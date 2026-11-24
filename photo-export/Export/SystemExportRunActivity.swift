import Foundation

/// Main-actor ownership keeps the process activity paired with its export run.
@MainActor
final class SystemExportRunActivity: ExportRunActivity {
  private var token: (any NSObjectProtocol)?

  func begin() {
    precondition(token == nil)
    token = ProcessInfo.processInfo.beginActivity(
      options: .userInitiatedAllowingIdleSystemSleep, reason: "Exporting photos")
  }

  func end() {
    guard let token else { return }
    self.token = nil
    ProcessInfo.processInfo.endActivity(token)
  }
}
