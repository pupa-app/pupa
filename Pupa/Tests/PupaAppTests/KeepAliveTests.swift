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

    @Test("navigating within one app accumulates visited tabs")
    func accumulatesWithinSubject() {
        let subject = MyAppHomeView.Subject.myApp(appA)
        var mounted: Set<SidebarSelection> = []
        var current: MyAppHomeView.Subject?

        for page in [SidebarSelection.myAppHome(appA),
                     .myAppAgents(appA),
                     .myAppMemories(appA)] {
            (current, mounted) = KeepAlive.visited(
                page, subject: subject, mounted: mounted, mountedSubject: current)
        }

        #expect(mounted == [.myAppHome(appA), .myAppAgents(appA), .myAppMemories(appA)])
        #expect(current == subject)
    }

    @Test("re-visiting a tab keeps the set intact — no re-mount")
    func revisitIsIdempotent() {
        let subject = MyAppHomeView.Subject.myApp(appA)
        var mounted: Set<SidebarSelection> = [.myAppHome(appA), .myAppAgents(appA)]
        var current: MyAppHomeView.Subject? = subject

        (current, mounted) = KeepAlive.visited(
            .myAppHome(appA), subject: subject, mounted: mounted, mountedSubject: current)

        #expect(mounted == [.myAppHome(appA), .myAppAgents(appA)])
    }

    @Test("switching app starts over, so the set can't grow without bound")
    func subjectChangeResets() {
        var mounted: Set<SidebarSelection> = [.myAppHome(appA), .myAppAgents(appA)]
        var current: MyAppHomeView.Subject? = .myApp(appA)

        (current, mounted) = KeepAlive.visited(
            .myAppHome(appB), subject: .myApp(appB),
            mounted: mounted, mountedSubject: current)

        #expect(mounted == [.myAppHome(appB)])
        #expect(current == .myApp(appB))
        // App A's pages leave `keepAlivePages` on the switch anyway.
        #expect(!mounted.contains(.myAppAgents(appA)))
    }

    @Test("the orchestrator is its own subject")
    func orchestratorIsSeparate() {
        var mounted: Set<SidebarSelection> = [.myAppHome(appA)]
        var current: MyAppHomeView.Subject? = .myApp(appA)

        (current, mounted) = KeepAlive.visited(
            .orchestrator, subject: .orchestrator,
            mounted: mounted, mountedSubject: current)
        #expect(mounted == [.orchestrator])

        (current, mounted) = KeepAlive.visited(
            .orchestratorMemories, subject: .orchestrator,
            mounted: mounted, mountedSubject: current)
        #expect(mounted == [.orchestrator, .orchestratorMemories])
    }
}
