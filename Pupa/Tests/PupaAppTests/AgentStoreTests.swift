import Foundation
import Testing
@testable import PupaApp

@MainActor
@Suite("AgentStore discovery + writer")
struct AgentStoreTests {

    private func tempStore() -> MemoryStore {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pupa-agents-\(UUID().uuidString)", isDirectory: true)
        return MemoryStore(rootOverride: root)
    }

    @Test("Discovers a subagent at pupa/agents/<slug>/AGENTS.md")
    func discoversAgent() throws {
        let store = tempStore()
        try store.writeFile(
            path: "pupa/agents/researcher/AGENTS.md",
            content: """
            ---
            name: Researcher
            description: Finds sources
            when_to_use: research tasks
            tools: getCanvasState, renderTracker
            model: claude-sonnet-5
            provider: anthropic
            ---
            You are a meticulous researcher.
            """
        )
        let agents = AgentStore(memory: store)
        #expect(agents.agents.count == 1)
        let a = try #require(agents.agent(named: "researcher"))
        #expect(a.displayName == "Researcher")
        #expect(a.description == "Finds sources")
        #expect(a.whenToUse == "research tasks")
        #expect(a.tools == ["getCanvasState", "renderTracker"])
        #expect(a.model == "claude-sonnet-5")
        #expect(a.provider == "anthropic")
        #expect(a.llmSelection?.provider == "anthropic")
        #expect(a.body == "You are a meticulous researcher.")
        #expect(a.sourcePath == "pupa/agents/researcher/AGENTS.md")
    }

    @Test("Ignores the main AGENTS.md, notes, and files outside pupa/agents")
    func ignoresNonAgentFiles() throws {
        let store = tempStore()
        try store.writeFile(path: "pupa/agents/coach/AGENTS.md", content: "---\ndescription: d\n---\nbody")
        try store.writeFile(path: "pupa/agents/coach/notes.md", content: "private notes")
        try store.writeFile(path: "pupa/AGENTS.md", content: "main prompt")   // not a subagent
        try store.writeFile(path: "pupa/skills/deploy/SKILL.md", content: "---\n---\nx")
        try store.writeFile(path: "notes/todo.md", content: "user content")
        let agents = AgentStore(memory: store)
        #expect(agents.agents.map(\.name) == ["coach"])
    }

    @Test("nil tools when frontmatter omits it (inherit full surface)")
    func inheritsWhenNoTools() throws {
        let store = tempStore()
        try store.writeFile(path: "pupa/agents/plain/AGENTS.md", content: "---\ndescription: d\n---\nb")
        let a = try #require(AgentStore(memory: store).agent(named: "plain"))
        #expect(a.tools == nil)
        #expect(a.disabledTools == nil)
        #expect(a.llmSelection == nil)
    }

    @Test("createAgent writes a round-trippable AGENTS.md and rescans")
    func createAgentRoundTrips() throws {
        let store = tempStore()
        let agents = AgentStore(memory: store)
        #expect(agents.agents.isEmpty)
        let slug = try agents.createAgent(
            name: "Trend Scout",
            description: "Spots trends",
            prompt: "Watch the feeds.",
            tools: ["getCanvasState"],
            model: "claude-opus-4-8",
            provider: "anthropic"
        )
        #expect(slug == "trend-scout")
        let a = try #require(agents.agent(named: "trend-scout"))
        #expect(a.displayName == "Trend Scout")
        #expect(a.description == "Spots trends")
        #expect(a.tools == ["getCanvasState"])
        #expect(a.model == "claude-opus-4-8")
        #expect(a.body.trimmingCharacters(in: .newlines) == "Watch the feeds.")
        // Also resolvable by the un-slugified display name.
        #expect(agents.agent(named: "Trend Scout")?.name == "trend-scout")
    }

    @Test("rescan() picks up a newly written subagent")
    func rescanPicksUpNewAgent() throws {
        let store = tempStore()
        let agents = AgentStore(memory: store)
        #expect(agents.agents.isEmpty)
        try store.writeFile(path: "pupa/agents/new/AGENTS.md", content: "---\ndescription: n\n---\nb")
        agents.rescan()
        #expect(agents.agents.map(\.name) == ["new"])
    }
}
