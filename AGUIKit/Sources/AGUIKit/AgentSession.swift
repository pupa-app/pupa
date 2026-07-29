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
    /// Carries why it settled so the UI can flag a turn that ended without a
    /// reply instead of silently dropping the spinner.
    case completed(CompletionOutcome)
    /// The agent emitted an error event.
    case error(message: String, code: String?)
    /// The replay cursor advanced: the frame stamped with this seq has been
    /// fully delivered (its session event, if any, was yielded first). Hosts
    /// that persist the cursor per thread (pupa#103) track this instead of
    /// `AgentSession.lastEventSeq` so a persisted value never runs ahead of
    /// the UI state saved alongside it.
    case cursorAdvanced(Int)
}

/// How a `send` / `reattach` settled, so the host can decide whether to show
/// the user a "the turn ended with no reply" notice.
public enum CompletionOutcome: Sendable, Equatable {
    /// The turn produced assistant text (or there was nothing to surface,
    /// e.g. a no-op reattach). Render no notice.
    case produced
    /// The turn ended with no assistant text and no error — the "looks like
    /// it died" case. `reason` says why, for a user-facing notice.
    case silent(SilentReason)
}

/// Why a turn ended without an assistant reply.
public enum SilentReason: Sendable, Equatable {
    /// `RUN_FINISHED` with no assistant text (tool-only or empty turn).
    case emptyTurn
    /// The client's runaway round cap was hit mid-turn.
    case maxRounds
    /// The stream ended without a `RUN_FINISHED` and without an error
    /// (a clean socket EOF mid-turn).
    case droppedStream
    /// A frontend tool call arrived with no `on_interrupt` to drive it, and a
    /// bounded recovery re-POST didn't surface one either — so the client
    /// couldn't run the tool. Fingerprint of the upstream `ag-ui-langgraph`
    /// emit-path bug: an interrupt parked on a non-first task is dropped at
    /// emit time (`state.tasks[0]` only), leaving the run looking finished.
    case droppedInterrupt
    /// A backend-attributed reason, or a client-side dispatch failure —
    /// carries a short human-readable message.
    case backend(String)
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
    /// Hard cap on rounds per send to bound runaway loops, or `nil` to run
    /// with no cap. With interrupt-driven dispatch every iteration is either a
    /// fresh model turn or a resume; LangGraph's `recursion_limit` counts graph
    /// steps, which this cap doesn't, so we keep an iOS-side breaker for runaway
    /// tool loops. Kept generous because EVERY frontend-tool round-trip consumes
    /// a round — a low cap silently truncates legitimate multi-step turns. When
    /// the cap is hit mid-interrupt the loop still POSTs the staged resume so
    /// the backend session is never left parked (see `runLoop`). `nil` removes
    /// the breaker entirely — the turn runs until the backend settles.
    public let maxRounds: Int?

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
    /// already applied may repeat; acceptable degraded mode). Readable so the
    /// host can persist it per thread and seed a relaunched session via
    /// `seedReplayCursor` — the launch-time catch-up half of pupa#103.
    public private(set) var lastEventSeq: Int?

    /// Adopt a persisted replay cursor (relaunch catch-up after an app kill).
    /// Keeps the newer of the two when this session already streamed past
    /// `seq`, so a stale persisted value can never rewind a live cursor.
    public func seedReplayCursor(_ seq: Int) {
        guard lastEventSeq.map({ seq > $0 }) ?? true else { return }
        lastEventSeq = seq
        AGUIKitLog.session("seeded replay cursor thread=\(threadId) after_seq=\(seq)")
    }

    /// Transport drops mid-round are retried this many times (exponential
    /// backoff, base 0.5s) before the error is surfaced to the caller.
    private let maxReattachAttempts = 4
    private let reattachBaseDelayNanos: UInt64 = 500_000_000

    /// Liveness heartbeat (pupa-backend#82): while a frontend-tool dispatch is
    /// in flight the backend's handler is parked with no open socket, so the
    /// session POSTs `command.keepalive` every `keepaliveInterval` seconds.
    /// The backend fails a silent (dead) app one grace period after the last
    /// ping instead of burning the full per-tool wall.
    private let keepaliveIntervalNanos: UInt64
    /// Host-reported scene phase. While backgrounded (iOS freezes timers) the
    /// pinger pauses and the backend is told once via `state: "background"` —
    /// it then falls back to its absolute per-tool wall.
    private var hostBackgrounded = false
    /// Number of `dispatchFrontendTools` bodies currently running — gates the
    /// immediate state ping in `setHostBackgrounded`.
    private var activeDispatches = 0

    public init(
        client: AgentClient,
        registry: ToolRegistry,
        threadId: String,
        initialMessages: [AgentMessage] = [],
        maxRounds: Int? = 24,
        keepaliveInterval: TimeInterval = 10
    ) {
        self.client = client
        self.registry = registry
        self.threadId = threadId
        self.messages = initialMessages
        self.maxRounds = maxRounds
        self.keepaliveIntervalNanos = UInt64(max(0.01, keepaliveInterval) * 1_000_000_000)
        let toolNames = registry.descriptors.map(\.name).sorted().joined(separator: ",")
        AGUIKitLog.session(
            "AgentSession init thread=\(threadId) maxRounds=\(Self.capDescription(maxRounds)) " +
            "tools=\(registry.descriptors.count) [\(toolNames)]"
        )
    }

    /// Human-readable cap for logs: the number, or "unlimited" for `nil`.
    private static func capDescription(_ cap: Int?) -> String {
        cap.map(String.init) ?? "unlimited"
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
    /// - Parameter images: Inline images attached to the user message. When
    ///   non-empty, the user message is encoded as a multimodal AG-UI payload
    ///   (text part + one image part each) instead of a plain string.
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
        images: [(data: Data, mimeType: String)] = [],
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
                        images: images,
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
        // (Launch-time catch-up after an app kill seeds the persisted cursor
        // via `seedReplayCursor` before calling this — pupa#103.)
        guard lastEventSeq != nil else {
            AGUIKitLog.session("reattach() skipped — no replay cursor for thread=\(threadId)")
            // Nothing to catch up on — not a silent stop, so no notice.
            yield(.completed(.produced))
            return
        }
        AGUIKitLog.session(
            "reattach() thread=\(threadId) after_seq=\(lastEventSeq.map(String.init) ?? "-1")"
        )
        var input = reattachInput()
        var producedText = false
        var round = 0
        while maxRounds == nil || round < maxRounds! {
            round += 1
            let outcome = try await runOneRound(input: input, yield: yield)
            producedText = producedText || outcome.producedText

            guard let dispatch = outcome.pendingDispatch else {
                // A first round with no frames at all is the replay layer's
                // "nothing buffered" answer (204, or an expired/evicted
                // buffer) — a clean no-op catch-up, not a dropped stream.
                if round == 1, !outcome.sawAnyFrame {
                    AGUIKitLog.session("reattach: nothing buffered for thread=\(threadId) → completed")
                    yield(.completed(.produced))
                    return
                }
                if outcome.hadOutput { lastSendSettledCleanly = true }
                let result = settleOutcome(producedText: producedText, outcome: outcome)
                AGUIKitLog.session("reattach round \(round) settled → completed (\(result))")
                yield(.completed(result))
                return
            }
            // The replayed tail ended on a frontend-tool interrupt the app
            // never serviced (it was backgrounded/dead when it fired).
            // Dispatch now and resume the parked run — same contract as
            // `runLoop`, including the mid-turn tool-surface refresh.
            AGUIKitLog.session(
                "reattach round \(round) found interrupt → dispatching \(dispatch.calls.count) tool(s)"
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
        AGUIKitLog.session("reattach hit maxRounds=\(Self.capDescription(maxRounds)) → completed")
        yield(.completed(producedText ? .produced : .silent(.maxRounds)))
    }

    private func runLoop(
        userText: String,
        images: [(data: Data, mimeType: String)],
        context: @Sendable () async -> [AgentContextEntry],
        toolFilter: (@Sendable () async -> Set<String>)?,
        state: (@Sendable () async -> AnyJSON)?,
        baseForwardedProps: AnyJSON,
        yield: @Sendable (SessionEvent) -> Void
    ) async throws {
        let userMessage = AgentMessage.user(text: userText, images: images)
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
        let imageNote = images.isEmpty ? "" :
            " images=\(images.count)/\(images.reduce(0) { $0 + $1.data.count })B"
        AGUIKitLog.session("send() user=\(snippet(userText))\(imageNote) thread=\(threadId) maxRounds=\(Self.capDescription(maxRounds))")

        // True if ANY round this turn emitted assistant text. Accumulated
        // across rounds so a turn that narrated in round 1 then settled
        // text-less in round 2 still counts as "produced" (no notice).
        var producedText = false

        // One round's POST body, built from `forwardedProps`. Value-in/value-out
        // (no captured mutable var) so it stays Sendable across the actor hops.
        // The tool/context/state closures are called once per round so the host
        // can grow/shrink the surface mid-turn.
        func makeInput(_ forwardedProps: AnyJSON) async -> RunAgentInput {
            let ctx = await context()
            let descriptors: [ToolDescriptor]
            if let filter = await toolFilter?() {
                descriptors = registry.descriptors.filter { filter.contains($0.name) }
            } else {
                descriptors = registry.descriptors
            }
            let stateJSON: AnyJSON = await state?() ?? .null
            return RunAgentInput(
                threadId: threadId,
                state: stateJSON,
                messages: messages,
                tools: descriptors,
                context: ctx,
                forwardedProps: forwardedProps
            )
        }

        // Dispatch the interrupt's frontend tools and return the resume payload
        // for the next POST. Mid-turn tool-surface refresh: after the handlers
        // run (e.g. `addComponent` updates the local store), recompute the
        // advertised descriptors and embed them so the backend refreshes
        // `state["copilotkit"]["actions"]` before the model is re-invoked
        // (`ag_ui_langgraph` discards `RunAgentInput.tools` on the resume
        // branch). The resume merges on top of the caller's base forwardedProps
        // so per-turn config (e.g. `llm`) survives every round.
        func resumeProps(for dispatch: PendingFrontendDispatch) async -> AnyJSON {
            let toolResults = await dispatchFrontendTools(calls: dispatch.calls, yield: yield)
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
            return mergeIntoObject(
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
        }

        var nextForwardedProps: AnyJSON = baseForwardedProps
        var round = 0
        // Bounded recovery for the `ag-ui-langgraph` dropped-interrupt bug —
        // see the settle branch below.
        var recoveryAttempts = 0
        let maxRecoveryAttempts = 2
        while true {
            let input = await makeInput(nextForwardedProps)
            AGUIKitLog.session(
                "round \(round + 1) → POST | msgs=\(messages.count) " +
                "(\(messageRoleSummary())) tools=\(input.tools.count) " +
                "resume=\(nextForwardedProps != baseForwardedProps)"
            )
            let outcome = try await runOneRound(input: input, yield: yield)
            producedText = producedText || outcome.producedText
            round += 1

            // No interrupt → the run has settled. `lastSendSettledCleanly`
            // tracks whether the round produced anything (empty round →
            // next send replaces the orphaned user message).
            guard let dispatch = outcome.pendingDispatch else {
                // Self-heal the `ag-ui-langgraph` dropped-interrupt bug: a
                // frontend tool was called this round but no `on_interrupt`
                // arrived to drive it (the emit path reads `state.tasks[0]`
                // only, so an interrupt parked on a non-first task is dropped
                // in-run). The run looks finished but the backend is parked. A
                // resume-less re-POST hits the backend's recovery path, which
                // collects interrupts from ALL tasks and re-emits the dropped
                // one — the next round then decodes it and dispatches normally.
                // Bounded so a genuine no-interrupt settle can't loop.
                let dropped = droppedFrontendCalls(in: outcome)
                if !dropped.isEmpty, !outcome.interruptDecodeFailed,
                   recoveryAttempts < maxRecoveryAttempts {
                    recoveryAttempts += 1
                    AGUIKitLog.session(
                        "round \(round) settled with frontend tool(s) but no interrupt " +
                        "[\(dropped.map { $0.name }.joined(separator: ", "))] → recovery re-POST " +
                        "\(recoveryAttempts)/\(maxRecoveryAttempts) (ag-ui-langgraph tasks[0] emit bug)"
                    )
                    nextForwardedProps = baseForwardedProps  // resume-less continuation
                    continue
                }
                lastSendSettledCleanly = outcome.hadOutput
                // A frontend tool called with no interrupt at all (recovery
                // exhausted) surfaces `.droppedInterrupt` even if the model also
                // narrated. An *undecodable* interrupt keeps `settleOutcome`'s
                // `.backend(...)` reason — re-POSTing wouldn't have helped it.
                let result: CompletionOutcome = (!dropped.isEmpty && !outcome.interruptDecodeFailed)
                    ? .silent(.droppedInterrupt)
                    : settleOutcome(producedText: producedText, outcome: outcome)
                AGUIKitLog.session("round \(round) settled → completed (\(result))")
                yield(.completed(result))
                return
            }

            // Interrupt: the graph is paused awaiting these tool results. A
            // computed dispatch MUST be followed by its resume POST — dropping
            // it strands the backend session (parked forever), the exact
            // "agent stopped silently" failure. So we always stage the resume.
            AGUIKitLog.session(
                "round \(round) paused on interrupt → dispatching \(dispatch.calls.count) " +
                "frontend tool(s) [" + dispatch.calls.map { $0.name }.joined(separator: ", ") + "]"
            )
            nextForwardedProps = await resumeProps(for: dispatch)

            // Runaway guard. The pending dispatch's resume is now staged; when
            // the cap is hit, POST it once to unpark the backend, consume the
            // settling round, then stop with a notice rather than looping
            // forever. A `nil` cap removes the breaker — keep going until the
            // backend settles on its own.
            if let cap = maxRounds, round >= cap {
                AGUIKitLog.session("hit maxRounds=\(cap) mid-interrupt → final resume then stop")
                let finalOutcome = try await runOneRound(input: await makeInput(nextForwardedProps), yield: yield)
                producedText = producedText || finalOutcome.producedText
                // Not a clean settle — next send replaces the orphaned user message.
                lastSendSettledCleanly = false
                yield(.completed(producedText ? .produced : .silent(.maxRounds)))
                return
            }
        }
    }

    /// Classify a settled round for the UI: `.produced` when any assistant
    /// text was emitted this turn, otherwise a `.silent` reason so the host
    /// can show a "turn ended with no reply" notice.
    private func settleOutcome(producedText: Bool, outcome: RoundOutcome) -> CompletionOutcome {
        if producedText { return .produced }
        if outcome.interruptDecodeFailed { return .silent(.backend("couldn't read the agent's tool request")) }
        if !outcome.sawRunFinished { return .silent(.droppedStream) }
        return .silent(.emptyTurn)
    }

    /// Frontend tool calls the model emitted this round that the client has
    /// registered locally, but which arrived WITHOUT an `on_interrupt` to drive
    /// them (no pending dispatch) and WITHOUT a backend-produced result. This is
    /// the fingerprint of the `ag-ui-langgraph` dropped-interrupt bug: the graph
    /// parked an interrupt on a non-first task and the emit path (`state.tasks[0]`
    /// only) never sent the `on_interrupt`. Backend-executed tools (e.g.
    /// `tavily_search`) don't resolve in the registry, so they're excluded.
    private func droppedFrontendCalls(in outcome: RoundOutcome) -> [(id: String, name: String)] {
        outcome.observedOrder.compactMap { id in
            guard let meta = outcome.observedToolCalls[id] else { return nil }
            guard registry.resolve(meta.name) != nil else { return nil }
            guard outcome.backendResults[id] == nil else { return nil }
            return (id: id, name: meta.name)
        }
    }

    /// Tell the session the host app's scene phase changed. While a dispatch
    /// is in flight, a transition posts one immediate keepalive carrying the
    /// new state — backgrounding tells the backend to fall back to its
    /// absolute wall (pupa-backend#82); foregrounding re-arms the short
    /// liveness grace. The periodic pinger pauses while backgrounded.
    public func setHostBackgrounded(_ flag: Bool) async {
        guard flag != hostBackgrounded else { return }
        hostBackgrounded = flag
        guard activeDispatches > 0 else { return }
        await postKeepalive(state: flag ? "background" : "active")
    }

    /// Minimal `POST /` body for the liveness ping — the endpoint answers 204
    /// without starting a run.
    private func keepaliveInput(state: String) -> RunAgentInput {
        RunAgentInput(
            threadId: threadId,
            messages: [],
            tools: [],
            context: [],
            forwardedProps: .object([
                "command": .object([
                    "keepalive": .object(["state": .string(state)])
                ])
            ])
        )
    }

    /// Fire one liveness ping. Best-effort: a failed ping is logged and
    /// dropped — the next interval retries, and the backend's grace absorbs
    /// isolated losses.
    private func postKeepalive(state: String) async {
        do {
            for try await _ in client.runSequenced(keepaliveInput(state: state)) {}
        } catch {
            AGUIKitLog.session("keepalive ping failed (ignored): \(error)")
        }
    }

    /// Run every frontend tool the backend asked us to dispatch, pinging
    /// `command.keepalive` every `keepaliveInterval` while the dispatch is in
    /// flight so the backend's parked handler can tell a slow tool from a
    /// dead app (pupa-backend#82).
    private func dispatchFrontendTools(
        calls: [FrontendToolCall],
        yield: @Sendable (SessionEvent) -> Void
    ) async -> [AnyJSON] {
        activeDispatches += 1
        let intervalNanos = keepaliveIntervalNanos
        // Interval-first: a dispatch faster than one interval (sub-second CRUD)
        // never pings at all — only genuinely long parks arm the backend's
        // liveness deadline.
        let pinger = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: intervalNanos)
                if Task.isCancelled { break }
                if let self, await !self.hostBackgrounded {
                    await self.postKeepalive(state: "active")
                }
            }
        }
        defer {
            pinger.cancel()
            activeDispatches -= 1
        }
        return await runFrontendDispatch(calls: calls, yield: yield)
    }

    /// Dispatch body. Tools marked `parallelSafe` start concurrently; the rest
    /// run inline in submission order. Results are returned in submission
    /// order so the resume payload mirrors the call order the model emitted,
    /// and the caller's `.toolCallFinished` events fire deterministically.
    private func runFrontendDispatch(
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
        /// True if the round emitted any assistant text. Distinct from
        /// `hadOutput` (which is also true for tool-only rounds) — drives the
        /// "turn ended with no reply" notice.
        var producedText: Bool = false
        /// True once a `RUN_FINISHED` arrived this round. A round that ends
        /// without it (clean socket EOF mid-turn) is a dropped stream, not a
        /// clean settle.
        var sawRunFinished: Bool = false
        /// True if an `on_interrupt` custom event arrived but its payload
        /// couldn't be decoded into frontend tool calls — the turn would
        /// otherwise settle silently with no dispatch.
        var interruptDecodeFailed: Bool = false
        /// True once ANY frame arrived this round. A reattach round that ends
        /// with this false is the replay layer's "nothing buffered" answer
        /// (204 / expired buffer) — benign, not a dropped stream.
        var sawAnyFrame: Bool = false
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
    /// network blip) but the backend run may well still be going. Edge 5xx
    /// (and 408/429) count too — a flaky tunnel/proxy answering for a healthy
    /// origin is indistinguishable from a drop, and the replay log makes the
    /// retry safe. Other HTTP errors, malformed events, and user cancellation
    /// are NOT re-attachable.
    private static func isReattachable(_ error: Error) -> Bool {
        switch error {
        case AgentClientError.requestFailed:
            return true
        case AgentClientError.httpStatus(let code, _):
            return code >= 500 || code == 408 || code == 429
        default:
            return false
        }
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
            state.outcome.sawAnyFrame = true
            switch sequenced.event {
            case .runStarted:
                break
            case .runFinished(let r):
                state.outcome.sawRunFinished = true
                yield(.roundFinished(threadId: r.threadId, runId: r.runId))
            case .runError(let e):
                yield(.error(message: e.message, code: e.code))
            case .textMessageStart(let s):
                state.textBuffers[s.messageId] = ""
                state.outcome.hadOutput = true
                state.outcome.producedText = true
                yield(.assistantMessageStart(messageId: s.messageId))
            case .textMessageContent(let c):
                state.textBuffers[c.messageId, default: ""].append(c.delta)
                state.outcome.producedText = true
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
                if let name = state.pendingNames[e.toolCallId] {
                    let argsString = state.pendingArgs[e.toolCallId] ?? ""
                    let parsedArgs: AnyJSON
                    do {
                        parsedArgs = try ToolCallFunction(name: name, arguments: argsString).parsedArguments()
                    } catch {
                        parsedArgs = .object([:])
                    }
                    state.outcome.observedToolCalls[e.toolCallId] = (name: name, args: parsedArgs)
                }
            case .toolCallResult(let r):
                state.outcome.backendResults[r.toolCallId] = r.content
            case .stateSnapshot, .stateDelta, .messagesSnapshot:
                break
            case .custom(let c):
                // `ag_ui_langgraph` emits `CUSTOM(on_interrupt, value=…)`
                // when the graph pauses via `langgraph.interrupt(...)`.
                // `CopilotKitMiddlewareWithFrontendInterrupt` is the sole producer in
                // pupa; its payload carries `frontend_tool_calls`.
                if c.name == "on_interrupt" {
                    if let parsed = decodeFrontendDispatch(c.value) {
                        state.outcome.pendingDispatch = PendingFrontendDispatch(calls: parsed)
                    } else {
                        // An interrupt we can't read is worse than an error we
                        // can — without a dispatch the run settles silently.
                        // Flag it so the loop surfaces a notice instead.
                        state.outcome.interruptDecodeFailed = true
                        AGUIKitLog.session("⚠️ on_interrupt payload undecodable — will surface as silent stop")
                    }
                }
            case .stepStarted, .stepFinished, .raw, .unknown:
                break
            }
            // After the frame's own event (if any): the cursor now covers it.
            if let seq = sequenced.seq {
                lastEventSeq = seq
                yield(.cursorAdvanced(seq))
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
