import Foundation
import Observation
import AGUIKit

/// Errors thrown by `ChatSessionCoordinator.runSubagent` distinct from an
/// `AgentInvocationRejection`. Surfaced by the `invoke_agent` tool handler as
/// an `{ok:false, error}` echo.
public enum SubagentRunError: Error, CustomStringConvertible {
    case notFound(String)
    public var description: String {
        switch self {
        case .notFound(let name): return "no subagent named '\(name)' (create pupa/agents/<slug>/AGENTS.md)"
        }
    }
}

/// Owns one `ChatViewModel` per `ChatScope` (one per myApp + one shared for
/// memory mode) and lazily creates them on first access. Sessions live for
/// the rest of the app process (or until their backing myApp is deleted), so
/// a stream started in myApp A keeps running when the user navigates to
/// myApp B — the visible chat just rebinds to B's session.
///
/// Each session owns its own `AgentSession`, `ToolRegistry`, and stream
/// task. The registry is built with tools pinned to the session's scope, so
/// tool dispatch from concurrent streams never races on `activeMyAppId`.
@MainActor
@Observable
public final class ChatSessionCoordinator {
    /// Merge the active backend harness's own permission-control values (e.g.
    /// Claude Code's `claude_loop_native` / `claude_loop_auto_approve`) into a
    /// `RunAgentInput.state` dict, keyed by the exact state key its gate reads.
    /// Empty for LangGraph. Shared by the sub-run / A2A / slack state builders.
    @MainActor
    static func mergeActiveHarnessControls(into entries: inout [String: AnyJSON], settings: SettingsStore) {
        guard let harnessID = settings.activeHarnessID else { return }
        for (key, value) in settings.harnessControls(harnessID: harnessID) {
            switch value {
            case .bool(let b): entries[key] = .bool(b)
            case .string(let s): entries[key] = .string(s)
            case .stringSet(let arr): entries[key] = .array(arr.sorted().map(AnyJSON.string))
            }
        }
    }

    /// MyApp ids with at least one in-flight stream right now. Derived from
    /// `busyCounts` — a refcount per myApp — so independent concurrent
    /// streams against the same myApp (e.g. the user's own chat plus an
    /// orchestrator sub-run, or two parallel `invokeMyAppAgent` calls that
    /// happen to target the same myApp) don't race on a shared `Set`
    /// membership flag. Reads are O(1) on `busyCounts.keys`. The computed
    /// property still triggers `@Observable` re-evaluation because it reads
    /// the observed `busyCounts` storage.
    public var busyMyApps: Set<UUID> { Set(busyCounts.keys) }
    /// Per-myApp refcount of in-flight streams. `> 0` means visible streaming.
    /// Bumped by per-session `onStreamingChange` (the user's own chat in that
    /// myApp) AND by `runOneShot` for the lifetime of each orchestrator
    /// sub-run, so the sidebar spinner reflects both.
    private var busyCounts: [UUID: Int] = [:]

    /// Uniquely identifies one conversation — scope (which agent) + threadId
    /// (which conversation within that agent). Keying by both lets every thread
    /// maintain independent bubbles and in-flight streams while the user swipes.
    struct SessionKey: Hashable {
        let scope: ChatScope
        let threadId: String
    }

    private let store: MyAppStore
    private let memory: MemoryStore
    private let settings: SettingsStore
    private let urlSession: URLSession
    private var sessions: [SessionKey: ChatViewModel] = [:]

    /// Lifetime per-agent activity counters. Bumped via the gate's
    /// `onNestedEnter` hook so every MyApp sub-run and Slack sub-agent
    /// records `delegationsMade` / `invocationsReceived` through one path.
    public let agentStats: AgentStatsStore

    /// Cross-scope agent-invocation policy. Owns the busy set,
    /// invocation stack, and chain-depth cap. Shared with
    /// `slackInvoker` (which adds Slack-specific UI substrate on top)
    /// so MyApp sub-runs and Slack sub-agents participate in a single
    /// invocation graph — reentrancy is detected across the two
    /// scopes. Reads by SwiftUI go through `slackInvoker` for the
    /// Slack-shaped views; future agent scopes will gain their own
    /// thin adapters around this same gate.
    public let agentInvocationGate: AgentInvocationGate

    /// Per-Slack-agent lock + invocation-stack state. Driven by
    /// `invokeSlackAgent` and read by `SlackView` to show per-agent
    /// "thinking…" indicators. Held here (not on `SlackView`) so the
    /// state survives view rebinds and so a sub-agent invocation
    /// chain shares the same lock state as the user-triggered run
    /// that started it.
    public let slackInvoker: SlackInvoker

    public init(
        store: MyAppStore,
        memory: MemoryStore,
        settings: SettingsStore,
        agentStats: AgentStatsStore? = nil,
        urlSession: URLSession? = nil
    ) {
        self.store = store
        self.memory = memory
        self.settings = settings
        let stats = agentStats ?? AgentStatsStore()
        self.agentStats = stats
        // Use the cert-pinning session when the active backend has a fingerprint;
        // fall back to .shared (or the injected test session) otherwise.
        self.urlSession = urlSession ?? settings.backendSession
        let gate = AgentInvocationGate(
            maxChainDepth: settings.a2aMaxChainDepth,
            maxTurnsPerPair: settings.a2aMaxTurnsPerPair
        )
        self.agentInvocationGate = gate
        self.slackInvoker = SlackInvoker(gate: gate)
        // Record lifetime activity at the one chokepoint every nested run
        // funnels through. `caller` delegated to `target`.
        gate.onNestedEnter = { [weak stats] caller, target in
            stats?.bump(caller.statKey, AgentStatsStore.delegationsMade)
            stats?.bump(target.statKey, AgentStatsStore.invocationsReceived)
        }
        bootstrapMemories()
    }

    /// Refresh the A2A gate's limits from the current `SettingsStore` values.
    /// Called right before each gate decision so changes made in
    /// Settings → Agent-to-agent take effect on the next invocation without
    /// an app restart.
    private func syncGateLimitsFromSettings() {
        agentInvocationGate.maxChainDepth = settings.a2aMaxChainDepth
        agentInvocationGate.maxTurnsPerPair = settings.a2aMaxTurnsPerPair
    }

    /// Write AGENTS.md for every existing myApp and the orchestrator at
    /// startup, so the sidebar shows files immediately without waiting for
    /// a chat session to be lazily opened.
    private func bootstrapMemories() {
        let orchMemory = MemoryStore(rootOverride: MemoryStore.orchestratorRoot())
        if !orchMemory.fileExists(at: MemoryStore.pupaAgentsPath) {
            _ = try? orchMemory.writeFile(path: MemoryStore.pupaAgentsPath, content: Self.orchestratorAgentsMd())
            memory.rescan()
        }
        for myApp in store.myApps {
            ensureMyAppMemory(myApp)
        }
    }

    /// Idempotent: writes AGENTS.md for a myApp if it doesn't exist yet.
    /// Call when a new myApp is created so the sidebar shows the file
    /// immediately, before any chat session is opened.
    public func ensureMyAppMemory(_ myApp: MyApp) {
        let appMemory = MemoryStore(rootOverride: MemoryStore.appRoot(myAppName: myApp.name))
        if !appMemory.fileExists(at: MemoryStore.pupaAgentsPath) {
            let typeFragment = MyAppTypeRegistry.shared.resolve(id: myApp.typeId)
                .map { $0.baseSystemPromptFragment } ?? ""
            let content = """
                # \(myApp.name)

                **Type:** \(myApp.typeId)

                ## Instructions
                \(typeFragment.isEmpty ? "_No instructions set._" : typeFragment)
                """
            _ = try? appMemory.writeFile(path: MemoryStore.pupaAgentsPath, content: content)
            memory.rescan()
        }
    }

    private static func orchestratorAgentsMd() -> String {
        """
        # Orchestrator

        Manages the full workspace. Has access to the memories filesystem \
        and can create, list, and delegate work to myApps.

        ## Tool surface
        - **Memories filesystem** — read/write/organise notes that persist across sessions
        - **`listMyApps`** — list available myApps
        - **`createMyApp`** — create a new myApp
        - **`invokeMyAppAgent`** — delegate a one-shot prompt to any myApp's agent; \
        fan out multiple calls in one turn to run in parallel

        > Edit this file to customise orchestrator behaviour.
        """
    }

    /// Resolve (or lazily build) the session for a specific `(scope, threadId)` pair.
    /// Each conversation gets its own independent VM and stream.
    public func session(for scope: ChatScope, threadId: String) -> ChatViewModel {
        let key = SessionKey(scope: scope, threadId: threadId)
        if let existing = sessions[key] { return existing }
        let vm = makeSession(for: scope, threadId: threadId)
        sessions[key] = vm
        return vm
    }

    /// Convenience overload — resolves the store's current threadId for the scope
    /// first. Used by AppView and memory-focus paths that only care about the
    /// active conversation.
    public func session(for scope: ChatScope) -> ChatViewModel {
        session(for: scope, threadId: store.currentThreadId(for: scope))
    }

    /// Live status of one conversation, for the thread-list badges. Threads
    /// that never opened a session have no VM → `.idle` (no badge).
    public func status(for scope: ChatScope, threadId: String) -> ChatActivityStatus {
        sessions[SessionKey(scope: scope, threadId: threadId)]?.activityStatus ?? .idle
    }

    /// Highest-priority status across all live threads of a scope. Drives the
    /// collapsed pupa-circle badge. Reads `@Observable` storage (`sessions` +
    /// each VM's tracked properties) so a SwiftUI body that calls this
    /// re-renders when any contributing thread changes.
    public func aggregateStatus(for scope: ChatScope) -> ChatActivityStatus {
        sessions.reduce(ChatActivityStatus.idle) { acc, kv in
            kv.key.scope == scope ? .max(acc, kv.value.activityStatus) : acc
        }
    }

    /// True while any live session is streaming — read by the scenePhase
    /// hook to decide whether backgrounding needs a UIKit background task
    /// to keep the SSE socket alive a little longer.
    public var anyStreaming: Bool {
        sessions.values.contains { $0.isStreaming }
    }

    /// Foreground recovery: ask every live session to re-attach to any run
    /// whose stream died while the app was backgrounded. Each VM no-ops
    /// unless its last turn was actually interrupted, so calling this on
    /// every foreground transition is cheap. See pupa#103.
    public func reattachAllAfterForeground() {
        for vm in sessions.values { vm.reattachIfNeeded() }
    }

    private func makeSession(for scope: ChatScope, threadId: String) -> ChatViewModel {
        let registry = ToolRegistry()
        // Each session gets its own scoped MemoryStore so `lsMemories` /
        // `readMemoryFile` / etc. only see that scope's subtree. The global
        // `memory` is used by the sidebar; it is rescanned after each turn
        // so the sidebar reflects writes made through the scoped store.
        let sessionMemory: MemoryStore
        let sessionToolGateState: ToolGateState
        switch scope {
        case .myApp(let id):
            let myApp = store.myApps.first(where: { $0.id == id })
            let name = myApp?.name ?? ""
            sessionMemory = MemoryStore(rootOverride: MemoryStore.appRoot(myAppName: name))
            sessionMemory.onDidMutate = { [weak self] in self?.memory.rescan() }
            if let myApp { ensureMyAppMemory(myApp) }
            AppTools.registerMyAppTools(
                on: registry,
                store: store,
                myAppId: id,
                memory: sessionMemory,
                slack: mainChatSlackContext(myAppId: id)
            )
            AppTools.registerMemoryTools(on: registry, memory: sessionMemory)
            AppTools.registerSkillTools(on: registry, memory: sessionMemory)
            // Generic subagent invocation: the main agent can delegate to any
            // `pupa/agents/<slug>/AGENTS.md` subagent in this myApp.
            AppTools.registerSubagentTools(on: registry, run: { [weak self] name, prompt in
                guard let self else { return "" }
                return try await self.runSubagent(myAppId: id, agentName: name, prompt: prompt)
            })
            let toolGateState = ToolGateState()
            sessionToolGateState = toolGateState
            AppTools.registerNotificationTools(on: registry, coordinator: .shared, toolGateState: toolGateState)
            if let myApp,
               let type = MyAppTypeRegistry.shared.resolve(id: myApp.typeId) {
                AppTools.registerToolGates(on: registry, myAppType: type, toolGateState: toolGateState)
            }
        case .memory:
            let toolGateState = ToolGateState()
            sessionToolGateState = toolGateState
            sessionMemory = MemoryStore(rootOverride: MemoryStore.orchestratorRoot())
            sessionMemory.onDidMutate = { [weak self] in self?.memory.rescan() }
            AppTools.registerMemoryTools(on: registry, memory: sessionMemory)
            AppTools.registerSkillTools(on: registry, memory: sessionMemory)
            AppTools.registerNotificationTools(on: registry, coordinator: .shared, toolGateState: toolGateState)
            // Orchestrator surface: lets the memory-mode agent see / create
            // myApps and delegate a one-shot prompt to any existing myApp's
            // agent via runOneShot below. Only registered on .memory.
            AppTools.registerOrchestratorTools(
                on: registry,
                store: store,
                runOneShot: { [weak self] myAppId, prompt in
                    guard let self else { return "" }
                    return try await self.runOneShot(myAppId: myAppId, prompt: prompt)
                },
                onMyAppCreated: { [weak self] myApp in
                    Task { @MainActor [weak self] in self?.ensureMyAppMemory(myApp) }
                }
            )
        }
        let vm = ChatViewModel(
            store: store,
            memory: sessionMemory,
            settings: settings,
            registry: registry,
            scope: scope,
            threadId: threadId,
            urlSession: urlSession,
            toolGateState: sessionToolGateState,
            onStreamingChange: { [weak self] streaming in
                self?.updateBusy(scope: scope, streaming: streaming)
                // Rescan the global store after each turn so the sidebar
                // reflects any files the session's scoped store just wrote.
                if !streaming { self?.memory.rescan() }
            }
        )
        // Refresh the session's skill cache whenever its scoped memory mutates
        // (agent or user wrote a file), so the `/skill` palette and the skills
        // context entry pick up newly added `pupa/skills/`. Chains the existing
        // per-scope sidebar-sync handler set above.
        let priorOnMutate = sessionMemory.onDidMutate
        sessionMemory.onDidMutate = { [weak vm] in
            priorOnMutate?()
            vm?.refreshSkills()
        }
        // Wire `ask_user_questions` into the registry now that the
        // ChatViewModel exists to serve as the bridge. The handler is
        // captured weakly so the registry doesn't pin the VM.
        AppTools.registerHumanInTheLoopTools(on: registry, bridge: vm)
        return vm
    }

    /// Spin up a transient sub-session against `myAppId` with a fresh
    /// `threadId` and the target myApp's full tool surface (canvas mutators
    /// + memories), send `prompt` as a single user message, run the
    /// multi-round AG-UI loop to completion, and return the concatenated
    /// final assistant text.
    ///
    /// Used by the orchestrator's `invokeMyAppAgent` frontend tool when
    /// memory-mode chat delegates work to a myApp. Sub-runs do NOT mutate
    /// the target myApp's persistent `threadId` — the user's own
    /// conversation in that myApp is untouched.
    ///
    /// **Reentrancy / chain-depth.** Consults `agentInvocationGate`
    /// before doing any setup work. The optional `caller` is the
    /// `invocationId` of the agent run that issued this delegation
    /// (nil when invoked by a user-initiated session — the orchestrator
    /// chat panel is itself ungated). If the gate rejects the call,
    /// throws `AgentInvocationRejection` so the caller
    /// (`AppTools.invokeMyAppAgent`) can echo a structured
    /// `agent_unavailable` payload back to the orchestrating agent
    /// instead of running anyway and stomping on a concurrent run.
    func runOneShot(myAppId: UUID, prompt: String, caller: UUID? = nil) async throws -> String {
        let target: AgentInvocationKey = .myApp(myAppId)
        syncGateLimitsFromSettings()
        let decision = agentInvocationGate.decide(caller: caller, target: target)
        guard case let .proceed(invocationId, treeRoot) = decision else {
            let ancestors = caller.map { agentInvocationGate.ancestorChain(from: $0) } ?? []
            throw AgentInvocationRejection(
                decision: decision,
                callPath: ancestors.map { $0.agentKey },
                treeRootKey: ancestors.first?.agentKey
            )
        }
        agentInvocationGate.enter(
            invocationId: invocationId,
            target: target,
            caller: caller,
            treeRoot: treeRoot
        )
        defer { agentInvocationGate.exit(invocationId) }
        let registry = ToolRegistry()
        let myAppName = store.myApps.first(where: { $0.id == myAppId })?.name ?? ""
        let appMemory = MemoryStore(rootOverride: MemoryStore.appRoot(myAppName: myAppName))
        appMemory.onDidMutate = { [weak self] in self?.memory.rescan() }
        AppTools.registerMyAppTools(on: registry, store: store, myAppId: myAppId, memory: appMemory)
        AppTools.registerMemoryTools(on: registry, memory: appMemory)
        AppTools.registerSkillTools(on: registry, memory: appMemory)
        let subRunToolGateState = ToolGateState()
        AppTools.registerNotificationTools(on: registry, coordinator: .shared, toolGateState: subRunToolGateState)
        if let myApp = store.myApps.first(where: { $0.id == myAppId }),
           let type = MyAppTypeRegistry.shared.resolve(id: myApp.typeId) {
            AppTools.registerToolGates(on: registry, myAppType: type, toolGateState: subRunToolGateState)
        }
        let session = AgentSession(
            client: AgentClient(
                endpoint: settings.agentRunURL,
                session: urlSession,
                extraHeaders: settings.authHeaders
            ),
            registry: registry,
            threadId: UUID().uuidString,
            maxRounds: settings.effectiveMaxToolRounds
        )
        // Mirror ChatViewModel's per-turn payload so the sub-agent sees the
        // same context shape the user's own chat would for that myApp.
        let store = store
        let memory = appMemory
        let settings = settings
        let context: @Sendable () async -> [AgentContextEntry] = {
            await Self.subRunContextEntries(store: store, memory: memory, myAppId: myAppId)
        }
        let state: @Sendable () async -> AnyJSON = {
            await MainActor.run {
                // Global Settings → Tools set ∪ this MyApp's per-agent overrides.
                let disabledSet = settings.disabledBackendTools.union(store.myAppDisabledTools(for: myAppId))
                let disabled = disabledSet.sorted().map { AnyJSON.string($0) }
                var entries: [String: AnyJSON] = ["disabled_tools": .array(disabled)]
                let effective = EffectiveSettings(
                    globalSource: GlobalSettingsSource(shellApprovalDisabled: settings.shellApprovalDisabled),
                    myAppSettings: store.myApp(withId: myAppId).map { [$0.id: $0.settings] } ?? [:]
                )
                if effective.resolve(ShellApprovalDisabledKey.self, at: .myApp(myAppId)) {
                    entries["shell_approval_disabled"] = .bool(true)
                }
                Self.mergeActiveHarnessControls(into: &entries, settings: settings)
                return AnyJSON.object(entries)
            }
        }
        // Forward the per-MyApp model selection so the sub-agent runs on the
        // model configured for it (not the backend env default). Same shape as
        // ChatViewModel's main-agent turn.
        let modelProps = await MainActor.run { Self.llmForwardedProps(store.myAppLLM(for: myAppId)) }
        // Light up the sidebar spinner for the duration of the sub-run. The
        // refcount drops on every exit path — normal completion, thrown
        // error (incl. cancellation), or task-cancellation mid-stream — via
        // the `defer` below.
        incrementBusy(myAppId)
        defer { decrementBusy(myAppId) }
        var accumulated = ""
        let scope: ChatScope = .myApp(myAppId)
        let toolFilter: @Sendable () async -> Set<String> = { [store, subRunToolGateState] in
            await MainActor.run { ChatViewModel.allowedToolNames(scope: scope, store: store, toolGateState: subRunToolGateState) }
        }
        for try await event in session.send(
            prompt,
            context: context,
            toolFilter: toolFilter,
            state: state,
            forwardedProps: modelProps
        ) {
            switch event {
            case .assistantMessageEnd(_, let text):
                if !accumulated.isEmpty { accumulated.append("\n") }
                accumulated.append(text)
            case .error(let message, _):
                // An in-band RUN_ERROR from the delegated agent used to be
                // dropped (default: break), returning "" to the orchestrator —
                // the parent model then had no idea the sub-run failed. Fold it
                // into the result so the parent can react / tell the user.
                if !accumulated.isEmpty { accumulated.append("\n") }
                accumulated.append("[sub-agent error: \(message)]")
            case .completed(let outcome):
                // Sub-run settled with no text and no error — don't hand the
                // orchestrator an empty string it can't distinguish from "done".
                if case .silent = outcome, accumulated.isEmpty {
                    accumulated = "[sub-agent ended its turn with no reply]"
                }
            default:
                break
            }
        }
        self.memory.rescan()  // keep global sidebar tree in sync with app-scoped writes
        return accumulated
    }

    /// Spin up a transient sub-session for a `pupa/agents/<slug>/AGENTS.md`
    /// subagent within `myAppId`. Inherits the MyApp's canvas + memory
    /// surface but narrows the tool set to the subagent's frontmatter
    /// (`tools` / `disabled_tools`, always plus `invoke_agent`) and pins its
    /// persona (the AGENTS.md body) as a context entry. Runs the multi-round
    /// loop to completion and returns the concatenated final assistant text.
    ///
    /// The generic counterpart to `runOneShot` (which targets another MyApp's
    /// *main* agent). Invoked by the `invoke_agent` frontend tool — from the
    /// main chat (`caller == nil`) or from another subagent (A2A; `caller` is
    /// the parent run's invocationId). Consults `agentInvocationGate` first
    /// and throws `AgentInvocationRejection` when rejected so the tool handler
    /// can echo `agent_unavailable`; throws `SubagentRunError.notFound` when
    /// no such subagent exists.
    func runSubagent(
        myAppId: UUID,
        agentName: String,
        prompt: String,
        caller: UUID? = nil
    ) async throws -> String {
        let store = self.store
        let settings = self.settings
        let urlSession = self.urlSession
        let myAppName = store.myApps.first(where: { $0.id == myAppId })?.name ?? ""
        let appMemory = MemoryStore(rootOverride: MemoryStore.appRoot(myAppName: myAppName))
        appMemory.onDidMutate = { [weak self] in self?.memory.rescan() }
        guard let subagent = AgentStore(memory: appMemory).agent(named: agentName) else {
            throw SubagentRunError.notFound(agentName)
        }
        let target: AgentInvocationKey = .subagent(myAppId: myAppId, slug: subagent.name)
        syncGateLimitsFromSettings()
        let decision = agentInvocationGate.decide(caller: caller, target: target)
        guard case let .proceed(invocationId, treeRoot) = decision else {
            let ancestors = caller.map { agentInvocationGate.ancestorChain(from: $0) } ?? []
            throw AgentInvocationRejection(
                decision: decision,
                callPath: ancestors.map { $0.agentKey },
                treeRootKey: ancestors.first?.agentKey
            )
        }
        agentInvocationGate.enter(
            invocationId: invocationId,
            target: target,
            caller: caller,
            treeRoot: treeRoot
        )
        defer { agentInvocationGate.exit(invocationId) }

        let registry = ToolRegistry()
        AppTools.registerMyAppTools(on: registry, store: store, myAppId: myAppId, memory: appMemory)
        AppTools.registerMemoryTools(on: registry, memory: appMemory)
        AppTools.registerSkillTools(on: registry, memory: appMemory)
        // A2A: this subagent can invoke siblings; thread its own invocationId
        // as the caller so the gate records the nested edge and bounds depth.
        AppTools.registerSubagentTools(on: registry, run: { [weak self] name, subPrompt in
            guard let self else { return "" }
            return try await self.runSubagent(
                myAppId: myAppId, agentName: name, prompt: subPrompt, caller: invocationId
            )
        })
        let subRunToolGateState = ToolGateState()
        AppTools.registerNotificationTools(on: registry, coordinator: .shared, toolGateState: subRunToolGateState)
        if let myApp = store.myApps.first(where: { $0.id == myAppId }),
           let type = MyAppTypeRegistry.shared.resolve(id: myApp.typeId) {
            AppTools.registerToolGates(on: registry, myAppType: type, toolGateState: subRunToolGateState)
        }
        let session = AgentSession(
            client: AgentClient(
                endpoint: settings.agentRunURL,
                session: urlSession,
                extraHeaders: settings.authHeaders
            ),
            registry: registry,
            threadId: UUID().uuidString,
            maxRounds: settings.effectiveMaxToolRounds
        )
        let memory = appMemory
        let subagentSnapshot = subagent
        let context: @Sendable () async -> [AgentContextEntry] = {
            await Self.subagentContextEntries(
                store: store, memory: memory, myAppId: myAppId, subagent: subagentSnapshot
            )
        }
        let disabledExtra = Set(subagent.disabledTools ?? [])
        let state: @Sendable () async -> AnyJSON = {
            await MainActor.run {
                let disabledSet = settings.disabledBackendTools
                    .union(store.myAppDisabledTools(for: myAppId))
                    .union(disabledExtra)
                let disabled = disabledSet.sorted().map { AnyJSON.string($0) }
                var entries: [String: AnyJSON] = ["disabled_tools": .array(disabled)]
                let effective = EffectiveSettings(
                    globalSource: GlobalSettingsSource(shellApprovalDisabled: settings.shellApprovalDisabled),
                    myAppSettings: store.myApp(withId: myAppId).map { [$0.id: $0.settings] } ?? [:]
                )
                if effective.resolve(ShellApprovalDisabledKey.self, at: .myApp(myAppId)) {
                    entries["shell_approval_disabled"] = .bool(true)
                }
                Self.mergeActiveHarnessControls(into: &entries, settings: settings)
                return AnyJSON.object(entries)
            }
        }
        let fallbackModel = await MainActor.run { store.myAppLLM(for: myAppId) }
        let modelProps = Self.llmForwardedProps(subagent.llmSelection ?? fallbackModel)
        incrementBusy(myAppId)
        defer { decrementBusy(myAppId) }
        let scope: ChatScope = .myApp(myAppId)
        let toolFilter: @Sendable () async -> Set<String> = { [store, subRunToolGateState] in
            await MainActor.run {
                let base = ChatViewModel.allowedToolNames(
                    scope: scope, store: store, toolGateState: subRunToolGateState
                )
                return SubagentPolicy.narrowedTools(base: base, subagent: subagentSnapshot)
            }
        }
        var accumulated = ""
        for try await event in session.send(
            prompt,
            context: context,
            toolFilter: toolFilter,
            state: state,
            forwardedProps: modelProps
        ) {
            switch event {
            case .assistantMessageEnd(_, let text):
                if !accumulated.isEmpty { accumulated.append("\n") }
                accumulated.append(text)
            case .error(let message, _):
                if !accumulated.isEmpty { accumulated.append("\n") }
                accumulated.append("[sub-agent error: \(message)]")
            case .completed(let outcome):
                if case .silent = outcome, accumulated.isEmpty {
                    accumulated = "[sub-agent ended its turn with no reply]"
                }
            default:
                break
            }
        }
        self.memory.rescan()
        return accumulated
    }

    /// Per-turn context entries for a generic subagent invocation. Same
    /// canvas + memory shape as any sub-run, plus a persona entry pinning the
    /// subagent's AGENTS.md body and its private memory subfolder.
    private static func subagentContextEntries(
        store: MyAppStore,
        memory: MemoryStore,
        myAppId: UUID,
        subagent: Subagent
    ) async -> [AgentContextEntry] {
        let base = await subRunContextEntries(store: store, memory: memory, myAppId: myAppId)
        return await MainActor.run {
            var entries = base
            let subfolder = MemoryStore.subagentSubfolder(name: subagent.name)
            let personaPayload: [String: String] = [
                "name": subagent.displayName ?? subagent.name,
                "slug": subagent.name,
                "persona": subagent.body,
                "memorySubfolder": subfolder,
            ]
            let json = (try? JSONEncoder().encode(personaPayload))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            entries.append(AgentContextEntry(
                description: "Your subagent persona for this invocation. Adopt this role for your "
                    + "reply. Your private memory subfolder is `\(subfolder)` — keep notes there "
                    + "(e.g. `\(subfolder)/notes.md`); edit `\(subfolder)/AGENTS.md` to update your "
                    + "own instructions. You may delegate to sibling subagents via `invoke_agent`.",
                value: json
            ))
            return entries
        }
    }

    /// Build the per-turn context entries for a sub-run. Same shape as
    /// `ChatViewModel.contextEntries(... scope: .myApp(id))` so the
    /// sub-agent sees the canvas state, memories paths, and myApp-type
    /// fragment exactly the way the user's own chat in that myApp would.
    private static func subRunContextEntries(
        store: MyAppStore,
        memory: MemoryStore,
        myAppId: UUID
    ) async -> [AgentContextEntry] {
        await MainActor.run {
            let memoriesPayload: [String: [String]] = ["paths": memory.snapshotPaths()]
            let memoriesJSON = (try? JSONEncoder().encode(memoriesPayload))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "{\"paths\":[]}"
            let memoriesEntry = AgentContextEntry(
                description: "User memories — markdown filesystem (paths only). Use the memory tools to read or update.",
                value: memoriesJSON
            )
            // Skills under pupa/skills/ — the sub-run / Slack agent can load any
            // via app_skill_view (and create new ones). Same entry as main chat.
            let skillsEntry = [ChatViewModel.skillsContextEntry(SkillStore(memory: memory))]
            // Subagents under pupa/agents/ — sub-runs can delegate to siblings.
            let agentsEntry = [ChatViewModel.agentsContextEntry(AgentStore(memory: memory))]
            guard let myApp = store.myApps.first(where: { $0.id == myAppId }) else {
                return [memoriesEntry] + skillsEntry + agentsEntry
            }
            // Same thin enumeration as the main chat — full item lists
            // stay reachable via `getCanvasState` and the `list*` /
            // `search*` / `get*` discovery tools.
            let summary = CanvasSummary.build(myApp: myApp)
            let canvasJSON = summary.toJSONString()
            // System prompt for sub-run via MyAppPolicy — reads
            // <myapps/name>/pupa/AGENTS.md; falls back to type-fragment text.
            let typeDescription = MyAppPolicy(myAppId: myAppId).buildSystemPrompt(
                myApp: myApp, memory: memory
            )
            let typePayload: [String: String] = [
                "typeId": myApp.typeId,
                "myAppName": myApp.name,
                "subRun": "true",
            ]
            let typeJSON = (try? JSONEncoder().encode(typePayload))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            return [
                AgentContextEntry(
                    description: "Live canvas state for this sub-run's target myApp — thin enumeration. {components: [{id, name, kind, size, summary}], activeComponentId}. `size` is a coarse cache-stable bucket (empty/1-9/10-99/100+), not an exact count. `summary` is the LLM-authored content-summary slot (null until you write to it via the kind's render tool with only `summary` populated). Drill into items with the kind's discovery tools (`listTrackerItems` / `searchTrackerItems` / `getTrackerItem`, plus calendar / checklist equivalents) or `getCanvasState` for a full dump.",
                    value: canvasJSON
                ),
                memoriesEntry,
                AgentContextEntry(description: typeDescription, value: typeJSON),
            ] + skillsEntry + agentsEntry
        }
    }

    /// Spin up a transient sub-session for the given Slack agent on
    /// the given channel. Builds a fresh `AgentSession` with the
    /// agent's persona injected as a context entry, the channel's
    /// message history rendered as a transcript in the user prompt,
    /// and the target MyApp's normal tool surface. The final
    /// assistant text is posted to the channel as an `.agent`
    /// message authored by `agentId`.
    ///
    /// Reentrancy: if `agentId` is already on the invocation stack
    /// (the chain that started this call), the run is rejected with
    /// `.reentrant` and no lock is acquired — letting whichever
    /// agent in the chain is waiting on `agentId` finish its turn
    /// first. If `agentId` is busy for an unrelated reason (a
    /// concurrent user @-mention to the same agent), returns
    /// `.busy`.
    ///
    /// The `myAppId` busy refcount is bumped for the lifetime of
    /// the run so the sidebar spinner reflects the in-flight stream
    /// alongside the user's own chat for that MyApp.
    func invokeSlackAgent(
        agentId: String,
        channelId: String,
        myAppId: UUID,
        componentId: String,
        caller: UUID? = nil
    ) async -> SlackInvoker.InvocationOutcome {
        // Pull instance refs into local @Sendable bindings up front so
        // every closure below captures the same locals (avoids the
        // "closure captures store before declaration" diagnostic that
        // fires when one closure captures the property and a later
        // closure captures a shadowed local).
        let store = self.store
        let memory = self.memory
        let settings = self.settings
        let urlSession = self.urlSession
        let myAppName = store.myApps.first(where: { $0.id == myAppId })?.name ?? ""
        let appMemory = MemoryStore(rootOverride: MemoryStore.appRoot(myAppName: myAppName))
        appMemory.onDidMutate = { [weak self] in self?.memory.rescan() }
        // Resolve the subagent (`agentId` is its slug) from the filesystem and
        // the channel from the canvas. If either is missing, fail immediately.
        let snapshot = await MainActor.run { () -> (Subagent, SlackChannel, [SlackMessage])? in
            guard let subagent = AgentStore(memory: appMemory).agent(named: agentId),
                  let myApp = store.myApps.first(where: { $0.id == myAppId }),
                  let comp = myApp.components.first(where: { $0.id == componentId }),
                  case .slack(let s) = comp.body,
                  let channel = s.channels.first(where: { $0.id == channelId })
            else { return nil }
            let history = (s.messagesByChannel[channelId] ?? [])
                .sorted { $0.timestamp < $1.timestamp }
            return (subagent, channel, history)
        }
        guard let (subagent, channel, history) = snapshot else {
            return .failed(error: "agent or channel not found")
        }
        let slug = subagent.name
        let agentDisplayName = subagent.displayName ?? subagent.name
        let invocationId: UUID
        let treeRoot: UUID
        syncGateLimitsFromSettings()
        switch agentInvocationGate.decide(caller: caller, target: .subagent(myAppId: myAppId, slug: slug)) {
        case .reentrant: return .reentrant(targetName: agentDisplayName)
        case .busy: return .busy(targetName: agentDisplayName)
        case .maxDepthExceeded(_, let depth):
            return .maxDepthExceeded(targetName: agentDisplayName, depth: depth)
        case .budgetExhausted(_, let n):
            return .budgetExhausted(targetName: agentDisplayName, exhaustedAfter: n)
        case let .proceed(id, root):
            invocationId = id
            treeRoot = root
        }
        slackInvoker.enter(
            slug,
            agentName: agentDisplayName,
            channelId: channelId,
            myAppId: myAppId,
            invocationId: invocationId,
            caller: caller,
            treeRoot: treeRoot
        )
        incrementBusy(myAppId)
        defer {
            slackInvoker.exit(slug)
            decrementBusy(myAppId)
            memory.rescan()  // keep global sidebar tree in sync with app-scoped writes
        }
        // Build the transient session, mirroring runOneShot's setup so the
        // subagent has the same canvas + memory surface as the main agent in
        // this MyApp, narrowed to its frontmatter tools. Slack tools wired in
        // sub-agent mode (admin tools refuse, slackPostMessage works).
        let registry = ToolRegistry()
        AppTools.registerMyAppTools(
            on: registry,
            store: store,
            myAppId: myAppId,
            memory: appMemory,
            slack: subAgentSlackContext(myAppId: myAppId, currentAgentId: slug)
        )
        AppTools.registerMemoryTools(on: registry, memory: appMemory)
        AppTools.registerSkillTools(on: registry, memory: appMemory)
        // A2A: the subagent can also delegate to siblings via invoke_agent,
        // threading its own invocationId so the gate bounds the chain.
        AppTools.registerSubagentTools(on: registry, run: { [weak self] name, subPrompt in
            guard let self else { return "" }
            return try await self.runSubagent(
                myAppId: myAppId, agentName: name, prompt: subPrompt, caller: invocationId
            )
        })
        let slackToolGateState = ToolGateState()
        AppTools.registerNotificationTools(on: registry, coordinator: .shared, toolGateState: slackToolGateState)
        if let myApp = store.myApps.first(where: { $0.id == myAppId }),
           let type = MyAppTypeRegistry.shared.resolve(id: myApp.typeId) {
            AppTools.registerToolGates(on: registry, myAppType: type, toolGateState: slackToolGateState)
        }
        // Expose `ask_user_questions` to the sub-agent. The bridge parks
        // any question on this agent's `SlackInvocationState` so the
        // channel pane can render the inline question card; submit /
        // cancel routes back through the invoker. The tool registration
        // captures `bridge` weakly, so we hold a strong local for the
        // whole run; the `defer` below + `withExtendedLifetime` keep
        // ARC from releasing it across the session's await points.
        let hitlBridge = SlackHITLBridge(agentId: slug, invoker: slackInvoker)
        AppTools.registerHumanInTheLoopTools(on: registry, bridge: hitlBridge)
        defer { withExtendedLifetime(hitlBridge) {} }
        let session = AgentSession(
            client: AgentClient(
                endpoint: settings.agentRunURL,
                session: urlSession,
                extraHeaders: settings.authHeaders
            ),
            registry: registry,
            threadId: UUID().uuidString,
            maxRounds: settings.effectiveMaxToolRounds
        )
        let agentSnapshot = subagent
        let channelSnapshot = channel
        let historySnapshot = history
        let context: @Sendable () async -> [AgentContextEntry] = {
            await Self.slackContextEntries(
                store: store,
                memory: appMemory,
                myAppId: myAppId,
                agent: agentSnapshot,
                channel: channelSnapshot,
                history: historySnapshot
            )
        }
        let agentDisabledTools = Set(subagent.disabledTools ?? [])
        let state: @Sendable () async -> AnyJSON = {
            await MainActor.run {
                // Global Settings → Tools set ∪ this sub-agent's per-agent overrides.
                let disabledSet = settings.disabledBackendTools.union(agentDisabledTools)
                let disabled = disabledSet.sorted().map { AnyJSON.string($0) }
                var entries: [String: AnyJSON] = ["disabled_tools": .array(disabled)]
                let effective = EffectiveSettings(
                    globalSource: GlobalSettingsSource(shellApprovalDisabled: settings.shellApprovalDisabled),
                    myAppSettings: store.myApp(withId: myAppId).map { [$0.id: $0.settings] } ?? [:]
                )
                if effective.resolve(ShellApprovalDisabledKey.self, at: .myApp(myAppId)) {
                    entries["shell_approval_disabled"] = .bool(true)
                }
                Self.mergeActiveHarnessControls(into: &entries, settings: settings)
                return AnyJSON.object(entries)
            }
        }
        // Per-agent model selection (frontmatter, then MyApp's, then backend default).
        let fallbackModel = await MainActor.run { store.myAppLLM(for: myAppId) }
        let modelProps = Self.llmForwardedProps(subagent.llmSelection ?? fallbackModel)
        let scope: ChatScope = .myApp(myAppId)
        let toolFilter: @Sendable () async -> Set<String> = { [store, slackToolGateState] in
            await MainActor.run {
                let base = ChatViewModel.allowedToolNames(scope: scope, store: store, toolGateState: slackToolGateState)
                return SubagentPolicy.narrowedTools(base: base, subagent: agentSnapshot)
            }
        }
        let prompt = Self.slackInvocationPrompt(
            agentName: agentDisplayName,
            agentSlug: slug,
            channel: channel,
            history: history
        )
        var accumulated = ""
        var runError: String?
        do {
            for try await event in session.send(
                prompt,
                context: context,
                toolFilter: toolFilter,
                state: state,
                forwardedProps: modelProps
            ) {
                switch event {
                case .assistantMessageEnd(_, let text):
                    if !accumulated.isEmpty { accumulated.append("\n") }
                    accumulated.append(text)
                case .toolCallStarted(let id, let name):
                    slackInvoker.recordToolCallStart(agentId: slug, id: id, name: name)
                case .toolCallFinished(let id, let name, let arguments, let result):
                    let argsJSON = Self.prettyJSON(arguments)
                    let resultText = result.map(Self.prettyJSON) ?? ""
                    let failed = Self.toolResultIsFailure(result)
                    slackInvoker.recordToolCallFinish(
                        agentId: slug,
                        id: id,
                        name: name,
                        argsJSON: argsJSON,
                        resultText: resultText,
                        failed: failed
                    )
                case .error(let message, _):
                    // In-band RUN_ERROR: same outcome as a thrown transport
                    // error below — surface it as a failure instead of silently
                    // dropping it and auto-posting an empty/partial reply.
                    runError = message
                default:
                    break
                }
            }
        } catch {
            return .failed(error: String(describing: error))
        }
        if let runError { return .failed(error: runError) }
        let trimmed = accumulated.trimmingCharacters(in: .whitespacesAndNewlines)
        let explicitlyPosted = slackInvoker.hasExplicitlyPosted(agentId: slug)
        // Suppress auto-post when the agent explicitly used
        // `slackPostMessage` during its run — otherwise we'd
        // duplicate the agent's reply (once via the tool call,
        // once auto-posted here). Simple Q&A turns without an
        // explicit post still get their final message posted
        // automatically.
        let postedId: String? = (!trimmed.isEmpty && !explicitlyPosted) ? await MainActor.run {
            store.slackPostMessage(
                channelId: channelId,
                authorKind: .agent,
                authorId: slug,
                text: trimmed,
                myAppId: myAppId,
                componentId: componentId
            )
        } : nil
        return .completed(text: trimmed, postedMessageId: postedId)
    }

    /// `SlackToolContext` for the main chat panel — admin tools
    /// allowed, posting refused (only sub-agents post). The
    /// `invoke` closure still wires through to
    /// `invokeSlackAgent` so the main agent can theoretically
    /// trigger Slack runs from a tool — but the only tool that
    /// uses it is `slackPostMessage`, which is gated to
    /// sub-agents, so it's effectively unused for the main path.
    private func mainChatSlackContext(myAppId: UUID) -> AppTools.SlackToolContext {
        AppTools.SlackToolContext(
            currentAgentId: nil,
            invoke: { [weak self] agentId, channelId in
                guard let self else { return .failed(error: "coordinator gone") }
                let componentId = await MainActor.run { self.store.slackComponentId(myAppId: myAppId) }
                guard let componentId else { return .failed(error: "no slack component") }
                return await self.invokeSlackAgent(
                    agentId: agentId,
                    channelId: channelId,
                    myAppId: myAppId,
                    componentId: componentId
                )
            },
            resolveAgentId: { [weak self] name in
                guard let self else { return nil }
                return await MainActor.run { self.resolveSubagentSlug(name: name, myAppId: myAppId) }
            },
            markMessagePosted: { [weak self] agentId in
                await MainActor.run { self?.slackInvoker.markMessagePosted(agentId: agentId) }
            }
        )
    }

    /// Resolve an @-mention handle (display name or slug) to a subagent slug
    /// via the MyApp's `pupa/agents/` roster. Returns nil when no match.
    @MainActor
    private func resolveSubagentSlug(name: String, myAppId: UUID) -> String? {
        let appName = store.myApps.first(where: { $0.id == myAppId })?.name ?? ""
        let appMemory = MemoryStore(rootOverride: MemoryStore.appRoot(myAppName: appName))
        let lower = name.lowercased()
        return AgentStore(memory: appMemory).agents.first(where: {
            $0.name.lowercased() == lower || ($0.displayName?.lowercased() == lower)
        })?.name
    }

    /// `SlackToolContext` for a Slack sub-agent's transient
    /// session — admin tools refuse, `slackPostMessage` works
    /// and fans out via the same `invokeSlackAgent` path so the
    /// `SlackInvoker` invocation-stack guard sees agent-to-agent
    /// calls as nested.
    private func subAgentSlackContext(
        myAppId: UUID,
        currentAgentId: String
    ) -> AppTools.SlackToolContext {
        AppTools.SlackToolContext(
            currentAgentId: currentAgentId,
            invoke: { [weak self] agentId, channelId in
                guard let self else { return .failed(error: "coordinator gone") }
                let componentId = await MainActor.run { self.store.slackComponentId(myAppId: myAppId) }
                guard let componentId else { return .failed(error: "no slack component") }
                // Walk the live forest to find the current run's
                // invocationId so the nested call records the
                // sub-agent → sub-agent edge correctly. Read on
                // MainActor since the invoker is @MainActor.
                let caller = await MainActor.run {
                    self.slackInvoker.currentInvocationId(agentId: currentAgentId)
                }
                return await self.invokeSlackAgent(
                    agentId: agentId,
                    channelId: channelId,
                    myAppId: myAppId,
                    componentId: componentId,
                    caller: caller
                )
            },
            resolveAgentId: { [weak self] name in
                guard let self else { return nil }
                return await MainActor.run { self.resolveSubagentSlug(name: name, myAppId: myAppId) }
            },
            markMessagePosted: { [weak self] agentId in
                await MainActor.run { self?.slackInvoker.markMessagePosted(agentId: agentId) }
            }
        )
    }

    /// Build the `forwardedProps` LLM payload — `{"llm":{provider,model}}` —
    /// from an optional per-agent selection. Empty object when unset, so the
    /// backend falls back to its env-configured default. Mirrors the shape
    /// `ChatViewModel.forwardedPropsJSON` ships for the main-agent turn.
    static func llmForwardedProps(_ selection: (provider: String, model: String)?) -> AnyJSON {
        guard let (provider, model) = selection else { return .object([:]) }
        return .object([
            "llm": .object([
                "provider": .string(provider),
                "model": .string(model),
            ])
        ])
    }

    /// Pretty-print an `AnyJSON` payload for live tool-call display
    /// in the Slack thinking bubble. Matches the formatting of the
    /// main chat panel's `ToolRoundBubbleView`.
    static func prettyJSON(_ value: AnyJSON) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(value),
              let s = String(data: data, encoding: .utf8) else { return "" }
        return s
    }

    /// Classify a finished tool result as failed. Matches the
    /// failure shape AGUIKit uses for thrown handler errors: an
    /// object carrying `ok: false`. Anything else (including nil
    /// for backend tools without a server-emitted result) counts
    /// as success.
    static func toolResultIsFailure(_ result: AnyJSON?) -> Bool {
        guard case .object(let fields) = result else { return false }
        if case .bool(let ok) = fields["ok"], ok == false { return true }
        return false
    }

    /// Render the channel history as a chronological transcript and
    /// wrap it in a single user prompt for the invoked agent. The
    /// model receives this as the latest user message; persona +
    /// canvas state arrive separately via context entries.
    /// Default cap on the number of channel messages stuffed into a
    /// Slack agent's invocation prompt. Channels can grow without
    /// bound; sending the full transcript on every turn would burn
    /// input tokens and eventually blow the model's context window.
    /// Older messages remain reachable via the `slackReadChannelHistory`
    /// tool's `before` cursor.
    static let slackInvocationHistoryLimit = 30

    static func slackInvocationPrompt(
        agentName: String,
        agentSlug: String,
        channel: SlackChannel,
        history: [SlackMessage],
        historyLimit: Int = slackInvocationHistoryLimit
    ) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        let total = history.count
        let cap = max(0, historyLimit)
        let visible: [SlackMessage] = total > cap ? Array(history.suffix(cap)) : history
        let truncated = total > cap
        let transcript = visible.map { msg -> String in
            let speaker: String
            switch msg.authorKind {
            case .user: speaker = "user"
            case .agent: speaker = msg.authorId == agentSlug ? "you" : msg.authorId
            }
            return "[\(formatter.string(from: msg.timestamp))] \(speaker): \(msg.text)"
        }.joined(separator: "\n")
        let channelLabel = channel.type == .channel ? "#\(channel.name)" : channel.name
        let truncationHint: String
        if truncated, let oldestVisible = visible.first {
            truncationHint = """
            Showing the last \(visible.count) of \(total) messages — call slackReadChannelHistory \
            with `before: "\(oldestVisible.id)"` to fetch older context.


            """
        } else {
            truncationHint = ""
        }
        return """
        You've been mentioned in \(channelLabel). The conversation in this channel so far:

        \(truncationHint)\(transcript)

        Reply once as \(agentName). Your response is posted as a new message in \(channelLabel) — \
        keep it focused, conversational, and in your role. Do not prefix your reply with your name \
        or a timestamp; the channel renders those automatically.
        """
    }

    /// Per-turn context entries for a Slack subagent invocation. Same
    /// canvas + memory shape as a normal sub-run, plus a persona entry that
    /// pins the subagent's AGENTS.md body and channel context.
    private static func slackContextEntries(
        store: MyAppStore,
        memory: MemoryStore,
        myAppId: UUID,
        agent: Subagent,
        channel: SlackChannel,
        history: [SlackMessage]
    ) async -> [AgentContextEntry] {
        let baseEntries = await subRunContextEntries(store: store, memory: memory, myAppId: myAppId)
        return await MainActor.run {
            var entries = baseEntries
            let memorySubfolder = MemoryStore.subagentSubfolder(name: agent.name)
            let personaPayload: [String: String] = [
                "slug": agent.name,
                "name": agent.displayName ?? agent.name,
                "persona": agent.body,
                "channelId": channel.id,
                "channelName": channel.name,
                "channelType": channel.type.rawValue,
                "messageCount": String(history.count),
                "memorySubfolder": memorySubfolder,
            ]
            let personaJSON = (try? JSONEncoder().encode(personaPayload))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            entries.append(AgentContextEntry(
                description: "Your Slack persona for this invocation. Adopt this role for your reply. " +
                    "You're posting back into the named channel, so use `slackPostMessage` only if you " +
                    "need to send additional messages — your single direct reply is auto-posted by the host. " +
                    "Your private memory subfolder is `\(memorySubfolder)` — write your notes there " +
                    "(e.g. `\(memorySubfolder)/notes.md`). Edit `\(memorySubfolder)/AGENTS.md` to update your instructions.",
                value: personaJSON
            ))
            return entries
        }
    }

    private func updateBusy(scope: ChatScope, streaming: Bool) {
        guard case .myApp(let id) = scope else { return }
        if streaming {
            incrementBusy(id)
        } else {
            decrementBusy(id)
        }
    }

    // `internal` (not `private`) so tests can drive the refcount directly
    // without standing up a real `AgentSession`. Production callers go
    // through `updateBusy(scope:streaming:)` or `runOneShot`.
    func incrementBusy(_ id: UUID) {
        busyCounts[id, default: 0] += 1
    }

    func decrementBusy(_ id: UUID) {
        let next = (busyCounts[id] ?? 0) - 1
        if next <= 0 {
            busyCounts.removeValue(forKey: id)
        } else {
            busyCounts[id] = next
        }
    }

    /// Cancel and drop ALL sessions whose scope matches `scope`.
    /// Used when a myApp is deleted so every conversation's stream tears down
    /// cleanly before the underlying `MyApp` leaves `MyAppStore`.
    public func discardSession(for scope: ChatScope) {
        let keysToRemove = sessions.keys.filter { $0.scope == scope }
        for key in keysToRemove {
            sessions.removeValue(forKey: key)?.cancel()
        }
        if case .myApp(let id) = scope {
            busyCounts.removeValue(forKey: id)
        }
    }

    /// Cancel and drop the session for a single `(scope, threadId)` pair.
    /// Used when a thread is removed from the list.
    public func discardSession(for scope: ChatScope, threadId: String) {
        let key = SessionKey(scope: scope, threadId: threadId)
        sessions.removeValue(forKey: key)?.cancel()
        // Don't wipe busyCounts for the whole myApp — other threads may still stream.
    }
}
