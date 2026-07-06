import Foundation
import Observation
import SwiftUI
import AGUIKit

public struct ChatBubble: Identifiable, Hashable {
    /// `system` bubbles are local-only — emitted by client-side slash commands
    /// (e.g. `/help` output, "Unknown command" fallbacks) and never reach the
    /// backend. `toolRound` bubbles are also local-only — they aggregate the
    /// tool calls the model issued within a single round into one expandable
    /// row driven by `AGUIKit.SessionEvent.toolCallStarted` / `.toolCallFinished`.
    /// AGUIKit's `AgentSession` maintains its own `messages` list and does not
    /// read from `ChatViewModel`, so display-only bubbles can't leak into the
    /// conversation history sent to the agent.
    /// `humanQuestion` bubbles are local-only too — emitted when the
    /// `ask_user_questions` frontend tool's handler awaits the user's
    /// reply via [HumanInTheLoopBridge](../Tools/HumanInTheLoopBridge.swift).
    /// Visually distinct (yellow tint + question-mark glyph) and may
    /// carry multiple question rows in `humanQuestions`, each with its
    /// own options. Like other app-only bubbles, they never reach the
    /// backend — the user's actual replies are returned from the tool
    /// handler and the backend gets them as a `ToolMessage` via the
    /// `CopilotKitMiddlewareWithFrontendInterrupt` resume payload.
    public enum Role: String { case user, assistant, system, toolRound, humanQuestion, shellApproval }
    public let id: String
    public let role: Role
    public var text: String
    /// Optional inline image attached to a user bubble. Rendered above the
    /// text inside the bubble. Always nil for assistant / system / toolRound bubbles.
    public var imageData: Data?
    /// Tool calls aggregated into this bubble. Always empty for non-`toolRound`
    /// roles; populated incrementally as `.toolCallStarted` / `.toolCallFinished`
    /// events arrive within one agent round.
    public var toolEntries: [ToolCallEntry]
    /// Question rows for a `humanQuestion` bubble. The agent may pack
    /// multiple clarifying questions into one call; each row carries its
    /// own optional suggested-answer buttons. Empty for every other bubble
    /// role.
    public var humanQuestions: [HumanQuestionRow]
    /// A frozen chart pinned into this assistant bubble by the
    /// `embedComponent` tool (hostKind "chat"). Holds resolved series,
    /// not a live store reference, so it stays reproducible. nil for every
    /// other bubble.
    public var chartSnapshot: ChatChartSnapshot?

    public init(
        id: String = UUID().uuidString,
        role: Role,
        text: String = "",
        imageData: Data? = nil,
        toolEntries: [ToolCallEntry] = [],
        humanQuestions: [HumanQuestionRow] = [],
        chartSnapshot: ChatChartSnapshot? = nil
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.imageData = imageData
        self.toolEntries = toolEntries
        self.humanQuestions = humanQuestions
        self.chartSnapshot = chartSnapshot
    }
}

/// A frozen chart embedded in a chat bubble — resolved `[ChartSeries]` plus
/// the `kind` + `title` needed to draw a store-free `ChartView`. Snapshotted
/// at embed time by `embedComponent` (hostKind "chat") so the chart is
/// reproducible / shareable and never re-resolves against a mutated canvas.
public struct ChatChartSnapshot: Codable, Hashable, Sendable {
    public var title: String
    public var kind: ChartKind
    public var series: [ChartSeries]

    public init(title: String, kind: ChartKind, series: [ChartSeries]) {
        self.title = title
        self.kind = kind
        self.series = series
    }
}

/// One row inside a `humanQuestion` bubble — a single question the agent is
/// waiting on, with its suggested options. Answer state is held in
/// `ChatViewModel.pendingAnswers` keyed by index, not on the row itself,
/// so the bubble stays a passive view of the conversation state.
public struct HumanQuestionRow: Identifiable, Hashable, Sendable {
    public let id: String
    public let question: String
    public let options: [String]

    public init(id: String = UUID().uuidString, question: String, options: [String]) {
        self.id = id
        self.question = question
        self.options = options
    }
}

/// One tool-call line item inside a `toolRound` bubble. The `id` is the AG-UI
/// `toolCallId`, which is also the key used to patch the entry from `.pending`
/// to `.done` / `.failed` when the paired `.toolCallFinished` arrives.
public struct ToolCallEntry: Identifiable, Hashable {
    public enum State: String, Hashable { case pending, done, failed }
    public let id: String
    public let name: String
    /// Pretty-printed JSON of the arguments. Empty until the call finishes.
    public var argsJSON: String
    /// Pretty-printed result payload. Empty until the call finishes, or stays
    /// empty for backend tools whose server didn't emit a `TOOL_CALL_RESULT`.
    public var resultText: String
    public var state: State

    public init(
        id: String,
        name: String,
        argsJSON: String = "",
        resultText: String = "",
        state: State = .pending
    ) {
        self.id = id
        self.name = name
        self.argsJSON = argsJSON
        self.resultText = resultText
        self.state = state
    }
}

/// A user-picked image, prepared (downscaled + re-encoded) for sending and
/// display. Held by `ChatPanel` while the user is composing a message and
/// passed into `ChatViewModel.send` at submit time.
public struct PickedImage: Equatable, Sendable {
    public let data: Data
    public let mimeType: String

    public init(data: Data, mimeType: String) {
        self.data = data
        self.mimeType = mimeType
    }
}

/// A message the user submitted while a turn was still in flight. Held in
/// `ChatViewModel.queuedMessages` (FIFO), rendered with a clock/pending glyph
/// above the composer, and merged into a single next turn once the current
/// one settles cleanly. Not a `ChatBubble`: queued items are pre-conversation drafts, so
/// they stay out of `bubbles` (and thus out of the transcript / agent history)
/// until they're actually sent. `text` is the raw composer string — slash
/// commands are re-evaluated when the item drains back through `send`.
public struct QueuedMessage: Identifiable, Equatable, Sendable {
    public let id: String
    public var text: String
    public var imageData: Data?
    public var mimeType: String?

    public init(
        id: String = UUID().uuidString,
        text: String,
        imageData: Data? = nil,
        mimeType: String? = nil
    ) {
        self.id = id
        self.text = text
        self.imageData = imageData
        self.mimeType = mimeType
    }

    /// Reconstitute the `PickedImage` this item carried, if any.
    var pickedImage: PickedImage? {
        guard let imageData, let mimeType else { return nil }
        return PickedImage(data: imageData, mimeType: mimeType)
    }
}

/// What a `ChatViewModel` is bound to for its entire lifetime. Pinned at init
/// — a session never moves between myApps, so tool dispatch and per-turn
/// context can target a fixed scope without re-checking `activeMyAppId`.
/// Switching the visible scope is handled by `ChatSessionCoordinator`
/// returning a different `ChatViewModel`, not by mutating an existing one.
public enum ChatScope: Equatable, Hashable, Sendable {
    case myApp(UUID)
    case memory
}

@MainActor
@Observable
public final class ChatViewModel {
    /// Immutable scope binding — set at init, never changes. Determines which
    /// myApp's canvas (if any) this session's tools mutate and which tool
    /// surface is advertised per turn.
    public let pinnedScope: ChatScope
    /// The backend threadId this session is permanently bound to. Set at init
    /// from the store's current thread for this scope — never mutated.
    public let threadId: String
    public private(set) var bubbles: [ChatBubble] = []
    /// Messages the user queued while a turn was in flight, FIFO. Shown with a
    /// pending/clock glyph above the composer and merged into a single next
    /// turn once the current one settles cleanly (see `drainQueue()`). Empty
    /// whenever the session is idle with nothing waiting.
    public private(set) var queuedMessages: [QueuedMessage] = []
    public private(set) var isStreaming = false
    public private(set) var lastError: String?
    /// True when a turn finished while this thread was not on screen — drives
    /// the "unviewed answer" badge on the pupa circle / thread lists. Set when
    /// a real turn settles (see `setStreaming`); cleared by `markViewed()` when
    /// the thread becomes visible (`ChatPanel` appear / completion onChange).
    public private(set) var hasUnviewedCompletion = false
    /// For memory sessions only — the file path the user is currently viewing
    /// in the sidebar. Read into per-turn agent context so the model knows
    /// which file is in focus. The coordinator updates this when the user
    /// navigates between memory files; a single `.memory` session persists
    /// across those navigations so the conversation stays coherent.
    public var memoryFocusedPath: String = ""
    /// When true, slash commands render more detail (e.g. `/tools` includes
    /// tool descriptions, not just names). Per-session, in-memory only —
    /// resets on app launch and is not shared across `ChatScope`s. Flip with
    /// `/verbose`.
    public private(set) var verbose: Bool = false
    /// True iff the agent's `ask_user_questions` frontend tool is awaiting
    /// the user's answers. The composer reads this to gate input (the
    /// user must submit via the bubble's Submit button or hit cancel).
    public var hasPendingQuestion: Bool { pendingContinuation != nil }
    /// True iff the agent's `request_shell_approval` frontend tool is awaiting
    /// the user's Approve / Deny decision. The composer reads this to gate input.
    public var hasPendingShellApproval: Bool { pendingShellApprovalContinuation != nil }
    /// True while the turn is suspended on *any* human-in-the-loop interrupt
    /// (`ask_user_questions` or `request_shell_approval`). The turn is still in
    /// flight — `isStreaming` stays true so `busyMyApps`, attach-gating, etc.
    /// keep treating it as active — but the *model* is not generating; it is
    /// blocked on the user. The composer reads this to suppress its Stop
    /// affordance: hitting Stop here would cancel the session task and orphan
    /// the backend interrupt (the resume POST never fires, and the next send
    /// lands as a fresh run that silently drops the pending command). The only
    /// valid resolution is the bubble's Submit / Approve / Deny, which keeps
    /// the live AGUIKit loop intact so it can POST the resume.
    public var isAwaitingHumanInput: Bool { hasPendingQuestion || hasPendingShellApproval }
    /// True while a tool-round bubble has at least one entry still `.pending` —
    /// i.e. the tool-round "Calling N tools…" spinner is on screen.
    public var isToolRunning: Bool {
        bubbles.contains { $0.role == .toolRound && $0.toolEntries.contains { $0.state == .pending } }
    }
    /// True while the model itself is generating and nothing else already shows
    /// activity: streaming, not parked on a human interrupt, and no tool-round
    /// spinner up. Drives the transcript's "model working" spinner, which the
    /// tool spinner replaces once a tool round opens.
    public var isModelWorking: Bool {
        isStreaming && !isAwaitingHumanInput && !isToolRunning
    }
    /// True iff every pending answer has been filled in (non-empty after
    /// trimming whitespace). The bubble's Submit button reads this to
    /// decide whether the user can submit yet.
    public var pendingAnswersComplete: Bool {
        guard hasPendingQuestion else { return false }
        return !pendingAnswers.isEmpty &&
            pendingAnswers.allSatisfy { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    /// At-a-glance state for the pupa-circle / thread-list badges. Priority
    /// order matches `ChatActivityStatus.priority`: a parked interrupt outranks
    /// an error, which outranks an unviewed answer, which outranks an in-flight
    /// stream.
    public var activityStatus: ChatActivityStatus {
        if isAwaitingHumanInput { return .actionRequired }
        if lastError != nil { return .error }
        if hasUnviewedCompletion { return .unviewedAnswer }
        if isStreaming { return .running }
        return .idle
    }

    /// Clear the unviewed-answer flag. Called when this thread is on screen so
    /// the badge never shows for the conversation the user is actually reading.
    public func markViewed() {
        hasUnviewedCompletion = false
    }

    /// Mutable so the session can be swapped when `SettingsStore.backendURL`
    /// or `SettingsStore.apiKey` change — see `rebuildSessionIfSettingsChanged()`.
    /// The threadId is preserved across the swap so the backend checkpointer
    /// keeps the conversation history; in-flight bubbles aren't affected
    /// because they live on `self.bubbles`, not on the session.
    private var session: AgentSession
    /// Cached `(url, authHeaders)` captured at the last session build.
    /// We compare the *resolved* `authHeaders` (not just the legacy `apiKey`
    /// field) so the session rebuilds when the user pairs a device.
    private var sessionBackendURL: URL
    private var sessionAuthHeaders: [String: String]
    /// Whether `loadHistoryIfNeeded()` has already run for this VM.
    private var hasLoadedHistory = false
    private let store: MyAppStore
    private let memory: MemoryStore
    /// Skills discovered under this scope's `pupa/skills/`. Drives the `/`
    /// palette and the model-facing skills context entry. Refreshed via
    /// `refreshSkills()` when the backing memory mutates.
    private let skillStore: SkillStore
    private let settings: SettingsStore
    /// Held so `/tools` can enumerate exactly the tool surface advertised to
    /// the model — `AgentSession` reads from the same `ToolRegistry` when
    /// building each `RunAgentInput.tools`.
    private let registry: ToolRegistry
    /// Reused for AGUIKit's `AgentClient` and the REST `BackendToolsClient`
    /// when the session is rebuilt mid-app on a settings change.
    private let urlSession: URLSession
    /// Per-session sticky picker for the "Live canvas state" preview slate.
    /// Keeps the same 2 preview item ids per component across turns until
    /// one disappears, so the cache-stable canvas summary doesn't churn on
    /// unrelated mutations. Lifetime is the chat session; the instance is
    /// discarded with the `ChatViewModel`. See `CanvasSummary.swift`.
    private let previewTracker = CanvasPreviewTracker()
    private var streamTask: Task<Void, Never>?
    /// True while the current turn was halted by the user (Stop, Case B in
    /// `cancel()`). Suppresses the "turn ended with no reply" notice for a
    /// late `.completed(.silent)` from the torn-down stream. Reset on `send`.
    private var didUserStop = false
    /// The id of the currently-open tool-round bubble, if one is collecting
    /// streamed `.toolCallStarted` events. Cleared on the next
    /// `.assistantMessageStart` (LLM resumes narration after the tool batch),
    /// on `.completed`, or on `.error`. Crucially NOT cleared on
    /// `.roundFinished`: a single frontend tool call arrives as
    /// `.toolCallStarted` → `.roundFinished` → `.toolCallFinished` (the last
    /// event is yielded by `AgentSession.runLoop` *after* `runOneRound`
    /// returns), so closing on `.roundFinished` would orphan the pending entry
    /// and freeze the spinner. The bubble itself stays visible after closing;
    /// the id is dropped so the next `.toolCallStarted` opens a fresh bubble.
    private var openToolRoundId: String?
    /// Id of the currently-displayed question bubble — set while the
    /// `ask_user_questions` frontend tool is awaiting the user's reply
    /// via `HumanInTheLoopBridge`. Cleared on submit / cancel /
    /// `newThread()`.
    private var pendingBubbleId: String?
    /// Continuation suspended by `askQuestions(...)`. Resumed exactly
    /// once: with the user's answers on submit, or with empty answers on
    /// cancel / new-thread. Nil when no question is pending.
    private var pendingContinuation: CheckedContinuation<[String], Never>?
    /// The in-progress answer for each pending question, indexed by row
    /// position in the bubble's `humanQuestions` array. Mutated by the
    /// bubble view via `setPendingAnswer(rowIndex:value:)`. Empty when no
    /// interrupt is active.
    public private(set) var pendingAnswers: [String] = []
    /// Continuation suspended by `requestShellApproval(command:)`. Resumed
    /// exactly once via `submitShellApproval` or cleared on cancel / new-thread.
    private var pendingShellApprovalContinuation: CheckedContinuation<(approved: Bool, remember: Bool), Never>?
    /// Fired on every `isStreaming` transition so the coordinator can update
    /// its derived `busyMyApps` set without polling.
    private let onStreamingChange: ((Bool) -> Void)?
    /// Per-session tool-gate activation state. nil for sub-run sessions (which
    /// always get the full legacy tool surface). When non-nil, drives the
    /// tool-gate logic in `allowedToolNames(scope:store:toolGateState:)`.
    private let toolGateState: ToolGateState

    /// Client-side slash commands (e.g. `/reset`, `/help`). Built lazily so
    /// the closures can capture `self`. See [SlashCommands.swift].
    /// `@ObservationIgnored` so the `@Observable` macro doesn't try to
    /// instrument a `lazy var` (unsupported combination).
    @ObservationIgnored
    public private(set) lazy var slashCommands: SlashCommandRegistry = SlashCommandRegistry(commands: [
        SlashCommand(
            name: "reset",
            summary: "Start a new chat thread (clears conversation; canvas and memories untouched)"
        ) { [weak self] _ in
            self?.newThread()
            return .appOnly
        },
        SlashCommand(
            name: "help",
            summary: "List available slash commands (local-only — not sent to the agent)"
        ) { [weak self] _ in
            self?.appendHelpBubble()
            return .appOnly
        },
        SlashCommand(
            name: "tools",
            summary: "List the tools available to this agent (local-only)"
        ) { [weak self] _ in
            self?.appendToolsBubble()
            return .appOnly
        },
        SlashCommand(
            name: "verbose",
            summary: "Toggle verbose output for slash commands (e.g. /tools shows descriptions)"
        ) { [weak self] _ in
            self?.toggleVerbose()
            return .appOnly
        },
        SlashCommand(
            name: "ag-ui-payload",
            summary: "Print the AG-UI RunAgentInput payload (context, tools, state) that would go to the backend next turn"
        ) { [weak self] _ in
            self?.appendPromptDumpBubble()
            return .appOnly
        }
    ], skillProvider: { [weak self] in self?.skillStore.slashCommands() ?? [] })

    private func toggleVerbose() {
        verbose.toggle()
        appendBubble(ChatBubble(role: .system, text: "Verbose mode: \(verbose ? "on" : "off")"))
    }

    private func appendHelpBubble() {
        let lines = slashCommands.availableCommands.map { "/\($0.name) — \($0.summary)" }
        let body = "Available commands (local-only, not sent to the agent):\n" + lines.joined(separator: "\n")
        appendBubble(ChatBubble(role: .system, text: body))
    }

    /// Rebuild the skill cache from the backing memory. Called when files
    /// change so the `/` palette and the skills context entry stay current.
    public func refreshSkills() { skillStore.rescan() }

    /// Snapshot the FE → BE wire payload (`RunAgentInput` shape) the chat
    /// **would** send on its next turn — context entries, the advertised tool
    /// surface for the active scope, the per-turn `state` (disabled backend
    /// tools), and the live `threadId` from the bound `AgentSession`. Encodes
    /// the result as pretty-printed JSON and drops it into the transcript as a
    /// `system` bubble. Read-only: nothing is sent over the wire and no
    /// session state is mutated. Messages are intentionally **not** included
    /// — `AgentSession` owns history internally and there's no accessor; if
    /// you need transcript dumps too, add `messagesSnapshot()` on `AgentSession`.
    /// The three private statics this reuses (`contextEntries`,
    /// `allowedToolNames`, `stateJSON`) are the same ones `send(_:)` calls, so
    /// the dump reflects exactly what would land in the next `RunAgentInput`.
    private func appendPromptDumpBubble() {
        let placeholderId = UUID().uuidString
        appendBubble(ChatBubble(id: placeholderId, role: .system, text: "Building /ag-ui-payload…"))
        let scope = pinnedScope
        let focusedPath = memoryFocusedPath
        let store = store
        let memory = memory
        let settings = settings
        let registry = registry
        let session = session
        let previewTracker = previewTracker
        let toolGateState = toolGateState
        let vmThreadId = threadId
        Task { [weak self] in
            let context = await Self.contextEntries(
                store: store,
                memory: memory,
                scope: scope,
                focusedPath: focusedPath,
                previewTracker: previewTracker
            )
            let allowed = await MainActor.run { Self.allowedToolNames(scope: scope, store: store, toolGateState: toolGateState) }
            let advertised = registry.descriptors
                .filter { allowed.contains($0.name) }
                .sorted { $0.name < $1.name }
            let state = await Self.stateJSON(settings: settings, scope: scope, store: store)
            let forwardedProps = await MainActor.run { Self.forwardedPropsJSON(scope: scope, threadId: vmThreadId, store: store, settings: settings) }
            let threadId = await session.threadId

            let scopeString: String = {
                switch scope {
                case .memory: return "memory"
                case .myApp(let id): return "myApp:\(id.uuidString)"
                }
            }()

            let payload: AnyJSON = .object([
                "threadId": .string(threadId),
                "scope": .string(scopeString),
                "state": state,
                "forwardedProps": forwardedProps,
                "context": .array(context.map { entry in
                    .object([
                        "description": .string(entry.description),
                        "value": .string(entry.value),
                    ])
                }),
                "tools": .array(advertised.map { d in
                    .object([
                        "name": .string(d.name),
                        "description": .string(d.description),
                        "parameters": d.parameters,
                    ])
                }),
                "messages": .string("<managed by AgentSession; not dumped — extend AgentSession with messagesSnapshot() if you need this>"),
            ])

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let jsonString = (try? encoder.encode(payload))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            let header = "/ag-ui-payload — AG-UI RunAgentInput that would be sent on the next turn (read-only snapshot)"
            await MainActor.run {
                self?.mutateBubble(id: placeholderId) { $0.text = header + "\n" + jsonString }
            }
        }
    }

    /// Human-readable name of the agent the chat is currently bound to. Shown
    /// in the chat header and at the top of the `/tools` listing.
    public var agentDisplayName: String {
        switch pinnedScope {
        case .memory:
            return "Orchestrator"
        case .myApp(let id):
            return store.myApps.first(where: { $0.id == id })?.name ?? "MyApp"
        }
    }

    /// Accent color for the active agent — purple for the orchestrator, a
    /// creation-order palette color per MyApp (same index as the sidebar dot).
    public var agentColor: Color {
        switch pinnedScope {
        case .memory: return .orchestratorColor
        case .myApp(let id):
            let sorted = store.myApps.sorted { $0.createdAt < $1.createdAt }
            let index = sorted.firstIndex(where: { $0.id == id }) ?? 0
            return .color(atIndex: index)
        }
    }

    /// Tool names advertised to the model on the next round for the given
    /// scope. Single source of truth shared by `send(_:)` (per-round
    /// `toolFilter`) and the `/tools` listing — keeps both in lockstep so
    /// `/tools` shows exactly what the model will see.
    ///
    /// For myApp scopes, the set is resolved from the live `MyApp.components`
    /// list: `MyAppType.baseToolNames` always, plus
    /// `toolNamesByKind[kind]` for each component kind currently on the
    /// canvas, minus any tool whose `coPresenceGates` requirements aren't
    /// met. Recomputing per round (via the async `toolFilter` closure in
    /// `AgentSession.send`) is what lets the agent's `addComponent` call
    /// expose the new kind's tools mid-turn.
    static func allowedToolNames(
        scope: ChatScope,
        store: MyAppStore,
        toolGateState: ToolGateState
    ) -> Set<String> {
        switch scope {
        case .memory:
            // Memory-mode chat is the orchestrator surface: memory FS +
            // HITL + orchestrator tools. Notifications stay tool-gated —
            // the orchestrator rarely needs to schedule banners.
            var memResult: Set<String> = MyAppType.memoryToolNames
                .union(MyAppType.humanInTheLoopToolNames)
                .union(MyAppType.orchestratorToolNames)
            if toolGateState.isNotificationsActivated {
                memResult.formUnion(MyAppType.notificationToolNames)
            } else {
                memResult.insert("get_tools_notifications")
            }
            // app_skill_view is always advertised so the orchestrator can load
            // any skill listed in its context (progressive disclosure).
            memResult.formUnion(MyAppType.skillToolNames)
            return memResult
        case .myApp(let id):
            guard let myApp = store.myApps.first(where: { $0.id == id }),
                  let type = MyAppTypeRegistry.shared.resolve(id: myApp.typeId) else {
                return MyAppType.humanInTheLoopToolNames
            }
            let kinds = Set(myApp.components.map(\.kindString))

            // Tool-gated surface: base tools + HITL are always visible.
            // Component-kind tools, memory tools, and notifications are
            // hidden until the agent calls the matching get_tools_* gate.
            var result: Set<String> = type.baseToolNames
                .union(MyAppType.humanInTheLoopToolNames)
            if toolGateState.isNotificationsActivated {
                result.formUnion(MyAppType.notificationToolNames)
            } else {
                result.insert("get_tools_notifications")
            }

            for kind in kinds {
                guard type.toolNamesByKind[kind] != nil else { continue }
                if toolGateState.isActivated(kind: kind) {
                    result.formUnion(type.toolNamesByKind[kind]!)
                } else {
                    result.insert("get_tools_\(kind)")
                }
            }

            // Co-presence filtering still applies after tool unlock.
            // TODO: co-presence is evaluated against the components present at
            // gate-call time (when isActivated flips). Removing a component
            // after unlocking does NOT re-gate its tools — the latch is
            // one-way by design, but document this if it causes confusion.
            if !type.coPresenceGates.isEmpty {
                result = result.filter { name in
                    guard let required = type.coPresenceGates[name] else { return true }
                    return required.isSubset(of: kinds)
                }
            }

            // get_tools_memories is always advertised because every myApp has
            // at minimum an AGENTS.md in its memory root, so memory access is
            // universally relevant — this is intentional, not an oversight.
            if toolGateState.isMemoriesActivated {
                result.formUnion(MyAppType.memoryToolNames)
            } else {
                result.insert("get_tools_memories")
            }

            // app_skill_view is always advertised (like get_tools_memories):
            // skills are universally relevant and the list is cheap.
            result.formUnion(MyAppType.skillToolNames)

            // invoke_agent is always advertised so the agent can delegate to
            // any subagent listed in its context (like app_skill_view).
            result.formUnion(MyAppType.subagentToolNames)

            return result
        }
    }

    /// Prompt fragment forwarded to the agent for a myApp scope, gated on
    /// which component kinds currently exist on the canvas. `nil` for
    /// scopes / typeIds without a registered `MyAppType`.
    static func activeSystemPromptFragment(myApp: MyApp, type: MyAppType) -> String {
        let kinds = Set(myApp.components.map(\.kindString))
        return type.resolvedSystemPromptFragment(kindsPresent: kinds)
    }

    /// Append a "Loading tools…" system bubble, then fetch the backend tool
    /// list and rewrite the bubble in place with the full report. The
    /// frontend half is resolved synchronously from the same `ToolRegistry`
    /// `AgentSession` will read on the next turn, filtered to the active
    /// scope's allowed set — so the listing matches what the model actually
    /// receives. Backend half is fetched lazily from `GET /backend-tools` so
    /// `/tools` reflects current `enabledByEnv` state without restarting.
    private func appendToolsBubble() {
        let placeholderId = UUID().uuidString
        appendBubble(ChatBubble(id: placeholderId, role: .system, text: "Loading tools…"))
        let allowed = Self.allowedToolNames(scope: pinnedScope, store: store, toolGateState: toolGateState)
        let frontendDescriptors = registry.descriptors
            .filter { allowed.contains($0.name) }
            .sorted { $0.name < $1.name }
        let groups = Self.groupFrontendTools(
            descriptors: frontendDescriptors,
            scope: pinnedScope,
            store: store
        )
        let agentName = agentDisplayName
        let backendURL = settings.backendURL
        let authHeaders = settings.authHeaders
        let disabledByUser = settings.disabledBackendTools
        let verbose = self.verbose
        Task { [weak self] in
            let backend: [BackendToolDescriptor]?
            do {
                backend = try await BackendToolsClient(
                    backendURL: backendURL,
                    extraHeaders: authHeaders
                ).list()
            } catch {
                backend = nil
            }
            let body = Self.renderToolsBody(
                agentName: agentName,
                frontendGroups: groups,
                frontendIsEmpty: frontendDescriptors.isEmpty,
                backend: backend?.sorted { $0.name < $1.name },
                disabledByUser: disabledByUser,
                verbose: verbose
            )
            await MainActor.run {
                self?.mutateBubble(id: placeholderId) { $0.text = body }
            }
        }
    }

    /// One labelled bucket of frontend tools for `/tools` rendering. Order
    /// inside `tools` is whatever the caller passed in (alphabetical at the
    /// call site in `appendToolsBubble`).
    struct ToolGroup: Equatable {
        let label: String
        let tools: [ToolDescriptor]
    }

    /// Bucket the advertised frontend descriptors by component so `/tools`
    /// can render headed sections instead of one flat alphabetical list.
    /// Groups are derived from `MyAppType` (`baseToolNames`, `toolNamesByKind`,
    /// `memoryToolNames`, `notificationToolNames`, `orchestratorToolNames`) —
    /// no tool-name lists are duplicated here. Each descriptor lands in the
    /// first matching group, so a base-tool name doesn't double-print under
    /// a kind group. Empty groups are dropped by the caller via `tools.isEmpty`.
    /// Returned order is the order `/tools` renders sections: Canvas, then
    /// the canvas-kind groups, Memory, Notifications, Orchestrator, Other.
    static func groupFrontendTools(
        descriptors: [ToolDescriptor],
        scope: ChatScope,
        store: MyAppStore
    ) -> [ToolGroup] {
        var canvasNames: Set<String> = []
        var kindGroups: [(label: String, names: Set<String>)] = []
        var toolGateNames: Set<String> = []
        if case .myApp(let id) = scope,
           let myApp = store.myApps.first(where: { $0.id == id }),
           let type = MyAppTypeRegistry.shared.resolve(id: myApp.typeId) {
            canvasNames = type.baseToolNames
            // Render kind groups in a stable order independent of dictionary
            // iteration; only kinds the type actually declares show up.
            let kindOrder = ["tracker", "calendar", "checklist"]
            for kind in kindOrder {
                if let names = type.toolNamesByKind[kind], !names.isEmpty {
                    kindGroups.append((label: kind.capitalized, names: names))
                    toolGateNames.insert("get_tools_\(kind)")
                }
            }
            // Defensive: surface any kinds the type declares beyond the
            // known three so future kinds don't fall through to "Other".
            for kind in type.toolNamesByKind.keys.sorted() where !kindOrder.contains(kind) {
                if let names = type.toolNamesByKind[kind], !names.isEmpty {
                    kindGroups.append((label: kind.capitalized, names: names))
                    toolGateNames.insert("get_tools_\(kind)")
                }
            }
            toolGateNames.insert("get_tools_memories")
        }
        // `get_tools_notifications` exists in every scope (memory + myApp)
        // since notifications are app-global.
        toolGateNames.insert("get_tools_notifications")

        let orderedDefinitions: [(label: String, names: Set<String>)] = [
            (label: "Canvas", names: canvasNames),
        ] + kindGroups + [
            (label: "Tool Gates", names: toolGateNames),
            (label: "Memory", names: MyAppType.memoryToolNames),
            (label: "Skills", names: MyAppType.skillToolNames),
            (label: "Subagents", names: MyAppType.subagentToolNames),
            (label: "Notifications", names: MyAppType.notificationToolNames),
            (label: "Orchestrator", names: MyAppType.orchestratorToolNames),
            (label: "Human-in-the-loop", names: MyAppType.humanInTheLoopToolNames),
        ]

        var assigned: Set<String> = []
        var result: [ToolGroup] = []
        for def in orderedDefinitions {
            let bucket = descriptors.filter { def.names.contains($0.name) && !assigned.contains($0.name) }
            if bucket.isEmpty { continue }
            for d in bucket { assigned.insert(d.name) }
            result.append(ToolGroup(label: def.label, tools: bucket))
        }
        let leftovers = descriptors.filter { !assigned.contains($0.name) }
        if !leftovers.isEmpty {
            result.append(ToolGroup(label: "Other", tools: leftovers))
        }
        return result
    }

    static func renderToolsBody(
        agentName: String,
        frontendGroups: [ToolGroup],
        frontendIsEmpty: Bool,
        backend: [BackendToolDescriptor]?,
        disabledByUser: Set<String>,
        verbose: Bool
    ) -> String {
        var out = "Agent: \(agentName)\n\n"
        out += "Frontend tools (advertised to the model this turn):\n"
        if frontendIsEmpty {
            out += "  (none)\n"
        } else {
            for (idx, group) in frontendGroups.enumerated() {
                if idx > 0 { out += "\n" }
                out += "  \(group.label):\n"
                for d in group.tools {
                    if verbose {
                        out += "    • \(d.name) — \(d.description)\n"
                    } else {
                        out += "    • \(d.name)\n"
                    }
                }
            }
        }
        out += "\nBackend tools:\n"
        switch backend {
        case .none:
            out += "  (failed to load — backend offline?)"
        case .some(let list) where list.isEmpty:
            out += "  (none registered)"
        case .some(let list):
            for d in list {
                let suffix: String
                if !d.enabledByEnv {
                    suffix = " (disabled — env var not set)"
                } else if disabledByUser.contains(d.name) {
                    suffix = " (disabled in Settings)"
                } else {
                    suffix = ""
                }
                if verbose {
                    out += "  • \(d.name) — \(d.description)\(suffix)\n"
                } else {
                    out += "  • \(d.name)\(suffix)\n"
                }
            }
            // Trim the trailing newline so the bubble doesn't end with blank space.
            if out.hasSuffix("\n") { out.removeLast() }
        }
        return out
    }

    public init(
        store: MyAppStore,
        memory: MemoryStore,
        settings: SettingsStore,
        registry: ToolRegistry,
        scope: ChatScope,
        threadId: String,
        urlSession: URLSession = .shared,
        toolGateState: ToolGateState,
        onStreamingChange: ((Bool) -> Void)? = nil
    ) {
        self.store = store
        self.memory = memory
        self.skillStore = SkillStore(memory: memory)
        self.settings = settings
        self.registry = registry
        self.urlSession = urlSession
        self.pinnedScope = scope
        self.threadId = threadId
        self.toolGateState = toolGateState
        self.onStreamingChange = onStreamingChange
        let initialURL = settings.backendURL
        let initialHeaders = settings.authHeaders
        let client = AgentClient(
            endpoint: initialURL,
            session: urlSession,
            extraHeaders: initialHeaders
        )
        self.session = AgentSession(
            client: client,
            registry: registry,
            threadId: threadId,
            maxRounds: settings.effectiveMaxToolRounds
        )
        self.sessionBackendURL = initialURL
        self.sessionAuthHeaders = initialHeaders
    }

    /// Swap `session` for a fresh one if the user changed `backendURL` or
    /// `apiKey` in Settings since the current session was built. The threadId
    /// is preserved across the swap so the backend's checkpointer continues
    /// the same conversation. Bubbles already in `self.bubbles` stay put —
    /// they're a `ChatViewModel` property, not a session property.
    private func rebuildSessionIfSettingsChanged() {
        let url = settings.backendURL
        let headers = settings.authHeaders
        guard url != sessionBackendURL || headers != sessionAuthHeaders else { return }
        let client = AgentClient(
            endpoint: url,
            session: urlSession,
            extraHeaders: headers
        )
        // threadId is immutable — carry it across the rebuild so the backend
        // checkpointer keeps the conversation history.
        session = AgentSession(
            client: client,
            registry: registry,
            threadId: threadId,
            maxRounds: settings.effectiveMaxToolRounds
        )
        sessionBackendURL = url
        sessionAuthHeaders = headers
    }

    public func send(_ raw: String, image: PickedImage? = nil) {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // `text` is what reaches the backend; `displayText` is what the user
        // bubble shows. They diverge only for `/skill`-style rewrites, where
        // the bubble shows `/name args` but the agent receives the rendered
        // skill body.
        var displayText = text
        // Allow sends with an image but no text — the agent can still reason
        // about the image alone. Block only if both inputs are empty.
        guard !text.isEmpty || image != nil else { return }

        // Parked on a human-in-the-loop interrupt: the composer is gated and
        // resolution flows through the bubble, so a stray send is dropped
        // (mirrors the guard further down; checked up here so a queued send
        // never lands mid-interrupt either).
        if isAwaitingHumanInput { return }

        // A turn is already in flight → don't drop the message, queue it. It is
        // rendered with a pending glyph and auto-sent (FIFO) once the current
        // turn settles cleanly (see `drainQueue()`). The raw text is stored so
        // slash commands are re-evaluated when the item drains back through
        // `send`. Multiple queued messages preserve submit order.
        if isStreaming {
            queuedMessages.append(
                QueuedMessage(text: text, imageData: image?.data, mimeType: image?.mimeType)
            )
            return
        }

        // Slash-command interception. Runs before the user bubble is appended
        // so app-only commands (e.g. `/reset`) leave no trace in the chat
        // transcript and never hit the backend. Image attachments paired with
        // a slash command are dropped.
        switch slashCommands.dispatch(text) {
        case .appOnly:
            return
        case .rewriteMessage(let display, let payload):
            text = payload
            displayText = display
        case .hiddenHint:
            return
        case .unknown(let name):
            appendBubble(
                ChatBubble(role: .system, text: "Unknown command: /\(name) — type /help for the list.")
            )
            return
        case .notACommand:
            break
        }

        appendBubble(ChatBubble(role: .user, text: displayText, imageData: image?.data))

        // Capture the first user message as the thread title (set-once).
        let isFirstUserMessage = !bubbles.dropLast().contains(where: { $0.role == .user })
        if isFirstUserMessage {
            store.setThreadTitle(Self.deriveTitle(displayText), threadId: threadId, for: pinnedScope)
        }

        setStreaming(true)
        lastError = nil
        didUserStop = false

        rebuildSessionIfSettingsChanged()

        let scope = pinnedScope
        let focusedPath = memoryFocusedPath
        let store = store
        let memory = memory
        let settings = settings
        let imagePayload: (data: Data, mimeType: String)? = image.map { ($0.data, $0.mimeType) }
        let previewTracker = previewTracker
        // Resolve per-agent LLM selection at send time. The chosen model
        // is sent in `forwardedProps["llm"]` and survives across all rounds
        // of the turn (AgentSession merges it with the resume payload).
        // No override (or the orchestrator scope) → empty object → backend
        // uses its env-configured default.
        let baseForwardedProps = Self.forwardedPropsJSON(scope: scope, threadId: threadId, store: store, settings: settings)
        let stream = session.send(
            text,
            image: imagePayload,
            context: { [store, memory, previewTracker] in
                await Self.contextEntries(store: store, memory: memory, scope: scope, focusedPath: focusedPath, previewTracker: previewTracker)
            },
            // Recompute on every round so the kind-gated tool surface grows
            // mid-turn the instant the agent's `addComponent` call adds a
            // component of a new kind (and shrinks when the last one is
            // removed). MainActor hop reads the live `MyAppStore`.
            toolFilter: { [store, toolGateState] in
                await MainActor.run { Self.allowedToolNames(scope: scope, store: store, toolGateState: toolGateState) }
            },
            state: { [settings, store] in
                await Self.stateJSON(settings: settings, scope: scope, store: store)
            },
            forwardedProps: baseForwardedProps
        )
        consume(stream: stream)
    }

    // MARK: - Queued messages

    /// Cancel a queued message before it auto-sends. No-op if the id isn't
    /// currently queued (e.g. it already drained). Called from the composer's
    /// per-item ✕ affordance.
    public func removeQueuedMessage(id: String) {
        queuedMessages.removeAll { $0.id == id }
    }

    /// Edit the text of a queued message before it auto-sends. Trimmed-empty
    /// edits remove the item instead (an empty queued message can't be sent).
    /// The attached image, if any, is preserved.
    public func updateQueuedMessage(id: String, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let idx = queuedMessages.firstIndex(where: { $0.id == id }) else { return }
        if trimmed.isEmpty && queuedMessages[idx].imageData == nil {
            queuedMessages.remove(at: idx)
        } else {
            queuedMessages[idx].text = trimmed
        }
    }

    /// Clear every queued message. Called when the conversation is torn down
    /// (`newThread`) or the user deliberately halts an in-flight turn
    /// (`cancel` Case B) — in both cases the queued drafts no longer make
    /// sense to auto-send.
    private func clearQueue() {
        queuedMessages.removeAll()
    }

    /// Pop and send the next queued message, if the session is idle and clean.
    /// Called after a turn settles (see `consume`). Collapses the *whole*
    /// pending queue into a single next turn — everything queued during the
    /// last turn is merged and sent as one user message, so the user never
    /// waits a turn per message. Anything queued while this merged turn runs
    /// drains the same way on the next settle.
    ///
    /// Guards: never drain while streaming or parked on an interrupt, and never
    /// after an error (the failed turn's error stays on screen and the user
    /// decides whether to retry — auto-firing the queue could cascade
    /// failures).
    private func drainQueue() {
        guard !isStreaming, !isAwaitingHumanInput, lastError == nil else { return }
        guard let merged = Self.coalesceQueue(queuedMessages) else { return }
        queuedMessages.removeAll()
        send(merged.text, image: merged.image)
    }

    /// Collapse the pending queue into one outgoing message: the queued texts
    /// joined in FIFO order (blank-line separated), carrying the first attached
    /// image. Stays a single AG-UI user message so the backend's one-user-per-
    /// run history contract is untouched. `nil` when the queue is empty.
    static func coalesceQueue(_ queue: [QueuedMessage]) -> (text: String, image: PickedImage?)? {
        guard !queue.isEmpty else { return nil }
        let text = queue.map(\.text).filter { !$0.isEmpty }.joined(separator: "\n\n")
        let image = queue.compactMap(\.pickedImage).first
        return (text, image)
    }

    /// Update the in-progress answer for a single question row. The bubble
    /// view calls this when the user taps an option, types into the
    /// inline TextField, or picks "Other…". The agent only sees these
    /// values when the user taps Submit and `submitInterruptAnswers()`
    /// fires.
    public func setPendingAnswer(rowIndex: Int, value: String) {
        guard pendingContinuation != nil,
              pendingAnswers.indices.contains(rowIndex) else { return }
        pendingAnswers[rowIndex] = value
    }

    /// Submit the collected answers to the suspended `ask_user_questions`
    /// tool handler. No-op if no question is pending or the user hasn't
    /// filled every row. Appends a transcript bubble summarising what was
    /// sent, then resumes the bridge's continuation — AGUIKit's dispatch
    /// loop returns the answers as the tool result and POSTs the resume
    /// to the backend.
    public func submitInterruptAnswers() {
        guard let continuation = pendingContinuation, pendingAnswersComplete else { return }
        let answers = pendingAnswers
        // Append a single user bubble summarising the submitted answers
        // so the chat transcript reflects what was sent. For a
        // single-question interrupt the bubble shows the answer text
        // alone; for multi-row the answers are numbered to match the
        // question rows.
        let summary: String = answers.count == 1
            ? answers[0]
            : answers.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
        appendBubble(ChatBubble(role: .user, text: summary))
        pendingContinuation = nil
        pendingBubbleId = nil
        pendingAnswers = []
        continuation.resume(returning: answers)
    }

    /// Resume the shell approval interrupt with the user's decision. Called
    /// from the `ShellApprovalBubbleView` Approve / Deny buttons.
    public func submitShellApproval(approved: Bool, remember: Bool) {
        guard let continuation = pendingShellApprovalContinuation else { return }
        let label = approved ? (remember ? "Always allow" : "Allow once") : "Deny"
        appendBubble(ChatBubble(role: .user, text: label))
        pendingShellApprovalContinuation = nil
        continuation.resume(returning: (approved: approved, remember: remember))
    }

    /// Foreground recovery for a stream the OS killed while backgrounded.
    ///
    /// `AgentSession` already retries transport drops in-flight (re-attach
    /// with backoff against the backend's replay log); this covers the case
    /// where those retries were exhausted — or the process was suspended
    /// before they could run — and the turn surfaced as `lastError`. On
    /// return to the foreground we re-attach once more: the backend replays
    /// every missed event (and, if the run parked on a frontend-tool
    /// interrupt while we were away, the session dispatches it and resumes).
    ///
    /// No-op when a stream is still live (short background survived) or the
    /// last turn settled cleanly. Launch-time catch-up after a full app kill
    /// additionally needs the replay cursor persisted per thread — tracked as
    /// follow-up on pupa#103.
    public func reattachIfNeeded() {
        guard streamTask == nil else { return }  // stream survived the background
        guard lastError != nil else { return }   // nothing was interrupted
        AGUIKitLog.session("foreground reattach: thread=\(threadId)")
        lastError = nil
        setStreaming(true)
        consume(stream: session.reattach())
    }

    /// Shared event-pump for both the initial `send` and the post-interrupt
    /// `resume` streams. Mirrors what was previously inlined in `send`.
    private func consume(stream: AsyncThrowingStream<SessionEvent, Error>) {
        streamTask?.cancel()
        streamTask = Task { [weak self] in
            var cancelled = false
            do {
                for try await event in stream {
                    self?.apply(event)
                }
            } catch {
                if case AgentClientError.cancelled = error { cancelled = true } else {
                    self?.lastError = String(describing: error)
                }
            }
            self?.setStreaming(false)
            self?.streamTask = nil
            // Turn settled. Auto-send the next queued message unless the stream
            // was torn down by an explicit Stop (`cancel`), which clears the
            // queue anyway. `drainQueue` re-checks error / interrupt state.
            if !cancelled { self?.drainQueue() }
        }
    }

    public func cancel() {
        // Case A — parked on a human-in-the-loop interrupt. The model is NOT
        // running; the AGUIKit stream is suspended awaiting the user. Resolve
        // the interrupt by resuming the bridge continuation with its terminal
        // value (deny / empty answers) and let the *live* loop POST the
        // `command.resume` so the backend interrupt is actually answered. We
        // must NOT tear the task down here: cancelling the stream would strand
        // the backend interrupt — the resume never fires, and the next send
        // lands as a fresh run that silently drops the pending command (the
        // exact "agent stopped silently" failure). The run settles itself once
        // the backend processes the resolution, flipping `isStreaming` off via
        // `consume`. Resolve at most one interrupt per call (only one is ever
        // pending at a time).
        if let continuation = pendingShellApprovalContinuation {
            pendingShellApprovalContinuation = nil
            appendBubble(ChatBubble(role: .user, text: "Deny"))
            continuation.resume(returning: (approved: false, remember: false))
            return
        }
        if let continuation = pendingContinuation {
            pendingContinuation = nil
            pendingBubbleId = nil
            pendingAnswers = []
            continuation.resume(returning: [])
            return
        }
        // Case B — a genuine in-flight model turn with no pending interrupt.
        // Abort the stream; the backend run for this POST is dropped and there
        // is no interrupt to orphan. Stop means "halt everything", so any
        // queued messages are discarded rather than auto-fired afterwards.
        // Flag it so a late `.completed(.silent)` from the torn-down stream
        // doesn't render a spurious "turn ended with no reply" notice.
        didUserStop = true
        streamTask?.cancel()
        streamTask = nil
        clearQueue()
        setStreaming(false)
    }

    /// Start a new conversation. Stops any in-flight stream on this VM, then
    /// appends a fresh thread to the store for this scope, making it current.
    /// The `ConversationPager` observes the store and creates a brand-new,
    /// empty VM for the new thread — this VM's bubbles are untouched so the
    /// user can swipe back and read the old conversation.
    public func newThread() {
        cancel()
        clearQueue()
        store.addThread(for: pinnedScope)
    }

    // MARK: - History loading

    /// Fetch and render the backend transcript when this VM has no bubbles.
    /// Called by `ConversationPager` when a conversation page becomes visible.
    /// On success, also seeds `AgentSession.messages` with the prior human
    /// messages so the backend recognises subsequent sends as continuations.
    /// On failure, appends an inline error bubble — never blocks sending.
    public func loadHistoryIfNeeded() {
        guard bubbles.isEmpty, !hasLoadedHistory else { return }
        hasLoadedHistory = true
        let threadId = self.threadId
        let backendURL = settings.backendURL
        let headers = settings.authHeaders
        let urlSession = self.urlSession
        let session = self.session
        Task { [weak self] in
            let client = BackendThreadsClient(
                backendURL: backendURL,
                extraHeaders: headers,
                session: urlSession
            )
            do {
                let messages = try await client.fetchTranscript(threadId: threadId)
                guard !messages.isEmpty else { return }
                let bubbles = TranscriptMapper.bubbles(from: messages)
                let agentMessages = messages
                    .filter { $0.role == "human" }
                    .map { AgentMessage.user($0.content, id: $0.id ?? UUID().uuidString) }
                await session.reset(messages: agentMessages)
                await MainActor.run { [weak self] in
                    guard let self, self.bubbles.isEmpty else { return }
                    self.bubbles = bubbles
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.bubbles = [ChatBubble(role: .system, text: "Could not load history: \(error.localizedDescription)")]
                }
            }
        }
    }

    // MARK: - Helpers

    /// Trim `text` to its first ~6 words / 40 characters for use as a thread title.
    static func deriveTitle(_ text: String) -> String {
        let line = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .newlines).first ?? ""
        let words = line.split(separator: " ").prefix(6).joined(separator: " ")
        let trimmed = words.isEmpty ? line : words
        return trimmed.count > 40 ? String(trimmed.prefix(40)) : trimmed
    }

    // MARK: - Stream handling

    /// Internal so tests can drive the state machine directly without
    /// spinning up a real `AgentSession` — the streamed-event handlers (in
    /// particular the `toolRound` lifecycle) are subtle enough to warrant
    /// focused unit tests at this layer.
    func apply(_ event: SessionEvent) {
        switch event {
        case .assistantMessageStart(let id):
            // LLM is resuming narration after any tool batch — close the open
            // tool-round bubble so the next .toolCallStarted opens a fresh one.
            openToolRoundId = nil
            appendBubble(ChatBubble(id: id, role: .assistant, text: ""))
        case .assistantMessageDelta(let id, let delta):
            mutateBubble(id: id) { $0.text.append(delta) }
        case .assistantMessageEnd(let id, let text):
            mutateBubble(id: id) { $0.text = text }
        case .toolCallStarted(let id, let name):
            openOrAppendToolRoundEntry(id: id, name: name)
        case .toolCallFinished(let id, let name, let arguments, let result):
            finishToolRoundEntry(id: id, name: name, arguments: arguments, result: result)
        case .roundFinished:
            // Do NOT close the round here. `.toolCallFinished` is yielded by
            // `AgentSession.runLoop` after `runOneRound` returns, i.e. after
            // `.roundFinished` has already fired. Closing here would leave the
            // entry pending forever.
            break
        case .completed(let outcome):
            openToolRoundId = nil
            // A turn that settled without any assistant text and without an
            // error would otherwise just drop the spinner and look dead. Show
            // an inline system note with the reason so the user knows it
            // stopped (and can nudge it) rather than wondering if it crashed.
            if case .silent(let reason) = outcome, !didUserStop {
                appendBubble(ChatBubble(role: .system, text: Self.silentStopMessage(reason)))
            }
        case .error(let message, _):
            openToolRoundId = nil
            lastError = message
        }
    }

    /// User-facing note for a turn that ended with no assistant reply.
    static func silentStopMessage(_ reason: SilentReason) -> String {
        switch reason {
        case .emptyTurn:
            return "The agent finished its turn without a reply. Say \u{201C}continue\u{201D} to nudge it."
        case .maxRounds:
            return "Stopped after the tool-round safety limit. Say \u{201C}continue\u{201D} to resume."
        case .droppedStream:
            return "The connection closed before the agent replied. Say \u{201C}continue\u{201D} or try again."
        case .backend(let detail):
            return "The agent stopped: \(detail)"
        }
    }

    private func openOrAppendToolRoundEntry(id: String, name: String) {
        // Dedupe by id across ALL toolRound bubbles (not just the currently-
        // open one). In the mixed frontend+backend case backend tools get one
        // `TOOL_CALL_START` in round 1 (model emission) and another in round
        // 2 when `ToolNode` actually executes them after the frontend
        // interrupt resumes — same id both times. The shell-approval flow
        // makes this worse: between the two starts an `.assistantMessageStart`
        // can close round 1's bubble (resetting `openToolRoundId` to nil),
        // so a per-open-bubble dedupe would miss and a fresh empty bubble B
        // would open. `.toolCallFinished` then picks bubble A via its fallback
        // scan and bubble B's `.pending` entry never resolves — stuck spinner.
        // Scanning every toolRound bubble keeps round 1's entry the single
        // source of truth.
        if bubbles.contains(where: { $0.role == .toolRound && $0.toolEntries.contains(where: { $0.id == id }) }) {
            return
        }
        if openToolRoundId == nil {
            let bubble = ChatBubble(role: .toolRound, text: "")
            openToolRoundId = bubble.id
            appendBubble(bubble)
        }
        guard let roundId = openToolRoundId else { return }
        mutateBubble(id: roundId) { bubble in
            bubble.toolEntries.append(ToolCallEntry(id: id, name: name, state: .pending))
        }
    }

    private func finishToolRoundEntry(id: String, name: String, arguments: AnyJSON, result: AnyJSON?) {
        let argsJSON = prettyJSONString(arguments)
        let resultText = result.map(prettyJSONString) ?? ""
        let entryState = Self.entryState(for: result)
        // Prefer the currently-open round; fall back to a scan so a late
        // `.toolCallFinished` (e.g. arriving after the user hit Stop and the
        // round was force-closed by `.completed`/`.error`) still flips the
        // entry's spinner instead of leaving it pending forever.
        let bubbleId: String? = openToolRoundId
            ?? bubbles.first(where: { $0.role == .toolRound && $0.toolEntries.contains(where: { $0.id == id }) })?.id
        guard let bubbleId else { return }
        mutateBubble(id: bubbleId) { bubble in
            guard let idx = bubble.toolEntries.firstIndex(where: { $0.id == id }) else { return }
            bubble.toolEntries[idx].argsJSON = argsJSON
            bubble.toolEntries[idx].resultText = resultText
            bubble.toolEntries[idx].state = entryState
        }
        // `embedComponent` (hostKind "chat") snapshots a resolved chart into
        // its result; drop it in as its own assistant bubble so it renders
        // inline in the transcript.
        if name == "embedComponent", let snapshot = Self.chartSnapshot(from: result) {
            appendBubble(ChatBubble(role: .assistant, chartSnapshot: snapshot))
        }
    }

    /// Pull a `ChatChartSnapshot` out of an `embedComponent` result's
    /// `chartSnapshot` field, or nil when the call wasn't a chat-host embed.
    private static func chartSnapshot(from result: AnyJSON?) -> ChatChartSnapshot? {
        guard case .object(let fields) = result, let snap = fields["chartSnapshot"],
              let data = try? JSONEncoder().encode(snap) else { return nil }
        return try? JSONDecoder().decode(ChatChartSnapshot.self, from: data)
    }

    /// Classify a finished tool result as `.done` or `.failed`. Matches the
    /// failure shape AGUIKit uses for thrown handler errors (see
    /// `AgentSession.runLoop`): an object carrying `ok: false` and a non-empty
    /// `error` field. Anything else — including `nil` (backend tool with no
    /// server-emitted result) — counts as success.
    private static func entryState(for result: AnyJSON?) -> ToolCallEntry.State {
        guard case .object(let fields) = result else { return .done }
        if case .bool(let ok) = fields["ok"], ok == false { return .failed }
        return .done
    }

    private func appendBubble(_ bubble: ChatBubble) {
        bubbles.append(bubble)
    }

    private func mutateBubble(id: String, _ body: (inout ChatBubble) -> Void) {
        guard let idx = bubbles.firstIndex(where: { $0.id == id }) else { return }
        body(&bubbles[idx])
    }

    private func setStreaming(_ value: Bool) {
        guard isStreaming != value else { return }
        isStreaming = value
        // A genuine turn just settled (stream ended, not parked on an
        // interrupt) → flag it unviewed so the badge surfaces it for a thread
        // the user isn't currently looking at. The visible thread clears this
        // immediately via `markViewed()`.
        if !value && !isAwaitingHumanInput {
            hasUnviewedCompletion = true
        }
        onStreamingChange?(value)
    }

    // MARK: - State (per-turn agent state, distinct from `context`)

    /// Resolve the model for a turn. Single home for the selection precedence
    /// — the chat send path (`forwardedPropsJSON`) and the header chip's
    /// resting selection (`ConversationPager`) both call this so they can't
    /// drift. Precedence:
    /// 1. per-thread pin (`MyAppStore.threadLLM`) — set from the header chip;
    /// 2. per-agent default for the scope: `MyAppStore.myAppLLM(for: id)` for
    ///    `.myApp`, `SettingsStore.orchestratorLLM()` for `.memory` (the
    ///    orchestrator has no MyApp parent, so its selection is global);
    /// 3. `nil` → caller falls back to the backend's env-configured default.
    @MainActor
    static func effectiveLLM(
        scope: ChatScope,
        threadId: String,
        store: MyAppStore,
        settings: SettingsStore
    ) -> (provider: String, model: String)? {
        if let pin = store.threadLLM(threadId: threadId, for: scope) { return pin }
        switch scope {
        case .myApp(let id): return store.myAppLLM(for: id)
        case .memory:        return settings.orchestratorLLM()
        }
    }

    /// Build the `RunAgentInput.forwardedProps` payload sent at the start of
    /// every turn (and merged into resume rounds by `AgentSession`). Wraps
    /// `effectiveLLM` as `{"llm": {provider, model}}`, or an empty object when
    /// unresolved → backend uses its env-configured default model.
    @MainActor
    static func forwardedPropsJSON(
        scope: ChatScope,
        threadId: String,
        store: MyAppStore,
        settings: SettingsStore
    ) -> AnyJSON {
        guard let (provider, model) = effectiveLLM(scope: scope, threadId: threadId, store: store, settings: settings) else {
            return .object([:])
        }
        return .object([
            "llm": .object([
                "provider": .string(provider),
                "model": .string(model),
            ])
        ])
    }

    /// Build the `RunAgentInput.state` payload pushed every turn. Lands in
    /// the LangGraph agent state on the server via `prepare_stream`; the
    /// `ToolGatingMiddleware` reads `state["disabled_tools"]` to drop muted
    /// backend tools from the model's tool list per call. Distinct from
    /// `context` because state is typed runtime data, not free-text guidance.
    private static func stateJSON(
        settings: SettingsStore,
        scope: ChatScope,
        store: MyAppStore
    ) async -> AnyJSON {
        await MainActor.run {
            // Union the global Settings → Tools set with the per-agent disabled
            // set for the active scope (main agent → per-MyApp; orchestrator →
            // global orchestrator override). Per-agent is additive, never an
            // override — see `MyAppStore.myAppDisabledTools`.
            var disabledSet = settings.disabledBackendTools
            switch scope {
            case .myApp(let id): disabledSet.formUnion(store.myAppDisabledTools(for: id))
            case .memory:        disabledSet.formUnion(settings.orchestratorDisabledTools)
            }
            let disabled = disabledSet.sorted().map { AnyJSON.string($0) }
            var entries: [String: AnyJSON] = ["disabled_tools": .array(disabled)]
            // Resolve shellApprovalDisabled through the settings hierarchy:
            // per-myApp override (if any) beats the global toggle.
            let myAppSettings: [UUID: [String: SettingValue]]
            let resolveScope: SettingsScope
            if case .myApp(let id) = scope,
               let myApp = store.myApp(withId: id) {
                myAppSettings = [id: myApp.settings]
                resolveScope = .myApp(id)
            } else {
                myAppSettings = [:]
                resolveScope = .global
            }
            let effective = EffectiveSettings(
                globalSource: GlobalSettingsSource(shellApprovalDisabled: settings.shellApprovalDisabled),
                myAppSettings: myAppSettings
            )
            if effective.resolve(ShellApprovalDisabledKey.self, at: resolveScope) {
                entries["shell_approval_disabled"] = .bool(true)
            }
            return .object(entries)
        }
    }

    // MARK: - Context

    private static func contextEntries(
        store: MyAppStore,
        memory: MemoryStore,
        scope: ChatScope,
        focusedPath: String,
        previewTracker: CanvasPreviewTracker
    ) async -> [AgentContextEntry] {
        await MainActor.run {
            let memoriesPayload: [String: [String]] = ["paths": memory.snapshotPaths()]
            let memoriesJSON = (try? JSONEncoder().encode(memoriesPayload)).flatMap { String(data: $0, encoding: .utf8) } ?? "{\"paths\":[]}"
            let memoriesEntry = AgentContextEntry(
                description: "User memories — sandboxed markdown FileSystem persisted across sessions. Payload: flat list of paths relative to memories root. Explore via ls/read/grepMemories; write/append/editMemoryFile to save user-volunteered facts (e.g. diet.md, notes/goals.md); move/delete/createMemoryFolder for organisation.",
                value: memoriesJSON
            )
            // Skills available in this scope (pupa/skills/). Always present so
            // the agent knows it can use AND create skills, even with none yet.
            let skillsEntry = [skillsContextEntry(SkillStore(memory: memory))]

            switch scope {
            case .memory:
                // Snapshot the myApps sidebar so the orchestrator can resolve
                // user-mentioned myApp names without an extra `listMyApps`
                // round trip. `listMyApps` is still registered for when the
                // model wants a deterministic, fresh read mid-turn.
                let myAppsSnapshot: [[String: String]] = store.myApps.map { myApp in
                    [
                        "id": myApp.id.uuidString,
                        "typeId": myApp.typeId,
                        "name": myApp.name,
                        "iconSystemName": myApp.iconSystemName,
                    ]
                }
                let modePayload: [String: AnyJSON] = [
                    "mode": .string("memory"),
                    "focusedFile": .string(focusedPath),
                    "memoryFolder": .string(MemoryStore.orchestratorFolder()),
                    "myApps": .array(myAppsSnapshot.map { dict in
                        .object(dict.mapValues { .string($0) })
                    }),
                ]
                let modeJSON = (try? JSONEncoder().encode(modePayload)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                // System prompt via OrchestratorPolicy — reads
                // orchestrator/pupa/AGENTS.md; falls back to hardcoded text.
                let orchDescription = OrchestratorPolicy().buildSystemPrompt(memory: memory)
                return [
                    memoriesEntry,
                    AgentContextEntry(
                        description: orchDescription,
                        value: modeJSON
                    ),
                ] + skillsEntry

            case .myApp(let id):
                guard let myApp = store.myApps.first(where: { $0.id == id }) else {
                    // MyApp removed mid-stream. Fall back to memories-only
                    // context so the agent at least sees a coherent payload.
                    return [memoriesEntry]
                }
                let summary = CanvasSummary.build(myApp: myApp, previewTracker: previewTracker)
                let canvasJSON = summary.toJSONString()
                // System prompt via MyAppPolicy — reads <myapps/name>/pupa/AGENTS.md;
                // falls back to the type-fragment description.
                let typeDescription = MyAppPolicy(myAppId: id).buildSystemPrompt(
                    myApp: myApp, memory: memory
                )
                let typePayload: [String: String] = [
                    "typeId": myApp.typeId,
                    "myAppName": myApp.name,
                    "memoryFolder": MemoryStore.myAppFolder(myAppName: myApp.name),
                ]
                let typeJSON = (try? JSONEncoder().encode(typePayload)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                return [
                    AgentContextEntry(
                        description: "Live canvas state — thin enum. Shape: {components: [{id, name, kind, itemCount, summary}], activeComponentId}. `summary` is YOUR slot — set via the kind's render tool with only `summary` arg; rides every turn until overwritten (record field names, select-option meanings, user intent, data state). Drill via list/search/get per-kind; `getCanvasState` = full-dump escape hatch.",
                        value: canvasJSON
                    ),
                    memoriesEntry,
                    AgentContextEntry(description: typeDescription, value: typeJSON),
                ] + skillsEntry + [agentsContextEntry(AgentStore(memory: memory))]
            }
        }
    }

    /// The subagents context entry for a MyApp scope's `AgentStore`. Always
    /// present so the agent knows it can delegate to (and create) subagents,
    /// even with none defined yet. `value` lists each subagent's name +
    /// description + when_to_use (progressive disclosure); the persona body
    /// loads only when the subagent actually runs. Shared by the main-chat and
    /// sub-run paths.
    @MainActor
    static func agentsContextEntry(_ agentStore: AgentStore) -> AgentContextEntry {
        let payload: [[String: String]] = agentStore.modelContextAgents().map { agent in
            var dict: [String: String] = ["name": agent.name]
            if !agent.description.isEmpty { dict["description"] = agent.description }
            if let w = agent.whenToUse, !w.isEmpty { dict["when_to_use"] = w }
            return dict
        }
        let json = (try? JSONEncoder().encode(["agents": payload]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{\"agents\":[]}"
        return AgentContextEntry(
            description: "Subagents — Claude-Code-style delegates in pupa/agents/ (the `agents` list "
                + "below is the roster; empty means none yet). DELEGATE to one: call "
                + "invoke_agent(name:, prompt:) — it runs in a scoped sub-session and returns its "
                + "reply. CREATE one: writeMemoryFile to `pupa/agents/<slug>/AGENTS.md` — `<slug>` "
                + "becomes its invoke name. Optional YAML frontmatter above the persona body: "
                + "`name`, `description` (what + when to delegate), `when_to_use`, `tools` "
                + "(comma-separated allowlist; omit to inherit this myApp's surface), "
                + "`disabled_tools`, `model`, `provider`. Only names + descriptions ride context; "
                + "the persona loads when the subagent runs.",
            value: json
        )
    }

    /// The skills context entry for a scope's `SkillStore`. Always present so
    /// the agent knows both how to USE skills (`app_skill_view`) and how to
    /// CREATE them (write a `pupa/skills/<name>/SKILL.md`), even when the
    /// catalogue is empty. `value` lists only model-visible skills (name +
    /// when_to_use); bodies load on demand (progressive disclosure). Shared by
    /// the orchestrator/myApp chat paths and the sub-run / Slack paths in
    /// `ChatSessionCoordinator`.
    @MainActor
    static func skillsContextEntry(_ skillStore: SkillStore) -> AgentContextEntry {
        let payload: [[String: String]] = skillStore.modelContextSkills().map { skill in
            var dict: [String: String] = ["name": skill.name]
            if !skill.description.isEmpty { dict["description"] = skill.description }
            if let w = skill.whenToUse, !w.isEmpty { dict["when_to_use"] = w }
            if let a = skill.argumentHint, !a.isEmpty { dict["argument_hint"] = a }
            return dict
        }
        let json = (try? JSONEncoder().encode(["skills": payload]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{\"skills\":[]}"
        return AgentContextEntry(
            description: "Skills — reusable `/command` playbooks in pupa/skills/ (the `skills` list "
                + "below is the catalogue; empty means none yet). USE one: call app_skill_view(name:) "
                + "to load its full instructions, then follow them. CREATE one: writeMemoryFile to "
                + "`pupa/skills/<name>/SKILL.md` — `<name>` becomes its /command. Optional YAML "
                + "frontmatter above the markdown body: `description` (what + when to use it), "
                + "`when_to_use`, `disable-model-invocation: true` (user-only, hidden from you), "
                + "`user-invocable: false` (you-only, no slash command). Only descriptions ride "
                + "context; bodies load on view.",
            value: json
        )
    }
}

// MARK: - HumanInTheLoopBridge

extension ChatViewModel: HumanInTheLoopBridge {
    /// Render a `humanQuestion` bubble for the given rows, suspend the
    /// caller until the user taps Submit (or cancels), return the
    /// collected answers. Driven by the `ask_user_questions` frontend
    /// tool's handler in [AppTools.swift](../Tools/AppTools.swift).
    public func requestShellApproval(command: String) async -> (approved: Bool, remember: Bool) {
        openToolRoundId = nil
        let bubble = ChatBubble(role: .shellApproval, text: command)
        appendBubble(bubble)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<(approved: Bool, remember: Bool), Never>) in
                pendingShellApprovalContinuation = continuation
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, let continuation = self.pendingShellApprovalContinuation else { return }
                self.pendingShellApprovalContinuation = nil
                continuation.resume(returning: (approved: false, remember: false))
            }
        }
    }

    public func askQuestions(_ questions: [HumanQuestionRow]) async -> [String] {
        // Close any open tool-round bubble — `ask_user_questions` is
        // typically the only call in its batch, so the spinner should
        // resolve before we render the question panel.
        openToolRoundId = nil
        let bubble = ChatBubble(role: .humanQuestion, humanQuestions: questions)
        appendBubble(bubble)
        pendingBubbleId = bubble.id
        pendingAnswers = Array(repeating: "", count: questions.count)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<[String], Never>) in
                pendingContinuation = continuation
            }
        } onCancel: {
            // Cancellation must resume the continuation exactly once.
            // Hop back to the main actor to read/clear the stored
            // continuation safely.
            Task { @MainActor [weak self] in
                guard let self, let continuation = self.pendingContinuation else { return }
                self.pendingContinuation = nil
                self.pendingBubbleId = nil
                self.pendingAnswers = []
                continuation.resume(returning: [])
            }
        }
    }
}

/// Pretty-print an `AnyJSON` payload as a human-readable string. Used to
/// render tool-call args and results inside an expanded `toolRound` bubble.
/// Falls back to the encoder's default output if pretty-printing fails.
private func prettyJSONString(_ value: AnyJSON) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    if let data = try? encoder.encode(value), let s = String(data: data, encoding: .utf8) {
        return s
    }
    return ""
}
