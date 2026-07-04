import Foundation
import Testing
@testable import PupaApp

/// Tests for `SidebarSelection.globalizedMemoryPath` — the boundary that turns
/// `ChatLink`'s scope-relative memory paths into the global-root-relative paths
/// the shared UI `MemoryStore` reads from. Without it, a tapped
/// `pupa://memory/<path>` link resolves to a path the global store can't find,
/// so the note never opens.
struct SidebarSelectionGlobalizeTests {

    private let appId = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!

    @Test("myApp memory link is prefixed with the app slug")
    func myAppMemoryGlobalized() {
        let sel = SidebarSelection.myAppMemoryFile(appId, "notes/reading.md")
            .globalizedMemoryPath { _ in "My Fitness" }
        #expect(sel == .myAppMemoryFile(appId, "my-fitness/notes/reading.md"))
    }

    @Test("orchestrator memory link is prefixed with orchestrator/")
    func orchestratorMemoryGlobalized() {
        let sel = SidebarSelection.memoryFile("journal.md")
            .globalizedMemoryPath { _ in nil }
        #expect(sel == .memoryFile("orchestrator/journal.md"))
    }

    @Test("Unresolvable myApp id leaves the selection untouched")
    func unknownAppIdPassesThrough() {
        let sel = SidebarSelection.myAppMemoryFile(appId, "notes/x.md")
            .globalizedMemoryPath { _ in nil }
        #expect(sel == .myAppMemoryFile(appId, "notes/x.md"))
    }

    @Test("Non-memory selections pass through untouched")
    func nonMemoryPassesThrough() {
        let sel = SidebarSelection.myAppComponent(appId, "tracker-1")
            .globalizedMemoryPath { _ in "My Fitness" }
        #expect(sel == .myAppComponent(appId, "tracker-1"))
    }

    /// End-to-end: parse the link the agent emits, globalize it, and confirm the
    /// resulting path reads back from a global-rooted store.
    @Test("Parsed ChatLink globalizes to a path the global store can read")
    @MainActor
    func endToEndRoundTrip() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pupa-globalize-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MemoryStore(rootOverride: root)
        try store.writeFile(path: "my-fitness/notes/reading.md", content: "hi")

        let parsed = ChatLink.sidebarSelection(
            from: URL(string: "pupa://memory/notes/reading.md")!, currentMyAppId: appId)
        let global = parsed?.globalizedMemoryPath { _ in "My Fitness" }
        guard case .myAppMemoryFile(_, let path)? = global else {
            Issue.record("expected a myApp memory selection, got \(String(describing: global))")
            return
        }
        #expect(try store.readFile(path: path).content == "hi")
    }
}
