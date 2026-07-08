import Foundation
import Testing
@testable import PupaApp

@MainActor
@Suite("Default skills")
struct DefaultSkillsTests {

    private func freshStore() -> MemoryStore {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pupa-defskills-\(UUID().uuidString)", isDirectory: true)
        return MemoryStore(rootOverride: root)
    }

    @Test("seed writes a discoverable /to-memory skill targeting pupa/MEMORIES.md")
    func toMemorySeeded() throws {
        let mem = freshStore()

        #expect(DefaultSkills.seed(into: mem))                      // wrote on first seed
        #expect(mem.fileExists(at: "pupa/skills/to-memory/SKILL.md"))

        let skill = try #require(SkillStore(memory: mem).skill(named: "to-memory"))
        #expect(skill.paletteVisible)                              // /to-memory in chat palette
        #expect(skill.description.contains("MEMORIES.md"))         // frontmatter parsed
        #expect(skill.body.contains("pupa/MEMORIES.md"))          // playbook targets the file

        // /pupa-internals is retired — replaced by the GuideSkills plugin.
        #expect(!mem.fileExists(at: "pupa/skills/pupa-internals/SKILL.md"))
    }

    @Test("seed is idempotent — never clobbers an existing file")
    func idempotent() throws {
        let mem = freshStore()
        #expect(DefaultSkills.seed(into: mem))                     // first seed writes all defaults
        _ = try mem.writeFile(path: "pupa/skills/to-memory/SKILL.md", content: "edited")

        #expect(!DefaultSkills.seed(into: mem))                    // all present — nothing re-written
        let body = try mem.readFile(path: "pupa/skills/to-memory/SKILL.md").content
        #expect(body == "edited")                                 // user/agent edit survives
    }
}
