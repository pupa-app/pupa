import Foundation
import Testing
import AGUIKit
@testable import PupaApp

/// Tests for `ChatSessionCoordinator` — the registry that owns one
/// `ChatViewModel` per `ChatScope` and gives the app its concurrent
/// per-myApp chat behaviour (issue #17).
@MainActor
@Suite("ChatSessionCoordinator")
struct ChatSessionCoordinatorTests {

    private func makeStore(spaceCount: Int = 2) -> (store: MyAppStore, ids: [UUID]) {
        MyAppTypeRegistry.shared.registerBuiltins()
        let myApps = (0..<spaceCount).map { i in
            MyApp(name: "MyApp \(i)", iconSystemName: "circle", typeId: MyAppType.tracker.id)
        }
        let store = MyAppStore(initial: (myApps, myApps[0].id))
        return (store, myApps.map(\.id))
    }

    private func makeCoordinator(store: MyAppStore) -> ChatSessionCoordinator {
        ChatSessionCoordinator(
            store: store,
            memory: MemoryStore(rootOverride: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("pupa-tests-\(UUID().uuidString)")),
            settings: SettingsStore(backendURL: URL(string: "http://localhost:65535/")!)
        )
    }

    @Test("session(for:) caches per scope — same key returns same instance")
    func cachesPerScope() {
        let (store, ids) = makeStore()
        let coord = makeCoordinator(store: store)

        let first = coord.session(for: .myApp(ids[0]))
        let second = coord.session(for: .myApp(ids[0]))

        #expect(first === second)
    }

    @Test("Different myApp scopes return distinct ChatViewModel instances")
    func distinctPerSpace() {
        let (store, ids) = makeStore()
        let coord = makeCoordinator(store: store)

        let a = coord.session(for: .myApp(ids[0]))
        let b = coord.session(for: .myApp(ids[1]))

        #expect(a !== b)
        #expect(a.pinnedScope == .myApp(ids[0]))
        #expect(b.pinnedScope == .myApp(ids[1]))
    }

    @Test("Memory scope is independent from any myApp scope")
    func memoryIsSeparate() {
        let (store, ids) = makeStore()
        let coord = makeCoordinator(store: store)

        let mem = coord.session(for: .memory)
        let a = coord.session(for: .myApp(ids[0]))

        #expect(mem !== a)
        #expect(mem.pinnedScope == .memory)
    }

    @Test("discardSession drops the cached session — next session(for:) builds a fresh one")
    func discardEvicts() {
        let (store, ids) = makeStore()
        let coord = makeCoordinator(store: store)

        let original = coord.session(for: .myApp(ids[0]))
        coord.discardSession(for: .myApp(ids[0]))
        let rebuilt = coord.session(for: .myApp(ids[0]))

        #expect(original !== rebuilt)
    }

    @Test("status/aggregateStatus are .idle when no live session exists or the session is fresh")
    func statusIdleByDefault() {
        let (store, ids) = makeStore()
        let coord = makeCoordinator(store: store)
        let tid = store.currentThreadId(for: .myApp(ids[0]))

        // No session opened yet for this scope/thread.
        #expect(coord.status(for: .myApp(ids[0]), threadId: tid) == .idle)
        #expect(coord.aggregateStatus(for: .myApp(ids[0])) == .idle)

        // A freshly-built session (never streamed) is still idle.
        _ = coord.session(for: .myApp(ids[0]), threadId: tid)
        #expect(coord.status(for: .myApp(ids[0]), threadId: tid) == .idle)
        #expect(coord.aggregateStatus(for: .myApp(ids[0])) == .idle)
        // A different scope with no sessions stays idle too.
        #expect(coord.aggregateStatus(for: .myApp(ids[1])) == .idle)
    }

    @Test("busyMyApps starts empty and discardSession is safe to call on a never-streamed session")
    func busySpacesEmptyAndDiscardSafe() {
        let (store, ids) = makeStore()
        let coord = makeCoordinator(store: store)

        #expect(coord.busyMyApps.isEmpty)
        _ = coord.session(for: .myApp(ids[0]))
        #expect(coord.busyMyApps.isEmpty)  // creating a session does not mark it busy
        coord.discardSession(for: .myApp(ids[0]))  // no crash on an idle session
        #expect(coord.busyMyApps.isEmpty)
    }

    /// Direct refcount drive — pins the contract `busyMyApps` exposes a myApp
    /// while *any* claim against it is outstanding. This is the layer the
    /// orchestrator sub-run relies on so that an in-flight `invokeMyAppAgent`
    /// lights up the sidebar spinner the same way the user's own chat would,
    /// AND so a user-stream ending mid-sub-run doesn't prematurely clear it.
    @Test("busyMyApps is refcounted — multiple claims on the same myApp stack and unwind correctly")
    func busySpaces_refcountsAcrossConcurrentClaims() {
        let (store, ids) = makeStore()
        let coord = makeCoordinator(store: store)
        let target = ids[0]

        #expect(coord.busyMyApps.isEmpty)

        // Simulate the user's own chat starting a turn in `target`.
        coord.incrementBusy(target)
        #expect(coord.busyMyApps == [target])

        // Now an orchestrator sub-run kicks off against the same myApp.
        coord.incrementBusy(target)
        #expect(coord.busyMyApps == [target], "Still busy — both claims outstanding")

        // The user's chat finishes first. Spinner must stay lit because the
        // sub-run is still running.
        coord.decrementBusy(target)
        #expect(
            coord.busyMyApps == [target],
            "User chat ended but sub-run still in flight — spinner must remain"
        )

        // Sub-run finishes. Now the myApp is truly idle.
        coord.decrementBusy(target)
        #expect(coord.busyMyApps.isEmpty)
    }

    @Test("Decrementing past zero is a no-op and does not flip busyMyApps into a bad state")
    func busySpaces_decrementPastZeroIsNoOp() {
        let (store, ids) = makeStore()
        let coord = makeCoordinator(store: store)
        let target = ids[0]

        coord.decrementBusy(target)  // never incremented — must not crash or go negative
        #expect(coord.busyMyApps.isEmpty)

        coord.incrementBusy(target)
        coord.decrementBusy(target)
        coord.decrementBusy(target)  // one extra decrement
        #expect(coord.busyMyApps.isEmpty, "Refcount must clamp at zero")

        // After the over-decrement, a fresh claim still works.
        coord.incrementBusy(target)
        #expect(coord.busyMyApps == [target])
    }

    /// End-to-end behavioural test for the orchestrator's sub-run busy-flag
    /// wiring. The coordinator runs against an unreachable backend with a
    /// **fast-timeout** `URLSession` so the sub-run fails quickly; what we
    /// pin is that the target myApp appears in `busyMyApps` while the sub-run
    /// is in flight and is gone again once it settles — i.e. `runOneShot`'s
    /// `incrementBusy` + `defer { decrementBusy(...) }` actually fire.
    @Test("runOneShot lights up busyMyApps for the target myApp while in flight, clears on exit")
    func runOneShot_marksTargetBusyThenClearsOnExit() async throws {
        let (store, ids) = makeStore()
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 0.3
        cfg.timeoutIntervalForResource = 0.3
        let coord = ChatSessionCoordinator(
            store: store,
            memory: MemoryStore(rootOverride: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("pupa-tests-\(UUID().uuidString)")),
            settings: SettingsStore(backendURL: URL(string: "http://127.0.0.1:1/")!),  // guaranteed unreachable
            urlSession: URLSession(configuration: cfg)
        )
        let target = ids[0]

        #expect(coord.busyMyApps.isEmpty)

        let runTask = Task<Void, Never> {
            _ = try? await coord.runOneShot(myAppId: target, prompt: "ping")
        }

        // Wait for runOneShot's incrementBusy to land. The increment is
        // synchronous on MainActor before the HTTP POST is awaited, so this
        // typically clears in the first yield — but allow a small grace
        // window so the test stays robust under scheduler jitter.
        for _ in 0..<50 {
            if coord.busyMyApps.contains(target) { break }
            try await Task.sleep(nanoseconds: 10_000_000)  // 10 ms
        }
        #expect(
            coord.busyMyApps.contains(target),
            "Sub-run must mark its target myApp busy while in flight — sidebar spinner depends on this."
        )

        // Wait for the run to settle (connect timeout → throw → defer fires).
        await runTask.value
        #expect(coord.busyMyApps.isEmpty, "busyMyApps must clear after the sub-run exits.")
    }
}
