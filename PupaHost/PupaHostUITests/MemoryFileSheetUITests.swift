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

    /// Dismissing an edit session that changed nothing must leave the file
    /// intact. This is the `isEditing == true, buffer == loaded` branch of
    /// `MemoryFileDismiss.shouldSave` — distinct from never opening the editor
    /// at all, and the one a careless "always write on dismiss" would break.
    ///
    /// Scope, stated honestly: this proves the *content survives*. It cannot
    /// prove no write occurred — that would need the file's mtime, which the UI
    /// does not surface. `MemoryFileRouteTests.untouchedEditSessionWritesNothing`
    /// covers the no-write claim directly.
    ///
    /// An earlier version tapped Edit then Cancel before swiping, which set
    /// `isEditing = false` and so tested the trivial never-edited path instead,
    /// and asserted the absence of a marker that is never typed in this storage
    /// root. Both were theatre.
    @MainActor
    func testDismissingAnUnchangedEditSessionLeavesTheFileIntact() throws {
        let app = launched(storage: "ephemeral:memsheet-unchanged", reset: true)
        openAgentsFile(app)
        let heading = app.staticTexts["Example: Daily Briefing"]
        XCTAssertTrue(heading.waitForExistence(timeout: 20), "the memory file never opened")

        // Enter the editor and change nothing, so the dismissal runs with
        // `isEditing == true` and a buffer equal to what is on disk.
        app.buttons["Edit"].tap()
        XCTAssertTrue(app.textViews.firstMatch.waitForExistence(timeout: 10), "no editor")
        XCTAssertFalse(
            app.staticTexts["• Unsaved changes"].exists,
            "the editor reported changes before anything was typed"
        )
        swipeSheetAway(app)

        // Reopened, the note still renders its real content — a dismissal that
        // wrote an empty or truncated buffer would show up here.
        openAgentsFile(app)
        XCTAssertTrue(heading.waitForExistence(timeout: 20), "the memory file never reopened")
        XCTAssertTrue(
            app.staticTexts["Components"].exists,
            "the note came back missing content it had before the dismissal"
        )
    }

    /// An agent's **Prompt** row is a memory file too, and it is the route most
    /// people reach `AGENTS.md` by. It was left pushing when the tree was
    /// converted, so the same file saved on dismiss from Memories and discarded
    /// from Agents. Regression test for that.
    @MainActor
    func testAgentPromptLinkOpensTheFileAsASheetToo() throws {
        let app = launched(storage: "ephemeral:memsheet-agentlink", reset: true)

        let menu = app.buttons["Menu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 30), "no bar menu")
        menu.tap()
        let agents = app.buttons["Agents"]
        XCTAssertTrue(agents.waitForExistence(timeout: 10), "no Agents item in the menu")
        agents.tap()

        // The myApp's main agent, then its Prompt row.
        let agentRow = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "Main agent")).firstMatch
        XCTAssertTrue(agentRow.waitForExistence(timeout: 20), "no agent row")
        agentRow.tap()

        let prompt = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "AGENTS.md")).firstMatch
        XCTAssertTrue(prompt.waitForExistence(timeout: 20), "no Prompt link")
        prompt.tap()

        XCTAssertTrue(
            app.staticTexts["pupa/AGENTS.md"].waitForExistence(timeout: 20),
            "the Prompt link never opened the file"
        )
        // A sheet, not a push: the agent page it came from is still mounted, so
        // the very button that opened the file is still in the hierarchy. A
        // push would have unmounted it.
        XCTAssertTrue(
            prompt.exists,
            "the agent page was replaced rather than covered — the Prompt link still pushes"
        )
        // And it autosaves like every other route to this file.
        app.buttons["Edit"].tap()
        let editor = app.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 10), "no editor")
        editor.tap()
        editor.typeText(String(XCUIKeyboardKey.home.rawValue))
        editor.typeText(Self.marker)
        swipeSheetAway(app)

        prompt.tap()
        XCTAssertTrue(
            app.staticTexts["pupa/AGENTS.md"].waitForExistence(timeout: 20),
            "the file never reopened"
        )
        let saved = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", Self.marker)).firstMatch
        XCTAssertTrue(
            saved.waitForExistence(timeout: 15),
            "the Prompt route discarded the edit — it is not autosaving like the tree route"
        )
    }

    /// A `pupa://memory/…` link inside a note swaps the sheet to the linked
    /// note. Round 4 flagged this as the one path with no coverage: it does
    /// `memoryFileSheet = nil` then re-assigns a runloop turn later, and a
    /// dropped present there leaves the route id stuck and the file
    /// unopenable — the failure mode this PR fixed elsewhere.
    ///
    /// Also pins the reason the swap cannot lose an edit: links are only
    /// tappable in *preview*, and preview means `isEditing == false`, so
    /// `shouldSave` is false. In the editor the same text is raw markdown.
    @MainActor
    func testALinkInsideANoteSwapsToTheLinkedNote() throws {
        let app = launched(storage: "ephemeral:memsheet-notelink", reset: true)

        let memories = app.buttons["Memories"]
        XCTAssertTrue(memories.waitForExistence(timeout: 30), "no Memories button")
        memories.tap()

        newNote(app, named: "target", content: "# Landed in target")
        // Dismiss the note the composer opened for us before making the next.
        swipeSheetAway(app)
        newNote(app, named: "source", content: "[go](pupa://memory/target.md)")
        swipeSheetAway(app)

        // Open the source note and tap its link.
        let sourceRow = app.buttons["source.md"]
        XCTAssertTrue(sourceRow.waitForExistence(timeout: 20), "no source.md row")
        sourceRow.tap()
        XCTAssertTrue(
            app.staticTexts["source.md"].waitForExistence(timeout: 20),
            "source note never opened"
        )
        let link = app.links["go"].exists ? app.links["go"] : app.buttons["go"]
        XCTAssertTrue(link.waitForExistence(timeout: 10), "the note's link never rendered")
        link.tap()

        // The sheet swapped rather than being dropped.
        XCTAssertTrue(
            app.staticTexts["target.md"].waitForExistence(timeout: 20),
            "the link did not swap the sheet to the linked note"
        )
        XCTAssertTrue(
            app.staticTexts["Landed in target"].waitForExistence(timeout: 10),
            "the linked note opened without its content"
        )
    }

    // MARK: Helpers

    /// Create a note through the `+` menu on the Memories page.
    @MainActor
    private func newNote(_ app: XCUIApplication, named name: String, content: String) {
        // Not `buttons["plus"]` — that also matches the sidebar's offscreen
        // "New myapp". The Memories header labels its menu explicitly.
        let plus = app.buttons["Add note or folder"]
        XCTAssertTrue(plus.waitForExistence(timeout: 20), "no add menu on Memories")
        plus.tap()
        let newNote = app.buttons["New Note"]
        XCTAssertTrue(newNote.waitForExistence(timeout: 10), "no New Note item")
        newNote.tap()

        let nameField = app.textFields.firstMatch
        XCTAssertTrue(nameField.waitForExistence(timeout: 10), "no name field")
        nameField.tap()
        nameField.typeText(name)
        let body = app.textViews.firstMatch
        XCTAssertTrue(body.waitForExistence(timeout: 10), "no content editor")
        body.tap()
        body.typeText(content)
        app.buttons["Create"].tap()

        // The composer closes and the new note opens in its place. Waiting for
        // it is also the assertion that the created note is reachable at all —
        // presenting it while the composer was still up used to drop the
        // present and strand the route id.
        XCTAssertTrue(
            app.staticTexts["\(name).md"].waitForExistence(timeout: 20),
            "the created note never opened"
        )
    }

    private static let marker = "ZZMARKER"

    @MainActor
    private func launched(storage: String, reset: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-PupaStorageRoot", storage,
            "-PupaSkipOnboarding", "1",
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
        // Keyed on the sheet's Close button, not its title: a note at the tree
        // root renders the *same* string in its row behind the sheet, so a
        // title-based wait can never go false.
        XCTAssertTrue(
            app.buttons["Close"].waitForNonExistence(timeout: 20),
            "the sheet never dismissed"
        )
    }
}
