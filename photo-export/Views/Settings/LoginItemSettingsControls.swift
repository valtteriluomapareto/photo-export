import SwiftUI

/// The real Startup controls; Settings retains responsibility for refreshing on appearance.
struct LoginItemSettingsControls: View {
  @Environment(LoginItemController.self) private var loginItemController
  var body: some View {
    Group {
      Toggle(
        isOn: Binding(
          get: { loginItemController.status == .enabled },
          set: { newValue in
            if newValue {
              loginItemController.register()
            } else {
              loginItemController.unregister()
            }
          }
        )
      ) {
        VStack(alignment: .leading, spacing: 2) {
          Text("Open Photo Export at login")
          Text(loginItemController.status.footerText)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      if loginItemController.status == .requiresApproval {
        Button("Open System Settings\u{2026}") {
          loginItemController.openSystemLoginItems()
        }
        .accessibilityIdentifier("login-item-open-settings")
      }
    }
  }
}
