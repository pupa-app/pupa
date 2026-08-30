import Foundation
import Testing
@testable import PupaApp

/// Memory files present as a sheet; everything else still pushes. And a
/// dismissal commits the edit rather than dropping it — the rules that decide
/// both, without a view in the way.
@Suite("Memory file routing")
struct MemoryFileRouteTests {

    // MARK: Which selections become a sheet

    @Test("A myApp memory file routes to a sheet, carrying its app id")
    func myAppFileBecomesARoute() {
        let id = UUID()
        let route = MemoryFileRoute(.myAppMemoryFile(id, "notes/a.md"))
        #expect(route?.myAppId == id)
        #expect(route?.path == "notes/a.md")
        #expect(route?.restoredBuffer == nil)
    }

    @Test("An orchestrator memory file routes to a sheet with no app id")
    func orchestratorFileBecomesARoute() {
        let route = MemoryFileRoute(.memoryFile("orchestrator/journal.md"))
        #expect(route != nil)
        #expect(route?.myAppId == nil)
        #expect(route?.path == "orchestrator/journal.md")
    }

    @Test("Every other selection still pushes")
    func nonFileSelectionsAreNotRoutes() {
        let id = UUID()
        let pushed: [SidebarSelection] = [
            .orchestrator,
            .myAppHome(id),
            .myApp(id),
            .myAppComponent(id, "tracker-1"),
            .myAppAgents(id),
            .myAppAgentDetail(id, agentId: "myapp-main"),
            .myAppMemories(id),
            .myAppHistory(id),
            .orchestratorMemories,
            .orchestratorAgentDetail,
            .screenShare,
        ]
        for sel in pushed {
            #expect(MemoryFileRoute(sel) == nil, "\(sel) should push, not present")
        }
    }

    @Test("A route round-trips back to the selection the chat scope keys off")
    func routeRoundTripsToSelection() {
        let id = UUID()
        #expect(MemoryFileRoute(myAppId: id, path: "a.md").selection
                == .myAppMemoryFile(id, "a.md"))
        #expect(MemoryFileRoute(myAppId: nil, path: "a.md").selection
                == .memoryFile("a.md"))
    }

    @Test("Identity separates the same filename in different scopes")
    func idIsScoped() {
        let a = MemoryFileRoute(myAppId: UUID(), path: "notes.md")
        let b = MemoryFileRoute(myAppId: UUID(), path: "notes.md")
        let orchestrator = MemoryFileRoute(myAppId: nil, path: "notes.md")
        #expect(a.id != b.id)
        #expect(a.id != orchestrator.id)
    }

    @Test("A rescued buffer does not change which file the route is")
    func restoredBufferKeepsIdentity() {
        let id = UUID()
        let fresh = MemoryFileRoute(myAppId: id, path: "a.md")
        let retry = MemoryFileRoute(myAppId: id, path: "a.md", restoredBuffer: "half typed")
        #expect(fresh.id == retry.id)
        #expect(retry.restoredBuffer == "half typed")
    }

    // MARK: What a dismissal does with the buffer

    @Test("Dismissing mid-edit with changes saves them")
    func swipeSavesRealEdits() {
        #expect(MemoryFileDismiss.shouldSave(
            readOnly: false, isEditing: true, buffer: "new", loaded: "old"))
    }

    @Test("Dismissing a file that was only read never rewrites it")
    func readingNeverWrites() {
        // No edit session at all — the common case, and the one where a write
        // would churn mtime and the change log for nothing.
        #expect(!MemoryFileDismiss.shouldSave(
            readOnly: false, isEditing: false, buffer: "same", loaded: "same"))
        // Even if something left a stale buffer behind.
        #expect(!MemoryFileDismiss.shouldSave(
            readOnly: false, isEditing: false, buffer: "drifted", loaded: "on disk"))
    }

    @Test("Dismissing an edit session that changed nothing writes nothing")
    func untouchedEditSessionWritesNothing() {
        #expect(!MemoryFileDismiss.shouldSave(
            readOnly: false, isEditing: true, buffer: "same", loaded: "same"))
    }

    @Test("A locked file is never written, however it is dismissed")
    func lockedFilesNeverWrite() {
        #expect(!MemoryFileDismiss.shouldSave(
            readOnly: true, isEditing: true, buffer: "new", loaded: "old"))
    }
}
