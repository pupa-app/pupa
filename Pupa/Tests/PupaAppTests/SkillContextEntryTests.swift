import Foundation
import Testing
@testable import PupaApp

@MainActor
@Suite("Skills context entry")
struct SkillContextEntryTests {

    private func tempStore() -> MemoryStore {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pupa-ctx-\(UUID().uuidString)", isDirectory: true)
        return MemoryStore(rootOverride: root)
    }

    @Test("Always present; teaches use + creation even with an empty catalogue")
    func presentWhenEmpty() {
        let entry = ChatViewModel.skillsContextEntry(SkillStore(memory: tempStore()))
        #expect(entry.value.contains("\"skills\":[]"))         // empty catalogue
        #expect(entry.description.contains("app_skill_view"))   // how to use
        #expect(entry.description.contains("pupa/skills/<name>/SKILL.md")) // how to create
    }

    @Test("Lists model-visible skills; excludes disable-model-invocation")
    func listsModelVisibleOnly() throws {
        let store = tempStore()
        try store.writeFile(path: "pupa/skills/research/SKILL.md",
            content: "---\ndescription: research a topic\nwhen_to_use: when asked to dig\n---\nbody")
        try store.writeFile(path: "pupa/skills/deploy/SKILL.md",
            content: "---\ndescription: ship it\ndisable-model-invocation: true\n---\nbody")

        let entry = ChatViewModel.skillsContextEntry(SkillStore(memory: store))
        #expect(entry.value.contains("research"))
        #expect(entry.value.contains("when asked to dig"))
        // A user-only skill (disable-model-invocation) is not advertised to the model.
        #expect(!entry.value.contains("ship it"))
    }

    @Test("A model-only skill (user-invocable:false) is still listed to the model")
    func modelOnlySkillListed() throws {
        let store = tempStore()
        try store.writeFile(path: "pupa/skills/context/SKILL.md",
            content: "---\ndescription: background knowledge\nuser-invocable: false\n---\nbody")
        let entry = ChatViewModel.skillsContextEntry(SkillStore(memory: store))
        #expect(entry.value.contains("background knowledge"))
    }
}
