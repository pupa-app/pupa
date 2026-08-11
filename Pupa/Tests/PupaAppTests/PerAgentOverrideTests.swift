import Foundation
import Testing
import AGUIKit
@testable import PupaApp

/// Per-agent model + tool overrides: storage round-trips, the `forwardedProps`
/// LLM payload shape, and the descriptor summaries shown on the Agents page.
/// The per-agent disabled set is **additive** — unioned with the global
/// Settings → Tools set at send time, never an override. See
/// [docs/architecture.md → Per-agent overrides].
@MainActor
@Suite("Per-agent model + tool overrides")
struct PerAgentOverrideTests {

    private func freshStore() -> (MyAppStore, MyApp) {
        MyAppTypeRegistry.shared.registerBuiltins()
        let myApp = MyApp(name: "T", iconSystemName: "list.bullet.rectangle", typeId: "tracker")
        let store = MyAppStore(initial: ([myApp], myApp.id))
        return (store, myApp)
    }

    @Test("Main-agent disabled tools round-trip through MyApp.settings as a stringArray")
    func myAppDisabledToolsRoundTrip() {
        let (store, myApp) = freshStore()
        #expect(store.myAppDisabledTools(for: myApp.id).isEmpty)

        store.setMyAppDisabledTools(["mcp_playwright", "tavily_search"], for: myApp.id)
        #expect(store.myAppDisabledTools(for: myApp.id) == ["mcp_playwright", "tavily_search"])

        // Stored as a SettingValue.stringArray under the documented key.
        if case .stringArray(let names) = store.myApps.first!.settings[MyAppStore.disabledToolsSettingsKey] {
            #expect(Set(names) == ["mcp_playwright", "tavily_search"])
        } else {
            Issue.record("expected stringArray under \(MyAppStore.disabledToolsSettingsKey)")
        }

        // Clearing removes the key entirely.
        store.setMyAppDisabledTools([], for: myApp.id)
        #expect(store.myAppDisabledTools(for: myApp.id).isEmpty)
        #expect(store.myApps.first!.settings[MyAppStore.disabledToolsSettingsKey] == nil)
    }

    @Test("Subagent disabled tools round-trip through its AGENTS.md frontmatter")
    func subagentDisabledToolsRoundTrip() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pupa-override-\(UUID().uuidString)", isDirectory: true)
        let agents = AgentStore(memory: MemoryStore(rootOverride: root))
        try agents.createAgent(name: "Scout", description: "researcher", prompt: "Find things.")

        try agents.setDisabledTools(slug: "scout", ["sendNotification"])
        #expect(agents.agent(named: "scout")?.disabledTools == ["sendNotification"])
        // Persona body is preserved across the frontmatter rewrite.
        #expect(agents.agent(named: "scout")?.body.contains("Find things.") == true)

        // Empty clears back to nil (no per-agent overrides).
        try agents.setDisabledTools(slug: "scout", [])
        #expect(agents.agent(named: "scout")?.disabledTools == nil)
    }

    @Test("Subagent model override round-trips through frontmatter and clears")
    func subagentModelRoundTrip() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pupa-override-\(UUID().uuidString)", isDirectory: true)
        let agents = AgentStore(memory: MemoryStore(rootOverride: root))
        try agents.createAgent(name: "Scout", description: "researcher", prompt: "Find things.")

        try agents.setModel(slug: "scout", provider: "anthropic", model: "claude-opus-4-8")
        #expect(agents.agent(named: "scout")?.llmSelection?.provider == "anthropic")
        #expect(agents.agent(named: "scout")?.llmSelection?.model == "claude-opus-4-8")

        try agents.setModel(slug: "scout", provider: nil, model: nil)
        #expect(agents.agent(named: "scout")?.llmSelection == nil)
    }

    @Test("llmForwardedProps builds {llm:{provider,model}} or empty when unset")
    func forwardedPropsShape() {
        #expect(ChatSessionCoordinator.llmForwardedProps(nil) == .object([:]))

        let props = ChatSessionCoordinator.llmForwardedProps((provider: "anthropic", model: "claude-sonnet-4-6"))
        #expect(props == .object([
            "llm": .object([
                "provider": .string("anthropic"),
                "model": .string("claude-sonnet-4-6"),
            ])
        ]))
    }

    @Test("toolSummaryText reflects allowed count and how many are off")
    func toolSummaryText() {
        #expect(AgentRegistry.toolSummaryText(allowed: 12, disabled: 0) == "12 tools")
        #expect(AgentRegistry.toolSummaryText(allowed: 12, disabled: 2) == "12 tools · 2 off")
        #expect(AgentRegistry.toolSummaryText(allowed: 1, disabled: 0) == "1 tool")
    }

    // MARK: - Per-thread model override

    @Test("Per-thread LLM override round-trips and clears atomically")
    func threadLLMRoundTrip() {
        let (store, myApp) = freshStore()
        let scope: ChatScope = .myApp(myApp.id)
        let tid = store.addThread(for: scope)
        #expect(store.threadLLM(threadId: tid, for: scope) == nil)

        store.setThreadLLM(provider: "anthropic", model: "claude-opus-4-8", threadId: tid, for: scope)
        let got = store.threadLLM(threadId: tid, for: scope)
        #expect(got?.provider == "anthropic")
        #expect(got?.model == "claude-opus-4-8")

        // Nil either field clears both.
        store.setThreadLLM(provider: nil, model: nil, threadId: tid, for: scope)
        #expect(store.threadLLM(threadId: tid, for: scope) == nil)
    }

    @Test("forwardedProps prefers the thread pin over the MyApp default, independent of later default changes")
    func threadOverridePrecedence() {
        let (store, myApp) = freshStore()
        let settings = SettingsStore(backendURL: URL(string: "http://localhost:65535/")!)
        let scope: ChatScope = .myApp(myApp.id)
        let tid = store.addThread(for: scope)

        func props() -> AnyJSON {
            ChatViewModel.forwardedPropsJSON(scope: scope, threadId: tid, store: store, settings: settings)
        }
        func llm(_ provider: String, _ model: String) -> AnyJSON {
            .object(["llm": .object(["provider": .string(provider), "model": .string(model)])])
        }

        // No thread pin → inherits the MyApp default (A).
        store.setMyAppLLM(provider: "anthropic", model: "claude-sonnet-4-6", for: myApp.id)
        #expect(props() == llm("anthropic", "claude-sonnet-4-6"))

        // Pin the thread to B → B wins.
        store.setThreadLLM(provider: "bedrock", model: "claude-opus-4-8", threadId: tid, for: scope)
        #expect(props() == llm("bedrock", "claude-opus-4-8"))

        // Change the MyApp default to C → pinned thread is unaffected.
        store.setMyAppLLM(provider: "openai_compatible", model: "gpt-x", for: myApp.id)
        #expect(props() == llm("bedrock", "claude-opus-4-8"))

        // Clear the pin → re-inherits the current default (C).
        store.setThreadLLM(provider: nil, model: nil, threadId: tid, for: scope)
        #expect(props() == llm("openai_compatible", "gpt-x"))
    }

    @Test("forwardedProps is empty when neither thread nor MyApp sets a model")
    func threadNoOverrideEmpty() {
        let (store, myApp) = freshStore()
        let settings = SettingsStore(backendURL: URL(string: "http://localhost:65535/")!)
        let scope: ChatScope = .myApp(myApp.id)
        let tid = store.addThread(for: scope)
        #expect(ChatViewModel.forwardedPropsJSON(scope: scope, threadId: tid, store: store, settings: settings) == .object([:]))
    }

    // MARK: - Per-agent thinking override

    @Test("Per-MyApp thinking level round-trips and clears")
    func myAppThinkingRoundTrip() {
        let (store, myApp) = freshStore()
        #expect(store.myAppThinking(for: myApp.id) == nil)

        store.setMyAppThinking("high", for: myApp.id)
        #expect(store.myAppThinking(for: myApp.id) == "high")

        store.setMyAppThinking(nil, for: myApp.id)
        #expect(store.myAppThinking(for: myApp.id) == nil)
        // Empty string also clears.
        store.setMyAppThinking("low", for: myApp.id)
        store.setMyAppThinking("", for: myApp.id)
        #expect(store.myAppThinking(for: myApp.id) == nil)
    }

    @Test("forwardedProps folds thinking into the llm object alongside the model")
    func forwardedPropsCarriesThinking() {
        let (store, myApp) = freshStore()
        let settings = SettingsStore(backendURL: URL(string: "http://localhost:65535/")!)
        let scope: ChatScope = .myApp(myApp.id)
        let tid = store.addThread(for: scope)

        store.setMyAppLLM(provider: "anthropic", model: "claude-sonnet-4-6", for: myApp.id)
        store.setMyAppThinking("auto", for: myApp.id)
        #expect(ChatViewModel.forwardedPropsJSON(scope: scope, threadId: tid, store: store, settings: settings)
            == .object(["llm": .object([
                "provider": .string("anthropic"),
                "model": .string("claude-sonnet-4-6"),
                "thinking": .string("auto"),
            ])]))
    }

    @Test("thinking ships even with no model override (llm carries just thinking)")
    func forwardedPropsThinkingOnly() {
        let (store, myApp) = freshStore()
        let settings = SettingsStore(backendURL: URL(string: "http://localhost:65535/")!)
        let scope: ChatScope = .myApp(myApp.id)
        let tid = store.addThread(for: scope)

        store.setMyAppThinking("off", for: myApp.id)
        #expect(ChatViewModel.forwardedPropsJSON(scope: scope, threadId: tid, store: store, settings: settings)
            == .object(["llm": .object(["thinking": .string("off")])]))
    }

    @Test("clearThinkingLevels drops stale overrides but never wipes on an empty set")
    func clearStaleThinking() {
        let (store, myApp) = freshStore()
        store.setMyAppThinking("high", for: myApp.id)

        // Empty set (harness has no thinking / unreachable) → no-op, keeps value.
        #expect(store.clearThinkingLevels(notIn: []) == false)
        #expect(store.myAppThinking(for: myApp.id) == "high")

        // Non-empty set that still contains the level → kept.
        #expect(store.clearThinkingLevels(notIn: ["auto", "high"]) == false)
        #expect(store.myAppThinking(for: myApp.id) == "high")

        // Non-empty set missing the level → cleared.
        #expect(store.clearThinkingLevels(notIn: ["auto", "off"]) == true)
        #expect(store.myAppThinking(for: myApp.id) == nil)
    }

    @Test("No thinking row when the active harness advertises no levels")
    @MainActor
    func thinkingHiddenWhenHarnessHasNoLevels() {
        let (store, myApp) = freshStore()
        let settings = SettingsStore(backendURL: URL(string: "http://localhost:65535/")!)
        // Fresh catalog: no successful refresh → thinkingLevels empty.
        let catalog = ModelCatalogStore()
        #expect(catalog.thinkingLevels.isEmpty)

        let agents = AgentRegistry.enumerateAgents(myApp: myApp, store: store, settings: settings, catalog: catalog)
        let main = agents.first { $0.kind == .myApp }
        // Building the page must not crash and must omit the thinking picker.
        #expect(main != nil)
        #expect(main?.properties.contains { $0.id == "thinking" } == false)
    }

    @Test("Orchestrator thinking round-trips and rides memory-scope forwardedProps")
    func orchestratorThinking() {
        let (store, _) = freshStore()
        let settings = SettingsStore(backendURL: URL(string: "http://localhost:65535/")!)
        #expect(settings.orchestratorThinking == nil)

        settings.setOrchestratorThinking("medium")
        #expect(settings.orchestratorThinking == "medium")

        let scope: ChatScope = .memory
        let tid = store.memoryCurrentThreadId
        #expect(ChatViewModel.forwardedPropsJSON(scope: scope, threadId: tid, store: store, settings: settings)
            == .object(["llm": .object(["thinking": .string("medium")])]))

        settings.setOrchestratorThinking(nil)
        #expect(settings.orchestratorThinking == nil)
    }

    @Test("ChatThread without llm fields decodes to nil (back-compat); with fields round-trips")
    func chatThreadCodable() throws {
        let legacy = #"{"id":"t1","title":"Old","createdAt":0}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(ChatThread.self, from: legacy)
        #expect(decoded.llmProvider == nil)
        #expect(decoded.llmModel == nil)

        let pinned = ChatThread(id: "t2", title: "X", llmProvider: "anthropic", llmModel: "claude-opus-4-8")
        let back = try JSONDecoder().decode(ChatThread.self, from: JSONEncoder().encode(pinned))
        #expect(back.llmProvider == "anthropic")
        #expect(back.llmModel == "claude-opus-4-8")
    }
}
