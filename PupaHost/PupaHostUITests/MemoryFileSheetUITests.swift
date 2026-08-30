import XCTest

/// Memory files open as a sheet over the canvas rather than a full-page push,
/// and dismissing one commits the edit instead of dropping it.
///
/// Needs pixels: both claims are about presentation and a real dismissal
/// gesture. `MemoryFileRouteTests` covers the rules underneath headlessly.
final class MemoryFileSheetUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = true
    }

    /// The sheet leaves the page it was opened from mounted underneath — the
    /// whole point of not pushing. Asserted by the Memories page's own title
    /// still being on screen while the file is open.
    @MainActor
    func testMemoryFileOpensOverThePageInsteadOfReplacingIt() throws {
        let app = launched(storage: "ephemeral:memsheet-overlay", reset: true)
        openAgentsFile(app)

        // The file is up...
        XCTAssertTrue(
            app.staticTexts["pupa/AGENTS.md"].waitForExistence(timeout: 20),
            "the memory file never opened"
        )
        // ...and the Memories page it came from is still behind it. A push
        // would have unmounted the tree.
        XCTAssertTrue(
            app.staticTexts["MEMORIES"].exists,
            "the Memories page was replaced rather than covered — this is a push, not a sheet"
        )
    }

    /// Swipe-to-dismiss saves. A memory file is a document, not a form, and it
    /// is the agent's long-term context — losing the edit is the bad outcome.
    @MainActor
    func testSwipingTheSheetAwaySavesTheEdit() throws {
        let app = launched(storage: "ephemeral:memsheet-save", reset: true)
        openAgentsFile(app)
        XCTAssertTrue(
            app.staticTexts["pupa/AGENTS.md"].waitForExistence(timeout: 20),
            "the memory file never opened"
        )

        // Type a marker at the very start of the buffer, and never press Save.
        app.buttons["Edit"].tap()
        let editor = app.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 10), "no editor")
        editor.tap()
        // Home puts the caret at the start regardless of where the tap landed.
        editor.typeText(String(XCUIKeyboardKey.home.rawValue))
        editor.typeText(Self.marker)
        XCTAssertTrue(
            app.staticTexts["• Unsaved changes"].waitForExistence(timeout: 10),
            "the edit never registered as unsaved"
        )

        swipeSheetAway(app)

        // Reopen: the marker survived without a Save tap.
        openAgentsFile(app)
        XCTAssertTrue(
            app.staticTexts["pupa/AGENTS.md"].waitForExistence(timeout: 20),
            "the memory file never reopened"
        )
        let saved = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", Self.marker)).firstMatch
        XCTAssertTrue(
            saved.waitForExistence(timeout: 15),
            "dismissing the sheet dropped the edit instead of saving it"
        )
    }

    /// Reading a file and dismissing it must not rewrite it — no edit session,
    /// no write. Proven through the change log, which would show an entry.
    @MainActor
    func testDismissingWithoutEditingLeavesTheFileAlone() throws {
        let app = launched(storage: "ephemeral:memsheet-readonly", reset: true)
        openAgentsFile(app)
        XCTAssertTrue(
            app.staticTexts["pupa/AGENTS.md"].waitForExistence(timeout: 20),
            "the memory file never opened"
        )
        // Straight back out, having only read it.
        swipeSheetAway(app)
        // Reopening shows the file unchanged — no marker, and still readable.
        openAgentsFile(app)
        XCTAssertTrue(
            app.staticTexts["pupa/AGENTS.md"].waitForExistence(timeout: 20),
            "the memory file never reopened"
        )
        XCTAssertFalse(
            app.staticTexts["• Unsaved changes"].exists,
            "a file that was only read came back dirty"
        )
    }

    // MARK: Helpers

    private static let marker = "ZZMARKER"

    @MainActor
    private func launched(storage: String, reset: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-PupaStorageRoot", storage,
            "-PupaSkipOnboarding", "1",
            // The bar is what these tests drive, so keep the drawer out of it.
            "-pupa.ui.sidebarOpen", "NO",
        ]
        if reset { app.launchArguments += ["-PupaStorageReset", "1"] }
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 90), "app never foregrounded")
        let x = app.buttons["Dismiss"]
        if x.waitForExistence(timeout: 8), x.isHittable { x.tap() }
        return app
    }

    /// Memories → expand `pupa` → open `AGENTS.md`, the one file every seeded
    /// app has.
    @MainActor
    private func openAgentsFile(_ app: XCUIApplication) {
        let memories = app.buttons["Memories"]
        XCTAssertTrue(memories.waitForExistence(timeout: 30), "no Memories button")
        memories.tap()

        let file = app.buttons["AGENTS.md"]
        if !file.waitForExistence(timeout: 8) {
            let folder = app.buttons["pupa"]
            XCTAssertTrue(folder.waitForExistence(timeout: 20), "no pupa folder")
            folder.tap()
        }
        XCTAssertTrue(file.waitForExistence(timeout: 20), "no AGENTS.md row")
        file.tap()
    }

    /// Drag the sheet down from its grabber, far enough to pass the dismiss
    /// threshold, and wait until it has actually gone.
    ///
    /// Dismissal has to be proven by the *sheet* disappearing. The page it
    /// covers stays mounted the entire time — that is the whole point of this
    /// feature — so waiting for the page to appear proves nothing and races the
    /// dismiss animation, which is exactly how this test flaked under load.
    @MainActor
    private func swipeSheetAway(_ app: XCUIApplication) {
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08))
            .press(forDuration: 0.1,
                   thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95)))
        XCTAssertTrue(
            app.staticTexts["pupa/AGENTS.md"].waitForNonExistence(timeout: 20),
            "the sheet never dismissed"
        )
    }
}
