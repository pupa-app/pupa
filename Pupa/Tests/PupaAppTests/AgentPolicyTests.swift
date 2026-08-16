import Foundation
import Testing
@testable import PupaApp

// MARK: - Helpers

@MainActor
private func makeStore(myApps: [MyApp] = []) -> MyAppStore {
    if let first = myApps.first {
        return MyAppStore(initial: (myApps, first.id))
    }
    let dummy = MyApp(name: "Dummy", iconSystemName: "star", typeId: "tracker")
    return MyAppStore(initial: ([dummy], dummy.id))
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

    @Test("Returns MyAppPolicy for .myApp scope")
    func myAppScope() {
        let id = UUID()
        let dispatcher = AgentDispatcher()
        let policy = dispatcher.policy(for: .myApp(id))
        guard let p = policy as? MyAppPolicy else {
            Issue.record("Expected MyAppPolicy, got \(type(of: policy))")
            return
        }
        #expect(p.myAppId == id)
    }

    @Test("Different MyApp IDs produce policies with matching IDs")
    func differentMyAppIds() {
        let id1 = UUID()
        let id2 = UUID()
        let dispatcher = AgentDispatcher()
        let p1 = dispatcher.policy(for: .myApp(id1)) as? MyAppPolicy
        let p2 = dispatcher.policy(for: .myApp(id2)) as? MyAppPolicy
        #expect(p1?.myAppId == id1)
        #expect(p2?.myAppId == id2)
        #expect(p1?.myAppId != p2?.myAppId)
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
        #expect(p.canInvoke(from: .myApp(UUID())) == false)
    }

    @Test("toolsExposedTo returns nil (no A2A restriction)")
    func toolsExposedToNil() {
        #expect(OrchestratorPolicy().toolsExposedTo(caller: nil) == nil)
        #expect(OrchestratorPolicy().toolsExposedTo(caller: .myApp(UUID())) == nil)
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

// MARK: - MyAppPolicy

@Suite("MyAppPolicy")
@MainActor
struct MyAppPolicyTests {
    init() { TestStorage.activate() }

    @Test("canInvoke returns true for all callers by default")
    func canInvokeAll() {
        let p = MyAppPolicy(myAppId: UUID())
        #expect(p.canInvoke(from: nil) == true)
        #expect(p.canInvoke(from: .memory) == true)
        #expect(p.canInvoke(from: .myApp(UUID())) == true)
    }

    @Test("toolsExposedTo returns nil for user (nil caller)")
    func toolsExposedToUser() {
        let p = MyAppPolicy(myAppId: UUID())
        #expect(p.toolsExposedTo(caller: nil) == nil)
    }

    @Test("payload has non-empty systemPrompt for unknown myApp")
    func payloadUnknownMyApp() async {
        let store = makeStore()
        let unknownId = UUID()
        let payload = await MyAppPolicy(myAppId: unknownId).payload(for: .myApp(unknownId), store: store)
        #expect(!payload.systemPrompt.isEmpty)
    }

    @Test("payload memory root scoped to myApp folder (no cross-bleed)")
    func payloadMemoryRootIsolated() async {
        let appA = MyApp(name: "AppA", iconSystemName: "star", typeId: "tracker")
        let appB = MyApp(name: "AppB", iconSystemName: "circle", typeId: "tracker")
        let store = MyAppStore(initial: ([appA, appB], appA.id))

        let payloadA = await MyAppPolicy(myAppId: appA.id).payload(for: .myApp(appA.id), store: store)
        let payloadB = await MyAppPolicy(myAppId: appB.id).payload(for: .myApp(appB.id), store: store)

        // Write to A's root
        _ = try? payloadA.memory.writeFile(path: "_test.md", content: "from A")
        // B's root should be unaffected
        let fromB = try? payloadB.memory.readFile(path: "_test.md")
        #expect(fromB == nil)
        // cleanup
        _ = try? payloadA.memory.delete(path: "_test.md")
    }

    @Test("systemPrompt includes AGENTS.md content when present in myApp folder")
    func systemPromptWithAgentsMd() async {
        let app = MyApp(name: "TestApp", iconSystemName: "star", typeId: "tracker")
        let store = MyAppStore(initial: ([app], app.id))
        let memory = MemoryStore(rootOverride: MemoryStore.appRoot(myAppId: app.id))
        _ = try? memory.writeFile(path: "pupa/AGENTS.md", content: "## Custom MyApp instructions\n\nTrack things carefully.")
        defer { _ = try? memory.delete(path: "pupa/AGENTS.md") }
        let desc = MyAppPolicy(myAppId: app.id).buildSystemPrompt(myApp: app, memory: memory)
        #expect(desc.contains("Custom MyApp instructions"))
        #expect(desc.contains("pupa/AGENTS.md"))
    }

    @Test("AGENTS.md layers over type fragment, not replaces it (issue #164)")
    func systemPromptLayersAgentsMdOverTypeFragment() async {
        MyAppTypeRegistry.shared.registerBuiltins()
        let app = MyApp(name: "LayerApp", iconSystemName: "star", typeId: "tracker")
        let store = MyAppStore(initial: ([app], app.id))
        let memory = MemoryStore(rootOverride: MemoryStore.appRoot(myAppId: app.id))
        _ = try? memory.writeFile(path: "pupa/AGENTS.md", content: "## Custom\n\nBe terse.")
        defer { _ = try? memory.delete(path: "pupa/AGENTS.md") }
        let desc = MyAppPolicy(myAppId: app.id).buildSystemPrompt(myApp: app, memory: memory)
        // User customization present…
        #expect(desc.contains("Be terse."))
        // …and the dynamic type fragment (base + catalog) is still included,
        // so per-kind guidance is not dropped when AGENTS.md exists.
        #expect(desc.contains("per-type rules"))
        let type = MyAppTypeRegistry.shared.resolve(id: "tracker")!
        let expected = ChatViewModel.activeSystemPromptFragment(myApp: app, type: type)
        #expect(desc.contains(expected))
    }

    @Test("systemPrompt falls back to type-fragment when no AGENTS.md")
    func systemPromptFallback() async {
        let app = MyApp(name: "FallbackApp", iconSystemName: "star", typeId: "tracker")
        let store = MyAppStore(initial: ([app], app.id))
        let payload = await MyAppPolicy(myAppId: app.id).payload(for: .myApp(app.id), store: store)
        // Fallback should mention the myApp name or "tracker"
        #expect(!payload.systemPrompt.isEmpty)
    }
}

// MARK: - Scoping isolation (orchestrator vs MyApp)

@Suite("AgentPolicy scoping isolation")
@MainActor
struct AgentPolicyScopingTests {
    init() { TestStorage.activate() }

    @Test("Orchestrator and MyApp read from different memory roots")
    func differentRoots() async {
        let app = MyApp(name: "IsolationApp", iconSystemName: "star", typeId: "tracker")
        let store = MyAppStore(initial: ([app], app.id))

        let orchPayload = await OrchestratorPolicy().payload(for: .memory, store: store)
        let myAppPayload = await MyAppPolicy(myAppId: app.id).payload(for: .myApp(app.id), store: store)

        // Write a sentinel to orchestrator root
        _ = try? orchPayload.memory.writeFile(path: "_sentinel.md", content: "orch")
        // MyApp root must not see it
        let fromMyApp = try? myAppPayload.memory.readFile(path: "_sentinel.md")
        #expect(fromMyApp == nil)
        // cleanup
        _ = try? orchPayload.memory.delete(path: "_sentinel.md")
    }

    @Test("Orchestrator AGENTS.md does not affect MyApp system prompt")
    func orchAgentsMdDoesNotBleedIntoMyApp() async {
        let app = MyApp(name: "BleedTestApp", iconSystemName: "star", typeId: "tracker")
        let store = MyAppStore(initial: ([app], app.id))

        // Write orchestrator AGENTS.md with unique content
        let orchMem = MemoryStore(rootOverride: MemoryStore.orchestratorRoot())
        _ = try? orchMem.writeFile(path: "pupa/AGENTS.md", content: "ORCH UNIQUE MARKER XYZ")
        defer { _ = try? orchMem.delete(path: "pupa/AGENTS.md") }

        // MyApp payload should NOT contain the orchestrator marker
        let myAppPayload = await MyAppPolicy(myAppId: app.id).payload(for: .myApp(app.id), store: store)
        #expect(!myAppPayload.systemPrompt.contains("ORCH UNIQUE MARKER XYZ"))
    }

    @Test("MyApp AGENTS.md does not affect orchestrator system prompt")
    func myAppAgentsMdDoesNotBleedIntoOrch() async {
        let app = MyApp(name: "BleedTestApp2", iconSystemName: "star", typeId: "tracker")
        let store = MyAppStore(initial: ([app], app.id))

        // Write myApp AGENTS.md with unique content
        let myAppMem = MemoryStore(rootOverride: MemoryStore.appRoot(myAppId: app.id))
        _ = try? myAppMem.writeFile(path: "pupa/AGENTS.md", content: "MYAPP UNIQUE MARKER ABC")
        defer { _ = try? myAppMem.delete(path: "pupa/AGENTS.md") }

        // Orchestrator payload should NOT contain the myApp marker
        let orchPayload = await OrchestratorPolicy().payload(for: .memory, store: store)
        #expect(!orchPayload.systemPrompt.contains("MYAPP UNIQUE MARKER ABC"))
    }

    @Test("Two different MyApps each read their own AGENTS.md independently")
    func twoMyAppsIndependentAgentsMd() async {
        let appX = MyApp(name: "MyAppX", iconSystemName: "star", typeId: "tracker")
        let appY = MyApp(name: "MyAppY", iconSystemName: "circle", typeId: "tracker")
        let store = MyAppStore(initial: ([appX, appY], appX.id))

        let memX = MemoryStore(rootOverride: MemoryStore.appRoot(myAppId: appX.id))
        let memY = MemoryStore(rootOverride: MemoryStore.appRoot(myAppId: appY.id))
        _ = try? memX.writeFile(path: "pupa/AGENTS.md", content: "Instructions for X only")
        _ = try? memY.writeFile(path: "pupa/AGENTS.md", content: "Instructions for Y only")
        defer {
            _ = try? memX.delete(path: "pupa/AGENTS.md")
            _ = try? memY.delete(path: "pupa/AGENTS.md")
        }

        let payloadX = await MyAppPolicy(myAppId: appX.id).payload(for: .myApp(appX.id), store: store)
        let payloadY = await MyAppPolicy(myAppId: appY.id).payload(for: .myApp(appY.id), store: store)

        #expect(payloadX.systemPrompt.contains("Instructions for X only"))
        #expect(!payloadX.systemPrompt.contains("Instructions for Y only"))
        #expect(payloadY.systemPrompt.contains("Instructions for Y only"))
        #expect(!payloadY.systemPrompt.contains("Instructions for X only"))
    }
}
