import Foundation
import Testing
@testable import PupaApp

/// `NavState` carries the navigation root *and* the lazy keep-alive set,
/// because they have to move together. Two earlier attempts kept them apart
/// and both regressed: first the launch page was never recorded, then the
/// recording call was deletable with every test still green. These tests go
/// through the same type `AppView` drives, so deleting the recording is no
/// longer possible and deleting the filter is caught here.
@MainActor
@Suite("Navigation state")
struct NavStateTests {

    private let appA = UUID()
    private let appB = UUID()

    private var tabsOfA: [SidebarSelection] {
        [.myAppHome(appA), .myAppAgents(appA), .myAppMemories(appA)]
    }

    @Test("the launch page is recorded, so the first navigation keeps it")
    func launchPageSurvivesFirstNavigation() {
        var nav = NavState(rootPage: .myAppHome(appA))
        nav.setRoot(.myAppAgents(appA))

        #expect(nav.mounted.contains(.myAppHome(appA)), "launch page was torn down")
        #expect(nav.panes(from: tabsOfA) == [.myAppHome(appA), .myAppAgents(appA)])
    }

    @Test("the subject is derived from the root page, not supplied separately")
    func subjectIsDerived() {
        // A wrong seed here is what tore Home down the first time; deriving it
        // removes the chance to get it wrong.
        #expect(NavState(rootPage: .myAppHome(appA)).subject == .myApp(appA))
        #expect(NavState(rootPage: .orchestrator).subject == .orchestrator)
        #expect(NavState(rootPage: .screenShare).subject == nil)
    }

    @Test("only visited tabs are mounted — the whole point of lazy keep-alive")
    func unvisitedTabsAreNotMounted() {
        let nav = NavState(rootPage: .myAppHome(appA))
        // Home is the root; agents and memories have never been opened.
        #expect(nav.panes(from: tabsOfA) == [.myAppHome(appA)])
    }

    @Test("a visited tab stays mounted after navigating away")
    func visitedTabStaysMounted() {
        var nav = NavState(rootPage: .myAppHome(appA))
        nav.setRoot(.myAppAgents(appA))
        nav.setRoot(.myAppHome(appA))

        // Agents is no longer the root but must remain mounted, or repeat tab
        // clicks stop being free — the guarantee #154 bought.
        #expect(nav.panes(from: tabsOfA) == [.myAppHome(appA), .myAppAgents(appA)])
    }

    @Test("the root is always mounted even before it is recorded")
    func rootIsAlwaysMounted() {
        var nav = NavState(rootPage: .myAppHome(appA))
        nav.setRoot(.myAppMemories(appA))
        #expect(nav.panes(from: tabsOfA).contains(.myAppMemories(appA)))
    }

    @Test("switching app starts over, so the set can't grow without bound")
    func subjectChangeResets() {
        var nav = NavState(rootPage: .myAppHome(appA))
        nav.setRoot(.myAppAgents(appA))
        nav.setRoot(.myAppHome(appB))

        #expect(nav.mounted == [.myAppHome(appB)])
        #expect(nav.subject == .myApp(appB))
        #expect(!nav.mounted.contains(.myAppAgents(appA)))
    }

    @Test("re-selecting the page already showing changes nothing")
    func resettingSameRootIsANoOp() {
        var nav = NavState(rootPage: .myAppHome(appA))
        nav.setRoot(.myAppAgents(appA))
        let before = nav
        nav.setRoot(.myAppAgents(appA))
        // Equal value => SwiftUI sees no state change and skips invalidation.
        #expect(nav == before)
    }

    @Test("the orchestrator is its own subject")
    func orchestratorIsSeparate() {
        var nav = NavState(rootPage: .myAppHome(appA))
        nav.setRoot(.orchestrator)
        #expect(nav.mounted == [.orchestrator])

        nav.setRoot(.orchestratorMemories)
        #expect(nav.mounted == [.orchestrator, .orchestratorMemories])
    }
}
