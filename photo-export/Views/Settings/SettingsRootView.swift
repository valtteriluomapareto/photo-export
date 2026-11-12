import SwiftUI

struct SettingsRootView: View {
  @AppStorage(SettingsTab.storageKey) private var selection: SettingsTab = .autoExport

  var body: some View {
    TabView(selection: $selection) {
      AutoExportSettingsView()
        .tabItem { Label("Auto Export", systemImage: "arrow.triangle.2.circlepath") }
        .tag(SettingsTab.autoExport)
      ExportIssuesView()
        .tabItem { Label("Export Issues", systemImage: "exclamationmark.triangle") }
        .tag(SettingsTab.exportIssues)
      AdvancedSettingsView()
        .tabItem { Label("Advanced", systemImage: "slider.horizontal.3") }
        .tag(SettingsTab.advanced)
    }
  }
}
