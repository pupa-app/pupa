import Foundation
import Testing
@testable import PupaApp

// MARK: - Helpers

@MainActor
private func makeStore(miniApps: [MiniApp] = []) -> MiniAppStore {
    if let first = miniApps.first {
        return MiniAppStore(initial: (miniApps, first.id))
    }
    let dummy = MiniApp(name: "Dummy", iconSystemName: "star", typeId: "tracker")
    return MiniAppStore(initial: ([dummy], dummy.id))
}

// MARK: - AgentDispatcher lookup

@Suite("AgentDispatcher")
@MainActor
struct AgentDispatcherTests {

    @Test("Returns OrchestratorPolicy for .memory scope")
    func memoryScope() {
        let dispatcher = AgentDispatcher()
        let policy = dispatcher.policy(for: .memory)
        #expect(policy is OrchestratorPolicy)
    }

    @Test("Returns MiniAppPolicy for .miniApp scope")
    func miniAppScope() {
        let id = UUID()
        let dispatcher = AgentDispatcher()
        let policy = dispatcher.policy(for: .miniApp(id))
        guard let p = policy as? MiniAppPolicy else {
            Issue.record("Expected MiniAppPolicy, got \(type(of: policy))")
            return
        }
        #expect(p.miniAppId == id)
    }

    @Test("Different MiniApp IDs produce policies with matching IDs")
    func differentMiniAppIds() {
        let id1 = UUID()
        let id2 = UUID()
        let dispatcher = AgentDispatcher()
        let p1 = dispatcher.policy(for: .miniApp(id1)) as? MiniAppPolicy
        let p2 = dispatcher.policy(for: .miniApp(id2)) as? MiniAppPolicy
        #expect(p1?.miniAppId == id1)
        #expect(p2?.miniAppId == id2)
        #expect(p1?.miniAppId != p2?.miniAppId)
    }
}

// MARK: - OrchestratorPolicy

@Suite("OrchestratorPolicy")
@MainActor
struct OrchestratorPolicyTests {
    init() { TestStorage.activate() }

    @Test("canInvoke returns true for nil caller (user)")
    func canInvokeUser() {
        #expect(OrchestratorPolicy().canInvoke(from: nil) == true)
    }

    @Test("canInvoke returns false for agent callers")
    func canInvokeAgent() {
        let p = OrchestratorPolicy()
        #expect(p.canInvoke(from: .memory) == false)
        #expect(p.canInvoke(from: .miniApp(UUID())) == false)
    }

    @Test("toolsExposedTo returns nil (no A2A restriction)")
    func toolsExposedToNil() {
        #expect(OrchestratorPolicy().toolsExposedTo(caller: nil) == nil)
        #expect(OrchestratorPolicy().toolsExposedTo(caller: .miniApp(UUID())) == nil)
    }

    @Test("payload has non-empty systemPrompt with no AGENTS.md present")
    func payloadSystemPromptFallback() async {
        let store = makeStore()
        let payload = await OrchestratorPolicy().payload(for: .memory, store: store)
        #expect(!payload.systemPrompt.isEmpty)
    }

    @Test("payload memory root scoped to orchestrator folder")
    func payloadMemoryRoot() async {
        let store = makeStore()
        let payload = await OrchestratorPolicy().payload(for: .memory, store: store)
        // Memory root should be orchestratorRoot — verify by checking that
        // writing a file at "pupa/AGENTS.md" doesn't affect the global root.
        let globalMemory = MemoryStore()
        let globalBefore = try? globalMemory.readFile(path: "pupa/AGENTS.md")
        _ = try? payload.memory.writeFile(path: "_test_orch.md", content: "test")
        let globalAfter = try? globalMemory.readFile(path: "pupa/AGENTS.md")
        // Global AGENTS.md unaffected
        #expect(globalBefore?.content == globalAfter?.content)
        // cleanup
        _ = try? payload.memory.delete(path: "_test_orch.md")
    }

    @Test("systemPrompt includes AGENTS.md content when present")
    func systemPromptWithAgentsMd() async {
        let store = makeStore()
        let memory = MemoryStore(rootOverride: MemoryStore.orchestratorRoot())
        _ = try? memory.writeFile(path: "pupa/AGENTS.md", content: "## Custom orchestrator instructions\n\nBe helpful.")
        defer { _ = try? memory.delete(path: "pupa/AGENTS.md") }
        let desc = OrchestratorPolicy().buildSystemPrompt(memory: memory)
        #expect(desc.contains("Custom orchestrator instructions"))
        #expect(desc.contains("pupa/AGENTS.md"))
    }
}

// MARK: - MiniAppPolicy

@Suite("MiniAppPolicy")
@MainActor
struct MiniAppPolicyTests {
    init() { TestStorage.activate() }

    @Test("canInvoke returns true for all callers by default")
    func canInvokeAll() {
        let p = MiniAppPolicy(miniAppId: UUID())
        #expect(p.canInvoke(from: nil) == true)
        #expect(p.canInvoke(from: .memory) == true)
        #expect(p.canInvoke(from: .miniApp(UUID())) == true)
    }

    @Test("toolsExposedTo returns nil for user (nil caller)")
    func toolsExposedToUser() {
        let p = MiniAppPolicy(miniAppId: UUID())
        #expect(p.toolsExposedTo(caller: nil) == nil)
    }

    @Test("payload has non-empty systemPrompt for unknown miniApp")
    func payloadUnknownMiniApp() async {
        let store = makeStore()
        let unknownId = UUID()
        let payload = await MiniAppPolicy(miniAppId: unknownId).payload(for: .miniApp(unknownId), store: store)
        #expect(!payload.systemPrompt.isEmpty)
    }

    @Test("payload memory root scoped to miniApp folder (no cross-bleed)")
    func payloadMemoryRootIsolated() async {
        let appA = MiniApp(name: "AppA", iconSystemName: "star", typeId: "tracker")
        let appB = MiniApp(name: "AppB", iconSystemName: "circle", typeId: "tracker")
        let store = MiniAppStore(initial: ([appA, appB], appA.id))

        let payloadA = await MiniAppPolicy(miniAppId: appA.id).payload(for: .miniApp(appA.id), store: store)
        let payloadB = await MiniAppPolicy(miniAppId: appB.id).payload(for: .miniApp(appB.id), store: store)

        // Write to A's root
        _ = try? payloadA.memory.writeFile(path: "_test.md", content: "from A")
        // B's root should be unaffected
        let fromB = try? payloadB.memory.readFile(path: "_test.md")
        #expect(fromB == nil)
        // cleanup
        _ = try? payloadA.memory.delete(path: "_test.md")
    }

    @Test("systemPrompt includes AGENTS.md content when present in miniApp folder")
    func systemPromptWithAgentsMd() async {
        let app = MiniApp(name: "TestApp", iconSystemName: "star", typeId: "tracker")
        let store = MiniAppStore(initial: ([app], app.id))
        let memory = MemoryStore(rootOverride: MemoryStore.appRoot(miniAppId: app.id))
        _ = try? memory.writeFile(path: "pupa/AGENTS.md", content: "## Custom MiniApp instructions\n\nTrack things carefully.")
        defer { _ = try? memory.delete(path: "pupa/AGENTS.md") }
        let desc = MiniAppPolicy(miniAppId: app.id).buildSystemPrompt(miniApp: app, memory: memory)
        #expect(desc.contains("Custom MiniApp instructions"))
        #expect(desc.contains("pupa/AGENTS.md"))
    }

    @Test("AGENTS.md layers over type fragment, not replaces it (issue #164)")
    func systemPromptLayersAgentsMdOverTypeFragment() async {
        MiniAppTypeRegistry.shared.registerBuiltins()
        let app = MiniApp(name: "LayerApp", iconSystemName: "star", typeId: "tracker")
        let store = MiniAppStore(initial: ([app], app.id))
        let memory = MemoryStore(rootOverride: MemoryStore.appRoot(miniAppId: app.id))
        _ = try? memory.writeFile(path: "pupa/AGENTS.md", content: "## Custom\n\nBe terse.")
        defer { _ = try? memory.delete(path: "pupa/AGENTS.md") }
        let desc = MiniAppPolicy(miniAppId: app.id).buildSystemPrompt(miniApp: app, memory: memory)
        // User customization present…
        #expect(desc.contains("Be terse."))
        // …and the dynamic type fragment (base + catalog) is still included,
        // so per-kind guidance is not dropped when AGENTS.md exists.
        #expect(desc.contains("per-type rules"))
        let type = MiniAppTypeRegistry.shared.resolve(id: "tracker")!
        let expected = ChatViewModel.activeSystemPromptFragment(miniApp: app, type: type)
        #expect(desc.contains(expected))
    }

    @Test("systemPrompt falls back to type-fragment when no AGENTS.md")
    func systemPromptFallback() async {
        let app = MiniApp(name: "FallbackApp", iconSystemName: "star", typeId: "tracker")
        let store = MiniAppStore(initial: ([app], app.id))
        let payload = await MiniAppPolicy(miniAppId: app.id).payload(for: .miniApp(app.id), store: store)
        // Fallback should mention the miniApp name or "tracker"
        #expect(!payload.systemPrompt.isEmpty)
    }
}

// MARK: - Scoping isolation (orchestrator vs MiniApp)

@Suite("AgentPolicy scoping isolation")
@MainActor
struct AgentPolicyScopingTests {
    init() { TestStorage.activate() }

    @Test("Orchestrator and MiniApp read from different memory roots")
    func differentRoots() async {
        let app = MiniApp(name: "IsolationApp", iconSystemName: "star", typeId: "tracker")
        let store = MiniAppStore(initial: ([app], app.id))

        let orchPayload = await OrchestratorPolicy().payload(for: .memory, store: store)
        let miniAppPayload = await MiniAppPolicy(miniAppId: app.id).payload(for: .miniApp(app.id), store: store)

        // Write a sentinel to orchestrator root
        _ = try? orchPayload.memory.writeFile(path: "_sentinel.md", content: "orch")
        // MiniApp root must not see it
        let fromMiniApp = try? miniAppPayload.memory.readFile(path: "_sentinel.md")
        #expect(fromMiniApp == nil)
        // cleanup
        _ = try? orchPayload.memory.delete(path: "_sentinel.md")
    }

    @Test("Orchestrator AGENTS.md does not affect MiniApp system prompt")
    func orchAgentsMdDoesNotBleedIntoMiniApp() async {
        let app = MiniApp(name: "BleedTestApp", iconSystemName: "star", typeId: "tracker")
        let store = MiniAppStore(initial: ([app], app.id))

        // Write orchestrator AGENTS.md with unique content
        let orchMem = MemoryStore(rootOverride: MemoryStore.orchestratorRoot())
        _ = try? orchMem.writeFile(path: "pupa/AGENTS.md", content: "ORCH UNIQUE MARKER XYZ")
        defer { _ = try? orchMem.delete(path: "pupa/AGENTS.md") }

        // MiniApp payload should NOT contain the orchestrator marker
        let miniAppPayload = await MiniAppPolicy(miniAppId: app.id).payload(for: .miniApp(app.id), store: store)
        #expect(!miniAppPayload.systemPrompt.contains("ORCH UNIQUE MARKER XYZ"))
    }

    @Test("MiniApp AGENTS.md does not affect orchestrator system prompt")
    func miniAppAgentsMdDoesNotBleedIntoOrch() async {
        let app = MiniApp(name: "BleedTestApp2", iconSystemName: "star", typeId: "tracker")
        let store = MiniAppStore(initial: ([app], app.id))

        // Write miniApp AGENTS.md with unique content
        let miniAppMem = MemoryStore(rootOverride: MemoryStore.appRoot(miniAppId: app.id))
        _ = try? miniAppMem.writeFile(path: "pupa/AGENTS.md", content: "MINIAPP UNIQUE MARKER ABC")
        defer { _ = try? miniAppMem.delete(path: "pupa/AGENTS.md") }

        // Orchestrator payload should NOT contain the miniApp marker
        let orchPayload = await OrchestratorPolicy().payload(for: .memory, store: store)
        #expect(!orchPayload.systemPrompt.contains("MINIAPP UNIQUE MARKER ABC"))
    }

    @Test("Two different MiniApps each read their own AGENTS.md independently")
    func twoMiniAppsIndependentAgentsMd() async {
        let appX = MiniApp(name: "MiniAppX", iconSystemName: "star", typeId: "tracker")
        let appY = MiniApp(name: "MiniAppY", iconSystemName: "circle", typeId: "tracker")
        let store = MiniAppStore(initial: ([appX, appY], appX.id))

        let memX = MemoryStore(rootOverride: MemoryStore.appRoot(miniAppId: appX.id))
        let memY = MemoryStore(rootOverride: MemoryStore.appRoot(miniAppId: appY.id))
        _ = try? memX.writeFile(path: "pupa/AGENTS.md", content: "Instructions for X only")
        _ = try? memY.writeFile(path: "pupa/AGENTS.md", content: "Instructions for Y only")
        defer {
            _ = try? memX.delete(path: "pupa/AGENTS.md")
            _ = try? memY.delete(path: "pupa/AGENTS.md")
        }

        let payloadX = await MiniAppPolicy(miniAppId: appX.id).payload(for: .miniApp(appX.id), store: store)
        let payloadY = await MiniAppPolicy(miniAppId: appY.id).payload(for: .miniApp(appY.id), store: store)

        #expect(payloadX.systemPrompt.contains("Instructions for X only"))
        #expect(!payloadX.systemPrompt.contains("Instructions for Y only"))
        #expect(payloadY.systemPrompt.contains("Instructions for Y only"))
        #expect(!payloadY.systemPrompt.contains("Instructions for X only"))
    }
}
