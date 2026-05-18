import SwiftUI

struct AboutView: View {
  private let websiteURL = URL(string: "https://valtteriluomapareto.github.io/photo-export")!
  private let privacyURL = URL(
    string: "https://valtteriluomapareto.github.io/photo-export/privacy")!
  private let supportURL = URL(
    string: "https://valtteriluomapareto.github.io/photo-export/support")!
  private let repoURL = URL(string: "https://github.com/valtteriluomapareto/photo-export")!

  private var appVersion: String {
    Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "–"
  }

  var body: some View {
    VStack(spacing: 12) {
      Image(nsImage: NSApp.applicationIconImage)
        .resizable()
        .frame(width: 96, height: 96)

      Text("Photo Export")
        .font(.title)
        .fontWeight(.bold)

      Text("Version \(appVersion)")
        .font(.callout)
        .foregroundStyle(.secondary)

      Text("by Valtteri Luoma")
        .font(.callout)

      Divider()
        .padding(.vertical, 4)

      VStack(spacing: 6) {
        Link("Website", destination: websiteURL)
        Link("Privacy Policy", destination: privacyURL)
        Link("Support", destination: supportURL)
        Link("GitHub", destination: repoURL)
      }
      .font(.callout)
    }
    .padding(40)
    .frame(width: 300)
    .fixedSize()
  }
}
