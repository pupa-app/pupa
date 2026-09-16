import Foundation
import AGUIKit
import PupaScripting
import PupaApp

/// A real Pupa object graph, headless.
///
/// Builds the same stores the app builds — `MiniAppStore`, `MemoryStore`,
/// `SettingsStore`, `ChatSessionCoordinator` — against a storage root of your
/// choosing and a `URLSession` of your choosing, then lets a caller send chat
/// turns and read back everything they touched. The graph is the app's, not a
/// stand-in: tools are registered by `ChatSessionCoordinator`, so a turn here
/// runs the same handlers a tap does.
///
/// Two ways to drive it:
/// - `ScriptedTransport.session()` — deterministic, no network.
/// - a live backend URL with a default session — the real thing.
///
/// `PupaStorage.overrideRoot` is process-global, so one `Scenario` per process
/// (or serialize them, as `make test` already does with `--no-parallel`).
@MainActor
public final class Scenario {
    public let root: URL
    public let store: MiniAppStore
    public let memory: MemoryStore
    public let settings: SettingsStore
    public let coordinator: ChatSessionCoordinator

    /// The MiniApp every `send` targets.
    public private(set) var miniAppId: UUID
    public let orchestrator: Bool

    /// Whatever `PupaStorage.overrideRoot` held before this scenario claimed
    /// it. `PupaStorage` is process-global, so a scenario sharing a process
    /// with other suites must hand it back — see `restoreStorageRoot()`.
    private let previousStorageRoot: URL?

    public var scope: ChatScope { orchestrator ? .memory : .miniApp(miniAppId) }
    public var threadId: String { store.currentThreadId(for: scope) }
    public var vm: ChatViewModel { coordinator.session(for: scope) }

    /// - Parameters:
    ///   - root: storage root. **Always** overrides `PupaStorage`, so a
    ///     scenario can never write to real app data.
    ///   - backend: the AG-UI endpoint. Scripted runs still need one — the
    ///     transport intercepts it before it reaches the network.
    ///   - urlSession: `ScriptedTransport.session()` or a live session.
    ///   - typeId: MiniApp type to seed. Defaults to tracker.
    ///   - reset: wipe `root` first. False continues an existing store, which
    ///     is what multi-turn `PupaCtl --continue` needs.
    ///   - token: paired-device token for a live backend. Held in memory only
    ///     — see `TokenCredentialStore`. Scripted runs don't need one.
    ///   - harnessID: backend agent harness (`claude_code`, `deepagents`).
    ///     `nil` posts to the backend's default harness at `POST /`.
    public init(
        root: URL,
        backend: URL,
        urlSession: URLSession,
        typeId: String = MiniAppType.tracker.id,
        reset: Bool = true,
        token: String? = nil,
        harnessID: String? = nil,
        orchestrator: Bool = false,
        selectedMiniAppId: UUID? = nil
    ) {
        if reset { try? FileManager.default.removeItem(at: root) }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        self.previousStorageRoot = PupaStorage.overrideRoot
        PupaStorage.overrideRoot = root
        self.root = root
        self.orchestrator = orchestrator

        MiniAppTypeRegistry.shared.registerBuiltins()

        // A restored store already has apps; only seed when it came up empty.
        let restored = MiniAppStore()
        if let existing = restored.miniApps.first(where: { $0.id == selectedMiniAppId && !$0.isArchived })
            ?? restored.miniApps.first(where: { !$0.isArchived }) {
            self.store = restored
            self.miniAppId = existing.id
        } else {
            let seed = MiniApp(name: "Harness", iconSystemName: "circle", typeId: typeId)
            self.store = MiniAppStore(initial: ([seed], seed.id))
            self.miniAppId = seed.id
        }

        // No override — `PupaStorage.memoriesRoot` already follows the root
        // set above, so the tree lands exactly where the app puts it.
        self.memory = MemoryStore()
        self.settings = SettingsStore(
            backendURL: backend,
            harnessID: harnessID,
            credentials: TokenCredentialStore(token: token))
        self.coordinator = ChatSessionCoordinator(
            store: store, memory: memory, settings: settings, urlSession: urlSession)
    }

    /// Load the thread's history, the way `ConversationPager` does when a
    /// conversation becomes visible: on-device transcript first, backend fetch
    /// behind it. Without this a fresh process reports an empty chat for a
    /// thread that has one, and the session doesn't know the send is a
    /// continuation.
    ///
    /// The cached read is synchronous, so `settle` only covers the backend
    /// fetch — a genuinely empty thread returns as soon as it elapses.
    public func hydrate(settle: TimeInterval = 1) async {
        vm.loadHistoryIfNeeded()
        _ = await poll(timeout: settle) { !self.vm.bubbles.isEmpty }
    }

    /// Send one turn and wait for the session to go idle.
    ///
    /// Returns false if the turn never settled inside `timeout` — a hung turn
    /// is a finding, so callers should surface it rather than assert on state.
    @discardableResult
    public func send(_ text: String, timeout: TimeInterval = 120) async -> Bool {
        vm.send(text)
        return await waitIdle(timeout: timeout)
    }

    /// Wait for streaming to start and then stop. A turn that never starts
    /// (rejected, queued behind another) settles immediately.
    public func waitIdle(timeout: TimeInterval = 120) async -> Bool {
        _ = await poll(timeout: 2) { self.coordinator.anyStreaming }
        return await poll(timeout: timeout) { !self.coordinator.anyStreaming }
    }

    private func poll(timeout: TimeInterval, _ done: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if done() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return done()
    }

    /// Everything the last turns did, in one readable object.
    public func report() -> ScenarioReport {
        // Whichever transport was driving this run recorded the wire; a live
        // run through a plain session records neither and reports no rounds.
        let wire = ScriptedTransport.postBodies.isEmpty
            ? RecordingTransport.postBodies
            : ScriptedTransport.postBodies
        return ScenarioReport(
            miniApp: store.miniApps.first(where: { $0.id == miniAppId }),
            threadId: threadId,
            bubbles: vm.bubbles,
            connectionIssue: vm.connectionIssue.map { String(describing: $0) },
            wire: wire,
            root: root)
    }

    /// Wait for a report to satisfy `condition`.
    ///
    /// The on-disk records (`recovery`, `journal`) are written by a detached
    /// task chained after each settle, so they lag the in-memory turn by a
    /// beat. Anything asserting on them must poll rather than sample once.
    public func waitForReport(
        timeout: TimeInterval = 5, where condition: @escaping (ScenarioReport) -> Bool
    ) async -> ScenarioReport {
        _ = await poll(timeout: timeout) { condition(self.report()) }
        return report()
    }

    /// Give `PupaStorage.overrideRoot` back to whoever held it. A test suite
    /// sharing the process with others must call this before it returns, or
    /// every later suite writes into this scenario's root.
    public func restoreStorageRoot() {
        PupaStorage.overrideRoot = previousStorageRoot
    }

    /// Point the scenario at a different MiniApp — `PupaCtl --app`.
    public func select(miniAppId id: UUID) {
        guard store.miniApps.contains(where: { $0.id == id }) else { return }
        miniAppId = id
    }
}
