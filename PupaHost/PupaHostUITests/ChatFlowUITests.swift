import XCTest

/// The one thing only a launched app can prove: typing into the chat panel
/// drives the canvas.
///
/// The backend is a script passed in `PUPA_SCRIPT` (inline — the runner and
/// the app don't share a sandbox, so a path wouldn't resolve), and storage is
/// `ephemeral`, a fresh dir inside the app's own temp. So this test needs no
/// network, no backend, and no pairing, and it can never touch real app data.
///
///     make ui-test
///
/// Everything below the view layer is already covered far faster by
/// `ScenarioHarnessTests` — keep this suite to what genuinely needs pixels.
final class ChatFlowUITests: XCTestCase {

    /// Mirrors `PupaID` in PupaApp, which this target can't import.
    private enum ID {
        static let chatComposer = "chat.composer"
        static let chatSend = "chat.send"
        static let chatToggle = "chat.toggle"
        static let sidebarMyAppPrefix = "sidebar.myApp."
    }

    /// Round 1 parks on `addComponent`; round 2 closes the turn.
    private static let script = """
    {"events":[
      {"type":"RUN_STARTED","threadId":"t","runId":"r1"},
      {"type":"TOOL_CALL_START","toolCallId":"call_1","toolCallName":"addComponent"},
      {"type":"TOOL_CALL_ARGS","toolCallId":"call_1","delta":"{\\"kind\\":\\"tracker\\",\\"name\\":\\"Books\\"}"},
      {"type":"TOOL_CALL_END","toolCallId":"call_1"},
      {"type":"CUSTOM","name":"on_interrupt","value":"{\\"frontend_tool_calls\\":[{\\"id\\":\\"call_1\\",\\"name\\":\\"addComponent\\",\\"args\\":{\\"kind\\":\\"tracker\\",\\"name\\":\\"Books\\"}}]}"},
      {"type":"RUN_FINISHED","threadId":"t","runId":"r1"}
    ]}
    {"events":[
      {"type":"RUN_STARTED","threadId":"t","runId":"r2"},
      {"type":"TEXT_MESSAGE_START","messageId":"m1","role":"assistant"},
      {"type":"TEXT_MESSAGE_CONTENT","messageId":"m1","delta":"Added a Books tracker."},
      {"type":"TEXT_MESSAGE_END","messageId":"m1"},
      {"type":"RUN_FINISHED","threadId":"t","runId":"r2"}
    ]}
    """

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testChatTurnAddsComponentToCanvas() throws {
        let app = launched(script: Self.script)

        let composer = app.textFields[ID.chatComposer]
        XCTAssertTrue(composer.waitForExistence(timeout: 30), "chat composer never appeared")
        composer.tap()
        composer.typeText("add a Books tracker")

        app.buttons[ID.chatSend].tap()

        // The reply proves the turn completed; the tile proves the tool ran.
        XCTAssertTrue(
            app.staticTexts["Added a Books tracker."].waitForExistence(timeout: 30),
            "no assistant reply — the scripted backend never answered")
        XCTAssertTrue(
            app.staticTexts["Books"].waitForExistence(timeout: 30),
            "the tool ran but its component never reached the canvas")
    }

    // MARK: Helpers

    @MainActor
    private func launched(script: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-PupaStorageRoot", "ephemeral",
            "-PupaSkipOnboarding", "1",
        ]
        app.launchEnvironment["PUPA_SCRIPT"] = script
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 90), "app never foregrounded")
        openChat(app)
        return app
    }

    /// The MyApps drawer carries its own bottom bar, laid directly over the
    /// main one — so while it is open the chat toggle exists, and even reports
    /// hittable, while a tap at its point lands on the drawer's Settings
    /// button instead. A driven launch closes it (`-PupaSidebarOpen`).
    ///
    /// Fails loudly when it can't get through: the previous `if
    /// toggle.isHittable` silently did nothing, which turned every downstream
    /// assertion into the same misleading "chat composer never appeared".
    @MainActor
    private func openChat(_ app: XCUIApplication) {
        let toggle = app.buttons[ID.chatToggle]
        XCTAssertTrue(toggle.waitForExistence(timeout: 30), "chat toggle never appeared")

        // A driven launch comes up with the drawer closed. If one is open
        // anyway, dismiss it through the scrim — `isHittable` is no guard
        // here, since it reports true for a toggle the drawer is covering.
        let row = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", ID.sidebarMyAppPrefix))
            .firstMatch
        // `exists` is no test: the drawer is always mounted and merely offset
        // off-screen, so its rows stay in the tree while it is closed.
        if row.exists, row.isHittable {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.5)).tap()
            let gone = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "hittable == false"), object: row)
            XCTAssertEqual(
                XCTWaiter().wait(for: [gone], timeout: 15), .completed,
                "the drawer never closed, so the bottom bar stays unreachable")
        }

        toggle.tap()
        XCTAssertTrue(
            app.textFields[ID.chatComposer].waitForExistence(timeout: 30),
            "chat composer never appeared")
    }

    /// A screenshot of the moment it broke, in `build/shots`. `hasSucceeded`
    /// isn't settled yet during teardown — count failures instead.
    override func tearDownWithError() throws {
        guard (testRun?.failureCount ?? 0) > 0 || (testRun?.unexpectedExceptionCount ?? 0) > 0
        else { return }
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "failure-\(name)"
        shot.lifetime = .keepAlways
        add(shot)
    }
}
