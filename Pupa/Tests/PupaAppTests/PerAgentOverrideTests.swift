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
}
