import Foundation
import Testing
import AGUIKit
@testable import PupaApp

@MainActor
@Suite("ChecklistItem — Phase 4 migration")
struct ChecklistItemPolicyTests {

    private func makeStore() -> (store: MiniAppStore, id: UUID) {
        MiniAppTypeRegistry.shared.registerBuiltins()
        let miniApp = MiniApp(name: "C", iconSystemName: "checklist", typeId: MiniAppType.tracker.id)
        let store = MiniAppStore(initial: ([miniApp], miniApp.id))
        store.setChecklist(title: "Test", miniAppId: miniApp.id)
        return (store, miniApp.id)
    }

    private func makeItem(text: String = "Buy milk") -> ChecklistItem {
        ChecklistItem(text: text)
    }

    // MARK: - ChecklistItem: Item conformance

    @Test("ChecklistItem.kind is 'checklist'")
    func checklistItemKind() {
        #expect(ChecklistItem.kind == "checklist")
    }

    @Test("ChecklistItem.schemaVersion defaults to 1")
    func checklistItemSchemaVersion() {
        let item = makeItem()
        #expect(item.schemaVersion == 1)
    }

    @Test("ChecklistItem encodes schemaVersion: 1 on encode")
    func schemaVersionWrittenOnEncode() throws {
        let item = makeItem()
        let data = try JSONEncoder().encode(item)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(json?["schemaVersion"] as? Int == 1)
    }

    @Test("ChecklistItem decodes from blob without schemaVersion (backward-compat)")
    func decodesLegacyBlobWithoutSchemaVersion() throws {
        let json = """
        {"id": "00000000-0000-0000-0000-000000000001",
         "text": "Old task",
         "done": false,
         "linkedItems": []}
        """.data(using: .utf8)!
        let item = try JSONDecoder().decode(ChecklistItem.self, from: json)
        #expect(item.text == "Old task")
        #expect(item.schemaVersion == 1)
        let reEncoded = try JSONEncoder().encode(item)
        let re = try JSONSerialization.jsonObject(with: reEncoded) as? [String: Any]
        #expect(re?["schemaVersion"] as? Int == 1)
    }

    @Test("ChecklistItem decodes from blob without linkedItems (backward-compat)")
    func decodesLegacyBlobWithoutLinkedItems() throws {
        let json = """
        {"id": "00000000-0000-0000-0000-000000000002",
         "text": "Sprint review",
         "done": false}
        """.data(using: .utf8)!
        let item = try JSONDecoder().decode(ChecklistItem.self, from: json)
        #expect(item.linkedItems.isEmpty)
    }

    @Test("ChecklistItem.displayName returns text")
    func displayNameIsText() {
        let item = makeItem(text: "Pick up kids")
        #expect(item.displayName == "Pick up kids")
    }

    @Test("ChecklistItem.displayName returns dash for blank text")
    func displayNameFallsBackToDash() {
        let item = makeItem(text: "   ")
        #expect(item.displayName == "–")
    }

    @Test("deduplicateLinkedItems removes exact duplicates on ChecklistItem")
    func checklistItemDedup() {
        let ref = ComponentItemRef(componentId: "tracker-1", itemId: UUID())
        var item = makeItem()
        item.linkedItems = [ref, ref, ref]
        item.deduplicateLinkedItems()
        #expect(item.linkedItems.count == 1)
    }

    // MARK: - ChecklistItemPolicy

    @Test("ChecklistItemPolicy is registered after registerBuiltins")
    func policyRegistered() {
        MiniAppTypeRegistry.shared.registerBuiltins()
        #expect(ItemPolicyRegistry.shared.isRegistered(forKind: "checklist"))
    }

    @Test("ChecklistItemPolicy.canLinkTo allows tracker / calendar / checklist")
    func canLinkToAllowed() {
        let policy = ChecklistItemPolicy()
        #expect(policy.canLinkTo(targetKind: "tracker"))
        #expect(policy.canLinkTo(targetKind: "calendar"))
        #expect(policy.canLinkTo(targetKind: "checklist"))
    }

    @Test("ChecklistItemPolicy.canLinkTo blocks slack and empty")
    func canLinkToBlocked() {
        let policy = ChecklistItemPolicy()
        #expect(!policy.canLinkTo(targetKind: "slack"))
        #expect(!policy.canLinkTo(targetKind: "empty"))
        #expect(!policy.canLinkTo(targetKind: "unknown"))
    }

    @Test("ChecklistItemPolicy.validate passes for valid item")
    func validateValid() {
        let policy = ChecklistItemPolicy()
        let item = makeItem()
        #expect(policy.validate(item).isEmpty)
    }

    @Test("ChecklistItemPolicy.validate rejects empty text")
    func validateEmptyText() {
        let policy = ChecklistItemPolicy()
        let item = makeItem(text: "")
        let errors = policy.validate(item)
        #expect(errors.contains(where: { $0.field == "text" }))
    }

    @Test("ChecklistItemPolicy.validate rejects blank text")
    func validateBlankText() {
        let policy = ChecklistItemPolicy()
        let item = makeItem(text: "   ")
        let errors = policy.validate(item)
        #expect(errors.contains(where: { $0.field == "text" }))
    }

    // MARK: - patchChecklistItem uses deduplicateLinkedItems

    @Test("patchChecklistItem deduplicates linkedItems via Item protocol method")
    func patchDeduplicatesLinkedItems() {
        let (store, id) = makeStore()
        let itemId = store.addChecklistItem(text: "Task", miniAppId: id)!
        let ref = ComponentItemRef(componentId: "tracker-1", itemId: UUID())
        let patch = MiniAppStore.ChecklistItemPatch(linkedItems: [ref, ref, ref])
        let after = store.patchChecklistItem(id: itemId, patch: patch, miniAppId: id)
        #expect(after?.linkedItems.count == 1)
    }

    // MARK: - Event log emission

    @Test("addChecklistItem emits .added event with .user actor by default")
    func addEventEmitsUserEvent() {
        let (store, id) = makeStore()
        _ = store.addChecklistItem(text: "Task", miniAppId: id)
        let events = store.itemEventLog.events(forMiniApp: id)
        #expect(events.count == 1)
        #expect(events[0].kind == .added)
        #expect(events[0].actor == .user)
    }

    @Test("addChecklistItem emits .added event with .agent actor when passed")
    func addEventEmitsAgentEvent() {
        let (store, id) = makeStore()
        _ = store.addChecklistItem(text: "Task", miniAppId: id, actor: .agent(toolName: "addChecklistItem"))
        let events = store.itemEventLog.events(forMiniApp: id)
        #expect(events.count == 1)
        #expect(events[0].kind == .added)
        #expect(events[0].actor == .agent(toolName: "addChecklistItem"))
    }

    @Test("toggleChecklistItem emits .patched event")
    func toggleEmitsPatchedEvent() {
        let (store, id) = makeStore()
        let itemId = store.addChecklistItem(text: "Task", miniAppId: id, actor: .agent(toolName: "addChecklistItem"))!
        _ = store.toggleChecklistItem(id: itemId, miniAppId: id, actor: .agent(toolName: "toggleChecklistItem"))
        let events = store.itemEventLog.events(forMiniApp: id)
        #expect(events.last?.kind == .patched)
        #expect(events.last?.actor == .agent(toolName: "toggleChecklistItem"))
    }

    @Test("removeChecklistItem emits .removed event")
    func removeEventEmitsEvent() {
        let (store, id) = makeStore()
        let itemId = store.addChecklistItem(text: "Task", miniAppId: id, actor: .agent(toolName: "addChecklistItem"))!
        _ = store.removeChecklistItem(id: itemId, miniAppId: id, actor: .agent(toolName: "removeChecklistItem"))
        let events = store.itemEventLog.events(forMiniApp: id)
        let kinds = events.map(\.kind)
        #expect(kinds.contains(.added))
        #expect(kinds.contains(.removed))
        #expect(events.last?.actor == .agent(toolName: "removeChecklistItem"))
    }

    @Test("patchChecklistItem emits .patched event")
    func patchEventEmitsEvent() {
        let (store, id) = makeStore()
        let itemId = store.addChecklistItem(text: "Task", miniAppId: id, actor: .agent(toolName: "addChecklistItem"))!
        let patch = MiniAppStore.ChecklistItemPatch(text: "Updated task")
        _ = store.patchChecklistItem(id: itemId, patch: patch, miniAppId: id, actor: .agent(toolName: "patchChecklistItem"))
        let events = store.itemEventLog.events(forMiniApp: id)
        #expect(events.last?.kind == .patched)
        #expect(events.last?.actor == .agent(toolName: "patchChecklistItem"))
    }

    @Test("checklist events are scoped per miniApp — two miniApps don't mix")
    func eventsPerMiniApp() {
        MiniAppTypeRegistry.shared.registerBuiltins()
        let a = MiniApp(name: "A", iconSystemName: "checklist", typeId: MiniAppType.tracker.id)
        let b = MiniApp(name: "B", iconSystemName: "checklist", typeId: MiniAppType.tracker.id)
        let store = MiniAppStore(initial: ([a, b], a.id))
        store.setChecklist(title: "A", miniAppId: a.id)
        store.setChecklist(title: "B", miniAppId: b.id)
        _ = store.addChecklistItem(text: "from A", miniAppId: a.id)
        _ = store.addChecklistItem(text: "from B", miniAppId: b.id)
        _ = store.addChecklistItem(text: "from A again", miniAppId: a.id)
        #expect(store.itemEventLog.events(forMiniApp: a.id).count == 2)
        #expect(store.itemEventLog.events(forMiniApp: b.id).count == 1)
    }

}
