import Foundation
import Testing
@testable import PupaApp

/// Shared MiniApp id for `.subagent` keys in these tests. With a single app,
/// distinct slugs are distinct keys (the reentry semantics the old
/// `.slack(agentId:)` key provided).
private let kGateApp = UUID()

/// Tests for `AgentInvocationGate` (forest model, Phase 1b — issue #193).
///
/// Focus areas:
/// - Root invocations always proceed
/// - Ancestor-only reentry (A→B→A blocked; siblings allowed)
/// - Concurrent same-key across independent trees (default allow)
/// - Chain depth counted along ancestor chain
/// - Tree-root tag propagates through the forest
/// - `enter`/`exit` lifecycle and state consistency
/// - `SlackInvoker` integration (shared gate)
@MainActor
@Suite("Agent invocation gate")
struct AgentInvocationGateTests {

    // MARK: - Helpers

    /// Shorthand: decide + enter in one step. Returns the invocationId.
    @discardableResult
    func enter(
        gate: AgentInvocationGate,
        caller: UUID? = nil,
        target: AgentInvocationKey
    ) -> UUID {
        guard case let .proceed(id, root) = gate.decide(caller: caller, target: target) else {
            Issue.record("Expected .proceed but got a rejection for \(target)")
            return UUID()
        }
        gate.enter(
            invocationId: id, target: target,
            caller: caller.map(AgentCallerContext.agent) ?? .user, treeRoot: root
        )
        return id
    }

    // MARK: - Root invocations

    @Test("Root invocation (caller=nil) always proceeds")
    func rootProceeds() {
        let gate = AgentInvocationGate()
        let d = gate.decide(caller: nil, target: .miniApp(UUID()))
        guard case let .proceed(id, root) = d else { Issue.record("Expected proceed"); return }
        #expect(id == root, "Root: invocationId must equal treeRoot")
    }

    @Test("Multiple independent roots on the same key all proceed")
    func concurrentSameKeyRoots() {
        let gate = AgentInvocationGate()
        let app = UUID()
        let id1 = enter(gate: gate, caller: nil, target: .miniApp(app))
        // Second top-level invocation of the same key — different tree, must proceed.
        let d2 = gate.decide(caller: nil, target: .miniApp(app))
        guard case let .proceed(id2, root2) = d2 else {
            Issue.record("Expected .proceed for second root invocation of same key"); return
        }
        gate.enter(invocationId: id2, target: .miniApp(app), caller: .user, treeRoot: root2)
        #expect(id1 != id2)
        // Both nodes in the forest.
        #expect(gate.activeInvocations[id1] != nil)
        #expect(gate.activeInvocations[id2] != nil)
    }

    /// `.session` exists purely for stats attribution. It must cost nothing
    /// in gate policy — otherwise crediting a chat panel's delegation would
    /// silently shorten every A2A chain by one.
    @Test("A .session caller adds no depth")
    func sessionCallerAddsNoDepth() {
        let gate = AgentInvocationGate(maxChainDepth: 1)
        let a = UUID(), b = UUID()
        guard case let .proceed(idA, rootA) = gate.decide(caller: nil, target: .miniApp(a)) else {
            Issue.record("Expected .proceed"); return
        }
        gate.enter(invocationId: idA, target: .miniApp(a), caller: .session(.orchestrator), treeRoot: rootA)
        // A sits at depth 1, exactly as if the panel weren't there: the next
        // hop is depth 2 and blocked by maxChainDepth 1.
        #expect(gate.decide(caller: idA, target: .miniApp(b)) ==
                .maxDepthExceeded(target: .miniApp(b), depth: 2))
    }

    @Test("A .session caller owns no per-pair turn budget")
    func sessionCallerHasNoTurnBudget() {
        let gate = AgentInvocationGate(maxTurnsPerPair: 1)
        let b = UUID()
        // Same panel delegates to the same target twice. Each is its own root,
        // so neither consumes the other's budget.
        for turn in 1...2 {
            guard case let .proceed(id, root) = gate.decide(caller: nil, target: .miniApp(b)) else {
                Issue.record("Turn \(turn) from a chat panel must proceed"); return
            }
            gate.enter(invocationId: id, target: .miniApp(b), caller: .session(.orchestrator), treeRoot: root)
            gate.exit(id)
        }
    }

    // MARK: - Ancestor-only reentry

    @Test("Direct reentry A→A is blocked")
    func directReentry() {
        let gate = AgentInvocationGate()
        let app = UUID()
        let id = enter(gate: gate, caller: nil, target: .miniApp(app))
        let d = gate.decide(caller: id, target: .miniApp(app))
        guard case let .reentrant(target, _) = d else {
            Issue.record("Expected .reentrant"); return
        }
        #expect(target == .miniApp(app))
    }

    @Test("A→B→A is blocked at the A step")
    func reentryABA() {
        let gate = AgentInvocationGate()
        let a = UUID(), b = UUID()
        let idA = enter(gate: gate, caller: nil, target: .miniApp(a))
        let idB = enter(gate: gate, caller: idA, target: .miniApp(b))
        // B tries to invoke A (its own ancestor).
        let d = gate.decide(caller: idB, target: .miniApp(a))
        guard case let .reentrant(target, ancestors) = d else {
            Issue.record("Expected .reentrant for A→B→A"); return
        }
        #expect(target == .miniApp(a))
        #expect(ancestors.contains(.miniApp(a)))
    }

    @Test("A→B→C→A is blocked at the A step")
    func reentryABCA() {
        let gate = AgentInvocationGate()
        let a = UUID(), b = UUID(), c = UUID()
        let idA = enter(gate: gate, caller: nil, target: .miniApp(a))
        let idB = enter(gate: gate, caller: idA, target: .miniApp(b))
        let idC = enter(gate: gate, caller: idB, target: .miniApp(c))
        let d = gate.decide(caller: idC, target: .miniApp(a))
        guard case .reentrant = d else {
            Issue.record("Expected .reentrant for A→B→C→A"); return
        }
    }

    @Test("A→B→C→D where D is unrelated proceeds")
    func deepChainUnrelated() {
        let gate = AgentInvocationGate(maxChainDepth: 5)
        let a = UUID(), b = UUID(), c = UUID(), d = UUID()
        let idA = enter(gate: gate, caller: nil, target: .miniApp(a))
        let idB = enter(gate: gate, caller: idA, target: .miniApp(b))
        let idC = enter(gate: gate, caller: idB, target: .miniApp(c))
        let decision = gate.decide(caller: idC, target: .miniApp(d))
        guard case .proceed = decision else {
            Issue.record("Expected .proceed for unrelated D"); return
        }
    }

    // MARK: - Sibling / cross-branch (allowed)

    @Test("Sibling branches under the same root both proceed")
    func siblingBranches() {
        let gate = AgentInvocationGate()
        let a = UUID(), b = UUID(), c = UUID()
        // Root A spawns B and C as siblings.
        let idA = enter(gate: gate, caller: nil, target: .miniApp(a))
        let idB = enter(gate: gate, caller: idA, target: .miniApp(b))
        // C is a sibling of B — neither is an ancestor of the other.
        let d = gate.decide(caller: idA, target: .miniApp(c))
        guard case let .proceed(idC, _) = d else {
            Issue.record("Expected .proceed for sibling C"); return
        }
        gate.enter(invocationId: idC, target: .miniApp(c), caller: .agent(idA), treeRoot: idA)
        // B trying to invoke C (cross-branch).
        let dBC = gate.decide(caller: idB, target: .miniApp(c))
        guard case .proceed = dBC else {
            Issue.record("Expected .proceed for B→C cross-branch"); return
        }
        // C trying to invoke B (cross-branch, even though B is in the forest).
        let dCB = gate.decide(caller: idC, target: .miniApp(b))
        guard case .proceed = dCB else {
            Issue.record("Expected .proceed for C→B cross-branch"); return
        }
    }

    // MARK: - Chain depth

    @Test("Chain depth cap blocks a call that exceeds maxChainDepth")
    func maxChainDepth() {
        let gate = AgentInvocationGate(maxChainDepth: 3)
        let a = UUID(), b = UUID(), c = UUID(), d = UUID()
        let idA = enter(gate: gate, caller: nil, target: .miniApp(a))
        let idB = enter(gate: gate, caller: idA, target: .miniApp(b))
        let idC = enter(gate: gate, caller: idB, target: .miniApp(c))
        // Ancestor chain from idC is [A, B, C] (length 3). A fourth
        // nested call would be depth 4, exceeding maxChainDepth=3.
        let blocked = gate.decide(caller: idC, target: .miniApp(d))
        guard case let .maxDepthExceeded(target, depth) = blocked else {
            Issue.record("Expected .maxDepthExceeded"); return
        }
        #expect(target == .miniApp(d))
        #expect(depth == 4)
    }

    @Test("Exiting one node re-opens the depth slot")
    func depthSlotsRecycle() {
        let gate = AgentInvocationGate(maxChainDepth: 2)
        let a = UUID(), b = UUID(), c = UUID()
        let idA = enter(gate: gate, caller: nil, target: .miniApp(a))
        let idB = enter(gate: gate, caller: idA, target: .miniApp(b))
        // Chain A→B is at max depth (2). C is blocked.
        #expect(gate.decide(caller: idB, target: .miniApp(c)) ==
                .maxDepthExceeded(target: .miniApp(c), depth: 3))
        // B exits; chain shrinks to [A].
        gate.exit(idB)
        // Now depth would be 2 → allowed.
        guard case .proceed = gate.decide(caller: idA, target: .miniApp(c)) else {
            Issue.record("Expected .proceed after B exits"); return
        }
    }

    // MARK: - Tree-root tag

    @Test("Proceeding root: invocationId equals treeRoot")
    func rootTagEqualsId() {
        let gate = AgentInvocationGate()
        guard case let .proceed(id, root) = gate.decide(caller: nil, target: .miniApp(UUID())) else {
            Issue.record("Expected .proceed"); return
        }
        #expect(id == root)
    }

    @Test("Nested nodes inherit the tree root from their ancestor")
    func treeRootPropagates() {
        let gate = AgentInvocationGate()
        let a = UUID(), b = UUID(), c = UUID()
        let idA = enter(gate: gate, caller: nil, target: .miniApp(a))
        let idB = enter(gate: gate, caller: idA, target: .miniApp(b))
        let idC = enter(gate: gate, caller: idB, target: .miniApp(c))
        #expect(gate.activeInvocations[idA]?.treeRootInvocationId == idA)
        #expect(gate.activeInvocations[idB]?.treeRootInvocationId == idA)
        #expect(gate.activeInvocations[idC]?.treeRootInvocationId == idA)
    }

    @Test("Rejection carries treeRootKey of the deepest ancestor in the chain")
    func rejectionCarriesRootKey() {
        let gate = AgentInvocationGate()
        let a = UUID(), b = UUID()
        let idA = enter(gate: gate, caller: nil, target: .miniApp(a))
        let idB = enter(gate: gate, caller: idA, target: .miniApp(b))
        // B tries to invoke A (its ancestor) — rejected.
        let decision = gate.decide(caller: idB, target: .miniApp(a))
        guard case .reentrant = decision else {
            Issue.record("Expected .reentrant"); return
        }
        let ancestors = gate.ancestorChain(from: idB)
        let rootKey = ancestors.first?.agentKey
        #expect(rootKey == .miniApp(a))
    }

    // MARK: - `enter`/`exit` lifecycle

    @Test("exit removes the node; isBusy returns false")
    func exitClearsNode() {
        let gate = AgentInvocationGate()
        let app = UUID()
        let id = enter(gate: gate, caller: nil, target: .miniApp(app))
        #expect(gate.isBusy(.miniApp(app)))
        gate.exit(id)
        #expect(gate.activeInvocations.isEmpty)
        #expect(!gate.isBusy(.miniApp(app)))
    }

    @Test("exit is idempotent — double-exit does not trap")
    func idempotentExit() {
        let gate = AgentInvocationGate()
        let id = enter(gate: gate, caller: nil, target: .miniApp(UUID()))
        gate.exit(id)
        gate.exit(id)  // must not crash
        #expect(gate.activeInvocations.isEmpty)
    }

    @Test("After exit the key is decidable again from the same caller")
    func reuseAfterExit() {
        let gate = AgentInvocationGate()
        let a = UUID(), b = UUID()
        let idA = enter(gate: gate, caller: nil, target: .miniApp(a))
        let idB = enter(gate: gate, caller: idA, target: .miniApp(b))
        gate.exit(idB)
        // B is gone — A's child slot is free.
        guard case .proceed = gate.decide(caller: idA, target: .miniApp(b)) else {
            Issue.record("Expected .proceed after B exits"); return
        }
    }

    // MARK: - ancestorChain / tree helpers

    @Test("ancestorChain returns root→leaf order")
    func ancestorChainOrder() {
        let gate = AgentInvocationGate()
        let a = UUID(), b = UUID()
        let idA = enter(gate: gate, caller: nil, target: .miniApp(a))
        let idB = enter(gate: gate, caller: idA, target: .miniApp(b))
        let chain = gate.ancestorChain(from: idB)
        #expect(chain.count == 2)
        #expect(chain[0].agentKey == .miniApp(a))
        #expect(chain[1].agentKey == .miniApp(b))
    }

    @Test("ancestorChain for unknown id returns empty")
    func ancestorChainUnknown() {
        let gate = AgentInvocationGate()
        #expect(gate.ancestorChain(from: UUID()).isEmpty)
    }

    @Test("tree(rootedAt:) returns all nodes in a tree")
    func treeAccessor() {
        let gate = AgentInvocationGate()
        let a = UUID(), b = UUID(), c = UUID()
        let idA = enter(gate: gate, caller: nil, target: .miniApp(a))
        let idB = enter(gate: gate, caller: idA, target: .miniApp(b))
        let idC = enter(gate: gate, caller: idA, target: .miniApp(c))  // sibling of B
        let treeNodes = gate.tree(rootedAt: idA)
        let ids = Set(treeNodes.map { $0.invocationId })
        #expect(ids == [idA, idB, idC])
    }

    // MARK: - isBusy / snapshotForest

    @Test("isBusy reflects whether any active node carries the key")
    func isBusyReflectsState() {
        let gate = AgentInvocationGate()
        let app = UUID()
        #expect(!gate.isBusy(.miniApp(app)))
        let id = enter(gate: gate, caller: nil, target: .miniApp(app))
        #expect(gate.isBusy(.miniApp(app)))
        gate.exit(id)
        #expect(!gate.isBusy(.miniApp(app)))
    }

    @Test("snapshotForest returns all active nodes")
    func snapshotForest() {
        let gate = AgentInvocationGate()
        let a = UUID(), b = UUID()
        let idA = enter(gate: gate, caller: nil, target: .miniApp(a))
        let idB = enter(gate: gate, caller: idA, target: .miniApp(b))
        let snap = gate.snapshotForest()
        let ids = Set(snap.map { $0.invocationId })
        #expect(ids == [idA, idB])
    }

    // MARK: - Wire encoding

    @Test("wireValue produces stable strings for echo payloads")
    func wireValueStable() {
        let id = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        #expect(AgentInvocationKey.orchestrator.wireValue == "orchestrator")
        #expect(AgentInvocationKey.miniApp(id).wireValue == "miniApp:11111111-2222-3333-4444-555555555555")
        #expect(AgentInvocationKey.subagent(miniAppId: id, slug: "marketing").wireValue
            == "subagent:11111111-2222-3333-4444-555555555555:marketing")
    }

    // MARK: - AgentInvocationRejection construction

    @Test("Rejection from reentrant decision captures target and ancestors")
    func rejectionFromReentrant() {
        let gate = AgentInvocationGate()
        let app = UUID()
        let idA = enter(gate: gate, caller: nil, target: .miniApp(app))
        let decision = gate.decide(caller: idA, target: .miniApp(app))
        let ancestors = gate.ancestorChain(from: idA)
        let rejection = AgentInvocationRejection(
            decision: decision,
            callPath: ancestors.map { $0.agentKey },
            treeRootKey: ancestors.first?.agentKey
        )
        #expect(rejection.reason == .reentrant)
        #expect(rejection.target == .miniApp(app))
        #expect(rejection.treeRootKey == .miniApp(app))
    }

    @Test("Rejection carries depth for maxDepthExceeded case")
    func rejectionCarriesDepth() {
        let gate = AgentInvocationGate(maxChainDepth: 1)
        let a = UUID(), b = UUID()
        let idA = enter(gate: gate, caller: nil, target: .miniApp(a))
        let decision = gate.decide(caller: idA, target: .miniApp(b))
        guard case .maxDepthExceeded = decision else {
            Issue.record("Expected .maxDepthExceeded"); return
        }
        let rejection = AgentInvocationRejection(
            decision: decision,
            callPath: gate.ancestorChain(from: idA).map { $0.agentKey },
            treeRootKey: .miniApp(a)
        )
        #expect(rejection.reason == .maxDepthExceeded)
        #expect(rejection.depth == 2)
    }

    // MARK: - Cross-scope (MiniApp ↔ Slack)

    @Test("Reentrancy detected across MiniApp → Slack → MiniApp boundary")
    func crossScopeReentrancy() {
        let gate = AgentInvocationGate()
        let app = UUID()
        let idA = enter(gate: gate, caller: nil, target: .miniApp(app))
        let idSlack = enter(gate: gate, caller: idA, target: .subagent(miniAppId: kGateApp, slug:"marketing"))
        // Slack agent tries to invoke the MiniApp it was called from.
        let d = gate.decide(caller: idSlack, target: .miniApp(app))
        guard case .reentrant = d else {
            Issue.record("Expected .reentrant for cross-scope MiniApp → Slack → MiniApp"); return
        }
    }

    @Test("Independent MiniApp and Slack runs proceed in parallel")
    func independentMixed() {
        let gate = AgentInvocationGate()
        let app1 = UUID(), app2 = UUID()
        enter(gate: gate, caller: nil, target: .miniApp(app1))
        enter(gate: gate, caller: nil, target: .subagent(miniAppId: kGateApp, slug:"a1"))
        // Unrelated keys in separate trees.
        guard case .proceed = gate.decide(caller: nil, target: .miniApp(app2)) else {
            Issue.record("Expected .proceed for unrelated miniApp2"); return
        }
        guard case .proceed = gate.decide(caller: nil, target: .subagent(miniAppId: kGateApp, slug:"a2")) else {
            Issue.record("Expected .proceed for unrelated slack a2"); return
        }
    }

    // MARK: - Multi-turn budget (Phase 1c)

    @Test("Turns 1 through maxTurnsPerPair all proceed")
    func budgetProceedsUnderLimit() {
        let gate = AgentInvocationGate(maxTurnsPerPair: 3)
        let a = UUID(), b = UUID()
        let idA = enter(gate: gate, caller: nil, target: .miniApp(a))
        for _ in 1...3 {
            guard case let .proceed(idB, _) = gate.decide(caller: idA, target: .miniApp(b)) else {
                Issue.record("Expected .proceed within budget"); return
            }
            gate.enter(invocationId: idB, target: .miniApp(b), caller: .agent(idA), treeRoot: idA)
            gate.exit(idB)
        }
    }

    @Test("Turn maxTurnsPerPair+1 returns .budgetExhausted")
    func budgetExhaustedOnOverrun() {
        let gate = AgentInvocationGate(maxTurnsPerPair: 3)
        let a = UUID(), b = UUID()
        let idA = enter(gate: gate, caller: nil, target: .miniApp(a))
        for _ in 1...3 {
            guard case let .proceed(idB, _) = gate.decide(caller: idA, target: .miniApp(b)) else {
                Issue.record("Expected .proceed for first 3 turns"); return
            }
            gate.enter(invocationId: idB, target: .miniApp(b), caller: .agent(idA), treeRoot: idA)
            gate.exit(idB)
        }
        let d = gate.decide(caller: idA, target: .miniApp(b))
        guard case let .budgetExhausted(target, n) = d else {
            Issue.record("Expected .budgetExhausted on turn 4"); return
        }
        #expect(target == .miniApp(b))
        #expect(n == 3)
    }

    @Test("New parent invocationId resets the pair counter")
    func budgetResetsWithNewParent() {
        let gate = AgentInvocationGate(maxTurnsPerPair: 2)
        let a = UUID(), b = UUID()
        // First parent: exhaust budget.
        let idA1 = enter(gate: gate, caller: nil, target: .miniApp(a))
        for _ in 1...2 {
            guard case let .proceed(idB, _) = gate.decide(caller: idA1, target: .miniApp(b)) else {
                Issue.record("Expected .proceed"); return
            }
            gate.enter(invocationId: idB, target: .miniApp(b), caller: .agent(idA1), treeRoot: idA1)
            gate.exit(idB)
        }
        #expect(gate.decide(caller: idA1, target: .miniApp(b)) ==
                .budgetExhausted(target: .miniApp(b), exhaustedAfter: 2))
        // Parent exits; new root run of same parent key gets a fresh slot.
        gate.exit(idA1)
        let idA2 = enter(gate: gate, caller: nil, target: .miniApp(a))
        guard case .proceed = gate.decide(caller: idA2, target: .miniApp(b)) else {
            Issue.record("Expected .proceed for new parent's first turn with B"); return
        }
    }

    @Test("Budget is per-pair: A→B exhausted does not affect A→C")
    func budgetIsPerPair() {
        let gate = AgentInvocationGate(maxTurnsPerPair: 1)
        let a = UUID(), b = UUID(), c = UUID()
        let idA = enter(gate: gate, caller: nil, target: .miniApp(a))
        // Use up A→B budget.
        guard case let .proceed(idB, _) = gate.decide(caller: idA, target: .miniApp(b)) else {
            Issue.record("Expected .proceed"); return
        }
        gate.enter(invocationId: idB, target: .miniApp(b), caller: .agent(idA), treeRoot: idA)
        gate.exit(idB)
        #expect(gate.decide(caller: idA, target: .miniApp(b)) ==
                .budgetExhausted(target: .miniApp(b), exhaustedAfter: 1))
        // A→C is a different pair — still has full budget.
        guard case .proceed = gate.decide(caller: idA, target: .miniApp(c)) else {
            Issue.record("Expected .proceed for A→C which has separate budget"); return
        }
    }

    @Test("AgentInvocationRejection built from .budgetExhausted carries exhaustedAfter")
    func rejectionFromBudgetExhausted() {
        let gate = AgentInvocationGate(maxTurnsPerPair: 2)
        let a = UUID(), b = UUID()
        let idA = enter(gate: gate, caller: nil, target: .miniApp(a))
        for _ in 1...2 {
            guard case let .proceed(idB, _) = gate.decide(caller: idA, target: .miniApp(b)) else {
                Issue.record("Expected .proceed"); return
            }
            gate.enter(invocationId: idB, target: .miniApp(b), caller: .agent(idA), treeRoot: idA)
            gate.exit(idB)
        }
        let decision = gate.decide(caller: idA, target: .miniApp(b))
        let ancestors = gate.ancestorChain(from: idA)
        let rejection = AgentInvocationRejection(
            decision: decision,
            callPath: ancestors.map { $0.agentKey },
            treeRootKey: ancestors.first?.agentKey
        )
        #expect(rejection.reason == .budgetExhausted)
        #expect(rejection.target == .miniApp(b))
        #expect(rejection.exhaustedAfter == 2)
    }

    // MARK: - SlackInvoker integration

    @Test("SlackInvoker.enter pushes a .slack key onto the shared gate")
    func slackInvokerPushesGateKey() {
        let gate = AgentInvocationGate()
        let inv = SlackInvoker(gate: gate)
        let app = UUID()
        // Register a MiniApp root.
        let idApp = enter(gate: gate, caller: nil, target: .miniApp(app))
        // Now enter a Slack sub-agent under that MiniApp.
        guard case let .proceed(idSlack, root) = gate.decide(caller: idApp, target: .subagent(miniAppId: kGateApp, slug:"a1")) else {
            Issue.record("Expected .proceed for Slack sub-agent"); return
        }
        inv.enter("a1", agentName: "marketing", channelId: "c1",
                  miniAppId: kGateApp, invocationId: idSlack, caller: .agent(idApp), treeRoot: root)
        // Gate has both nodes.
        #expect(gate.activeInvocations[idApp] != nil)
        #expect(gate.activeInvocations[idSlack] != nil)
        // SlackInvoker knows a1 is busy.
        #expect(inv.isBusy("a1"))
        #expect(!inv.isBusy("a2"))
        // Exiting via invoker clears both the invoker and the gate node.
        inv.exit("a1")
        #expect(gate.activeInvocations[idSlack] == nil)
        #expect(!inv.isBusy("a1"))
        // MiniApp root still present.
        #expect(gate.activeInvocations[idApp] != nil)
    }

    @Test("currentInvocationId returns the live id for an active Slack agent")
    func currentInvocationId() {
        let gate = AgentInvocationGate()
        let inv = SlackInvoker(gate: gate)
        guard case let .proceed(id, root) = gate.decide(caller: nil, target: .subagent(miniAppId: kGateApp, slug:"a1")) else {
            Issue.record("Expected .proceed"); return
        }
        inv.enter("a1", agentName: "bot", channelId: "c1",
                  miniAppId: kGateApp, invocationId: id, caller: .user, treeRoot: root)
        #expect(inv.currentInvocationId(agentId: "a1") == id)
        #expect(inv.currentInvocationId(agentId: "a2") == nil)
        inv.exit("a1")
        #expect(inv.currentInvocationId(agentId: "a1") == nil)
    }

    @Test("Slack sub-agent depth counts against the shared chain depth")
    func slackSeesSharedChainDepth() {
        let gate = AgentInvocationGate(maxChainDepth: 1)
        let idApp = enter(gate: gate, caller: nil, target: .miniApp(UUID()))
        // Chain from idApp is length 1 — at the cap. A nested Slack call is depth 2.
        let d = gate.decide(caller: idApp, target: .subagent(miniAppId: kGateApp, slug:"a1"))
        guard case let .maxDepthExceeded(_, depth) = d else {
            Issue.record("Expected .maxDepthExceeded"); return
        }
        #expect(depth == 2)
    }
}
