import Testing

@testable import Photo_Export

/// Hosted tests must not run inside the real app: composing `PhotoExportApp` would restore
/// the developer's destination bookmark and open the real record and AutoSync stores.
@MainActor
@Suite struct TestHostTests {
  @Test func hostedTestsRunInTheMinimalTestHost() {
    #expect(AppEntry.mode == .testHost)
    #expect(!PhotoExportApp.wasComposed)
  }

  @Test func onlyTheTestEnvironmentSelectsTheTestHost() {
    let testEnvironment = ["XCTestConfigurationFilePath": "/tmp/x.xctestconfiguration"]
    #expect(AppEntry.mode(for: testEnvironment) == .testHost)
    #expect(AppEntry.mode(for: [:]) == .app)
    #expect(AppEntry.mode(for: ["PATH": "/usr/bin"]) == .app)
  }
}
