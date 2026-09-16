import Foundation
import Testing
@testable import PupaApp

/// Tests for unsent composer state (`ChatViewModel.draft` / `.draftImages`).
///
/// `ChatOverlay` unmounts `ChatPanel` when the user taps its X, so anything
/// held in panel `@State` is destroyed on close. These cover the property that
/// replaces it: the draft rides the coordinator-cached session, which outlives
/// the view and is keyed per `(scope, threadId)`.
@MainActor
@Suite("Chat drafts")
struct ChatDraftTests {

    private func makeStore(spaceCount: Int = 2) -> (store: MiniAppStore, ids: [UUID]) {
        MiniAppTypeRegistry.shared.registerBuiltins()
        let miniApps = (0..<spaceCount).map { i in
            MiniApp(name: "MiniApp \(i)", iconSystemName: "circle", typeId: MiniAppType.tracker.id)
        }
        let store = MiniAppStore(initial: (miniApps, miniApps[0].id))
        return (store, miniApps.map(\.id))
    }

    private func makeCoordinator(store: MiniAppStore) -> ChatSessionCoordinator {
        ChatSessionCoordinator(
            store: store,
            memory: MemoryStore(rootOverride: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("pupa-tests-\(UUID().uuidString)")),
            settings: SettingsStore(backendURL: URL(string: "http://localhost:65535/")!)
        )
    }

    @Test("Draft survives the panel unmounting — re-fetching the session returns the text")
    func draftSurvivesRefetch() {
        let (store, ids) = makeStore()
        let coord = makeCoordinator(store: store)
        let tid = store.currentThreadId(for: .miniApp(ids[0]))

        coord.session(for: .miniApp(ids[0]), threadId: tid).draft = "half-written thought"
        coord.session(for: .miniApp(ids[0]), threadId: tid).draftImages =
            [PickedImage(data: Data([0x1]), mimeType: "image/png")]

        // Closing + reopening the overlay rebuilds ChatPanel, which asks the
        // coordinator for the session again — same instance, same draft.
        let reopened = coord.session(for: .miniApp(ids[0]), threadId: tid)
        #expect(reopened.draft == "half-written thought")
        #expect(reopened.draftImages.count == 1)
    }

    @Test("Drafts are per thread")
    func draftPerThread() {
        let (store, ids) = makeStore()
        let coord = makeCoordinator(store: store)
        let scope = ChatScope.miniApp(ids[0])
        let first = store.currentThreadId(for: scope)
        store.addThread(for: scope)
        let second = store.currentThreadId(for: scope)
        #expect(first != second)

        coord.session(for: scope, threadId: first).draft = "thread one"

        #expect(coord.session(for: scope, threadId: second).draft.isEmpty)
        #expect(coord.session(for: scope, threadId: first).draft == "thread one")
    }

    @Test("Drafts are per miniApp scope")
    func draftPerScope() {
        let (store, ids) = makeStore()
        let coord = makeCoordinator(store: store)

        coord.session(for: .miniApp(ids[0])).draft = "for the first miniApp"

        #expect(coord.session(for: .miniApp(ids[1])).draft.isEmpty)
        #expect(coord.session(for: .memory).draft.isEmpty)
    }

    @Test("Deleting a thread drops its draft with the session")
    func discardClearsDraft() {
        let (store, ids) = makeStore()
        let coord = makeCoordinator(store: store)
        let tid = store.currentThreadId(for: .miniApp(ids[0]))

        coord.session(for: .miniApp(ids[0]), threadId: tid).draft = "gone with the thread"
        coord.discardSession(for: .miniApp(ids[0]), threadId: tid)

        #expect(coord.session(for: .miniApp(ids[0]), threadId: tid).draft.isEmpty)
    }
}
