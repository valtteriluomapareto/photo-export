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
            #if DEBUG
              .background {
                RenderedTextRecord(
                  key: "login-item-footer", text: loginItemController.status.footerText)
              }
            #endif
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

#if DEBUG
  /// Records the text of the view it backs, so a hosted test reads what that view renders
  /// rather than what the enclosing body computed.
  private struct RenderedTextRecord: View {
    let key: String
    let text: String
    @Environment(\.bodyInvalidationCounter) private var bodyCounter

    var body: some View {
      // swiftlint:disable:next redundant_discardable_let
      let _ = bodyCounter?.recordText([text], for: key)
      Color.clear
    }
  }
#endif
