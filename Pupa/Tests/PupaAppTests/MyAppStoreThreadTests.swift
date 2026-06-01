import Foundation
import Testing
@testable import PupaApp

/// Tests for the thread-management API on `MyAppStore`.
///
/// Covers: `addThread`, `setCurrentThread`, `setThreadTitle`, `removeThread`,
/// `threads(for:)`, `currentThreadId(for:)` — the full CRUD surface introduced
/// in issue #261.
@MainActor
@Suite("MyAppStore thread management")
struct MyAppStoreThreadTests {

    private func makeStore() -> (store: MyAppStore, id: UUID) {
        MyAppTypeRegistry.shared.registerBuiltins()
        let app = MyApp(name: "A", iconSystemName: "circle", typeId: MyAppType.tracker.id)
        let store = MyAppStore(initial: ([app], app.id))
        return (store, app.id)
    }

    // MARK: - addThread

    @Test("addThread appends a new thread and makes it current")
    func addThread_appendsAndSelects() {
        let (store, id) = makeStore()
        let scope = ChatScope.myApp(id)
        let initial = store.currentThreadId(for: scope)
        let initialCount = store.threads(for: scope).count

        let newId = store.addThread(for: scope)

        #expect(store.threads(for: scope).count == initialCount + 1)
        #expect(store.currentThreadId(for: scope) == newId)
        #expect(newId != initial)
    }

    @Test("addThread on memory scope appends to memoryThreads")
    func addThread_memoryScope() {
        let (store, _) = makeStore()
        let initialMemory = store.memoryCurrentThreadId
        let initialCount = store.memoryThreads.count

        let newId = store.addThread(for: .memory)

        #expect(store.memoryThreads.count == initialCount + 1)
        #expect(store.memoryCurrentThreadId == newId)
        #expect(newId != initialMemory)
    }

    @Test("addThread on one scope does not affect any other scope")
    func addThread_isolatedToScope() {
        MyAppTypeRegistry.shared.registerBuiltins()
        let a = MyApp(name: "A", iconSystemName: "circle", typeId: MyAppType.tracker.id)
        let b = MyApp(name: "B", iconSystemName: "square", typeId: MyAppType.tracker.id)
        let store = MyAppStore(initial: ([a, b], a.id))

        let initialB = store.currentThreadId(for: .myApp(b.id))
        let initialMemory = store.memoryCurrentThreadId

        store.addThread(for: .myApp(a.id))

        #expect(store.currentThreadId(for: .myApp(b.id)) == initialB)
        #expect(store.memoryCurrentThreadId == initialMemory)
    }

    // MARK: - setCurrentThread

    @Test("setCurrentThread switches the active thread without adding one")
    func setCurrentThread_switchesSelection() {
        let (store, id) = makeStore()
        let scope = ChatScope.myApp(id)
        let first = store.currentThreadId(for: scope)
        let second = store.addThread(for: scope)

        // Switch back to the first.
        store.setCurrentThread(first, for: scope)
        #expect(store.currentThreadId(for: scope) == first)

        // And forward to the second.
        store.setCurrentThread(second, for: scope)
        #expect(store.currentThreadId(for: scope) == second)
        // Still only two threads.
        #expect(store.threads(for: scope).count == 2)
    }

    @Test("setCurrentThread with an unknown id is a no-op")
    func setCurrentThread_unknownIdIgnored() {
        let (store, id) = makeStore()
        let scope = ChatScope.myApp(id)
        let current = store.currentThreadId(for: scope)
        store.setCurrentThread("does-not-exist", for: scope)
        #expect(store.currentThreadId(for: scope) == current)
    }

    // MARK: - setThreadTitle

    @Test("setThreadTitle sets the title on an untitled thread")
    func setThreadTitle_setsOnce() {
        let (store, id) = makeStore()
        let scope = ChatScope.myApp(id)
        let threadId = store.currentThreadId(for: scope)

        store.setThreadTitle("My first chat", threadId: threadId, for: scope)

        let title = store.threads(for: scope).first(where: { $0.id == threadId })?.title
        #expect(title == "My first chat")
    }

    @Test("setThreadTitle is a no-op if the thread already has a title")
    func setThreadTitle_setOnce_notOverwritten() {
        let (store, id) = makeStore()
        let scope = ChatScope.myApp(id)
        let threadId = store.currentThreadId(for: scope)

        store.setThreadTitle("First title", threadId: threadId, for: scope)
        store.setThreadTitle("Second title", threadId: threadId, for: scope)

        let title = store.threads(for: scope).first(where: { $0.id == threadId })?.title
        #expect(title == "First title", "Title must not be overwritten once set")
    }

    @Test("setThreadTitle with empty/whitespace-only string is a no-op")
    func setThreadTitle_emptyIgnored() {
        let (store, id) = makeStore()
        let scope = ChatScope.myApp(id)
        let threadId = store.currentThreadId(for: scope)

        store.setThreadTitle("   ", threadId: threadId, for: scope)
        store.setThreadTitle("", threadId: threadId, for: scope)

        let title = store.threads(for: scope).first(where: { $0.id == threadId })?.title
        #expect(title == "", "Blank title must leave the thread untitled")
    }

    // MARK: - removeThread

    @Test("removeThread removes the thread and selects a neighbour")
    func removeThread_removesAndSelectsNeighbour() {
        let (store, id) = makeStore()
        let scope = ChatScope.myApp(id)
        let first = store.currentThreadId(for: scope)
        let second = store.addThread(for: scope)
        #expect(store.currentThreadId(for: scope) == second)

        store.removeThread(second, for: scope)

        #expect(store.threads(for: scope).count == 1)
        #expect(store.threads(for: scope)[0].id == first)
        #expect(store.currentThreadId(for: scope) == first)
    }

    @Test("removeThread never leaves a scope with zero threads — auto-creates one")
    func removeThread_neverEmptiesScope() {
        let (store, id) = makeStore()
        let scope = ChatScope.myApp(id)
        let only = store.currentThreadId(for: scope)
        #expect(store.threads(for: scope).count == 1)

        store.removeThread(only, for: scope)

        #expect(store.threads(for: scope).count == 1, "Must always have at least one thread")
        #expect(!store.threads(for: scope).isEmpty)
        // The auto-created replacement is now current.
        let newCurrent = store.currentThreadId(for: scope)
        #expect(store.threads(for: scope).contains(where: { $0.id == newCurrent }))
    }

    @Test("removeThread on memory scope never empties memory threads")
    func removeThread_memoryNeverEmpty() {
        let (store, _) = makeStore()
        let only = store.memoryCurrentThreadId
        store.removeThread(only, for: .memory)
        #expect(store.memoryThreads.count == 1)
    }

    @Test("removeThread with an unknown id is a no-op")
    func removeThread_unknownIdIgnored() {
        let (store, id) = makeStore()
        let scope = ChatScope.myApp(id)
        let count = store.threads(for: scope).count
        let current = store.currentThreadId(for: scope)

        store.removeThread("ghost-id", for: scope)

        #expect(store.threads(for: scope).count == count)
        #expect(store.currentThreadId(for: scope) == current)
    }

    // MARK: - New MyApp starts with exactly one thread

    @Test("A newly-created MyApp has exactly one thread and it is the current thread")
    func newMyApp_hasOneThread() {
        let (store, id) = makeStore()
        let scope = ChatScope.myApp(id)
        let threads = store.threads(for: scope)

        #expect(threads.count == 1)
        #expect(threads[0].id == store.currentThreadId(for: scope))
        #expect(threads[0].title == "")
    }

    // MARK: - Memory scope initial state

    @Test("Memory scope starts with exactly one thread")
    func memoryScope_startsWithOneThread() {
        let (store, _) = makeStore()
        #expect(store.memoryThreads.count == 1)
        #expect(store.memoryThreads[0].id == store.memoryCurrentThreadId)
    }
}
