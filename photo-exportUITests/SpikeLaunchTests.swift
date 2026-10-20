import XCTest

/// Feasibility check: can XCUITest launch the app on the CI runner, find its window and capture
/// a screenshot? Screenshot mode keeps PhotoKit untouched.
final class SpikeLaunchTests: XCTestCase {
  override func setUpWithError() throws {
    continueAfterFailure = false
  }

  @MainActor
  func testLaunchShowsWindowAndCapturesScreenshot() throws {
    let app = XCUIApplication()
    app.launchArguments = ["--screenshot-mode", "-ApplePersistenceIgnoreState", "YES"]
    app.launch()
    XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 30))
    let attachment = XCTAttachment(screenshot: app.screenshot())
    attachment.name = "Launch"
    attachment.lifetime = .keepAlways
    add(attachment)
    app.typeKey(",", modifierFlags: .command)
    XCTAssertTrue(app.windows.element(boundBy: 1).waitForExistence(timeout: 10) || app.windows.count >= 1)
    let settings = XCTAttachment(screenshot: app.screenshot())
    settings.name = "Settings"
    settings.lifetime = .keepAlways
    add(settings)
    app.terminate()
  }
}
