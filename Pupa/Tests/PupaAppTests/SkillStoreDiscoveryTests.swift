import Foundation
import Testing
@testable import PupaApp

@MainActor
@Suite("SkillStore discovery")
struct SkillStoreDiscoveryTests {

    private func tempStore() -> MemoryStore {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pupa-skills-\(UUID().uuidString)", isDirectory: true)
        return MemoryStore(rootOverride: root)
    }

    @Test("Discovers a skill at pupa/skills/<name>/SKILL.md")
    func discoversSkill() throws {
        let store = tempStore()
        try store.writeFile(
            path: "pupa/skills/greet/SKILL.md",
            content: "---\ndescription: Greet the user\nwhen_to_use: on hello\n---\nSay hi to $0."
        )
        let skills = SkillStore(memory: store)
        #expect(skills.skills.count == 1)
        let s = try #require(skills.skill(named: "greet"))
        #expect(s.description == "Greet the user")
        #expect(s.whenToUse == "on hello")
        #expect(s.body == "Say hi to $0.")
        #expect(s.sourcePath == "pupa/skills/greet/SKILL.md")
    }

    @Test("Ignores non-SKILL.md files, supporting files, and files outside pupa/skills")
    func ignoresNonSkillFiles() throws {
        let store = tempStore()
        try store.writeFile(path: "pupa/skills/deploy/SKILL.md", content: "---\ndescription: d\n---\nbody")
        try store.writeFile(path: "pupa/skills/deploy/reference.md", content: "supporting")
        try store.writeFile(path: "pupa/skills/deploy/scripts/run.md", content: "nested")
        try store.writeFile(path: "pupa/AGENTS.md", content: "main prompt")
        try store.writeFile(path: "notes/todo.md", content: "user content")
        let skills = SkillStore(memory: store)
        #expect(skills.skills.map(\.name) == ["deploy"])
    }

    @Test("disable-model-invocation and user-invocable drive visibility")
    func visibilityFlags() throws {
        let store = tempStore()
        try store.writeFile(path: "pupa/skills/cmd/SKILL.md",
            content: "---\ndescription: user-only\ndisable-model-invocation: true\n---\nb")
        try store.writeFile(path: "pupa/skills/bg/SKILL.md",
            content: "---\ndescription: model-only\nuser-invocable: false\n---\nb")
        try store.writeFile(path: "pupa/skills/both/SKILL.md",
            content: "---\ndescription: both\n---\nb")
        let skills = SkillStore(memory: store)
        #expect(Set(skills.paletteSkills().map(\.name)) == ["cmd", "both"])
        #expect(Set(skills.modelContextSkills().map(\.name)) == ["bg", "both"])
    }

    @Test("rescan() picks up a newly written skill")
    func rescanPicksUpNewSkill() throws {
        let store = tempStore()
        let skills = SkillStore(memory: store)
        #expect(skills.skills.isEmpty)
        try store.writeFile(path: "pupa/skills/new/SKILL.md", content: "---\ndescription: n\n---\nb")
        skills.rescan()
        #expect(skills.skills.map(\.name) == ["new"])
    }

    @Test("substitute fills $ARGUMENTS and positional $N tokens")
    func substitution() {
        #expect(SkillStore.substitute("Deploy $ARGUMENTS now", arguments: "prod fast")
            == "Deploy prod fast now")
        #expect(SkillStore.substitute("first=$0 second=$1", arguments: "a b")
            == "first=a second=b")
        // Quoted span is one token.
        #expect(SkillStore.substitute("x=$0", arguments: "\"hello world\" y")
            == "x=hello world")
        // No placeholder + non-empty args → appended.
        #expect(SkillStore.substitute("Just do it.", arguments: "ARG")
            == "Just do it.\n\nARGUMENTS: ARG")
        // No placeholder + empty args → unchanged.
        #expect(SkillStore.substitute("Just do it.", arguments: "") == "Just do it.")
    }
}
