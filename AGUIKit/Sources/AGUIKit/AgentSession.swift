import Foundation

/// High-level events the chat UI cares about, distilled from the raw
/// AG-UI event stream. Drives a typical chat experience without exposing
/// per-protocol minutiae.
public enum SessionEvent: Sendable {
    /// New assistant message starting; its tokens will follow.
    case assistantMessageStart(messageId: String)
    /// Append text to the assistant message identified by `messageId`.
    case assistantMessageDelta(messageId: String, delta: String)
    /// The assistant message identified by `messageId` is complete (final text in `text`).
    case assistantMessageEnd(messageId: String, text: String)
    /// A tool call has begun streaming from the agent. Yielded as soon as
    /// `TOOL_CALL_START` arrives so chat UIs can render a live "calling X…"
    /// indicator. The args buffer is not yet available — wait for the paired
    /// `.toolCallFinished` for the parsed args + result.
    case toolCallStarted(id: String, name: String)
    /// A tool call has fully resolved. For frontend tools dispatched via the
    /// interrupt loop, `result` is the local handler's return value. For
    /// backend tools, `result` is the server-emitted `TOOL_CALL_RESULT`
    /// content decoded as JSON when possible, or `.string` fallback when the
    /// payload isn't JSON, or `nil` when the backend didn't emit a result
    /// for this call.
    case toolCallFinished(id: String, name: String, arguments: AnyJSON, result: AnyJSON?)
    /// One agent run finished. With interrupt-driven dispatch this fires
    /// after every paused-then-resumed segment; the session continues with
    /// another POST until no further interrupt arrives.
    case roundFinished(threadId: String, runId: String)
    /// The full multi-round exchange has settled — no more pending tool calls.
    case completed
    /// The agent emitted an error event.
    case error(message: String, code: String?)
}

/// Drives the interrupt-driven AG-UI loop on top of `AgentClient`.
///
/// Responsibilities:
///   1. POST the user message + registered tool descriptors + caller-supplied context.
///   2. Stream events; accumulate text deltas into `messageId`-keyed buffers; surface
///      tool-call lifecycle to the host via `.toolCallStarted` / `.toolCallFinished`.
///   3. When `ag_ui_langgraph` emits `CUSTOM(on_interrupt, …)` with a
///      `frontend_tool_calls` payload, dispatch every call through the local
///      `ToolRegistry` (parallel-safe handlers run concurrently, others run in
///      submission order), collect their results, and POST a follow-up round
///      with `forwardedProps.command.resume = {"tool_results": [...]}`. Repeat
///      until the backend stops requesting more dispatches.
///   4. Yield `.completed` when the run settles with no further interrupt.
public actor AgentSession {
    public let client: AgentClient
    public let registry: ToolRegistry
    public private(set) var threadId: String
    /// Hard cap on rounds per send to bound runaway loops. With interrupt-
    /// driven dispatch every iteration is either a fresh model turn or a
    /// resume; LangGraph's `recursion_limit` counts graph steps, which this
    /// cap doesn't, so we keep an iOS-side breaker for runaway tool loops.
    public let maxRounds: Int

    /// User messages accumulated across turns. Re-POSTed every round so
    /// `ag_ui_langgraph.prepare_stream` recognises the run as a continuation
    /// (its HumanMessage-id-based check) rather than a time-travel
    /// regeneration. We don't track assistant / tool messages locally — the
    /// backend checkpoint is the source of truth for those, and the chat UI
    /// builds its bubbles from `SessionEvent`s rather than from this list.
    public private(set) var messages: [AgentMessage] = []

    /// True once the most recent `send(_:)` reached `.completed` cleanly
    /// (no HTTP error, no empty round, no cancellation). The next send
    /// checks this to decide whether to APPEND its user message (previous
    /// send settled) or REPLACE the trailing one (previous send orphaned
    /// the user — HTTP 500, agent emitted nothing, etc.). Without this
    /// signal we'd POST two consecutive user messages, which the backend
    /// checkpoints and which triggers the duplicate-tool-call spiral.
    private var lastSendSettledCleanly: Bool = true

    /// Highest replay sequence number observed on this thread — the SSE `id:`
    /// the backend's resumable-SSE layer stamps on every frame. A dropped
    /// socket re-attaches with `command.reattach.after_seq = lastEventSeq`
    /// and the backend replays only what was missed. Nil until the first
    /// sequenced event arrives (older backends never stamp ids, in which
    /// case re-attach replays the whole buffered turn — events the UI has
    /// already applied may repeat; acceptable degraded mode). See pupa#103.
    private var lastEventSeq: Int?

    /// Transport drops mid-round are retried this many times (exponential
    /// backoff, base 0.5s) before the error is surfaced to the caller.
    private let maxReattachAttempts = 4
    private let reattachBaseDelayNanos: UInt64 = 500_000_000

    public init(
        client: AgentClient,
        registry: ToolRegistry,
        threadId: String,
        initialMessages: [AgentMessage] = [],
        maxRounds: Int = 8
    ) {
        self.client = client
        self.registry = registry
        self.threadId = threadId
        self.messages = initialMessages
        self.maxRounds = maxRounds
        let toolNames = registry.descriptors.map(\.name).sorted().joined(separator: ",")
        AGUIKitLog.session(
            "AgentSession init thread=\(threadId) maxRounds=\(maxRounds) " +
            "tools=\(registry.descriptors.count) [\(toolNames)]"
        )
    }

    /// Reset the conversation history. Optionally swap the threadId — pass a
    /// new UUID when starting a fresh logical session, so subsequent rounds
    /// hit a brand-new checkpoint on the backend instead of resuming the
    /// previous thread.
    public func reset(messages: [AgentMessage] = [], threadId: String? = nil) {
        self.messages = messages
        self.lastSendSettledCleanly = true
        if let threadId {
            self.threadId = threadId
            self.lastEventSeq = nil
            AGUIKitLog.session("AgentSession reset threadId=\(threadId)")
        }
    }

    /// Send a user message and stream session-level events until the agent
    /// settles. Caller supplies `context` per turn (e.g. live state snapshots).
    ///
    /// - Parameter image: Optional inline image attached to the user message.
    ///   When non-nil, the user message is encoded as a multimodal AG-UI
    ///   payload (text part + image part) instead of a plain string.
    /// - Parameter toolFilter: When non-nil, the registry's descriptors are
    ///   intersected with the returned set before being sent to the backend.
    ///   Use this to expose only a subset of locally-registered tools to the
    ///   agent on a given turn (e.g. per-space tool surfaces). Tools not in
    ///   the filter remain executable locally if the agent calls them, but
    ///   they aren't advertised. The closure is `async` and **called once
    ///   per round**, so the host can read live MainActor-bound state to
    ///   grow / shrink the advertised surface mid-turn.
    /// - Parameter state: Optional `RunAgentInput.state` provider, called once
    ///   per round. Top-level keys are merged into `state` server-side via
    ///   `ag_ui_langgraph.prepare_stream`.
    /// - Parameter forwardedProps: Optional base `RunAgentInput.forwardedProps`
    ///   resolved once at `send` time and re-applied on every round of the
    ///   turn (including resume rounds after a frontend interrupt). The
    ///   loop merges the resume-only `command` key on top of these base
    ///   keys, so per-turn config like `llm = {provider, model}` survives
    ///   across rounds — picking a per-agent model in iOS would otherwise
    ///   only apply to the first round, with subsequent resume rounds
    ///   silently falling back to the backend's env default.
    public nonisolated func send(
        _ text: String,
        image: (data: Data, mimeType: String)? = nil,
        context: @Sendable @escaping () async -> [AgentContextEntry],
        toolFilter: (@Sendable () async -> Set<String>)? = nil,
        state: (@Sendable () async -> AnyJSON)? = nil,
        forwardedProps: AnyJSON = .object([:])
    ) -> AsyncThrowingStream<SessionEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { [self] in
                do {
                    try await runLoop(
                        userText: text,
                        image: image,
                        context: context,
                        toolFilter: toolFilter,
                        state: state,
                        baseForwardedProps: forwardedProps,
                        yield: { ev in continuation.yield(ev) }
                    )
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: AgentClientError.cancelled)
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Re-attach to a run that may have continued — or finished — on the
    /// backend while this client was backgrounded, offline, or dead
    /// (catch-up after app kill). Replays every event after the last seen
    /// replay seq; if the replayed tail contains a frontend-tool interrupt,
    /// the tools are dispatched and the run resumed, exactly like `send`'s
    /// loop, minus a new user message.
    ///
    /// Completes immediately (no events, then `.completed`) when the backend
    /// has nothing buffered for this thread — callers can invoke it
    /// opportunistically on foreground/launch without special-casing.
    ///
    /// Note: resume rounds triggered from here carry no per-turn
    /// `forwardedProps` (model selection etc.) — the backend falls back to
    /// its env default for the remainder of the turn. Acceptable for the
    /// recovery path.
    public nonisolated func reattach() -> AsyncThrowingStream<SessionEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { [self] in
                do {
                    try await runReattachLoop(yield: { ev in continuation.yield(ev) })
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: AgentClientError.cancelled)
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Internals

    private func runReattachLoop(yield: @Sendable (SessionEvent) -> Void) async throws {
        // No replay cursor → either the backend never stamped a seq (predates
        // the replay layer) or this session never streamed. Reattaching would
        // hit a real agent loop with an empty message list — do nothing.
        // (Launch-time catch-up after an app kill needs the cursor persisted;
        // follow-up on pupa#103.)
        guard lastEventSeq != nil else {
            AGUIKitLog.session("reattach() skipped — no replay cursor for thread=\(threadId)")
            yield(.completed)
            return
        }
        AGUIKitLog.session(
            "reattach() thread=\(threadId) after_seq=\(lastEventSeq.map(String.init) ?? "-1")"
        )
        var input = reattachInput()
        for round in 0..<maxRounds {
            var state = RoundState()
            try await consumeRoundStream(client.runSequenced(input), state: &state, yield: yield)
            finishRound(state: state, yield: yield)

            guard let dispatch = state.outcome.pendingDispatch else {
                AGUIKitLog.session("reattach round \(round + 1) settled → completed")
                if state.outcome.hadOutput { lastSendSettledCleanly = true }
                yield(.completed)
                return
            }
            // The replayed tail ended on a frontend-tool interrupt the app
            // never serviced (it was backgrounded/dead when it fired).
            // Dispatch now and resume the parked run — same contract as
            // `runLoop`, including the mid-turn tool-surface refresh.
            AGUIKitLog.session(
                "reattach round \(round + 1) found interrupt → dispatching \(dispatch.calls.count) tool(s)"
            )
            let toolResults = await dispatchFrontendTools(calls: dispatch.calls, yield: yield)
            let toolsAfterRound: [AnyJSON] = registry.descriptors.map { d in
                .object([
                    "name": .string(d.name),
                    "description": .string(d.description),
                    "parameters": d.parameters,
                ])
            }
            input = RunAgentInput(
                threadId: threadId,
                messages: messages,
                tools: registry.descriptors,
                context: [],
                forwardedProps: .object([
                    "command": .object([
                        "resume": .object([
                            "tool_results": .array(toolResults),
                            "tools_after_round": .array(toolsAfterRound),
                        ])
                    ])
                ])
            )
        }
        AGUIKitLog.session("reattach hit maxRounds=\(maxRounds) → completed")
        yield(.completed)
    }

    private func runLoop(
        userText: String,
        image: (data: Data, mimeType: String)?,
        context: @Sendable () async -> [AgentContextEntry],
        toolFilter: (@Sendable () async -> Set<String>)?,
        state: (@Sendable () async -> AnyJSON)?,
        baseForwardedProps: AnyJSON,
        yield: @Sendable (SessionEvent) -> Void
    ) async throws {
        let userMessage = AgentMessage.user(text: userText, image: image)
        // If the previous send was cancelled, errored, or settled with no
        // assistant output, the prior user message is sitting at the tail
        // of `messages` with no follow-up on the backend either. Stacking
        // another user on top of it produces malformed history (two
        // consecutive user messages) which the backend would checkpoint,
        // triggering the duplicate-tool-call spiral. Replace the orphan.
        if !lastSendSettledCleanly, let last = messages.last, last.role == .user {
            AGUIKitLog.session("send() replacing orphan user message (previous send didn't settle cleanly)")
            messages[messages.count - 1] = userMessage
        } else {
            messages.append(userMessage)
        }
        // Reset the flag for this send; we'll flip it back true if we
        // reach `.completed`.
        lastSendSettledCleanly = false
        let imageNote = image.map { " image=\($0.mimeType)/\($0.data.count)B" } ?? ""
        AGUIKitLog.session("send() user=\(snippet(userText))\(imageNote) thread=\(threadId) maxRounds=\(maxRounds)")

        var nextForwardedProps: AnyJSON = baseForwardedProps

        for round in 0..<maxRounds {
            let ctx = await context()
            let descriptors: [ToolDescriptor]
            if let filter = await toolFilter?() {
                descriptors = registry.descriptors.filter { filter.contains($0.name) }
            } else {
                descriptors = registry.descriptors
            }
            let stateJSON: AnyJSON = await state?() ?? .null
            let input = RunAgentInput(
                threadId: threadId,
                state: stateJSON,
                messages: messages,
                tools: descriptors,
                context: ctx,
                forwardedProps: nextForwardedProps
            )
            AGUIKitLog.session(
                "round \(round + 1) → POST | msgs=\(messages.count) " +
                "(\(messageRoleSummary())) tools=\(descriptors.count) " +
                "ctx=\(ctx.count) resume=\(nextForwardedProps != baseForwardedProps)"
            )

            let outcome = try await runOneRound(input: input, yield: yield)

            // If `ag_ui_langgraph` emitted `on_interrupt` during this round
            // the graph is paused with a batched list of frontend tool calls
            // to dispatch locally. Run them, encode the results, and POST a
            // resume on the next loop iteration.
            if let dispatch = outcome.pendingDispatch {
                AGUIKitLog.session(
                    "round \(round + 1) paused on interrupt → dispatching \(dispatch.calls.count) " +
                    "frontend tool(s) [" +
                    dispatch.calls.map { $0.name }.joined(separator: ", ") + "]"
                )
                let toolResults = await dispatchFrontendTools(
                    calls: dispatch.calls,
                    yield: yield
                )
                // Mid-turn tool-surface refresh. After the dispatched
                // tool handlers run (e.g. `addComponent(kind:"checklist")`
                // updates the local store), recompute the advertised
                // descriptor list and embed it in the resume payload so
                // the backend can refresh `state["copilotkit"]["actions"]`
                // before the model is re-invoked. `ag_ui_langgraph`
                // discards `RunAgentInput.tools` on the resume branch
                // (`Command(resume=...)` carries nothing else), so this
                // side-channel is the only thing the model has to see
                // the newly-unlocked tools within the same turn.
                let postDispatchDescriptors: [ToolDescriptor]
                if let filter = await toolFilter?() {
                    postDispatchDescriptors = registry.descriptors.filter { filter.contains($0.name) }
                } else {
                    postDispatchDescriptors = registry.descriptors
                }
                let toolsAfterRound: [AnyJSON] = postDispatchDescriptors.map { d in
                    .object([
                        "name": .string(d.name),
                        "description": .string(d.description),
                        "parameters": d.parameters,
                    ])
                }
                // Merge the resume payload on top of the caller-supplied base
                // forwardedProps so per-turn config (e.g. `llm = {provider,
                // model}`) survives the second-and-later rounds — without this
                // merge, every round after the first would land at the backend
                // without the model selection and silently fall back to env.
                nextForwardedProps = mergeIntoObject(
                    base: baseForwardedProps,
                    overlay: [
                        "command": .object([
                            "resume": .object([
                                "tool_results": .array(toolResults),
                                "tools_after_round": .array(toolsAfterRound),
                            ])
                        ])
                    ]
                )
                continue
            }

            // No interrupt — the run has settled. Treat it as a clean
            // settle only if the round actually produced something
            // (text or tool calls); a fully empty round (RUN_STARTED →
            // RUN_FINISHED with nothing in between) leaves the user
            // message orphaned, so the next send should replace it.
            AGUIKitLog.session("round \(round + 1) settled (no interrupt) → completed (hadOutput=\(outcome.hadOutput))")
            lastSendSettledCleanly = outcome.hadOutput
            yield(.completed)
            return
        }

        AGUIKitLog.session("hit maxRounds=\(maxRounds) → completed")
        // Hitting maxRounds is a runaway-loop guard, not a clean settle —
        // leave `lastSendSettledCleanly = false` so the next send's user
        // message replaces this orphaned one.
        yield(.completed)
    }

    /// Run every frontend tool the backend asked us to dispatch. Tools
    /// marked `parallelSafe` start concurrently; the rest run inline in
    /// submission order. Results are returned in submission order so the
    /// resume payload mirrors the call order the model emitted, and the
    /// caller's `.toolCallFinished` events fire deterministically.
    private func dispatchFrontendTools(
        calls: [FrontendToolCall],
        yield: @Sendable (SessionEvent) -> Void
    ) async -> [AnyJSON] {
        var parallelTasks: [String: Task<AnyJSON, Never>] = [:]
        for call in calls {
            guard let tool = registry.resolve(call.name), tool.parallelSafe else { continue }
            let handler = tool.handler
            let args = call.args
            parallelTasks[call.id] = Task<AnyJSON, Never> {
                do {
                    return try await handler(args)
                } catch {
                    return .object(["ok": .bool(false), "error": .string(String(describing: error))])
                }
            }
        }
        if !parallelTasks.isEmpty {
            AGUIKitLog.session("dispatched \(parallelTasks.count) parallel-safe tool(s) concurrently")
        }

        var results: [AnyJSON] = []
        results.reserveCapacity(calls.count)
        for call in calls {
            AGUIKitLog.session("dispatch tool=\(call.name) call=\(call.id)")
            let result: AnyJSON
            if let tool = registry.resolve(call.name) {
                if let task = parallelTasks[call.id] {
                    result = await task.value
                } else {
                    do {
                        result = try await tool.handler(call.args)
                    } catch {
                        result = .object([
                            "ok": .bool(false),
                            "error": .string(String(describing: error)),
                        ])
                    }
                }
            } else {
                // Backend advertised a tool the client doesn't know about.
                // Synthesise a structured failure so the model can react
                // rather than the run deadlocking on a missing result.
                AGUIKitLog.session("⚠️ unknown frontend tool=\(call.name) — returning failure result")
                result = .object([
                    "ok": .bool(false),
                    "error": .string("frontend tool '\(call.name)' is not registered on this client"),
                ])
            }
            let resultString: String = encodeJSONString(result)
            AGUIKitLog.session("done    tool=\(call.name) call=\(call.id) result=\(snippet(resultString))")
            yield(.toolCallFinished(id: call.id, name: call.name, arguments: call.args, result: result))
            results.append(.object([
                "toolCallId": .string(call.id),
                "content": .string(resultString),
            ]))
        }
        return results
    }

    private func messageRoleSummary() -> String {
        var counts: [AgentMessage.Role: Int] = [:]
        for m in messages { counts[m.role, default: 0] += 1 }
        let parts: [String] = counts
            .sorted(by: { $0.key.rawValue < $1.key.rawValue })
            .map { "\($0.key.rawValue):\($0.value)" }
        return parts.joined(separator: ",")
    }

    private nonisolated func snippet(_ s: String, max: Int = 80) -> String {
        if s.count <= max { return s.replacingOccurrences(of: "\n", with: "⏎") }
        let head = s.prefix(max).replacingOccurrences(of: "\n", with: "⏎")
        return "\(head)…(\(s.count)c)"
    }

    private struct RoundOutcome {
        /// Server-emitted `TOOL_CALL_RESULT` content keyed by `toolCallId`.
        /// The backend produces these for tools it executes itself (e.g.
        /// `tavily_search`); used to populate `.toolCallFinished.result`.
        var backendResults: [String: String] = [:]
        /// Tool-call metadata observed in the stream — name + parsed args
        /// keyed by `toolCallId`. Used to enrich `.toolCallFinished` events
        /// for backend tools that resolve mid-stream.
        var observedToolCalls: [String: (name: String, args: AnyJSON)] = [:]
        var observedOrder: [String] = []
        /// Set when `ag_ui_langgraph` emitted a `CUSTOM(on_interrupt, ...)`
        /// event during the round. The graph is paused; the run loop should
        /// dispatch the listed tools locally and POST a resume.
        var pendingDispatch: PendingFrontendDispatch?
        /// True if the round produced any text or any tool-call event. An
        /// empty round (RUN_STARTED → RUN_FINISHED with nothing in between)
        /// leaves this false so the run loop can mark the send as not
        /// having settled cleanly — the next send replaces the orphan
        /// user message rather than stacking on top.
        var hadOutput: Bool = false
    }

    private struct PendingFrontendDispatch {
        var calls: [FrontendToolCall]
    }

    fileprivate struct FrontendToolCall {
        var id: String
        var name: String
        var args: AnyJSON
    }

    /// Accumulated per-round decode state. Lives OUTSIDE the stream-consuming
    /// loop so a transport drop mid-round can re-attach (replaying only unseen
    /// frames) and keep appending to the same buffers — a text message split
    /// across the drop still assembles correctly.
    private struct RoundState {
        var outcome = RoundOutcome()
        var textBuffers: [String: String] = [:]
        var pendingArgs: [String: String] = [:]
        var pendingNames: [String: String] = [:]
    }

    /// True for errors worth a re-attach: the socket died (app backgrounded,
    /// network blip) but the backend run may well still be going. HTTP-level
    /// errors, malformed events, and user cancellation are NOT re-attachable.
    private static func isReattachable(_ error: Error) -> Bool {
        if case AgentClientError.requestFailed = error { return true }
        return false
    }

    /// Minimal `POST /` body for the replay layer's re-attach branch. The
    /// middleware short-circuits it — no agent loop ever sees this input, so
    /// messages/tools/context stay empty.
    private func reattachInput() -> RunAgentInput {
        RunAgentInput(
            threadId: threadId,
            messages: [],
            tools: [],
            context: [],
            forwardedProps: .object([
                "command": .object([
                    "reattach": .object(["after_seq": .int(lastEventSeq ?? -1)])
                ])
            ])
        )
    }

    private func runOneRound(
        input: RunAgentInput,
        yield: @Sendable (SessionEvent) -> Void
    ) async throws -> RoundOutcome {
        var state = RoundState()
        do {
            try await consumeRoundStream(client.runSequenced(input), state: &state, yield: yield)
        } catch let error where Self.isReattachable(error) {
            try await reattachAfterDrop(originalError: error, state: &state, yield: yield)
        }
        finishRound(state: state, yield: yield)
        return state.outcome
    }

    /// The socket died mid-round. Re-attach to the backend's replay log with
    /// exponential backoff, resuming event consumption exactly where the seq
    /// cursor left off. Throws the last transport error once attempts are
    /// exhausted (the caller then surfaces it as before this feature existed).
    private func reattachAfterDrop(
        originalError: Error,
        state: inout RoundState,
        yield: @Sendable (SessionEvent) -> Void
    ) async throws {
        // Never seen a replay seq → the backend predates the replay layer
        // (or this run died before its first frame). A reattach POST would
        // then reach a real agent loop with an empty message list — worse
        // than surfacing the drop. Bail to the legacy error path.
        guard lastEventSeq != nil else { throw originalError }
        var lastError = originalError
        for attempt in 1...maxReattachAttempts {
            try? await Task.sleep(nanoseconds: reattachBaseDelayNanos << (attempt - 1))
            if Task.isCancelled { throw AgentClientError.cancelled }
            AGUIKitLog.session(
                "stream dropped (\(lastError)) — reattach \(attempt)/\(maxReattachAttempts) " +
                "after_seq=\(lastEventSeq.map(String.init) ?? "-1")"
            )
            do {
                try await consumeRoundStream(client.runSequenced(reattachInput()), state: &state, yield: yield)
                AGUIKitLog.session("reattach succeeded on attempt \(attempt)")
                return
            } catch let error where Self.isReattachable(error) {
                lastError = error
            }
        }
        AGUIKitLog.session("reattach exhausted after \(maxReattachAttempts) attempts — surfacing error")
        throw lastError
    }

    private func consumeRoundStream(
        _ stream: AsyncThrowingStream<SequencedAgentEvent, Error>,
        state: inout RoundState,
        yield: @Sendable (SessionEvent) -> Void
    ) async throws {
        for try await sequenced in stream {
            if let seq = sequenced.seq { lastEventSeq = seq }
            switch sequenced.event {
            case .runStarted:
                continue
            case .runFinished(let r):
                yield(.roundFinished(threadId: r.threadId, runId: r.runId))
            case .runError(let e):
                yield(.error(message: e.message, code: e.code))
            case .textMessageStart(let s):
                state.textBuffers[s.messageId] = ""
                state.outcome.hadOutput = true
                yield(.assistantMessageStart(messageId: s.messageId))
            case .textMessageContent(let c):
                state.textBuffers[c.messageId, default: ""].append(c.delta)
                yield(.assistantMessageDelta(messageId: c.messageId, delta: c.delta))
            case .textMessageEnd(let e):
                let final = state.textBuffers[e.messageId] ?? ""
                yield(.assistantMessageEnd(messageId: e.messageId, text: final))
            case .toolCallStart(let s):
                state.pendingArgs[s.toolCallId] = ""
                state.pendingNames[s.toolCallId] = s.toolCallName
                state.outcome.observedOrder.append(s.toolCallId)
                state.outcome.hadOutput = true
                yield(.toolCallStarted(id: s.toolCallId, name: s.toolCallName))
            case .toolCallArgs(let a):
                state.pendingArgs[a.toolCallId, default: ""].append(a.delta)
            case .toolCallEnd(let e):
                guard let name = state.pendingNames[e.toolCallId] else { continue }
                let argsString = state.pendingArgs[e.toolCallId] ?? ""
                let parsedArgs: AnyJSON
                do {
                    parsedArgs = try ToolCallFunction(name: name, arguments: argsString).parsedArguments()
                } catch {
                    parsedArgs = .object([:])
                }
                state.outcome.observedToolCalls[e.toolCallId] = (name: name, args: parsedArgs)
            case .toolCallResult(let r):
                state.outcome.backendResults[r.toolCallId] = r.content
            case .stateSnapshot, .stateDelta, .messagesSnapshot:
                continue
            case .custom(let c):
                // `ag_ui_langgraph` emits `CUSTOM(on_interrupt, value=…)`
                // when the graph pauses via `langgraph.interrupt(...)`.
                // `CopilotKitMiddlewareWithFrontendInterrupt` is the sole producer in
                // pupa; its payload carries `frontend_tool_calls`.
                if c.name == "on_interrupt", let parsed = decodeFrontendDispatch(c.value) {
                    state.outcome.pendingDispatch = PendingFrontendDispatch(calls: parsed)
                }
                continue
            case .stepStarted, .stepFinished, .raw, .unknown:
                continue
            }
        }
    }

    /// Post-stream flush: yield `.toolCallFinished` for tool calls the
    /// backend executed in this round (their results came in via
    /// `TOOL_CALL_RESULT`). Tool calls the backend ASKED us to dispatch
    /// arrive on the interrupt; their `.toolCallFinished` is yielded later
    /// by `dispatchFrontendTools` so we don't double-fire here.
    private func finishRound(
        state: RoundState,
        yield: @Sendable (SessionEvent) -> Void
    ) {
        let outcome = state.outcome
        let dispatchIds: Set<String> = Set(outcome.pendingDispatch?.calls.map(\.id) ?? [])
        for id in outcome.observedOrder where !dispatchIds.contains(id) {
            guard let meta = outcome.observedToolCalls[id] else { continue }
            let result: AnyJSON? = outcome.backendResults[id].map(decodeJSONStringPermissive)
            yield(.toolCallFinished(id: id, name: meta.name, arguments: meta.args, result: result))
        }
    }
}

// MARK: - Helpers

private func encodeJSONString(_ value: AnyJSON) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = []
    do {
        let data = try encoder.encode(value)
        return String(data: data, encoding: .utf8) ?? "{}"
    } catch {
        return "{}"
    }
}

/// Decode a `TOOL_CALL_RESULT.content` string into `AnyJSON`. The wire shape
/// is a free-form string — most backend tools emit JSON, but some return plain
/// prose. Try JSON first; fall back to `.string` so the original payload is
/// preserved either way.
private func decodeJSONStringPermissive(_ s: String) -> AnyJSON {
    guard let data = s.data(using: .utf8) else { return .string(s) }
    if let decoded = try? JSONDecoder().decode(AnyJSON.self, from: data) {
        return decoded
    }
    return .string(s)
}

/// Parse the `value` field of `CUSTOM(on_interrupt, …)`. `ag_ui_langgraph`
/// runs the interrupt payload through `dump_json_safe`, which JSON-encodes
/// non-string values and leaves strings untouched — so on the wire `value`
/// arrives as either a JSON-encoded string `'{"frontend_tool_calls":[…]}'`
/// or (if some future code path passes the dict through Pydantic without
/// dumping) a raw object. Decode both; return `nil` for shapes that don't
/// carry a non-empty `frontend_tool_calls` list.
private func decodeFrontendDispatch(_ value: AnyJSON) -> [AgentSession.FrontendToolCall]? {
    let fields: [String: AnyJSON]
    switch value {
    case .object(let obj):
        fields = obj
    case .string(let s):
        guard
            let data = s.data(using: .utf8),
            case let .object(obj)? = try? JSONDecoder().decode(AnyJSON.self, from: data)
        else { return nil }
        fields = obj
    default:
        return nil
    }
    guard case .array(let arr) = fields["frontend_tool_calls"] else { return nil }
    let parsed = arr.compactMap(decodeOneFrontendCall)
    return parsed.isEmpty ? nil : parsed
}

/// Shallow-merge `overlay` into `base` (which must be an object — non-object
/// bases are treated as empty so the overlay always wins). Used by the run
/// loop to preserve caller-supplied forwardedProps keys (e.g. `llm`) when
/// stamping the per-round `command.resume` block on top.
private func mergeIntoObject(base: AnyJSON, overlay: [String: AnyJSON]) -> AnyJSON {
    var dict: [String: AnyJSON]
    if case .object(let obj) = base {
        dict = obj
    } else {
        dict = [:]
    }
    for (key, value) in overlay {
        dict[key] = value
    }
    return .object(dict)
}

private func decodeOneFrontendCall(_ value: AnyJSON) -> AgentSession.FrontendToolCall? {
    guard case .object(let fields) = value,
          case .string(let id) = fields["id"],
          case .string(let name) = fields["name"] else { return nil }
    let args = fields["args"] ?? .object([:])
    return AgentSession.FrontendToolCall(id: id, name: name, args: args)
}
