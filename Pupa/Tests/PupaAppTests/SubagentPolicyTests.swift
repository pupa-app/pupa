import Foundation
import Testing
@testable import PupaApp

@Suite("SubagentPolicy tool narrowing")
struct SubagentPolicyTests {

    private func agent(tools: [String]? = nil, disabled: [String]? = nil) -> Subagent {
        Subagent(name: "x", tools: tools, disabledTools: disabled, sourcePath: "pupa/agents/x/AGENTS.md")
    }

    @Test("nil tools inherits the base surface plus invoke_agent")
    func inheritsBase() {
        let base: Set<String> = ["getCanvasState", "renderTracker"]
        let result = SubagentPolicy.narrowedTools(base: base, subagent: agent())
        #expect(result == ["getCanvasState", "renderTracker", "invoke_agent"])
    }

    @Test("tools allowlist intersects the base surface")
    func allowlistIntersects() {
        let base: Set<String> = ["a", "b", "c"]
        let result = SubagentPolicy.narrowedTools(base: base, subagent: agent(tools: ["a", "b", "zzz"]))
        // zzz isn't in base → dropped; invoke_agent always added.
        #expect(result == ["a", "b", "invoke_agent"])
    }

    @Test("disabled_tools are subtracted")
    func disabledSubtracted() {
        let base: Set<String> = ["a", "b"]
        let result = SubagentPolicy.narrowedTools(base: base, subagent: agent(disabled: ["a"]))
        #expect(result == ["b", "invoke_agent"])
    }

    @Test("main-chat-only excluded tools are stripped from a subagent")
    func excludedStripped() {
        let base: Set<String> = ["getCanvasState", "slackCreateChannels", "slackAddAgentsToChannel"]
        let result = SubagentPolicy.narrowedTools(base: base, subagent: agent())
        #expect(!result.contains("slackCreateChannels"))
        #expect(!result.contains("slackAddAgentsToChannel"))
        #expect(result.contains("getCanvasState"))
        #expect(result.contains("invoke_agent"))
    }

    @Test("disabling invoke_agent removes A2A")
    func disableA2A() {
        let base: Set<String> = ["a"]
        let result = SubagentPolicy.narrowedTools(base: base, subagent: agent(disabled: ["invoke_agent"]))
        #expect(!result.contains("invoke_agent"))
        #expect(result == ["a"])
    }
}
