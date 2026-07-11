import Foundation
import Testing
import AGUIKit
@testable import PupaApp

@MainActor
@Suite("TrackerItem — Phase 2 migration")
struct TrackerItemPolicyTests {

    private func makeStore(fields: [FieldDef] = [FieldDef(name: "title", type: .text)]) -> (store: MyAppStore, id: UUID) {
        MyAppTypeRegistry.shared.registerBuiltins()
        let myApp = MyApp(name: "T", iconSystemName: "list.bullet.rectangle", typeId: MyAppType.tracker.id)
        let store = MyAppStore(initial: ([myApp], myApp.id))
        store.setTracker(title: "Test", fields: fields, myAppId: myApp.id)
        return (store, myApp.id)
    }

    // MARK: - TrackerItem: Item conformance

    @Test("TrackerItem.kind is 'tracker'")
    func trackerItemKind() {
        #expect(TrackerItem.kind == "tracker")
    }

    @Test("TrackerItem.schemaVersion defaults to 1")
    func trackerItemSchemaVersion() {
        let item = TrackerItem(values: ["title": "test"])
        #expect(item.schemaVersion == 1)
    }

    @Test("TrackerItem encodes schemaVersion: 1 on encode")
    func schemaVersionWrittenOnEncode() throws {
        let item = TrackerItem(values: ["title": "hello"])
        let data = try JSONEncoder().encode(item)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(json?["schemaVersion"] as? Int == 1)
    }

    @Test("TrackerItem decodes from blob without schemaVersion (backward-compat)")
    func decodesLegacyBlobWithoutSchemaVersion() throws {
        let json = """
        {"id": "00000000-0000-0000-0000-000000000001",
         "values": {"title": "old item"},
         "linkedItems": []}
        """.data(using: .utf8)!
        let item = try JSONDecoder().decode(TrackerItem.self, from: json)
        #expect(item.values["title"] == "old item")
        #expect(item.schemaVersion == 1)
        // Re-encode writes schemaVersion.
        let reEncoded = try JSONEncoder().encode(item)
        let re = try JSONSerialization.jsonObject(with: reEncoded) as? [String: Any]
        #expect(re?["schemaVersion"] as? Int == 1)
    }

    @Test("TrackerItem.displayName picks 'title' key first")
    func displayNamePrefersTitle() {
        let item = TrackerItem(values: ["zzz": "last", "title": "My Task", "aaa": "first"])
        #expect(item.displayName == "My Task")
    }

    @Test("TrackerItem.displayName falls back to sorted-key first non-empty value")
    func displayNameSortedFallback() {
        let item = TrackerItem(values: ["banana": "B", "apple": "A"])
        #expect(item.displayName == "A")
    }

    @Test("TrackerItem.displayName returns dash when values is empty")
    func displayNameEmpty() {
        let item = TrackerItem(values: [:])
        #expect(item.displayName == "–")
    }

    @Test("deduplicateLinkedItems removes exact duplicates on TrackerItem")
    func trackerItemDedup() {
        let ref = ComponentItemRef(componentId: "calendar-1", itemId: UUID())
        var item = TrackerItem(values: [:], linkedItems: [ref, ref])
        item.deduplicateLinkedItems()
        #expect(item.linkedItems.count == 1)
    }

    // MARK: - TrackerItemPolicy

    @Test("TrackerItemPolicy is registered after registerBuiltins")
    func policyRegistered() {
        MyAppTypeRegistry.shared.registerBuiltins()
        #expect(ItemPolicyRegistry.shared.isRegistered(forKind: "tracker"))
    }

    @Test("TrackerItemPolicy.canLinkTo allows tracker / calendar / checklist")
    func canLinkToAllowed() {
        let policy = TrackerItemPolicy()
        #expect(policy.canLinkTo(targetKind: "tracker"))
        #expect(policy.canLinkTo(targetKind: "calendar"))
        #expect(policy.canLinkTo(targetKind: "checklist"))
    }

    @Test("TrackerItemPolicy.canLinkTo blocks slack and empty")
    func canLinkToBlocked() {
        let policy = TrackerItemPolicy()
        #expect(!policy.canLinkTo(targetKind: "slack"))
        #expect(!policy.canLinkTo(targetKind: "empty"))
        #expect(!policy.canLinkTo(targetKind: "unknown"))
    }

    @Test("TrackerItemPolicy.validate returns no errors")
    func validateEmpty() {
        let policy = TrackerItemPolicy()
        let item = TrackerItem(values: ["title": "test"])
        #expect(policy.validate(item).isEmpty)
    }

    // MARK: - setTrackerItemLinkedItems uses Item.deduplicateLinkedItems

    @Test("setTrackerItemLinkedItems deduplicates via Item protocol method")
    func setLinkedItemsDeduplicates() {
        let (store, id) = makeStore()
        let itemId = store.addItem(["title": "row"], myAppId: id)!
        let ref = ComponentItemRef(componentId: "calendar-1", itemId: UUID())
        let ok = store.setTrackerItemLinkedItems(id: itemId, refs: [ref, ref, ref], myAppId: id)
        let t = store.myApps.first(where: { $0.id == id })?.canvas.trackerData
        #expect(ok == true)
        #expect(t?.items.first(where: { $0.id == itemId })?.linkedItems.count == 1)
    }

    // MARK: - Event log emission

    @Test("addItem emits .added event with .user actor by default")
    func addItemEmitsUserEvent() {
        let (store, id) = makeStore()
        _ = store.addItem(["title": "task"], myAppId: id)
        let events = store.itemEventLog.events(forMyApp: id)
        #expect(events.count == 1)
        #expect(events[0].kind == .added)
        #expect(events[0].actor == .user)
    }

    @Test("addItem emits .added event with .agent actor when passed")
    func addItemEmitsAgentEvent() {
        let (store, id) = makeStore()
        _ = store.addItem(["title": "task"], myAppId: id, actor: .agent(toolName: "addTrackerItems"))
        let events = store.itemEventLog.events(forMyApp: id)
        #expect(events.count == 1)
        #expect(events[0].kind == .added)
        #expect(events[0].actor == .agent(toolName: "addTrackerItems"))
    }

    @Test("removeItem emits .removed event")
    func removeItemEmitsEvent() {
        let (store, id) = makeStore()
        let itemId = store.addItem(["title": "task"], myAppId: id, actor: .agent(toolName: "addTrackerItems"))!
        _ = store.removeItem(id: itemId, myAppId: id, actor: .agent(toolName: "removeTrackerItems"))
        let events = store.itemEventLog.events(forMyApp: id)
        let kinds = events.map(\.kind)
        #expect(kinds.contains(.added))
        #expect(kinds.contains(.removed))
        #expect(events.last?.actor == .agent(toolName: "removeTrackerItems"))
    }

    @Test("patchItem(id:) emits .patched event")
    func patchItemEmitsEvent() {
        let (store, id) = makeStore()
        let itemId = store.addItem(["title": "task"], myAppId: id, actor: .agent(toolName: "addTrackerItems"))!
        _ = store.patchItem(id: itemId, with: ["title": "edited"], myAppId: id, actor: .agent(toolName: "patchTrackerItems"))
        let events = store.itemEventLog.events(forMyApp: id)
        #expect(events.last?.kind == .patched)
        #expect(events.last?.actor == .agent(toolName: "patchTrackerItems"))
    }

    @Test("events are scoped per myApp — two myApps don't mix")
    func eventsPerMyApp() {
        MyAppTypeRegistry.shared.registerBuiltins()
        let a = MyApp(name: "A", iconSystemName: "list.bullet.rectangle", typeId: MyAppType.tracker.id)
        let b = MyApp(name: "B", iconSystemName: "list.bullet.rectangle", typeId: MyAppType.tracker.id)
        let store = MyAppStore(initial: ([a, b], a.id))
        store.setTracker(title: "A", fields: [FieldDef(name: "title", type: .text)], myAppId: a.id)
        store.setTracker(title: "B", fields: [FieldDef(name: "title", type: .text)], myAppId: b.id)
        _ = store.addItem(["title": "from A"], myAppId: a.id)
        _ = store.addItem(["title": "from B"], myAppId: b.id)
        _ = store.addItem(["title": "from A again"], myAppId: a.id)
        #expect(store.itemEventLog.events(forMyApp: a.id).count == 2)
        #expect(store.itemEventLog.events(forMyApp: b.id).count == 1)
    }
}

private extension CanvasApp {
    var trackerData: TrackerData? {
        if case .tracker(let t) = self { return t }
        return nil
    }
}
