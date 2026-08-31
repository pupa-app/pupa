import XCTest

/// The one thing only a launched app can prove about notifications: a real
/// `UNUserNotificationCenter` accepts a scheduled reminder, and once it fires
/// the log notices and moves it from Active to Past.
///
/// Needs pixels because `UNUserNotificationCenter` raises in a process without
/// a bundle identifier, so no SwiftPM test can touch it — the store's logic is
/// covered far faster by `NotificationLogStoreTests`, which is why this suite
/// stays one round-trip. It also drives the OS permission alert, which only
/// exists here.
final class NotificationsFlowUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = true
    }

    @MainActor
    func testScheduledReminderFiresAndLandsInPast() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-PupaStorageRoot", "ephemeral",
            "-PupaSkipOnboarding", "1",
        ]
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 90), "app never foregrounded")

        let x = app.buttons["Dismiss"]
        if x.waitForExistence(timeout: 8), x.isHittable { x.tap() }

        let menu = app.buttons["Menu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 30), "no bar menu")
        menu.tap()

        let settings = app.buttons["Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10), "no Settings item in the menu")
        settings.tap()

        let row = app.buttons
            .matching(NSPredicate(format: "label BEGINSWITH 'Notifications'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20), "no Notifications row")
        row.tap()

        XCTAssertTrue(
            app.staticTexts["No scheduled notifications."].waitForExistence(timeout: 20),
            "empty Active state never appeared"
        )
        shoot("01-active-empty")

        // Past tab, still empty.
        tab(app, "Past").tap()
        _ = app.staticTexts["Nothing has fired yet."].waitForExistence(timeout: 10)
        shoot("02-past-empty")
        tab(app, "Active").tap()

        // Compose one as the user. Scope every query to its own navigation bar
        // — the seeded canvas has a component labelled "Schedule" too.
        let bar = app.navigationBars["Notifications"]
        bar.buttons.element(boundBy: bar.buttons.count - 1).tap()

        let composer = app.navigationBars["New Reminder"]
        XCTAssertTrue(composer.waitForExistence(timeout: 15), "composer never appeared")
        let title = app.textFields["Title"]
        XCTAssertTrue(title.waitForExistence(timeout: 15), "no title field")
        title.tap()
        title.typeText("Stretch break")
        shoot("03-composer")

        composer.buttons["Schedule"].tap()

        // First schedule triggers the OS permission prompt.
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = springboard.buttons["Allow"]
        if allow.waitForExistence(timeout: 15) { allow.tap() }

        XCTAssertTrue(
            app.staticTexts["Stretch break"].waitForExistence(timeout: 20),
            "the scheduled reminder never reached the Active list"
        )
        shoot("04-active-with-row")

        // It fires ~immediately (trigger defaults to Now), so a reconcile
        // should move it to Past.
        tab(app, "Past").tap()
        XCTAssertTrue(
            app.staticTexts["Stretch break"].waitForExistence(timeout: 20),
            "it fired but never moved to Past"
        )
        shoot("05-past")
    }

    /// The Active / Past segmented control, wherever SwiftUI hung it.
    @MainActor
    private func tab(_ app: XCUIApplication, _ name: String) -> XCUIElement {
        let seg = app.segmentedControls.buttons[name]
        return seg.exists ? seg : app.buttons[name].firstMatch
    }

    private func shoot(_ name: String) {
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }
}
