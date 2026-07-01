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

    @Test("Slack sub-agent disabled tools round-trip on the SlackAgent struct")
    func slackAgentDisabledToolsRoundTrip() {
        let (store, myApp) = freshStore()
        guard let componentId = store.addComponent(kind: "slack", name: "Team", iconSystemName: "bubble.left", myAppId: myApp.id) else {
            Issue.record("addComponent returned nil")
            return
        }
        guard let agentId = store.slackAddAgent(name: "Scout", role: "researcher", systemPromptAddition: "", myAppId: myApp.id, componentId: componentId) else {
            Issue.record("slackAddAgent returned nil")
            return
        }

        func storedAgent() -> SlackAgent? {
            store.myApps.first!.components
                .first(where: { $0.id == componentId })
                .flatMap { if case .slack(let s) = $0.body { return s.agents.first(where: { $0.id == agentId }) } else { return nil } }
        }

        store.setSlackAgentDisabledTools(["sendNotification"], componentId: componentId, agentId: agentId, myAppId: myApp.id)
        #expect(storedAgent()?.disabledTools == ["sendNotification"])

        // Empty clears back to nil (no per-agent overrides).
        store.setSlackAgentDisabledTools([], componentId: componentId, agentId: agentId, myAppId: myApp.id)
        #expect(storedAgent()?.disabledTools == nil)
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

    @Test("SlackAgent without disabledTools decodes cleanly (back-compat)")
    func slackAgentBackCompatDecode() throws {
        // A pre-existing blob lacking the new key.
        let json = """
        {"id":"a1","name":"Old","role":"","systemPromptAddition":""}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(SlackAgent.self, from: json)
        #expect(decoded.disabledTools == nil)
        #expect(decoded.llmProvider == nil)
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
