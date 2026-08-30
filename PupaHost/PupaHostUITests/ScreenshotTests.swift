import XCTest

/// Drives the app to each App Store screenshot state and attaches a
/// full-screen capture. Not a correctness test — a capture tool.
///
///   xcodebuild test -project PupaHost.xcodeproj -scheme PupaHost \
///     -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' \
///     -parallel-testing-enabled NO \
///     -only-testing:PupaHostUITests/ScreenshotTests
///
/// Then export the PNGs:
///   xcrun xcresulttool export attachments --path <Test-*.xcresult> \
///     --output-path ./shots
///
/// One state per test method — a fresh launch is more reliable than
/// unwinding navigation between frames.
final class ScreenshotTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = true
    }

    // MARK: Frames

    /// Frame 1 — the populated canvas, drawer closed.
    @MainActor
    func testFrame01Canvas() throws {
        let app = launched()
        dismissBanner(app)
        _ = app.buttons["Today's Briefing"].waitForExistence(timeout: 15)
        shoot("frame-01-canvas")
    }

    /// Frame 4 — the MyApps library, now a sheet from the bar's menu.
    @MainActor
    func testFrame04Library() throws {
        let app = launched()
        dismissBanner(app)
        openMyApps(app)
        XCTAssertTrue(
            app.staticTexts["MyApps"].waitForExistence(timeout: 20),
            "the MyApps sheet never opened"
        )
        shoot("frame-04-library")
    }

    /// Chat panel — the side-panel that drives the canvas.
    @MainActor
    func testFrame02Chat() throws {
        let app = launched()
        dismissBanner(app)
        let chat = app.buttons["Open chat"]
        if chat.waitForExistence(timeout: 20) { chat.tap() }
        _ = app.staticTexts.firstMatch.waitForExistence(timeout: 10)
        shoot("frame-02-chat")
    }

    /// Frame 6 — settings root (backend / account / agents).
    @MainActor
    func testFrame06Settings() throws {
        // Launch with the drawer already shut rather than swiping it closed:
        // opening a menu straight after the close animation races it, and the
        // tap lands on the scrim. `NotificationsFlowUITests` reaches Settings
        // the same way.
        let app = launched()
        dismissBanner(app)
        openSettings(app)
        _ = app.staticTexts.firstMatch.waitForExistence(timeout: 10)
        shoot("frame-06-settings")
    }

    /// Memories — the long-lived filesystem.
    @MainActor
    func testFrame08Memories() throws {
        let app = launched()
        dismissBanner(app)
        let mem = app.buttons["Memories"]
        if mem.waitForExistence(timeout: 20) { mem.tap() }
        _ = app.staticTexts.firstMatch.waitForExistence(timeout: 10)
        shoot("frame-08-memories")
    }

    // MARK: Helpers

    @MainActor
    private func launched() -> XCUIApplication {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 90), "app never foregrounded")
        _ = app.staticTexts["Daily Briefing"].waitForExistence(timeout: 45)
        return app
    }

    /// The "Connect your backend" banner sits over the top of every frame.
    @MainActor
    private func dismissBanner(_ app: XCUIApplication) {
        let x = app.buttons["Dismiss"]
        if x.waitForExistence(timeout: 8), x.isHittable { x.tap() }
    }

    /// Open the MyApps sheet from the bar's menu.
    @MainActor
    private func openMyApps(_ app: XCUIApplication) {
        let menu = app.buttons["Menu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 20), "no bar menu")
        let myApps = app.buttons["MyApps"]
        for _ in 0..<3 {
            menu.tap()
            if myApps.waitForExistence(timeout: 5) { break }
        }
        XCTAssertTrue(myApps.exists, "no MyApps item in the menu")
        myApps.tap()
    }

    /// Open Settings through the bar's menu.
    @MainActor
    private func openSettings(_ app: XCUIApplication) {
        let menu = app.buttons["Menu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 20), "no bar menu")
        let settings = app.buttons["Settings"]
        // SwiftUI reports the menu as a PopUpButton, and a tap that lands
        // before it is ready opens nothing at all rather than failing — so
        // confirm the menu actually came up, and tap again if it didn't.
        for _ in 0..<3 {
            menu.tap()
            if settings.waitForExistence(timeout: 5) { break }
        }
        XCTAssertTrue(settings.exists, "no Settings item in the menu")
        settings.tap()
    }

    private func shoot(_ name: String) {
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }
}
