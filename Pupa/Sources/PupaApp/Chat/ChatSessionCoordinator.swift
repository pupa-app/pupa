import Foundation
import Observation
import AGUIKit

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
        urlSession: URLSession? = nil
    ) {
        self.store = store
        self.memory = memory
        self.settings = settings
        // Use the cert-pinning session when the active backend has a fingerprint;
        // fall back to .shared (or the injected test session) otherwise.
        self.urlSession = urlSession ?? settings.backendSession
        let gate = AgentInvocationGate()
        self.agentInvocationGate = gate
        self.slackInvoker = SlackInvoker(gate: gate)
        bootstrapMemories()
    }

    /// Write AGENTS.md for every existing myApp and the orchestrator at
    /// startup, so the sidebar shows files immediately without waiting for
    /// a chat session to be lazily opened.
    private func bootstrapMemories() {
        let orchMemory = MemoryStore(rootOverride: MemoryStore.orchestratorRoot())
        if !orchMemory.fileExists(at: "AGENTS.md") {
            _ = try? orchMemory.writeFile(path: "AGENTS.md", content: Self.orchestratorAgentsMd())
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
        if !appMemory.fileExists(at: "AGENTS.md") {
            let typeFragment = MyAppTypeRegistry.shared.resolve(id: myApp.typeId)
                .map { $0.baseSystemPromptFragment } ?? ""
            let content = """
                # \(myApp.name)

                **Type:** \(myApp.typeId)

                ## Instructions
                \(typeFragment.isEmpty ? "_No instructions set._" : typeFragment)
                """
            _ = try? appMemory.writeFile(path: "AGENTS.md", content: content)
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

    private func makeSession(for scope: ChatScope, threadId: String) -> ChatViewModel {
        let registry = ToolRegistry()
        // Each session gets its own scoped MemoryStore so `lsMemories` /
        // `readMemoryFile` / etc. only see that scope's subtree. The global
        // `memory` is used by the sidebar; it is rescanned after each turn
        // so the sidebar reflects writes made through the scoped store.
        let sessionMemory: MemoryStore
        let sessionSkillState: SkillState
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
            let skillState = SkillState()
            sessionSkillState = skillState
            AppTools.registerNotificationTools(on: registry, coordinator: .shared, skillState: skillState)
            if let myApp,
               let type = MyAppTypeRegistry.shared.resolve(id: myApp.typeId) {
                AppTools.registerSkillGateTools(on: registry, myAppType: type, skillState: skillState)
            }
        case .memory:
            let skillState = SkillState()
            sessionSkillState = skillState
            sessionMemory = MemoryStore(rootOverride: MemoryStore.orchestratorRoot())
            sessionMemory.onDidMutate = { [weak self] in self?.memory.rescan() }
            AppTools.registerMemoryTools(on: registry, memory: sessionMemory)
            AppTools.registerNotificationTools(on: registry, coordinator: .shared, skillState: skillState)
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
            skillState: sessionSkillState,
            onStreamingChange: { [weak self] streaming in
                self?.updateBusy(scope: scope, streaming: streaming)
                // Rescan the global store after each turn so the sidebar
                // reflects any files the session's scoped store just wrote.
                if !streaming { self?.memory.rescan() }
            }
        )
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
        let subRunSkillState = SkillState()
        AppTools.registerNotificationTools(on: registry, coordinator: .shared, skillState: subRunSkillState)
        if let myApp = store.myApps.first(where: { $0.id == myAppId }),
           let type = MyAppTypeRegistry.shared.resolve(id: myApp.typeId) {
            AppTools.registerSkillGateTools(on: registry, myAppType: type, skillState: subRunSkillState)
        }
        let session = AgentSession(
            client: AgentClient(
                endpoint: settings.backendURL,
                session: urlSession,
                extraHeaders: settings.authHeaders
            ),
            registry: registry,
            threadId: UUID().uuidString
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
                let disabled = settings.disabledBackendTools.sorted().map { AnyJSON.string($0) }
                var entries: [String: AnyJSON] = ["disabled_tools": .array(disabled)]
                let effective = EffectiveSettings(
                    globalSource: GlobalSettingsSource(shellApprovalDisabled: settings.shellApprovalDisabled),
                    myAppSettings: store.myApp(withId: myAppId).map { [$0.id: $0.settings] } ?? [:]
                )
                if effective.resolve(ShellApprovalDisabledKey.self, at: .myApp(myAppId)) {
                    entries["shell_approval_disabled"] = .bool(true)
                }
                return AnyJSON.object(entries)
            }
        }
        // Light up the sidebar spinner for the duration of the sub-run. The
        // refcount drops on every exit path — normal completion, thrown
        // error (incl. cancellation), or task-cancellation mid-stream — via
        // the `defer` below.
        incrementBusy(myAppId)
        defer { decrementBusy(myAppId) }
        var accumulated = ""
        let scope: ChatScope = .myApp(myAppId)
        let toolFilter: @Sendable () async -> Set<String> = { [store, subRunSkillState] in
            await MainActor.run { ChatViewModel.allowedToolNames(scope: scope, store: store, skillState: subRunSkillState) }
        }
        for try await event in session.send(
            prompt,
            context: context,
            toolFilter: toolFilter,
            state: state
        ) {
            switch event {
            case .assistantMessageEnd(_, let text):
                if !accumulated.isEmpty { accumulated.append("\n") }
                accumulated.append(text)
            default:
                break
            }
        }
        self.memory.rescan()  // keep global sidebar tree in sync with app-scoped writes
        return accumulated
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
            guard let myApp = store.myApps.first(where: { $0.id == myAppId }) else {
                return [memoriesEntry]
            }
            // Same thin enumeration as the main chat — full item lists
            // stay reachable via `getCanvasState` and the `list*` /
            // `search*` / `get*` discovery tools.
            let summary = CanvasSummary.build(myApp: myApp)
            let canvasJSON = summary.toJSONString()
            // System prompt for sub-run via MyAppPolicy — reads
            // <myapps/name>/AGENTS.md; falls back to type-fragment text.
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
                    description: "Live canvas state for this sub-run's target myApp — thin enumeration. {components: [{id, name, kind, itemCount, summary}], activeComponentId}. `summary` is the LLM-authored content-summary slot (null until you write to it via the kind's render tool with only `summary` populated). Drill into items with the kind's discovery tools (`listTrackerItems` / `searchTrackerItems` / `getTrackerItem`, plus calendar / checklist equivalents) or `getCanvasState` for a full dump.",
                    value: canvasJSON
                ),
                memoriesEntry,
                AgentContextEntry(description: typeDescription, value: typeJSON),
            ]
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
        // Snapshot the agent + channel under MainActor before
        // touching anything else. If either is missing, fail
        // immediately — the channel may have been deleted between
        // composer-send and dispatch.
        let snapshot = await MainActor.run { () -> (SlackAgent, SlackChannel, [SlackMessage])? in
            guard let myApp = store.myApps.first(where: { $0.id == myAppId }),
                  let comp = myApp.components.first(where: { $0.id == componentId }),
                  case .slack(let s) = comp.body,
                  let agent = s.agents.first(where: { $0.id == agentId }),
                  let channel = s.channels.first(where: { $0.id == channelId })
            else { return nil }
            let history = (s.messagesByChannel[channelId] ?? [])
                .sorted { $0.timestamp < $1.timestamp }
            return (agent, channel, history)
        }
        guard let (agent, channel, history) = snapshot else {
            return .failed(error: "agent or channel not found")
        }
        let invocationId: UUID
        let treeRoot: UUID
        switch agentInvocationGate.decide(caller: caller, target: .slack(agentId: agentId)) {
        case .reentrant: return .reentrant(targetName: agent.name)
        case .busy: return .busy(targetName: agent.name)
        case .maxDepthExceeded(_, let depth):
            return .maxDepthExceeded(targetName: agent.name, depth: depth)
        case .budgetExhausted(_, let n):
            return .budgetExhausted(targetName: agent.name, exhaustedAfter: n)
        case let .proceed(id, root):
            invocationId = id
            treeRoot = root
        }
        slackInvoker.enter(
            agentId,
            agentName: agent.name,
            channelId: channelId,
            invocationId: invocationId,
            caller: caller,
            treeRoot: treeRoot
        )
        incrementBusy(myAppId)
        defer {
            slackInvoker.exit(agentId)
            decrementBusy(myAppId)
            memory.rescan()  // keep global sidebar tree in sync with app-scoped writes
        }
        // Build the transient session, mirroring runOneShot's setup
        // so the Slack agent has the same canvas + memory surface
        // as the main agent in this MyApp. Slack sub-agents get the
        // same app-scoped MemoryStore as the myApp's main session so
        // `lsMemories` only sees the app's subtree. Their private
        // subfolder is communicated via the persona context entry.
        // Slack tools wired in sub-agent mode (admin tools refuse,
        // slackPostMessage works).
        let myAppName = store.myApps.first(where: { $0.id == myAppId })?.name ?? ""
        let appMemory = MemoryStore(rootOverride: MemoryStore.appRoot(myAppName: myAppName))
        appMemory.onDidMutate = { [weak self] in self?.memory.rescan() }
        // Back-fill AGENTS.md for agents created before this feature was added.
        let agentSubfolder = MemoryStore.slackAgentSubfolder(agentName: agent.name)
        if !appMemory.fileExists(at: "\(agentSubfolder)/AGENTS.md") {
            let content = """
                # \(agent.name)

                **Role:** \(agent.role)

                ## Persona
                \(agent.systemPromptAddition.isEmpty ? "_No persona set._" : agent.systemPromptAddition)
                """
            _ = try? appMemory.writeFile(path: "\(agentSubfolder)/AGENTS.md", content: content)
        }
        let registry = ToolRegistry()
        AppTools.registerMyAppTools(
            on: registry,
            store: store,
            myAppId: myAppId,
            memory: appMemory,
            slack: subAgentSlackContext(myAppId: myAppId, currentAgentId: agentId)
        )
        AppTools.registerMemoryTools(on: registry, memory: appMemory)
        let slackSkillState = SkillState()
        AppTools.registerNotificationTools(on: registry, coordinator: .shared, skillState: slackSkillState)
        if let myApp = store.myApps.first(where: { $0.id == myAppId }),
           let type = MyAppTypeRegistry.shared.resolve(id: myApp.typeId) {
            AppTools.registerSkillGateTools(on: registry, myAppType: type, skillState: slackSkillState)
        }
        // Expose `ask_user_questions` to the sub-agent. The bridge parks
        // any question on this agent's `SlackInvocationState` so the
        // channel pane can render the inline question card; submit /
        // cancel routes back through the invoker. The tool registration
        // captures `bridge` weakly, so we hold a strong local for the
        // whole run; the `defer` below + `withExtendedLifetime` keep
        // ARC from releasing it across the session's await points.
        let hitlBridge = SlackHITLBridge(agentId: agentId, invoker: slackInvoker)
        AppTools.registerHumanInTheLoopTools(on: registry, bridge: hitlBridge)
        defer { withExtendedLifetime(hitlBridge) {} }
        let session = AgentSession(
            client: AgentClient(
                endpoint: settings.backendURL,
                session: urlSession,
                extraHeaders: settings.authHeaders
            ),
            registry: registry,
            threadId: UUID().uuidString
        )
        let agentSnapshot = agent
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
        let state: @Sendable () async -> AnyJSON = {
            await MainActor.run {
                let disabled = settings.disabledBackendTools.sorted().map { AnyJSON.string($0) }
                var entries: [String: AnyJSON] = ["disabled_tools": .array(disabled)]
                let effective = EffectiveSettings(
                    globalSource: GlobalSettingsSource(shellApprovalDisabled: settings.shellApprovalDisabled),
                    myAppSettings: store.myApp(withId: myAppId).map { [$0.id: $0.settings] } ?? [:]
                )
                if effective.resolve(ShellApprovalDisabledKey.self, at: .myApp(myAppId)) {
                    entries["shell_approval_disabled"] = .bool(true)
                }
                return AnyJSON.object(entries)
            }
        }
        let scope: ChatScope = .myApp(myAppId)
        let toolFilter: @Sendable () async -> Set<String> = { [store, slackSkillState] in
            await MainActor.run { ChatViewModel.allowedToolNames(scope: scope, store: store, skillState: slackSkillState) }
        }
        let prompt = Self.slackInvocationPrompt(
            agent: agent,
            channel: channel,
            history: history
        )
        var accumulated = ""
        do {
            for try await event in session.send(
                prompt,
                context: context,
                toolFilter: toolFilter,
                state: state
            ) {
                switch event {
                case .assistantMessageEnd(_, let text):
                    if !accumulated.isEmpty { accumulated.append("\n") }
                    accumulated.append(text)
                case .toolCallStarted(let id, let name):
                    slackInvoker.recordToolCallStart(agentId: agentId, id: id, name: name)
                case .toolCallFinished(let id, let name, let arguments, let result):
                    let argsJSON = Self.prettyJSON(arguments)
                    let resultText = result.map(Self.prettyJSON) ?? ""
                    let failed = Self.toolResultIsFailure(result)
                    slackInvoker.recordToolCallFinish(
                        agentId: agentId,
                        id: id,
                        name: name,
                        argsJSON: argsJSON,
                        resultText: resultText,
                        failed: failed
                    )
                default:
                    break
                }
            }
        } catch {
            return .failed(error: String(describing: error))
        }
        let trimmed = accumulated.trimmingCharacters(in: .whitespacesAndNewlines)
        let explicitlyPosted = slackInvoker.hasExplicitlyPosted(agentId: agentId)
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
                authorId: agentId,
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
                return await MainActor.run {
                    self.store.myApps.first(where: { $0.id == myAppId })?
                        .components.lazy.compactMap { comp -> [SlackAgent]? in
                            if case .slack(let s) = comp.body { return s.agents }
                            return nil
                        }.first?
                        .first(where: { $0.name.lowercased() == name.lowercased() })?.id
                }
            },
            markMessagePosted: { [weak self] agentId in
                await MainActor.run { self?.slackInvoker.markMessagePosted(agentId: agentId) }
            }
        )
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
                return await MainActor.run {
                    self.store.myApps.first(where: { $0.id == myAppId })?
                        .components.lazy.compactMap { comp -> [SlackAgent]? in
                            if case .slack(let s) = comp.body { return s.agents }
                            return nil
                        }.first?
                        .first(where: { $0.name.lowercased() == name.lowercased() })?.id
                }
            },
            markMessagePosted: { [weak self] agentId in
                await MainActor.run { self?.slackInvoker.markMessagePosted(agentId: agentId) }
            }
        )
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
        agent: SlackAgent,
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
            case .agent: speaker = msg.authorId == agent.id ? "you" : msg.authorId
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

        Reply once as \(agent.name). Your response is posted as a new message in \(channelLabel) — \
        keep it focused, conversational, and in your role. Do not prefix your reply with your name \
        or a timestamp; the channel renders those automatically.
        """
    }

    /// Per-turn context entries for a Slack agent invocation. Same
    /// canvas + memory shape as a normal sub-run, plus a persona
    /// entry that pins the agent's role / system-prompt addition.
    private static func slackContextEntries(
        store: MyAppStore,
        memory: MemoryStore,
        myAppId: UUID,
        agent: SlackAgent,
        channel: SlackChannel,
        history: [SlackMessage]
    ) async -> [AgentContextEntry] {
        let baseEntries = await subRunContextEntries(store: store, memory: memory, myAppId: myAppId)
        return await MainActor.run {
            var entries = baseEntries
            // Relative to the app-scoped MemoryStore root (which IS appRoot),
            // so no myApp prefix needed.
            let memorySubfolder = MemoryStore.slackAgentSubfolder(agentName: agent.name)
            // Use AGENTS.md as the source of truth for persona; fall back to
            // systemPromptAddition if the file is missing (old agents).
            let agentsMd = (try? memory.readFile(path: "\(memorySubfolder)/AGENTS.md"))?.content
            let persona = agentsMd ?? agent.systemPromptAddition
            let personaPayload: [String: String] = [
                "agentId": agent.id,
                "name": agent.name,
                "role": agent.role,
                "persona": persona,
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
