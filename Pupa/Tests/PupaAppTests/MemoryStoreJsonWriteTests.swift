import Foundation
import Testing
@testable import PupaApp

@MainActor
@Suite("MemoryStore write extension allowlist")
struct MemoryStoreJsonWriteTests {

    private func tempStore() -> MemoryStore {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pupa-ext-\(UUID().uuidString)", isDirectory: true)
        return MemoryStore(rootOverride: root)
    }

    @Test("Markdown and JSON writes are allowed")
    func allowsMdAndJson() throws {
        let store = tempStore()
        try store.writeFile(path: "pupa/config.json", content: "{\"k\":1}")
        try store.writeFile(path: "pupa/AGENTS.md", content: "# prompt")
        #expect(store.fileExists(at: "pupa/config.json"))
        #expect(store.fileExists(at: "pupa/AGENTS.md"))
    }

    @Test("Non-allowlisted extensions are rejected")
    func rejectsOtherExtensions() {
        let store = tempStore()
        #expect(throws: (any Error).self) {
            try store.writeFile(path: "pupa/skills/x/run.py", content: "print(1)")
        }
        #expect(throws: (any Error).self) {
            try store.writeFile(path: "notes/readme.txt", content: "hi")
        }
    }
}
