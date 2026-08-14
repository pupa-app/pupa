import Foundation
import Testing
@testable import PupaApp

/// Shared MyApp id for `.subagent` keys in these tests. With a single app,
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
        let d = gate.decide(caller: nil, target: .myApp(UUID()))
        guard case let .proceed(id, root) = d else { Issue.record("Expected proceed"); return }
        #expect(id == root, "Root: invocationId must equal treeRoot")
    }

    @Test("Multiple independent roots on the same key all proceed")
    func concurrentSameKeyRoots() {
        let gate = AgentInvocationGate()
        let app = UUID()
        let id1 = enter(gate: gate, caller: nil, target: .myApp(app))
        // Second top-level invocation of the same key — different tree, must proceed.
        let d2 = gate.decide(caller: nil, target: .myApp(app))
        guard case let .proceed(id2, root2) = d2 else {
            Issue.record("Expected .proceed for second root invocation of same key"); return
        }
        gate.enter(invocationId: id2, target: .myApp(app), caller: .user, treeRoot: root2)
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
        guard case let .proceed(idA, rootA) = gate.decide(caller: nil, target: .myApp(a)) else {
            Issue.record("Expected .proceed"); return
        }
        gate.enter(invocationId: idA, target: .myApp(a), caller: .session(.orchestrator), treeRoot: rootA)
        // A sits at depth 1, exactly as if the panel weren't there: the next
        // hop is depth 2 and blocked by maxChainDepth 1.
        #expect(gate.decide(caller: idA, target: .myApp(b)) ==
                .maxDepthExceeded(target: .myApp(b), depth: 2))
    }

    @Test("A .session caller owns no per-pair turn budget")
    func sessionCallerHasNoTurnBudget() {
        let gate = AgentInvocationGate(maxTurnsPerPair: 1)
        let b = UUID()
        // Same panel delegates to the same target twice. Each is its own root,
        // so neither consumes the other's budget.
        for turn in 1...2 {
            guard case let .proceed(id, root) = gate.decide(caller: nil, target: .myApp(b)) else {
                Issue.record("Turn \(turn) from a chat panel must proceed"); return
            }
            gate.enter(invocationId: id, target: .myApp(b), caller: .session(.orchestrator), treeRoot: root)
            gate.exit(id)
        }
    }

    // MARK: - Ancestor-only reentry

    @Test("Direct reentry A→A is blocked")
    func directReentry() {
        let gate = AgentInvocationGate()
        let app = UUID()
        let id = enter(gate: gate, caller: nil, target: .myApp(app))
        let d = gate.decide(caller: id, target: .myApp(app))
        guard case let .reentrant(target, _) = d else {
            Issue.record("Expected .reentrant"); return
        }
        #expect(target == .myApp(app))
    }

    @Test("A→B→A is blocked at the A step")
    func reentryABA() {
        let gate = AgentInvocationGate()
        let a = UUID(), b = UUID()
        let idA = enter(gate: gate, caller: nil, target: .myApp(a))
        let idB = enter(gate: gate, caller: idA, target: .myApp(b))
        // B tries to invoke A (its own ancestor).
        let d = gate.decide(caller: idB, target: .myApp(a))
        guard case let .reentrant(target, ancestors) = d else {
            Issue.record("Expected .reentrant for A→B→A"); return
        }
        #expect(target == .myApp(a))
        #expect(ancestors.contains(.myApp(a)))
    }

    @Test("A→B→C→A is blocked at the A step")
    func reentryABCA() {
        let gate = AgentInvocationGate()
        let a = UUID(), b = UUID(), c = UUID()
        let idA = enter(gate: gate, caller: nil, target: .myApp(a))
        let idB = enter(gate: gate, caller: idA, target: .myApp(b))
        let idC = enter(gate: gate, caller: idB, target: .myApp(c))
        let d = gate.decide(caller: idC, target: .myApp(a))
        guard case .reentrant = d else {
            Issue.record("Expected .reentrant for A→B→C→A"); return
        }
    }

    @Test("A→B→C→D where D is unrelated proceeds")
    func deepChainUnrelated() {
        let gate = AgentInvocationGate(maxChainDepth: 5)
        let a = UUID(), b = UUID(), c = UUID(), d = UUID()
        let idA = enter(gate: gate, caller: nil, target: .myApp(a))
        let idB = enter(gate: gate, caller: idA, target: .myApp(b))
        let idC = enter(gate: gate, caller: idB, target: .myApp(c))
        let decision = gate.decide(caller: idC, target: .myApp(d))
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
        let idA = enter(gate: gate, caller: nil, target: .myApp(a))
        let idB = enter(gate: gate, caller: idA, target: .myApp(b))
        // C is a sibling of B — neither is an ancestor of the other.
        let d = gate.decide(caller: idA, target: .myApp(c))
        guard case let .proceed(idC, _) = d else {
            Issue.record("Expected .proceed for sibling C"); return
        }
        gate.enter(invocationId: idC, target: .myApp(c), caller: .agent(idA), treeRoot: idA)
        // B trying to invoke C (cross-branch).
        let dBC = gate.decide(caller: idB, target: .myApp(c))
        guard case .proceed = dBC else {
            Issue.record("Expected .proceed for B→C cross-branch"); return
        }
        // C trying to invoke B (cross-branch, even though B is in the forest).
        let dCB = gate.decide(caller: idC, target: .myApp(b))
        guard case .proceed = dCB else {
            Issue.record("Expected .proceed for C→B cross-branch"); return
        }
    }

    // MARK: - Chain depth

    @Test("Chain depth cap blocks a call that exceeds maxChainDepth")
    func maxChainDepth() {
        let gate = AgentInvocationGate(maxChainDepth: 3)
        let a = UUID(), b = UUID(), c = UUID(), d = UUID()
        let idA = enter(gate: gate, caller: nil, target: .myApp(a))
        let idB = enter(gate: gate, caller: idA, target: .myApp(b))
        let idC = enter(gate: gate, caller: idB, target: .myApp(c))
        // Ancestor chain from idC is [A, B, C] (length 3). A fourth
        // nested call would be depth 4, exceeding maxChainDepth=3.
        let blocked = gate.decide(caller: idC, target: .myApp(d))
        guard case let .maxDepthExceeded(target, depth) = blocked else {
            Issue.record("Expected .maxDepthExceeded"); return
        }
        #expect(target == .myApp(d))
        #expect(depth == 4)
    }

    @Test("Exiting one node re-opens the depth slot")
    func depthSlotsRecycle() {
        let gate = AgentInvocationGate(maxChainDepth: 2)
        let a = UUID(), b = UUID(), c = UUID()
        let idA = enter(gate: gate, caller: nil, target: .myApp(a))
        let idB = enter(gate: gate, caller: idA, target: .myApp(b))
        // Chain A→B is at max depth (2). C is blocked.
        #expect(gate.decide(caller: idB, target: .myApp(c)) ==
                .maxDepthExceeded(target: .myApp(c), depth: 3))
        // B exits; chain shrinks to [A].
        gate.exit(idB)
        // Now depth would be 2 → allowed.
        guard case .proceed = gate.decide(caller: idA, target: .myApp(c)) else {
            Issue.record("Expected .proceed after B exits"); return
        }
    }

    // MARK: - Tree-root tag

    @Test("Proceeding root: invocationId equals treeRoot")
    func rootTagEqualsId() {
        let gate = AgentInvocationGate()
        guard case let .proceed(id, root) = gate.decide(caller: nil, target: .myApp(UUID())) else {
            Issue.record("Expected .proceed"); return
        }
        #expect(id == root)
    }

    @Test("Nested nodes inherit the tree root from their ancestor")
    func treeRootPropagates() {
        let gate = AgentInvocationGate()
        let a = UUID(), b = UUID(), c = UUID()
        let idA = enter(gate: gate, caller: nil, target: .myApp(a))
        let idB = enter(gate: gate, caller: idA, target: .myApp(b))
        let idC = enter(gate: gate, caller: idB, target: .myApp(c))
        #expect(gate.activeInvocations[idA]?.treeRootInvocationId == idA)
        #expect(gate.activeInvocations[idB]?.treeRootInvocationId == idA)
        #expect(gate.activeInvocations[idC]?.treeRootInvocationId == idA)
    }

    @Test("Rejection carries treeRootKey of the deepest ancestor in the chain")
    func rejectionCarriesRootKey() {
        let gate = AgentInvocationGate()
        let a = UUID(), b = UUID()
        let idA = enter(gate: gate, caller: nil, target: .myApp(a))
        let idB = enter(gate: gate, caller: idA, target: .myApp(b))
        // B tries to invoke A (its ancestor) — rejected.
        let decision = gate.decide(caller: idB, target: .myApp(a))
        guard case .reentrant = decision else {
            Issue.record("Expected .reentrant"); return
        }
        let ancestors = gate.ancestorChain(from: idB)
        let rootKey = ancestors.first?.agentKey
        #expect(rootKey == .myApp(a))
    }

    // MARK: - `enter`/`exit` lifecycle

    @Test("exit removes the node; isBusy returns false")
    func exitClearsNode() {
        let gate = AgentInvocationGate()
        let app = UUID()
        let id = enter(gate: gate, caller: nil, target: .myApp(app))
        #expect(gate.isBusy(.myApp(app)))
        gate.exit(id)
        #expect(gate.activeInvocations.isEmpty)
        #expect(!gate.isBusy(.myApp(app)))
    }

    @Test("exit is idempotent — double-exit does not trap")
    func idempotentExit() {
        let gate = AgentInvocationGate()
        let id = enter(gate: gate, caller: nil, target: .myApp(UUID()))
        gate.exit(id)
        gate.exit(id)  // must not crash
        #expect(gate.activeInvocations.isEmpty)
    }

    @Test("After exit the key is decidable again from the same caller")
    func reuseAfterExit() {
        let gate = AgentInvocationGate()
        let a = UUID(), b = UUID()
        let idA = enter(gate: gate, caller: nil, target: .myApp(a))
        let idB = enter(gate: gate, caller: idA, target: .myApp(b))
        gate.exit(idB)
        // B is gone — A's child slot is free.
        guard case .proceed = gate.decide(caller: idA, target: .myApp(b)) else {
            Issue.record("Expected .proceed after B exits"); return
        }
    }

    // MARK: - ancestorChain / tree helpers

    @Test("ancestorChain returns root→leaf order")
    func ancestorChainOrder() {
        let gate = AgentInvocationGate()
        let a = UUID(), b = UUID()
        let idA = enter(gate: gate, caller: nil, target: .myApp(a))
        let idB = enter(gate: gate, caller: idA, target: .myApp(b))
        let chain = gate.ancestorChain(from: idB)
        #expect(chain.count == 2)
        #expect(chain[0].agentKey == .myApp(a))
        #expect(chain[1].agentKey == .myApp(b))
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
        let idA = enter(gate: gate, caller: nil, target: .myApp(a))
        let idB = enter(gate: gate, caller: idA, target: .myApp(b))
        let idC = enter(gate: gate, caller: idA, target: .myApp(c))  // sibling of B
        let treeNodes = gate.tree(rootedAt: idA)
        let ids = Set(treeNodes.map { $0.invocationId })
        #expect(ids == [idA, idB, idC])
    }

    // MARK: - isBusy / snapshotForest

    @Test("isBusy reflects whether any active node carries the key")
    func isBusyReflectsState() {
        let gate = AgentInvocationGate()
        let app = UUID()
        #expect(!gate.isBusy(.myApp(app)))
        let id = enter(gate: gate, caller: nil, target: .myApp(app))
        #expect(gate.isBusy(.myApp(app)))
        gate.exit(id)
        #expect(!gate.isBusy(.myApp(app)))
    }

    @Test("snapshotForest returns all active nodes")
    func snapshotForest() {
        let gate = AgentInvocationGate()
        let a = UUID(), b = UUID()
        let idA = enter(gate: gate, caller: nil, target: .myApp(a))
        let idB = enter(gate: gate, caller: idA, target: .myApp(b))
        let snap = gate.snapshotForest()
        let ids = Set(snap.map { $0.invocationId })
        #expect(ids == [idA, idB])
    }

    // MARK: - Wire encoding

    @Test("wireValue produces stable strings for echo payloads")
    func wireValueStable() {
        let id = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        #expect(AgentInvocationKey.orchestrator.wireValue == "orchestrator")
        #expect(AgentInvocationKey.myApp(id).wireValue == "myApp:11111111-2222-3333-4444-555555555555")
        #expect(AgentInvocationKey.subagent(myAppId: id, slug: "marketing").wireValue
            == "subagent:11111111-2222-3333-4444-555555555555:marketing")
    }

    // MARK: - AgentInvocationRejection construction

    @Test("Rejection from reentrant decision captures target and ancestors")
    func rejectionFromReentrant() {
        let gate = AgentInvocationGate()
        let app = UUID()
        let idA = enter(gate: gate, caller: nil, target: .myApp(app))
        let decision = gate.decide(caller: idA, target: .myApp(app))
        let ancestors = gate.ancestorChain(from: idA)
        let rejection = AgentInvocationRejection(
            decision: decision,
            callPath: ancestors.map { $0.agentKey },
            treeRootKey: ancestors.first?.agentKey
        )
        #expect(rejection.reason == .reentrant)
        #expect(rejection.target == .myApp(app))
        #expect(rejection.treeRootKey == .myApp(app))
    }

    @Test("Rejection carries depth for maxDepthExceeded case")
    func rejectionCarriesDepth() {
        let gate = AgentInvocationGate(maxChainDepth: 1)
        let a = UUID(), b = UUID()
        let idA = enter(gate: gate, caller: nil, target: .myApp(a))
        let decision = gate.decide(caller: idA, target: .myApp(b))
        guard case .maxDepthExceeded = decision else {
            Issue.record("Expected .maxDepthExceeded"); return
        }
        let rejection = AgentInvocationRejection(
            decision: decision,
            callPath: gate.ancestorChain(from: idA).map { $0.agentKey },
            treeRootKey: .myApp(a)
        )
        #expect(rejection.reason == .maxDepthExceeded)
        #expect(rejection.depth == 2)
    }

    // MARK: - Cross-scope (MyApp ↔ Slack)

    @Test("Reentrancy detected across MyApp → Slack → MyApp boundary")
    func crossScopeReentrancy() {
        let gate = AgentInvocationGate()
        let app = UUID()
        let idA = enter(gate: gate, caller: nil, target: .myApp(app))
        let idSlack = enter(gate: gate, caller: idA, target: .subagent(myAppId: kGateApp, slug:"marketing"))
        // Slack agent tries to invoke the MyApp it was called from.
        let d = gate.decide(caller: idSlack, target: .myApp(app))
        guard case .reentrant = d else {
            Issue.record("Expected .reentrant for cross-scope MyApp → Slack → MyApp"); return
        }
    }

    @Test("Independent MyApp and Slack runs proceed in parallel")
    func independentMixed() {
        let gate = AgentInvocationGate()
        let app1 = UUID(), app2 = UUID()
        enter(gate: gate, caller: nil, target: .myApp(app1))
        enter(gate: gate, caller: nil, target: .subagent(myAppId: kGateApp, slug:"a1"))
        // Unrelated keys in separate trees.
        guard case .proceed = gate.decide(caller: nil, target: .myApp(app2)) else {
            Issue.record("Expected .proceed for unrelated myApp2"); return
        }
        guard case .proceed = gate.decide(caller: nil, target: .subagent(myAppId: kGateApp, slug:"a2")) else {
            Issue.record("Expected .proceed for unrelated slack a2"); return
        }
    }

    // MARK: - Multi-turn budget (Phase 1c)

    @Test("Turns 1 through maxTurnsPerPair all proceed")
    func budgetProceedsUnderLimit() {
        let gate = AgentInvocationGate(maxTurnsPerPair: 3)
        let a = UUID(), b = UUID()
        let idA = enter(gate: gate, caller: nil, target: .myApp(a))
        for _ in 1...3 {
            guard case let .proceed(idB, _) = gate.decide(caller: idA, target: .myApp(b)) else {
                Issue.record("Expected .proceed within budget"); return
            }
            gate.enter(invocationId: idB, target: .myApp(b), caller: .agent(idA), treeRoot: idA)
            gate.exit(idB)
        }
    }

    @Test("Turn maxTurnsPerPair+1 returns .budgetExhausted")
    func budgetExhaustedOnOverrun() {
        let gate = AgentInvocationGate(maxTurnsPerPair: 3)
        let a = UUID(), b = UUID()
        let idA = enter(gate: gate, caller: nil, target: .myApp(a))
        for _ in 1...3 {
            guard case let .proceed(idB, _) = gate.decide(caller: idA, target: .myApp(b)) else {
                Issue.record("Expected .proceed for first 3 turns"); return
            }
            gate.enter(invocationId: idB, target: .myApp(b), caller: .agent(idA), treeRoot: idA)
            gate.exit(idB)
        }
        let d = gate.decide(caller: idA, target: .myApp(b))
        guard case let .budgetExhausted(target, n) = d else {
            Issue.record("Expected .budgetExhausted on turn 4"); return
        }
        #expect(target == .myApp(b))
        #expect(n == 3)
    }

    @Test("New parent invocationId resets the pair counter")
    func budgetResetsWithNewParent() {
        let gate = AgentInvocationGate(maxTurnsPerPair: 2)
        let a = UUID(), b = UUID()
        // First parent: exhaust budget.
        let idA1 = enter(gate: gate, caller: nil, target: .myApp(a))
        for _ in 1...2 {
            guard case let .proceed(idB, _) = gate.decide(caller: idA1, target: .myApp(b)) else {
                Issue.record("Expected .proceed"); return
            }
            gate.enter(invocationId: idB, target: .myApp(b), caller: .agent(idA1), treeRoot: idA1)
            gate.exit(idB)
        }
        #expect(gate.decide(caller: idA1, target: .myApp(b)) ==
                .budgetExhausted(target: .myApp(b), exhaustedAfter: 2))
        // Parent exits; new root run of same parent key gets a fresh slot.
        gate.exit(idA1)
        let idA2 = enter(gate: gate, caller: nil, target: .myApp(a))
        guard case .proceed = gate.decide(caller: idA2, target: .myApp(b)) else {
            Issue.record("Expected .proceed for new parent's first turn with B"); return
        }
    }

    @Test("Budget is per-pair: A→B exhausted does not affect A→C")
    func budgetIsPerPair() {
        let gate = AgentInvocationGate(maxTurnsPerPair: 1)
        let a = UUID(), b = UUID(), c = UUID()
        let idA = enter(gate: gate, caller: nil, target: .myApp(a))
        // Use up A→B budget.
        guard case let .proceed(idB, _) = gate.decide(caller: idA, target: .myApp(b)) else {
            Issue.record("Expected .proceed"); return
        }
        gate.enter(invocationId: idB, target: .myApp(b), caller: .agent(idA), treeRoot: idA)
        gate.exit(idB)
        #expect(gate.decide(caller: idA, target: .myApp(b)) ==
                .budgetExhausted(target: .myApp(b), exhaustedAfter: 1))
        // A→C is a different pair — still has full budget.
        guard case .proceed = gate.decide(caller: idA, target: .myApp(c)) else {
            Issue.record("Expected .proceed for A→C which has separate budget"); return
        }
    }

    @Test("AgentInvocationRejection built from .budgetExhausted carries exhaustedAfter")
    func rejectionFromBudgetExhausted() {
        let gate = AgentInvocationGate(maxTurnsPerPair: 2)
        let a = UUID(), b = UUID()
        let idA = enter(gate: gate, caller: nil, target: .myApp(a))
        for _ in 1...2 {
            guard case let .proceed(idB, _) = gate.decide(caller: idA, target: .myApp(b)) else {
                Issue.record("Expected .proceed"); return
            }
            gate.enter(invocationId: idB, target: .myApp(b), caller: .agent(idA), treeRoot: idA)
            gate.exit(idB)
        }
        let decision = gate.decide(caller: idA, target: .myApp(b))
        let ancestors = gate.ancestorChain(from: idA)
        let rejection = AgentInvocationRejection(
            decision: decision,
            callPath: ancestors.map { $0.agentKey },
            treeRootKey: ancestors.first?.agentKey
        )
        #expect(rejection.reason == .budgetExhausted)
        #expect(rejection.target == .myApp(b))
        #expect(rejection.exhaustedAfter == 2)
    }

    // MARK: - SlackInvoker integration

    @Test("SlackInvoker.enter pushes a .slack key onto the shared gate")
    func slackInvokerPushesGateKey() {
        let gate = AgentInvocationGate()
        let inv = SlackInvoker(gate: gate)
        let app = UUID()
        // Register a MyApp root.
        let idApp = enter(gate: gate, caller: nil, target: .myApp(app))
        // Now enter a Slack sub-agent under that MyApp.
        guard case let .proceed(idSlack, root) = gate.decide(caller: idApp, target: .subagent(myAppId: kGateApp, slug:"a1")) else {
            Issue.record("Expected .proceed for Slack sub-agent"); return
        }
        inv.enter("a1", agentName: "marketing", channelId: "c1",
                  myAppId: kGateApp, invocationId: idSlack, caller: .agent(idApp), treeRoot: root)
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
        // MyApp root still present.
        #expect(gate.activeInvocations[idApp] != nil)
    }

    @Test("currentInvocationId returns the live id for an active Slack agent")
    func currentInvocationId() {
        let gate = AgentInvocationGate()
        let inv = SlackInvoker(gate: gate)
        guard case let .proceed(id, root) = gate.decide(caller: nil, target: .subagent(myAppId: kGateApp, slug:"a1")) else {
            Issue.record("Expected .proceed"); return
        }
        inv.enter("a1", agentName: "bot", channelId: "c1",
                  myAppId: kGateApp, invocationId: id, caller: .user, treeRoot: root)
        #expect(inv.currentInvocationId(agentId: "a1") == id)
        #expect(inv.currentInvocationId(agentId: "a2") == nil)
        inv.exit("a1")
        #expect(inv.currentInvocationId(agentId: "a1") == nil)
    }

    @Test("Slack sub-agent depth counts against the shared chain depth")
    func slackSeesSharedChainDepth() {
        let gate = AgentInvocationGate(maxChainDepth: 1)
        let idApp = enter(gate: gate, caller: nil, target: .myApp(UUID()))
        // Chain from idApp is length 1 — at the cap. A nested Slack call is depth 2.
        let d = gate.decide(caller: idApp, target: .subagent(myAppId: kGateApp, slug:"a1"))
        guard case let .maxDepthExceeded(_, depth) = d else {
            Issue.record("Expected .maxDepthExceeded"); return
        }
        #expect(depth == 2)
    }
}
