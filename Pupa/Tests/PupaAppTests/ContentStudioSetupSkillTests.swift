import Foundation
import Testing
@testable import PupaApp

@MainActor
@Suite("Content Studio setup skill")
struct ContentStudioSetupSkillTests {

    @Test("seedAgentsMd writes a discoverable /setup skill, not a root SETUP.md")
    func setupIsASkill() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pupa-cs-\(UUID().uuidString)", isDirectory: true)
        let mem = MemoryStore(rootOverride: root)
        ContentStudioExample.seedAgentsMd(globalMemory: mem, appRootOverride: root)

        #expect(mem.fileExists(at: "pupa/skills/setup/SKILL.md"))
        #expect(!mem.fileExists(at: "SETUP.md"))          // no legacy root playbook

        let skill = try #require(SkillStore(memory: mem).skill(named: "setup"))
        #expect(skill.paletteVisible)                      // /setup available in chat
        #expect(skill.description.contains("reels"))       // frontmatter parsed
        #expect(skill.body.contains("Reels backend setup")) // playbook body present
    }
}
