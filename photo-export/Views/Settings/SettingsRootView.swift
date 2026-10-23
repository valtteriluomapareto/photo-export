import SwiftUI

struct SettingsRootView: View {
  @AppStorage(SettingsTab.storageKey) private var selection: SettingsTab = .autoExport
  #if DEBUG
    @Environment(\.bodyInvalidationCounter) private var counter
  #endif

  var body: some View {
    TabView(selection: $selection) {
      AutoExportSettingsView()
        .tabItem { Label("Auto Export", systemImage: "arrow.triangle.2.circlepath") }
        .tag(SettingsTab.autoExport)
        #if DEBUG
          .onAppear { counter?.recordText(["Auto Export"], for: "settings-visible-tab") }
        #endif
      ExportIssuesView()
        .tabItem { Label("Export Issues", systemImage: "exclamationmark.triangle") }
        .tag(SettingsTab.exportIssues)
        #if DEBUG
          .onAppear { counter?.recordText(["Export Issues"], for: "settings-visible-tab") }
        #endif
      AdvancedSettingsView()
        .tabItem { Label("Advanced", systemImage: "slider.horizontal.3") }
        .tag(SettingsTab.advanced)
        #if DEBUG
          .onAppear { counter?.recordText(["Advanced"], for: "settings-visible-tab") }
        #endif
    }
  }
}
