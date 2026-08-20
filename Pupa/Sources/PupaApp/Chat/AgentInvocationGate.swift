import Foundation
import Observation

/// Scope-agnostic key identifying one agent invocation slot. Used by
/// `AgentInvocationGate` to label `InvocationNode`s in the active
/// forest. The same key can appear on multiple nodes (e.g. two
/// independent invocation trees both ending at `.myApp(X)`) — the
/// forest stores `(invocationId, parent)` pairs, so identity is per
/// node, not per key.
///
/// Keys are `Hashable` so the gate can equate them when walking the
/// ancestor chain for reentry detection.
public enum AgentInvocationKey: Hashable, Sendable {
    case orchestrator
    case myApp(UUID)
    /// A `pupa/agents/<slug>/AGENTS.md` subagent, scoped to its MyApp.
    /// Slugs are unique only within a MyApp, so the key carries both.
    /// Slack agents are a UI presentation of these subagents.
    case subagent(myAppId: UUID, slug: String)

    /// Opaque, stable id used to key `AgentStatsStore`. Subagents carry
    /// `"subagent:<myAppId>:<slug>"`; the agents overview derives the same
    /// from a descriptor id. MyApp uses the raw UUID string (the per-MyApp
    /// main-agent descriptor id is a shared constant, so the overview keys
    /// main agents off `myAppId`, not id).
    public var statKey: String {
        switch self {
        case .orchestrator: return "orchestrator"
        case .myApp(let id): return id.uuidString
        case .subagent(let myAppId, let slug): return "subagent:\(myAppId.uuidString):\(slug)"
        }
    }
}

/// Who issued a delegation. Separates *policy* (does this call nest under a
/// live run?) from *attribution* (which agent gets credit for making it).
///
/// A user-facing chat panel is ungated — it owns no forest node — but the
/// agent driving it is known, so `.session` attributes its delegations
/// without adding a level to the tree.
public enum AgentCallerContext: Hashable, Sendable {
    /// Human-initiated: the chat composer, a Slack @-mention. Roots a tree
    /// and attributes nothing — a person is not an agent.
    case user
    /// An ungated chat panel acting on its agent's behalf. Roots a tree
    /// exactly like `.user` — no node, no depth, no turn budget — but the
    /// delegation is credited to `key`.
    case session(AgentInvocationKey)
    /// A live gated run. Nests under it; its key is resolved from the forest.
    case agent(UUID)

    /// The forest parent, if any. Only `.agent` has one — which is what keeps
    /// `.session` policy-neutral.
    public var invocationId: UUID? {
        if case .agent(let id) = self { return id }
        return nil
    }
}

/// One node in the active invocation forest. Every in-flight agent
/// run produces exactly one node; nested calls hang off their parent
/// via `parentInvocationId`. Tree roots have `parentInvocationId ==
/// nil` and `treeRootInvocationId == invocationId`.
///
/// `turnsWithParent` is reserved for Phase 1c (per-pair multi-turn
/// budget — issue #193); Phase 1b always sets it to 1.
public struct InvocationNode: Hashable, Sendable {
    public let invocationId: UUID
    public let agentKey: AgentInvocationKey
    public let parentInvocationId: UUID?
    public let treeRootInvocationId: UUID
    public let startedAt: Date
    public var turnsWithParent: Int

    public init(
        invocationId: UUID,
        agentKey: AgentInvocationKey,
        parentInvocationId: UUID?,
        treeRootInvocationId: UUID,
        startedAt: Date = Date(),
        turnsWithParent: Int = 1
    ) {
        self.invocationId = invocationId
        self.agentKey = agentKey
        self.parentInvocationId = parentInvocationId
        self.treeRootInvocationId = treeRootInvocationId
        self.startedAt = startedAt
        self.turnsWithParent = turnsWithParent
    }
}

/// Verdict returned by `AgentInvocationGate.decide(caller:target:)`.
/// The caller switches on this BEFORE acquiring the slot: only
/// `.proceed` gives permission to run; the other cases reject the
/// call without mutating gate state, so the active forest stays
/// intact and the outer turns can unwind cleanly.
///
/// `.busy` remains in the enum for the (future) strict-mode toggle
/// — issue #193 promotes "concurrent same-key" to allow-by-default,
/// so Phase 1b never returns it from `decide(...)`.
public enum AgentInvocationDecision: Equatable, Sendable {
    case proceed(invocationId: UUID, treeRoot: UUID)
    case reentrant(target: AgentInvocationKey, ancestorPath: [AgentInvocationKey])
    case busy(target: AgentInvocationKey)
    case maxDepthExceeded(target: AgentInvocationKey, depth: Int)
    /// Returned when a caller has already consumed `exhaustedAfter` turns
    /// talking to `target`. Reset by exiting and re-entering the caller
    /// (i.e. the parent agent starts a fresh invocation).
    case budgetExhausted(target: AgentInvocationKey, exhaustedAfter: Int)
}

/// Cross-scope agent-invocation policy: tracks an invocation forest,
/// rejects calls that would re-enter an ancestor on the caller's
/// branch, and caps how deep any single branch can grow. Owns no run
/// logic itself — `ChatSessionCoordinator.runOneShot` /
/// `invokeSlackAgent` consult it via `decide(caller:target:)`, then
/// call `enter(...)` / `exit(_:)` around the actual session loop.
///
/// **Forest model.** Each in-flight run is one `InvocationNode`,
/// linked to its parent via `parentInvocationId`. `.user` and
/// `.session` callers are tree roots. Reentry is *"target appears in
/// the caller's ancestor chain"* — siblings and cross-branch calls
/// are explicitly allowed, even when they share an `AgentInvocationKey`,
/// because neither sits above the other on the tree.
///
/// **Concurrent same-key.** Multiple roots — or unrelated branches —
/// may share an `AgentInvocationKey` (e.g. two top-level runs against
/// `.myApp(X)`). They do not collide. The `.busy` case is retained
/// for a future strict-mode setting; Phase 1b never produces it.
///
/// **Chain depth.** Counted along the *caller's ancestor chain*
/// (depth 1 = a root). Hard cap of `maxChainDepth` blocks any further
/// nested call. Default 4 — well past the depth a useful conversation
/// needs but tight enough to fail fast on runaway A2A loops.
///
/// Lifecycle is explicit (`decide` → `enter` → `exit`, not RAII) to
/// mirror the original `SlackInvoker` idiom: call sites use
/// `defer { exit }` so the slot releases on every exit path. Every
/// `enter` MUST be paired with exactly one `exit` for the same
/// `invocationId`.
@MainActor
@Observable
public final class AgentInvocationGate {
    /// Max depth of any single ancestor chain. Reaching it blocks
    /// further nested calls with `.maxDepthExceeded`. 4 is plenty —
    /// most useful chains are 1–2 deep. Loops produce 5+ very
    /// quickly. Mutable so Settings → Agents can retune it live
    /// (the coordinator syncs it from `SettingsStore` before each decision).
    public var maxChainDepth: Int

    /// Max number of turns a parent may direct at the same child before
    /// the gate returns `.budgetExhausted`. Counted per (parentInvocationId,
    /// childKey) pair; resets when the parent exits and re-enters (i.e.
    /// starts a new tree or a new top-level run). Default 5 — enough for a
    /// short back-and-forth without letting runaway loops exhaust tokens.
    /// Mutable for the same reason as `maxChainDepth`.
    public var maxTurnsPerPair: Int

    /// Active forest, keyed by `invocationId`. Trees are reconstructed
    /// on demand by walking `parentInvocationId` (`ancestorChain(from:)`
    /// / `tree(rootedAt:)`).
    public private(set) var activeInvocations: [UUID: InvocationNode] = [:]

    /// Per-parent turn counters: `pairTurnCounts[callerInvocationId][childKey]`
    /// is the number of times that parent has called that child key so far.
    /// Cleaned up when the parent node exits.
    private var pairTurnCounts: [UUID: [AgentInvocationKey: Int]] = [:]

    /// Fired on every `enter` whose caller resolves to an agent key — a
    /// nested run (`.agent`) or an ungated chat panel (`.session`). Not fired
    /// for `.user`: a person makes no delegation. The single chokepoint every
    /// delegation funnels through, so the coordinator wires this once to
    /// record lifetime activity in `AgentStatsStore`. Pure side-channel: the
    /// gate's own policy never consults it.
    @ObservationIgnored
    public var onDelegation: ((_ caller: AgentInvocationKey, _ target: AgentInvocationKey) -> Void)?

    public init(maxChainDepth: Int = 4, maxTurnsPerPair: Int = 5) {
        self.maxChainDepth = maxChainDepth
        self.maxTurnsPerPair = maxTurnsPerPair
    }

    /// Pure decision — no state mutation. Caller is expected to
    /// `enter(...)` with the returned IDs immediately after `.proceed`
    /// and to handle every other case by reporting back to its caller
    /// without touching the gate. Reentrancy takes priority over
    /// depth so the structured rejection always names the most
    /// specific reason.
    public func decide(caller: UUID?, target: AgentInvocationKey) -> AgentInvocationDecision {
        if let caller {
            let ancestors = ancestorChain(from: caller)
            if ancestors.contains(where: { $0.agentKey == target }) {
                return .reentrant(
                    target: target,
                    ancestorPath: ancestors.map { $0.agentKey }
                )
            }
            let proposedDepth = ancestors.count + 1
            if proposedDepth > maxChainDepth {
                return .maxDepthExceeded(target: target, depth: proposedDepth)
            }
            let turns = pairTurnCounts[caller]?[target] ?? 0
            if turns >= maxTurnsPerPair {
                return .budgetExhausted(target: target, exhaustedAfter: maxTurnsPerPair)
            }
            let newId = UUID()
            let root = activeInvocations[caller]?.treeRootInvocationId ?? newId
            return .proceed(invocationId: newId, treeRoot: root)
        } else {
            // Root invocation. Caller is the user composer / outer
            // shell. A root always sits at depth 1; only the
            // pathological `maxChainDepth == 0` blocks it.
            if maxChainDepth < 1 {
                return .maxDepthExceeded(target: target, depth: 1)
            }
            let newId = UUID()
            return .proceed(invocationId: newId, treeRoot: newId)
        }
    }

    /// Record a node in the forest. Caller must use the
    /// `invocationId` + `treeRoot` returned by the matching
    /// `.proceed` decision — passing different values produces a
    /// dangling node that won't be reachable from any tree walk.
    public func enter(
        invocationId: UUID,
        target: AgentInvocationKey,
        caller: AgentCallerContext,
        treeRoot: UUID
    ) {
        // Policy state keys off the forest parent only, so `.session` and
        // `.user` behave identically to a bare root.
        let parent = caller.invocationId
        activeInvocations[invocationId] = InvocationNode(
            invocationId: invocationId,
            agentKey: target,
            parentInvocationId: parent,
            treeRootInvocationId: treeRoot
        )
        if let parent {
            pairTurnCounts[parent, default: [:]][target, default: 0] += 1
        }
        if let callerKey = callerKey(caller) {
            onDelegation?(callerKey, target)
        }
    }

    /// The delegating agent's key, or nil when there is none to credit.
    private func callerKey(_ caller: AgentCallerContext) -> AgentInvocationKey? {
        switch caller {
        case .user:
            return nil
        case .session(let key):
            return key
        case .agent(let id):
            // The parent was entered before this node, so its key is
            // resolvable from the live forest — unless it already exited.
            return activeInvocations[id]?.agentKey
        }
    }

    /// Remove the node. Idempotent — exiting an already-exited or
    /// never-entered id is a no-op so cancellation paths that race
    /// the normal exit don't trap. Also clears any per-pair turn
    /// counters owned by this node so its children's counts don't
    /// accumulate across independent parent runs.
    public func exit(_ invocationId: UUID) {
        activeInvocations.removeValue(forKey: invocationId)
        pairTurnCounts.removeValue(forKey: invocationId)
    }

    /// Walk from `start` up through `parentInvocationId` and return
    /// the chain *including* `start`, ordered root → leaf. Empty
    /// when `start` isn't in the forest. Used by `decide` to detect
    /// reentry and to count depth.
    public func ancestorChain(from start: UUID) -> [InvocationNode] {
        var chain: [InvocationNode] = []
        var cursor: UUID? = start
        // Defensive bound: cycles shouldn't exist (every node's
        // parent must have been entered first), but cap the walk at
        // `activeInvocations.count + 1` to be safe.
        let bound = activeInvocations.count + 1
        var steps = 0
        while let id = cursor, let node = activeInvocations[id], steps < bound {
            chain.append(node)
            cursor = node.parentInvocationId
            steps += 1
        }
        return chain.reversed()
    }

    /// All nodes in the tree rooted at `rootId`, in unspecified order.
    /// Returns an empty array when no such tree exists. Debug / future-UI
    /// accessor — the gate itself never consults it.
    public func tree(rootedAt rootId: UUID) -> [InvocationNode] {
        activeInvocations.values.filter { $0.treeRootInvocationId == rootId }
    }

    /// True iff any active node carries `key`. Slack-side UI uses
    /// `SlackInvoker.isBusy(_:)` directly; this is for tests / debug.
    public func isBusy(_ key: AgentInvocationKey) -> Bool {
        activeInvocations.values.contains { $0.agentKey == key }
    }

    /// Snapshot of the full active forest, in insertion order. Used
    /// for the `callPath` field of rejection echoes and for tracing.
    public func snapshotForest() -> [InvocationNode] {
        Array(activeInvocations.values)
    }
}

/// Error thrown by callers that consult the gate before doing real
/// work (e.g. `runOneShot`) when the gate rejects the invocation.
/// Carries enough information for the tool-message echo path
/// (`AppTools.invokeMyAppAgent`) to emit a structured
/// `agent_unavailable` payload back to the calling agent.
public struct AgentInvocationRejection: Error, Equatable, Sendable {
    public enum Reason: String, Sendable, Equatable {
        case reentrant
        case busy
        case maxDepthExceeded
        case budgetExhausted
    }

    public let reason: Reason
    public let target: AgentInvocationKey
    public let callPath: [AgentInvocationKey]
    public let depth: Int?
    /// Root-of-tree key for the caller that triggered this rejection.
    /// Nil only for the pathological case of a root rejection (which
    /// Phase 1b never produces). Surfaced in the `agent_unavailable`
    /// echo as `treeRootedAt`.
    public let treeRootKey: AgentInvocationKey?
    /// For `.budgetExhausted`: the turn limit that was reached.
    public let exhaustedAfter: Int?

    public init(
        reason: Reason,
        target: AgentInvocationKey,
        callPath: [AgentInvocationKey],
        depth: Int? = nil,
        treeRootKey: AgentInvocationKey? = nil,
        exhaustedAfter: Int? = nil
    ) {
        self.reason = reason
        self.target = target
        self.callPath = callPath
        self.depth = depth
        self.treeRootKey = treeRootKey
        self.exhaustedAfter = exhaustedAfter
    }

    /// Convenience: build from an `AgentInvocationDecision` other
    /// than `.proceed`. Pre-condition: decision is one of the
    /// rejection cases — `.proceed` traps because constructing a
    /// rejection from it is a caller-side programmer error.
    public init(
        decision: AgentInvocationDecision,
        callPath: [AgentInvocationKey],
        treeRootKey: AgentInvocationKey? = nil
    ) {
        switch decision {
        case .proceed:
            preconditionFailure("AgentInvocationRejection requires a non-proceed decision")
        case .reentrant(let target, _):
            self.init(reason: .reentrant, target: target, callPath: callPath, treeRootKey: treeRootKey)
        case .busy(let target):
            self.init(reason: .busy, target: target, callPath: callPath, treeRootKey: treeRootKey)
        case .maxDepthExceeded(let target, let depth):
            self.init(
                reason: .maxDepthExceeded,
                target: target,
                callPath: callPath,
                depth: depth,
                treeRootKey: treeRootKey
            )
        case .budgetExhausted(let target, let n):
            self.init(
                reason: .budgetExhausted,
                target: target,
                callPath: callPath,
                treeRootKey: treeRootKey,
                exhaustedAfter: n
            )
        }
    }
}

extension AgentInvocationKey {
    /// Stable string form for cross-language transport (tool-message
    /// echoes). `myApp` keys use the UUID string; `slack` uses the
    /// agentId verbatim.
    public var wireValue: String {
        switch self {
        case .orchestrator: return "orchestrator"
        case .myApp(let id): return "myApp:\(id.uuidString)"
        case .subagent(let myAppId, let slug): return "subagent:\(myAppId.uuidString):\(slug)"
        }
    }
}
