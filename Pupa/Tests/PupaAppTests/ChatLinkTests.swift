import Foundation
import Testing
@testable import PupaApp

/// Tests for `ChatLink.sidebarSelection(from:currentMyAppId:)` — the pure
/// parser that turns `pupa://` markdown links the agent emits in chat into
/// in-app navigation targets. Pins the scope-relative resolution (the agent
/// emits only relative note paths) and the fall-through for real URLs.
struct ChatLinkTests {

    private let appId = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!

    private func url(_ s: String) -> URL { URL(string: s)! }

    @Test("Scope-relative memory link binds to the current myApp")
    func memoryInMyAppScope() {
        let sel = ChatLink.sidebarSelection(
            from: url("pupa://memory/notes/reading.md"), currentMyAppId: appId)
        #expect(sel == .myAppMemoryFile(appId, "notes/reading.md"))
    }

    @Test("Scope-relative memory link in orchestrator scope is a plain memory file")
    func memoryInOrchestratorScope() {
        let sel = ChatLink.sidebarSelection(
            from: url("pupa://memory/journal.md"), currentMyAppId: nil)
        #expect(sel == .memoryFile("journal.md"))
    }

    @Test("Percent-encoded spaces in the path are decoded")
    func decodesPercentEncoding() {
        let sel = ChatLink.sidebarSelection(
            from: url("pupa://memory/My%20Note.md"), currentMyAppId: nil)
        #expect(sel == .memoryFile("My Note.md"))
    }

    @Test("Explicit cross-scope myapp link carries its own app id")
    func explicitMyAppMemory() {
        let other = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let sel = ChatLink.sidebarSelection(
            from: url("pupa://myapp/22222222-2222-2222-2222-222222222222/memory/a/b.md"),
            currentMyAppId: appId)
        #expect(sel == .myAppMemoryFile(other, "a/b.md"))
    }

    @Test("Component link resolves against the current myApp")
    func componentLink() {
        let sel = ChatLink.sidebarSelection(
            from: url("pupa://component/tracker-1"), currentMyAppId: appId)
        #expect(sel == .myAppComponent(appId, "tracker-1"))
    }

    @Test("Component link with no current myApp is unresolvable")
    func componentLinkNoScope() {
        #expect(ChatLink.sidebarSelection(
            from: url("pupa://component/tracker-1"), currentMyAppId: nil) == nil)
    }

    @Test("Empty memory path is rejected")
    func emptyMemoryPath() {
        #expect(ChatLink.sidebarSelection(
            from: url("pupa://memory/"), currentMyAppId: appId) == nil)
    }

    @Test("Real web URLs fall through (nil → system browser)")
    func nonPupaFallsThrough() {
        #expect(ChatLink.sidebarSelection(
            from: url("https://example.com/page"), currentMyAppId: appId) == nil)
        #expect(ChatLink.sidebarSelection(
            from: url("pupa-mention://agent-7"), currentMyAppId: appId) == nil)
    }
}
