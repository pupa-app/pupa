import Foundation
import Testing
@testable import PupaApp

/// Lazy keep-alive: a tab pays its mount on first visit and stays alive after.
/// The rule matters because the cache is what stops a MyApp switch rebuilding
/// every tab — and because "does opening the drawer or Settings cost me the
/// pages again?" should have an answer that is checked, not argued.
@MainActor
@Suite("Lazy keep-alive")
struct KeepAliveTests {

    private let appA = UUID()
    private let appB = UUID()

    /// What `AppView.init` builds. `KeepAliveState` has no empty initialiser,
    /// so the launch page cannot be left unrecorded — the previous version of
    /// this suite seeded the set by hand in the test body and therefore passed
    /// even with the seed deleted from `init`.
    private func atLaunch(_ id: UUID) -> KeepAliveState {
        KeepAliveState(rootPage: .myAppHome(id), subject: .myApp(id))
    }

    @Test("the launch page is recorded, so the first navigation keeps it")
    func launchPageSurvivesFirstNavigation() {
        var state = atLaunch(appA)
        state.visit(.myAppAgents(appA), subject: .myApp(appA))

        #expect(state.pages.contains(.myAppHome(appA)), "launch page was torn down")
        #expect(state.pages == [.myAppHome(appA), .myAppAgents(appA)])
    }

    @Test("navigating within one app accumulates visited tabs")
    func accumulatesWithinSubject() {
        var state = atLaunch(appA)
        for page in [SidebarSelection.myAppAgents(appA), .myAppMemories(appA)] {
            state.visit(page, subject: .myApp(appA))
        }
        #expect(state.pages == [.myAppHome(appA), .myAppAgents(appA), .myAppMemories(appA)])
    }

    @Test("re-visiting a tab keeps the set intact — no re-mount")
    func revisitIsIdempotent() {
        var state = atLaunch(appA)
        state.visit(.myAppAgents(appA), subject: .myApp(appA))
        let before = state.pages
        state.visit(.myAppHome(appA), subject: .myApp(appA))
        #expect(state.pages == before)
    }

    @Test("switching app starts over, so the set can't grow without bound")
    func subjectChangeResets() {
        var state = atLaunch(appA)
        state.visit(.myAppAgents(appA), subject: .myApp(appA))
        state.visit(.myAppHome(appB), subject: .myApp(appB))

        #expect(state.pages == [.myAppHome(appB)])
        #expect(state.subject == .myApp(appB))
        #expect(!state.pages.contains(.myAppAgents(appA)))
    }

    @Test("the orchestrator is its own subject")
    func orchestratorIsSeparate() {
        var state = atLaunch(appA)
        state.visit(.orchestrator, subject: .orchestrator)
        #expect(state.pages == [.orchestrator])

        state.visit(.orchestratorMemories, subject: .orchestrator)
        #expect(state.pages == [.orchestrator, .orchestratorMemories])
    }
}
