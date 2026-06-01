import Foundation
import Testing
import AGUIKit
@testable import PupaApp

@MainActor
@Suite("ChecklistItem — Phase 4 migration")
struct ChecklistItemPolicyTests {

    private func makeStore() -> (store: MyAppStore, id: UUID) {
        MyAppTypeRegistry.shared.registerBuiltins()
        let myApp = MyApp(name: "C", iconSystemName: "checklist", typeId: MyAppType.tracker.id)
        let store = MyAppStore(initial: ([myApp], myApp.id))
        store.setChecklist(title: "Test", myAppId: myApp.id)
        return (store, myApp.id)
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
        MyAppTypeRegistry.shared.registerBuiltins()
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
        let itemId = store.addChecklistItem(text: "Task", myAppId: id)!
        let ref = ComponentItemRef(componentId: "tracker-1", itemId: UUID())
        let patch = MyAppStore.ChecklistItemPatch(linkedItems: [ref, ref, ref])
        let after = store.patchChecklistItem(id: itemId, patch: patch, myAppId: id)
        #expect(after?.linkedItems.count == 1)
    }

    // MARK: - Event log emission

    @Test("addChecklistItem emits .added event with .user actor by default")
    func addEventEmitsUserEvent() {
        let (store, id) = makeStore()
        _ = store.addChecklistItem(text: "Task", myAppId: id)
        let events = store.itemEventLog.events(forMyApp: id)
        #expect(events.count == 1)
        #expect(events[0].kind == .added)
        #expect(events[0].actor == .user)
    }

    @Test("addChecklistItem emits .added event with .agent actor when passed")
    func addEventEmitsAgentEvent() {
        let (store, id) = makeStore()
        _ = store.addChecklistItem(text: "Task", myAppId: id, actor: .agent(toolName: "addChecklistItem"))
        let events = store.itemEventLog.events(forMyApp: id)
        #expect(events.count == 1)
        #expect(events[0].kind == .added)
        #expect(events[0].actor == .agent(toolName: "addChecklistItem"))
    }

    @Test("toggleChecklistItem emits .patched event")
    func toggleEmitsPatchedEvent() {
        let (store, id) = makeStore()
        let itemId = store.addChecklistItem(text: "Task", myAppId: id, actor: .agent(toolName: "addChecklistItem"))!
        _ = store.toggleChecklistItem(id: itemId, myAppId: id, actor: .agent(toolName: "toggleChecklistItem"))
        let events = store.itemEventLog.events(forMyApp: id)
        #expect(events.last?.kind == .patched)
        #expect(events.last?.actor == .agent(toolName: "toggleChecklistItem"))
    }

    @Test("removeChecklistItem emits .removed event")
    func removeEventEmitsEvent() {
        let (store, id) = makeStore()
        let itemId = store.addChecklistItem(text: "Task", myAppId: id, actor: .agent(toolName: "addChecklistItem"))!
        _ = store.removeChecklistItem(id: itemId, myAppId: id, actor: .agent(toolName: "removeChecklistItem"))
        let events = store.itemEventLog.events(forMyApp: id)
        let kinds = events.map(\.kind)
        #expect(kinds.contains(.added))
        #expect(kinds.contains(.removed))
        #expect(events.last?.actor == .agent(toolName: "removeChecklistItem"))
    }

    @Test("patchChecklistItem emits .patched event")
    func patchEventEmitsEvent() {
        let (store, id) = makeStore()
        let itemId = store.addChecklistItem(text: "Task", myAppId: id, actor: .agent(toolName: "addChecklistItem"))!
        let patch = MyAppStore.ChecklistItemPatch(text: "Updated task")
        _ = store.patchChecklistItem(id: itemId, patch: patch, myAppId: id, actor: .agent(toolName: "patchChecklistItem"))
        let events = store.itemEventLog.events(forMyApp: id)
        #expect(events.last?.kind == .patched)
        #expect(events.last?.actor == .agent(toolName: "patchChecklistItem"))
    }

    @Test("checklist events are scoped per myApp — two myApps don't mix")
    func eventsPerMyApp() {
        MyAppTypeRegistry.shared.registerBuiltins()
        let a = MyApp(name: "A", iconSystemName: "checklist", typeId: MyAppType.tracker.id)
        let b = MyApp(name: "B", iconSystemName: "checklist", typeId: MyAppType.tracker.id)
        let store = MyAppStore(initial: ([a, b], a.id))
        store.setChecklist(title: "A", myAppId: a.id)
        store.setChecklist(title: "B", myAppId: b.id)
        _ = store.addChecklistItem(text: "from A", myAppId: a.id)
        _ = store.addChecklistItem(text: "from B", myAppId: b.id)
        _ = store.addChecklistItem(text: "from A again", myAppId: a.id)
        #expect(store.itemEventLog.events(forMyApp: a.id).count == 2)
        #expect(store.itemEventLog.events(forMyApp: b.id).count == 1)
    }

}
