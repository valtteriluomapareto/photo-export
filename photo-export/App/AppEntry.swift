import SwiftUI
#if DEBUG
  import AppKit
#endif

enum ControlLaunchFlag: String {
  case fixture = "-PEFixture"
  case runDirectory = "-PERunDirectory"
  case snapshot = "-PESnapshot"
  case surface = "-PESurface"
  case dark = "-PEDark"
  case size = "-PESize"
}

/// The process entry point. Hosted unit tests run inside this app, so under XCTest it
/// starts `TestHostApp` instead of composing `PhotoExportApp`: no destination bookmark,
/// record stores, AutoSync stores or Photos observers are built from the real app state.
@main
enum AppEntry {
  enum Mode: Sendable { case app, testHost }

  /// The app this process started. Hosted tests assert `.testHost`.
  @MainActor private(set) static var mode: Mode = .app

  /// XCTest and Swift Testing set `XCTestConfigurationFilePath` in the test-host
  /// environment. Normal launches, UI-test launches and screenshot captures do not.
  static func mode(for environment: [String: String]) -> Mode {
    environment["XCTestConfigurationFilePath"] != nil ? .testHost : .app
  }

  static var isRunningInTests: Bool {
    mode(for: ProcessInfo.processInfo.environment) == .testHost
  }

  @MainActor static func main() {
    mode = mode(for: ProcessInfo.processInfo.environment)
    switch mode {
    case .testHost: TestHostApp.main()
    case .app:
      let arguments = ProcessInfo.processInfo.arguments
      #if DEBUG
        do {
          if let options = try ControlLaunch.parse(arguments) {
            let runtime = try ControlRuntime(options: options)
            ControlRuntime.launch = runtime
            let app = NSApplication.shared
            app.appearance = NSAppearance(named: options.dark ? .darkAqua : .aqua)
            // Start the fixture mailbox even if AppKit has not presented a window yet.
            Task { @MainActor in await runtime.start() }
            if options.snapshot != nil {
              app.setActivationPolicy(.prohibited)
              app.run()
              return
            }
          }
        } catch {
          ControlRuntime.fail(error)
        }
      #else
        if arguments.dropFirst().contains(where: { ControlLaunchFlag(rawValue: $0) != nil }) {
          FileHandle.standardError.write(
            Data("Photo Export control flags require a Debug build.\n".utf8))
          exit(64)
        }
      #endif
      PhotoExportApp.main()
    }
  }
}

/// The app hosted unit tests run in: no windows, services or observers. Tests build the
/// objects they need themselves.
struct TestHostApp: App {
  var body: some Scene {
    Settings { EmptyView() }
  }
}
