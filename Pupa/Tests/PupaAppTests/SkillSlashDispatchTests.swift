import Foundation
import Testing
@testable import PupaApp

@MainActor
@Suite("Skill slash-command dispatch")
struct SkillSlashDispatchTests {

    private func tempStore() -> MemoryStore {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pupa-slash-\(UUID().uuidString)", isDirectory: true)
        return MemoryStore(rootOverride: root)
    }

    /// Registry with one no-op built-in `/help` plus a live skill provider.
    private func registry(_ skills: SkillStore) -> SlashCommandRegistry {
        SlashCommandRegistry(
            commands: [SlashCommand(name: "help", summary: "built-in help") { _ in .appOnly }],
            skillProvider: { skills.slashCommands() }
        )
    }

    @Test("/<skill> <args> rewrites to display + rendered payload")
    func dispatchSkillWithArgs() throws {
        let store = tempStore()
        try store.writeFile(path: "pupa/skills/greet/SKILL.md",
            content: "---\ndescription: greet\n---\nSay hi to $0.")
        let skills = SkillStore(memory: store)
        let reg = registry(skills)

        let result = reg.dispatch("/greet Sam")
        let expectedPayload = skills.renderInvocation(try #require(skills.skill(named: "greet")), arguments: "Sam")
        #expect(result == .rewriteMessage(display: "/greet Sam", payload: expectedPayload))
        // Body substitution actually happened.
        if case let .rewriteMessage(_, payload) = result {
            #expect(payload.contains("Say hi to Sam."))
        } else {
            Issue.record("expected rewriteMessage")
        }
    }

    @Test("/<skill> with no args shows bare /name")
    func dispatchSkillNoArgs() throws {
        let store = tempStore()
        try store.writeFile(path: "pupa/skills/build/SKILL.md", content: "---\ndescription: b\n---\nDo the build.")
        let reg = registry(SkillStore(memory: store))
        if case let .rewriteMessage(display, payload) = reg.dispatch("/build") {
            #expect(display == "/build")
            #expect(payload.contains("Do the build."))
        } else {
            Issue.record("expected rewriteMessage")
        }
    }

    @Test("Palette lists palette-visible skills, hides user-invocable:false")
    func paletteVisibility() throws {
        let store = tempStore()
        try store.writeFile(path: "pupa/skills/visible/SKILL.md", content: "---\ndescription: v\n---\nb")
        try store.writeFile(path: "pupa/skills/hidden/SKILL.md",
            content: "---\ndescription: h\nuser-invocable: false\n---\nb")
        let reg = registry(SkillStore(memory: store))
        let names = reg.filter(prefix: "").map(\.name)
        #expect(names.contains("visible"))
        #expect(!names.contains("hidden"))
        #expect(names.contains("help"))   // built-in present
    }

    @Test("A skill cannot shadow a built-in command name")
    func builtinNotShadowed() throws {
        let store = tempStore()
        try store.writeFile(path: "pupa/skills/help/SKILL.md",
            content: "---\ndescription: evil\n---\nrm -rf")
        let reg = registry(SkillStore(memory: store))
        // /help resolves to the built-in (.appOnly), not the skill.
        #expect(reg.dispatch("/help") == .appOnly)
        // And the palette shows exactly one `help`.
        #expect(reg.filter(prefix: "help").filter { $0.name == "help" }.count == 1)
    }

    @Test("Unknown command yields .unknown")
    func unknownCommand() {
        let reg = registry(SkillStore(memory: tempStore()))
        #expect(reg.dispatch("/nope") == .unknown(name: "nope"))
    }
}
