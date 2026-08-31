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

    /// Frame 1 — the populated canvas.
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

    /// Screen share is the one page with no bottom bar, so before this it was
    /// opened with a root swap and had no way out at all — no bar, no menu, no
    /// Back button. Deleting the always-present toolbar hamburger is what made
    /// that fatal, so this pins the escape route.
    @MainActor
    func testScreenShareIsNotADeadEnd() throws {
        let app = launched()
        dismissBanner(app)

        let menu = app.buttons["Menu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 20), "no bar menu")
        let share = app.buttons["Screen share"]
        for _ in 0..<3 {
            menu.tap()
            if share.waitForExistence(timeout: 5) { break }
        }
        XCTAssertTrue(share.exists, "no Screen share item in the menu")
        share.tap()

        XCTAssertTrue(
            app.buttons["Connect"].waitForExistence(timeout: 20),
            "screen share never opened"
        )
        // It was pushed, so the stack gives it a Back button — the only way
        // off a page that has no bar.
        let back = app.navigationBars.buttons.firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 10), "screen share has no way back")
        back.tap()
        XCTAssertTrue(
            app.buttons["Today's Briefing"].waitForExistence(timeout: 20),
            "Back did not leave screen share"
        )
    }

    /// Tapping a row is what the sheet is *for*, and it had no coverage: the
    /// two observers that make it work — `onChange(of: selection)` in AppView
    /// (dismiss) and in MyAppSidebarView (navigate) — now sit on opposite
    /// sides of a sheet-presentation boundary rather than in one view tree.
    @MainActor
    func testTappingAMyAppRowNavigatesAndDismissesTheSheet() throws {
        let app = launched()
        dismissBanner(app)
        openMyApps(app)
        XCTAssertTrue(
            app.staticTexts["MyApps"].waitForExistence(timeout: 20),
            "the MyApps sheet never opened"
        )

        // By identifier, not label: the row is `accessibilityElement(.combine)`
        // inside a List, so it is not a plain button. This is what
        // `PupaID.sidebarMyApp` exists for — it had no consumer left after the
        // drawer's test helpers went.
        let row = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "sidebar.myApp."))
            .firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20), "no MyApp row")
        row.tap()

        // The sheet goes...
        XCTAssertTrue(
            app.buttons["Close"].waitForNonExistence(timeout: 20),
            "tapping a row left the sheet up"
        )
        // ...and the app it names is what the bar is now driving.
        XCTAssertTrue(
            app.buttons["Today's Briefing"].waitForExistence(timeout: 20),
            "tapping a row dismissed the sheet without navigating"
        )
        XCTAssertTrue(app.buttons["Menu"].exists, "the bar never came back")
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
