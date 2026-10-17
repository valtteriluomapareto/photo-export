/// Shared selection for Settings entry points and terminal export feedback.
enum SettingsTab: String, Hashable, Sendable {
  static let storageKey = "Settings.selectedTab"
  case autoExport, exportIssues, advanced
}
