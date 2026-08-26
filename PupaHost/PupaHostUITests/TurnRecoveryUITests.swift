import XCTest

/// The three things only a launched app can prove: what a turn survives when
/// the app is backgrounded, when it is killed outright, and what the user is
/// offered when a turn stops short.
///
/// Everything below the view layer is covered far faster by `ScenarioHarness`
/// and the AGUIKit suites. What is *only* reachable here is the scene-phase
/// path (`AppView.handleScenePhase`) and the relaunch path, because both need
/// a real process to background and a real process to kill.
///
/// State is read from the `debug.turnState` probe. The runner and the app
/// don't share a sandbox, so the app cannot hand a file back; the probe's
/// accessibility value is the channel. It reports nothing while the app is
/// backgrounded — there is no accessibility tree then — so anything that has
/// to be observed *during* the background window is read from the unified log
/// instead (`make ui-test-recovery` captures it to build/trace.log).
///
///     make ui-test-recovery
final class TurnRecoveryUITests: XCTestCase {

    /// Mirrors `PupaID` in PupaApp, which this target can't import.
    private enum ID {
        static let chatComposer = "chat.composer"
        static let chatSend = "chat.send"
        static let chatToggle = "chat.toggle"
        static let sidebarMyAppPrefix = "sidebar.myApp."
        static let chatContinue = "chat.continue"
        static let turnState = "debug.turnState"
        static let componentPrefix = "canvas.component."
    }

    override func setUpWithError() throws { continueAfterFailure = false }

    // MARK: - Fixtures

    /// Round 1 parks on `addComponent`; the resume is accepted and never
    /// answered, so the turn sits at the park with no clock of its own. This
    /// is the pupa#258 window, held open deliberately.
    private static let parkThenHang = """
    {"events":[
      {"type":"RUN_STARTED","threadId":"t","runId":"r1"},
      {"type":"TOOL_CALL_START","toolCallId":"call_1","toolCallName":"addComponent"},
      {"type":"TOOL_CALL_ARGS","toolCallId":"call_1","delta":"{\\"kind\\":\\"tracker\\",\\"name\\":\\"Books\\"}"},
      {"type":"TOOL_CALL_END","toolCallId":"call_1"},
      {"type":"CUSTOM","name":"on_interrupt","value":"{\\"frontend_tool_calls\\":[{\\"id\\":\\"call_1\\",\\"name\\":\\"addComponent\\",\\"args\\":{\\"kind\\":\\"tracker\\",\\"name\\":\\"Books\\"}}]}"},
      {"type":"RUN_FINISHED","threadId":"t","runId":"r1"}
    ]}
    {"fail":"hang","events":[]}
    """

    /// A turn that starts narrating and then holds the socket open — a live
    /// stream that stays live for as long as the test needs it.
    private static let streamThenHang = """
    {"fail":"hang","events":[
      {"type":"RUN_STARTED","threadId":"t","runId":"r1"},
      {"type":"TEXT_MESSAGE_START","messageId":"m1","role":"assistant"},
      {"type":"TEXT_MESSAGE_CONTENT","messageId":"m1","delta":"Thinking about it"}
    ]}
    """

    /// The socket dies mid-narration; the reattach that follows serves the
    /// rest of the turn from the replay log.
    private static let dropThenReattach = """
    {"fail":"midStream","failAfter":3,"events":[
      {"type":"RUN_STARTED","threadId":"t","runId":"r1"},
      {"type":"TEXT_MESSAGE_START","messageId":"m1","role":"assistant"},
      {"type":"TEXT_MESSAGE_CONTENT","messageId":"m1","delta":"Half a "},
      {"type":"TEXT_MESSAGE_CONTENT","messageId":"m1","delta":"sentence"}
    ]}
    {"events":[
      {"type":"TEXT_MESSAGE_CONTENT","messageId":"m1","delta":" and the rest."},
      {"type":"TEXT_MESSAGE_END","messageId":"m1"},
      {"type":"RUN_FINISHED","threadId":"t","runId":"r1"}
    ]}
    """

    /// Nothing but a start and a finish: the backend answered, with no reply
    /// in it. `CompletionOutcome.silent(.emptyTurn)` — the *notice* ending.
    private static let emptyTurn = """
    {"events":[
      {"type":"RUN_STARTED","threadId":"t","runId":"r1"},
      {"type":"RUN_FINISHED","threadId":"t","runId":"r1"}
    ]}
    """

    /// Every POST refused at connect. With the retry budget shrunk to one this
    /// exhausts immediately — the *throw* ending.
    private static let deadBackend = """
    {"round":1,"fail":"connect","events":[]}
    {"round":2,"fail":"connect","events":[]}
    {"round":3,"fail":"connect","events":[]}
    """

    // MARK: - Background and foreground

    /// A turn that is mid-stream when the app leaves the screen must still be
    /// mid-stream when it comes back. The regression this guards is the
    /// foreground path re-driving a turn that never stopped.
    @MainActor
    func testShortBackgroundLeavesALiveTurnAlone() throws {
        let app = launched(script: Self.streamThenHang, root: "recovery-shortbg")
        send(app, "tell me something")

        waitForProbe(app, "the turn is streaming") { $0.isStreaming }
        let eventsBefore = probe(app).events

        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30), "app never came back")

        let after = probe(app)
        XCTAssertTrue(after.isStreaming, "the live turn was dropped by going away and coming back")
        XCTAssertNil(after.connectionIssue, "a turn that never broke must not show a banner")
        XCTAssertEqual(
            after.events.filter { $0 == "fdp" }.count,
            eventsBefore.filter { $0 == "fdp" }.count,
            "foregrounding announced a second park for a turn that was already parked")
    }

    /// The socket really dies while the app is away. Coming back must reattach
    /// and finish the turn — once — rather than stranding it on "Reconnecting…"
    /// or replaying what already rendered.
    @MainActor
    func testBackgroundDropReattachesOnForeground() throws {
        let app = launched(
            script: Self.dropThenReattach, root: "recovery-bgdrop",
            extra: ["-PupaBackgroundGrace", "2", "-PupaReattachDelayMs", "50"])
        send(app, "tell me something")

        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30), "app never came back")

        waitForProbe(app, "the turn settled", timeout: 60) { !$0.isStreaming }
        // No `rea` assertion: a drop the app only notices on foreground is
        // recovered by `reattachIfNeeded`, a different path from the retry
        // ladder inside a live round, and it yields no `.reattaching`.
        XCTAssertNil(probe(app).connectionIssue, "a recovered turn must not leave the banner up")
        XCTAssertEqual(
            app.staticTexts.matching(
                NSPredicate(format: "label CONTAINS %@", "and the rest.")).count, 1,
            "the reattached tail never rendered (or rendered twice). state: "
            + "\(probe(app).fields) texts: \(app.staticTexts.allElementsBoundByIndex.map(\.label))")
    }

    // MARK: - Force quit and relaunch

    /// `terminate()` is a kill: `.background` never runs, so nothing the
    /// scene-phase path does can help. Everything recovered here comes from
    /// the `persistTranscript()` calls on the event path itself.
    @MainActor
    func testForceQuitMidStreamRelaunchesOntoTheSameTurn() throws {
        let root = "recovery-killmidstream"
        let app = launched(script: Self.streamThenHang, root: root)
        send(app, "tell me something")
        waitForProbe(app, "the turn is streaming") { $0.isStreaming }
        let threadBefore = probe(app).threadId
        XCTAssertNotNil(threadBefore)

        app.terminate()

        // Relaunch onto the same storage: round 1 of this process is the
        // catch-up the app makes on its own.
        let relaunched = launched(script: Self.emptyTurn, root: root, reset: false)
        openChat(relaunched)
        waitForProbe(relaunched, "history rehydrated", timeout: 60) { $0.threadId == threadBefore }
        XCTAssertTrue(
            relaunched.staticTexts.matching(
                NSPredicate(format: "label CONTAINS %@", "tell me something")).count >= 1,
            "the question the user asked did not survive the kill")
    }

    /// The pupa#258 window, made sittable by `hang`: the app dies between the
    /// park and the resume that answers it. The side effect has already run,
    /// so a relaunch that re-dispatches instead of replaying the journal will
    /// run it a second time — two identical trackers on the canvas.
    @MainActor
    func testForceQuitWhileParkedDoesNotRerunTheSideEffect() throws {
        let root = "recovery-killparked"
        let app = launched(script: Self.parkThenHang, root: root)
        // The seeded MyApp ships with components of its own, so what matters
        // is the delta, not the count.
        let before = componentCount(app)
        send(app, "add a Books tracker")

        waitForProbe(app, "the turn parked on a frontend tool", timeout: 60) {
            $0.pendingDispatchAfterSeq != nil
        }
        XCTAssertEqual(componentCount(app), before + 1, "setup: the tool ran once before the kill")

        app.terminate()

        let relaunched = launched(script: Self.emptyTurn, root: root, reset: false)
        waitForProbe(relaunched, "recovery finished", timeout: 60) { !$0.isStreaming }
        XCTAssertEqual(
            componentCount(relaunched), before + 1,
            "the parked tool ran a second time — the dispatch journal did not replay it")
    }

    // MARK: - What a stopped turn offers

    /// A turn whose stream throws ends on a banner, and the banner carries a
    /// Continue button. This is the ending that already worked; it is pinned
    /// so the notice ending below can be fixed without losing it.
    @MainActor
    func testThrowEndingOffersContinue() throws {
        let app = launched(
            script: Self.deadBackend, root: "recovery-throw",
            extra: ["-PupaReattachAttempts", "1", "-PupaReattachDelayMs", "10"])
        send(app, "hello")

        // A refused POST is `requestFailed`, which maps to `.reconnecting`
        // rather than `.failed` — the banner is calmer, but the turn is just
        // as stuck, which is why #267 put the button on both.
        waitForProbe(app, "the turn stopped on a banner", timeout: 60) {
            $0.connectionIssue != nil && !$0.isStreaming
        }
        XCTAssertTrue(
            app.buttons[ID.chatContinue].waitForExistence(timeout: 10),
            "the banner offered no way to pick the turn back up")
    }

    /// The common ending, and the bug: a turn that ends cleanly but unsettled
    /// raises no banner, so the Continue button never renders — and the
    /// transcript asks the user to type "continue" by hand instead.
    @MainActor
    func testNoticeEndingOffersContinue() throws {
        let app = launched(script: Self.emptyTurn, root: "recovery-notice")
        send(app, "hello")

        waitForProbe(app, "the turn stopped short", timeout: 60) { $0.noticeReason != nil }
        XCTAssertNil(probe(app).connectionIssue, "this ending raises no banner — that is the bug")

        XCTAssertTrue(
            app.buttons[ID.chatContinue].waitForExistence(timeout: 10),
            "a turn that ended on a notice offers no way to continue it")
        XCTAssertEqual(
            app.staticTexts.matching(
                NSPredicate(format: "label CONTAINS[c] %@", "Say “continue”")).count, 0,
            "the transcript still asks the user to type “continue” by hand")
    }

    // MARK: - Probe

    /// One turn state, decoded from `debug.turnState`.
    private struct Probe {
        let fields: [String: Any]
        var isStreaming: Bool { fields["s"] as? Int == 1 }
        var connectionIssue: String? { fields["ci"] as? String }
        var pendingDispatchAfterSeq: Int? { fields["pd"] as? Int }
        var noticeReason: String? { fields["nr"] as? String }
        var threadId: String? { fields["th"] as? String }
        var events: [String] {
            (fields["ev"] as? String).map { $0.isEmpty ? [] : $0.components(separatedBy: ",") } ?? []
        }
    }

    @MainActor
    private func probeElement(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: ID.turnState).firstMatch
    }

    @MainActor
    private func probe(_ app: XCUIApplication) -> Probe {
        let raw = probeElement(app).value as? String ?? "{}"
        let object = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any]
        return Probe(fields: object ?? [:])
    }

    /// XCTest re-evaluates the predicate on its own cadence and diagnoses the
    /// timeout properly; a hand-rolled poll loop reports far worse. Note that
    /// the snapshot behind each read is served on the app's main thread, so a
    /// blocked main actor surfaces here as a snapshot failure — that is a hang
    /// being detected, not a broken probe.
    @MainActor
    private func waitForProbe(
        _ app: XCUIApplication, _ what: String,
        timeout: TimeInterval = 30,
        file: StaticString = #filePath, line: UInt = #line,
        where match: @escaping (Probe) -> Bool
    ) {
        let predicate = NSPredicate { element, _ in
            guard let element = element as? XCUIElement else { return false }
            let raw = element.value as? String ?? "{}"
            let object = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any]
            return match(Probe(fields: object ?? [:]))
        }
        let waiter = XCTNSPredicateExpectation(predicate: predicate, object: probeElement(app))
        guard XCTWaiter().wait(for: [waiter], timeout: timeout) == .completed else {
            return XCTFail(
                "timed out waiting for: \(what). last state: \(probe(app).fields)",
                file: file, line: line)
        }
    }

    // MARK: - Driving

    @MainActor
    private func launched(
        script: String, root: String, reset: Bool = true, extra: [String] = []
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-PupaStorageRoot", "ephemeral:\(root)",
            "-PupaSkipOnboarding", "1",
        ] + (reset ? ["-PupaStorageReset", "1"] : []) + extra
        app.launchEnvironment["PUPA_SCRIPT"] = script
        // Forwarded by `make ui-test-live`; absent for a scripted run.
        for key in ["PUPA_BACKEND_TOKEN"] {
            if let value = ProcessInfo.processInfo.environment[key] {
                app.launchEnvironment[key] = value
            }
        }
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 90), "app never foregrounded")
        return app
    }

    @MainActor
    private func send(_ app: XCUIApplication, _ text: String) {
        openChat(app)
        let composer = app.textFields[ID.chatComposer]
        XCTAssertTrue(composer.waitForExistence(timeout: 30), "chat composer never appeared")
        composer.tap()
        composer.typeText(text)
        app.buttons[ID.chatSend].tap()
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

    /// Canvas tiles, counted by identifier rather than by name — a name also
    /// appears in the chat transcript that asked for it.
    @MainActor
    private func componentCount(_ app: XCUIApplication) -> Int {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", ID.componentPrefix))
            .count
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
