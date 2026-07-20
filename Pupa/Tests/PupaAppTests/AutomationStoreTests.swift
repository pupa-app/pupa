import Foundation
import Testing
@testable import PupaApp

/// Loading `pupa/automations.json` from a scope's memory. Mirrors the
/// hostile-bundle tolerance of the importer: malformed entries are skipped,
/// never fatal.
@MainActor
@Suite("Automation store")
struct AutomationStoreTests {

    private func freshMemory() -> MemoryStore {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pupa-autos-\(UUID().uuidString)", isDirectory: true)
        return MemoryStore(rootOverride: root)
    }

    @Test("parses event-keyed rules: matcher / action / prompt / confirm")
    func parsesRules() throws {
        let mem = freshMemory()
        let json = """
        {"automations":{"item.moved":[
          {"id":"review-on-move","matcher":{"toColumn":"Review"},
           "action":{"startThread":{"prompt":"Review {{item.title}}."}},"confirm":true}
        ]}}
        """
        _ = try mem.writeFile(path: MemoryStore.pupaAutomationsPath, content: json)

        let rule = try #require(AutomationStore(memory: mem).rules(for: .itemMoved).first)
        #expect(rule.id == "review-on-move")
        #expect(rule.matcher["toColumn"] == "Review")
        #expect(rule.action.startThreadPrompt == "Review {{item.title}}.")
        #expect(rule.confirm)
    }

    @Test("confirm defaults true when omitted")
    func confirmDefault() throws {
        let mem = freshMemory()
        let json = """
        {"automations":{"item.moved":[
          {"id":"r","matcher":{"toColumn":"Review"},
           "action":{"startThread":{"prompt":"go"}}}
        ]}}
        """
        _ = try mem.writeFile(path: MemoryStore.pupaAutomationsPath, content: json)
        #expect(AutomationStore(memory: mem).rules.first?.confirm == true)
    }

    @Test("hostile tolerance: malformed / unknown-verb entries skipped, valid ones survive")
    func tolerantParse() throws {
        let mem = freshMemory()
        let json = """
        {"automations":{"item.moved":[
          {"id":"no-action"},
          {"matcher":{"toColumn":"Review"},"action":{"startThread":{"prompt":"missing id"}}},
          {"id":"unknown-verb","action":{"runWorkflow":"archive"}},
          {"id":"good","matcher":{"toColumn":"Done"},"action":{"startThread":{"prompt":"ok"}}}
        ], "item.exploded":[{"id":"bad-event","action":{"startThread":{"prompt":"x"}}}]}}
        """
        _ = try mem.writeFile(path: MemoryStore.pupaAutomationsPath, content: json)

        let rules = AutomationStore(memory: mem).rules
        #expect(rules.map(\.id) == ["good"])   // only the well-formed, known-verb rule survives
    }

    @Test("missing file → empty ruleset; rescan picks up a later write")
    func missingThenWritten() throws {
        let mem = freshMemory()
        let store = AutomationStore(memory: mem)
        #expect(store.rules.isEmpty)

        let json = """
        {"automations":{"item.moved":[
          {"id":"r","action":{"startThread":{"prompt":"go"}}}
        ]}}
        """
        _ = try mem.writeFile(path: MemoryStore.pupaAutomationsPath, content: json)
        store.rescan()
        #expect(store.rules.count == 1)
    }
}
