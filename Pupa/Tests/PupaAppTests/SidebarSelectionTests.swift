import Foundation
import Testing
@testable import PupaApp

/// Locks the detail-pane fallback that fixes the iOS drawer re-tap regression:
/// the drawer clears `selection` to nil after every tap so re-tapping the same
/// row re-fires `List.onChange`. While nil, `content` must resolve to the active
/// MyApp's *home* (where a tap lands) — not a blank pane or the stale canvas.
@Suite("SidebarSelection.detailRoot")
struct SidebarSelectionTests {

    @Test("nil selection falls back to the active MyApp's home")
    func nilFallsBackToActiveHome() {
        let active = UUID()
        #expect(SidebarSelection.detailRoot(for: nil, activeMyAppId: active) == .myAppHome(active))
    }

    @Test("a set selection passes through unchanged")
    func passthrough() {
        let active = UUID()
        let other = UUID()
        #expect(SidebarSelection.detailRoot(for: .myApp(other), activeMyAppId: active) == .myApp(other))
        #expect(SidebarSelection.detailRoot(for: .orchestrator, activeMyAppId: active) == .orchestrator)
        #expect(
            SidebarSelection.detailRoot(for: .myAppHome(other), activeMyAppId: active) == .myAppHome(other)
        )
    }
}

/// Locks the fix for the "tapping Agents / Memories / a component flashes the
/// page then bounces back to Home" regression on iOS. The drawer clears
/// `selection` to nil after each tap, so any page that *isn't* the active
/// MyApp's home (which `detailRoot` resolves to while nil) must be pushed onto
/// `detailPath` to survive — otherwise it collapses straight back to the canvas.
@Suite("SidebarSelection.iOSDetailStack")
struct IOSDetailStackTests {
    private let id = UUID()

    @Test("home and canvas need no push — they resolve via activeMyAppId")
    func homeAndCanvasAreRoot() {
        #expect(SidebarSelection.myAppHome(id).iOSDetailStack == [])
        #expect(SidebarSelection.myApp(id).iOSDetailStack == [])
    }

    @Test("every other page is pushed so it doesn't bounce to home")
    func subPagesArePushed() {
        // The exact regression: these all bounced when they weren't pushed.
        let pushed: [SidebarSelection] = [
            .myAppAgents(id),
            .myAppAgentDetail(id, agentId: "myapp-main"),
            .myAppMemories(id),
            .myAppMemoryFile(id, "note.md"),
            .myAppComponent(id, "tracker-1"),
            .myAppHistory(id),
            .orchestrator,
            .orchestratorMemories,
            .orchestratorAgentDetail,
            .memoryFile("shared.md"),
            .screenShare,
        ]
        for sel in pushed {
            #expect(sel.iOSDetailStack == [sel])
        }
    }
}

/// Locks the fix for the "switch tabs from a non-home page → blank page"
/// regression on iOS. The bottom bar / sidebar only set `selection`; this single
/// reducer replaces the whole detail stack, so a tab switch never routes through
/// an empty stack (the clear-then-refill that blanked `NavigationStack`).
@Suite("SidebarSelection.detailStack(picking:from:)")
struct DetailStackPickTests {
    private let id = UUID()

    /// The exact regression: picking Memories while already on the Agents page
    /// must land on Memories — not blank — and must NOT route through an empty
    /// stack (the clear-then-refill that glitched NavigationStack).
    @Test("picking a tab from a non-home stack replaces it in one step")
    func replacesNonEmptyStack() {
        let from: [SidebarSelection] = [.myAppAgents(id)]
        #expect(SidebarSelection.detailStack(picking: .myAppMemories(id), from: from)
                == [.myAppMemories(id)])
    }

    @Test("result depends only on the target, not the prior stack")
    func independentOfPriorStack() {
        let priors: [[SidebarSelection]] = [
            [], [.myAppAgents(id)], [.myAppMemories(id)], [.myAppHistory(id)],
            [.myAppComponent(id, "tracker-1")],
        ]
        for prior in priors {
            #expect(SidebarSelection.detailStack(picking: .myAppMemories(id), from: prior)
                    == [.myAppMemories(id)])
        }
        // Home resolves to the stack root from anywhere.
        for prior in priors {
            #expect(SidebarSelection.detailStack(picking: .myAppHome(id), from: prior) == [])
        }
    }
}
