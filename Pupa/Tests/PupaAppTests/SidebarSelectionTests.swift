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
