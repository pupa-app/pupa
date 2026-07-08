import Foundation
import Testing
@testable import PupaApp

@MainActor
@Suite("Guide skills")
struct GuideSkillsTests {

    private func freshStore() -> MemoryStore {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pupa-guideskills-\(UUID().uuidString)", isDirectory: true)
        return MemoryStore(rootOverride: root)
    }

    private let allNames = ["pupa", "pupa-components", "pupa-sharing", "pupa-memory", "pupa-agents", "pupa-system"]

    private func pluginPath(_ name: String) -> String {
        "\(GuideSkills.pluginDir)/skills/\(name)/SKILL.md"
    }

    @Test("seed writes every guide skill, discoverable and mother names each child")
    func seedsAll() throws {
        let mem = freshStore()
        #expect(GuideSkills.seed(into: mem))

        let store = SkillStore(memory: mem)
        for name in allNames {
            let skill = try #require(store.skill(named: name), "missing \(name)")
            #expect(skill.paletteVisible)   // user-invocable /command
            #expect(skill.modelVisible)     // loadable via app_skill_view
            #expect(!skill.description.isEmpty)
        }
        let mother = try #require(store.skill(named: "pupa"))
        for child in allNames.dropFirst() {
            #expect(mother.body.contains(child), "mother must point at \(child)")
        }
    }

    @Test("idempotent at same version — no rewrite, body edits survive")
    func idempotentAtSameVersion() throws {
        let mem = freshStore()
        #expect(GuideSkills.seed(into: mem))

        // Edit a body below an up-to-date version line: must survive a reseed.
        let path = pluginPath("pupa-memory")
        let edited = """
        ---
        description: edited
        version: \(GuideSkills.version)
        ---
        my notes
        """
        _ = try mem.writeFile(path: path, content: edited)

        #expect(!GuideSkills.seed(into: mem))
        #expect(try mem.readFile(path: path).content == edited)
    }

    @Test("older or missing version is overwritten")
    func versionBumpOverwrites() throws {
        let mem = freshStore()
        #expect(GuideSkills.seed(into: mem))

        let path = pluginPath("pupa")
        _ = try mem.writeFile(path: path, content: "---\ndescription: stale\nversion: 0\n---\nold")
        #expect(GuideSkills.seed(into: mem))
        #expect(try mem.readFile(path: path).content.contains("version: \(GuideSkills.version)"))

        _ = try mem.writeFile(path: path, content: "no frontmatter at all")
        #expect(GuideSkills.seed(into: mem))
        #expect(try mem.readFile(path: path).content.contains("version: \(GuideSkills.version)"))
    }

    @Test("deleted guide skill resurrects on next seed (managed, unlike DefaultSkills)")
    func deletionResurrects() throws {
        let mem = freshStore()
        #expect(GuideSkills.seed(into: mem))
        try mem.delete(path: "\(GuideSkills.pluginDir)/skills/pupa-sharing", recursive: true)
        #expect(!mem.fileExists(at: pluginPath("pupa-sharing")))

        #expect(GuideSkills.seed(into: mem))
        #expect(mem.fileExists(at: pluginPath("pupa-sharing")))
    }

    @Test("legacy root-level guide copies (managed version: frontmatter) migrate into the plugin")
    func migratesLegacyRootGuideSkills() throws {
        let mem = freshStore()
        // A pre-plugin build seeded the guide at the root of pupa/skills/.
        _ = try mem.writeFile(
            path: "pupa/skills/pupa/SKILL.md",
            content: "---\ndescription: old guide\nversion: 2\n---\nold"
        )
        // A user skill that happens to share a guide name but has no managed
        // version marker must NOT be swept.
        _ = try mem.writeFile(path: "pupa/skills/pupa-memory/SKILL.md", content: "---\ndescription: mine\n---\nkeep")

        #expect(GuideSkills.seed(into: mem))
        #expect(!mem.fileExists(at: "pupa/skills/pupa/SKILL.md"))
        #expect(try mem.readFile(path: "pupa/skills/pupa-memory/SKILL.md").content.contains("keep"))
        #expect(mem.fileExists(at: pluginPath("pupa")))
    }

    @Test("user skill wins a name collision with a plugin skill")
    func userSkillWinsCollision() throws {
        let mem = freshStore()
        #expect(GuideSkills.seed(into: mem))
        _ = try mem.writeFile(path: "pupa/skills/pupa-sharing/SKILL.md", content: "---\ndescription: mine\n---\nuser version")

        let skill = try #require(SkillStore(memory: mem).skill(named: "pupa-sharing"))
        #expect(skill.body.contains("user version"))
        #expect(skill.sourcePath.hasPrefix("pupa/skills/"))
    }

    @Test("pristine seeded pupa-internals is removed; user-modified copy is left")
    func migratesAwayPupaInternals() throws {
        let pristine = freshStore()
        _ = try pristine.writeFile(
            path: "pupa/skills/pupa-internals/SKILL.md",
            content: DefaultSkills.retiredPupaInternalsSkillMd
        )
        #expect(GuideSkills.seed(into: pristine))
        #expect(!pristine.fileExists(at: "pupa/skills/pupa-internals/SKILL.md"))

        let modified = freshStore()
        _ = try modified.writeFile(path: "pupa/skills/pupa-internals/SKILL.md", content: "customised")
        #expect(GuideSkills.seed(into: modified))
        #expect(try modified.readFile(path: "pupa/skills/pupa-internals/SKILL.md").content == "customised")
    }

    @Test("every supported component kind and its blurb appears in pupa-components")
    func componentKindsDoNotDrift() throws {
        let mem = freshStore()
        #expect(GuideSkills.seed(into: mem))
        let body = try #require(SkillStore(memory: mem).skill(named: "pupa-components")).body

        let type = MyAppType.tracker
        for kind in type.supportedComponentKinds {
            #expect(body.contains("**\(kind)**"), "kind \(kind) missing from guide")
            let blurb = try #require(type.kinds[kind]?.catalogBlurb)
            #expect(body.contains(blurb), "blurb for \(kind) missing from guide")
        }
    }

    @Test("no implementation internals leak into any guide body")
    func noInternalsLeak() throws {
        let banned = [
            ".swift", "MemoryStore", "SkillStore", "CanvasState", "ViewModel",
            "SSE", "AG-UI", "~/Library", "writeMemoryFile", "JSON-Schema",
        ]
        for (dir, body) in GuideSkills.files() {
            for term in banned {
                #expect(!body.contains(term), "\(dir) leaks \(term)")
            }
        }
    }

    @Test("every seeded skill carries the shipped version in frontmatter")
    func frontmatterVersion() throws {
        let mem = freshStore()
        #expect(GuideSkills.seed(into: mem))
        for name in allNames {
            let raw = try mem.readFile(path: pluginPath(name)).content
            let (fields, _) = SkillFrontMatter.parse(raw)
            #expect(fields["version"] == GuideSkills.version, "\(name) version mismatch")
        }
    }
}
