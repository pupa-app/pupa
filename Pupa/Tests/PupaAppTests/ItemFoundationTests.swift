import Foundation
import Testing
@testable import PupaApp

@MainActor
@Suite("Item foundation — Phase 1")
struct ItemFoundationTests {

    // MARK: - Helpers

    /// Minimal Item conformance used only in these tests.
    struct MockItem: Item {
        var id: UUID = UUID()
        var linkedItems: [ComponentItemRef] = []
        var displayName: String { "mock" }
        static var kind: String { "mock" }

        enum CodingKeys: String, CodingKey { case id, linkedItems }
        init(id: UUID = UUID(), linkedItems: [ComponentItemRef] = []) {
            self.id = id
            self.linkedItems = linkedItems
        }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.id = try c.decode(UUID.self, forKey: .id)
            self.linkedItems = try c.decodeIfPresent([ComponentItemRef].self, forKey: .linkedItems) ?? []
        }
    }

    struct MockPolicy: ItemPolicy {
        typealias ItemType = MockItem
        var maxLinkedItems: Int { 5 }
        var maxDisplayNameLength: Int { 100 }
        func canLinkTo(targetKind: String) -> Bool { targetKind != "blocked" }
    }

    // MARK: - Item protocol defaults

    @Test("schemaVersion defaults to 1")
    func defaultSchemaVersion() {
        #expect(MockItem().schemaVersion == 1)
    }

    @Test("validate returns empty by default")
    func defaultValidateEmpty() {
        #expect(MockItem().validate().isEmpty)
    }

    @Test("deduplicateLinkedItems removes exact duplicates, preserves order")
    func deduplicateDropsDuplicates() {
        let ref1 = ComponentItemRef(componentId: "tracker-1", itemId: UUID())
        let ref2 = ComponentItemRef(componentId: "tracker-1", itemId: UUID())
        var item = MockItem(linkedItems: [ref1, ref1, ref2, ref1])
        item.deduplicateLinkedItems()
        #expect(item.linkedItems == [ref1, ref2])
    }

    @Test("deduplicateLinkedItems is a no-op on an already-unique list")
    func deduplicateNoOpWhenUnique() {
        let refs = [
            ComponentItemRef(componentId: "tracker-1", itemId: UUID()),
            ComponentItemRef(componentId: "calendar-1", itemId: UUID()),
        ]
        var item = MockItem(linkedItems: refs)
        item.deduplicateLinkedItems()
        #expect(item.linkedItems == refs)
    }

    // MARK: - ItemPolicyRegistry

    @Test("register + lookup by kind")
    func registryRoundTrip() {
        let registry = ItemPolicyRegistry()
        #expect(!registry.isRegistered(forKind: "mock"))
        registry.register(MockPolicy(), forKind: "mock")
        #expect(registry.isRegistered(forKind: "mock"))
        #expect(registry.policy(forKind: "mock") != nil)
        #expect(registry.registeredKinds.contains("mock"))
    }

    @Test("policy returns nil for unregistered kind")
    func registryMissReturnsNil() {
        let registry = ItemPolicyRegistry()
        #expect(registry.policy(forKind: "nonexistent") == nil)
    }

    @Test("canLinkTo is consulted via registry")
    func registryCanLinkTo() {
        let registry = ItemPolicyRegistry()
        registry.register(MockPolicy(), forKind: "mock")
        let policy = registry.policy(forKind: "mock")
        #expect(policy?.canLinkTo(targetKind: "tracker") == true)
        #expect(policy?.canLinkTo(targetKind: "blocked") == false)
    }

    @Test("registeredKinds reflects all registrations")
    func registryKinds() {
        let registry = ItemPolicyRegistry()
        registry.register(MockPolicy(), forKind: "a")
        registry.register(MockPolicy(), forKind: "b")
        #expect(registry.registeredKinds == ["a", "b"])
    }

    // MARK: - MigrationRegistry

    @Test("no registered migration returns data unchanged")
    func migrationNoOp() throws {
        let registry = MigrationRegistry()
        let data = "original".data(using: .utf8)!
        let result = try registry.migrate(data: data, kind: "tracker", fromVersion: 0, toVersion: 1)
        #expect(result == data)
    }

    @Test("identity migration runs and passes data through")
    func migrationIdentity() throws {
        var registry = MigrationRegistry()
        var ran = false
        registry.register(kind: "tracker", fromVersion: 0) { data in
            ran = true
            return data
        }
        let data = "test".data(using: .utf8)!
        let result = try registry.migrate(data: data, kind: "tracker", fromVersion: 0, toVersion: 1)
        #expect(ran)
        #expect(result == data)
    }

    @Test("version-bump migration transforms JSON data")
    func migrationVersionBump() throws {
        var registry = MigrationRegistry()
        registry.register(kind: "tracker", fromVersion: 0) { data in
            var json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            json["schemaVersion"] = 1
            json["migrated"] = true
            return try JSONSerialization.data(withJSONObject: json)
        }
        let input = try JSONSerialization.data(withJSONObject: ["name": "test"])
        let result = try registry.migrate(data: input, kind: "tracker", fromVersion: 0, toVersion: 1)
        let decoded = try JSONSerialization.jsonObject(with: result) as? [String: Any]
        #expect(decoded?["migrated"] as? Bool == true)
        #expect(decoded?["schemaVersion"] as? Int == 1)
        #expect(decoded?["name"] as? String == "test")
    }

    @Test("migration chain applies versions in ascending order")
    func migrationChain() throws {
        var registry = MigrationRegistry()
        var order: [Int] = []
        registry.register(kind: "tracker", fromVersion: 0) { data in order.append(0); return data }
        registry.register(kind: "tracker", fromVersion: 1) { data in order.append(1); return data }
        let data = "x".data(using: .utf8)!
        _ = try registry.migrate(data: data, kind: "tracker", fromVersion: 0, toVersion: 2)
        #expect(order == [0, 1])
    }

    @Test("migration skips versions with no registered entry")
    func migrationSparseSkip() throws {
        var registry = MigrationRegistry()
        var ran = false
        registry.register(kind: "tracker", fromVersion: 2) { data in ran = true; return data }
        // Running from version 0 to 3 should only run the v2 migration.
        let data = "x".data(using: .utf8)!
        _ = try registry.migrate(data: data, kind: "tracker", fromVersion: 0, toVersion: 3)
        #expect(ran)
    }

    @Test("migration is a no-op when fromVersion >= toVersion")
    func migrationNoRange() throws {
        var registry = MigrationRegistry()
        var ran = false
        registry.register(kind: "tracker", fromVersion: 0) { data in ran = true; return data }
        let data = "x".data(using: .utf8)!
        _ = try registry.migrate(data: data, kind: "tracker", fromVersion: 1, toVersion: 1)
        #expect(!ran)
    }

    // MARK: - ItemEventLog

    @Test("append increments count")
    func logAppend() {
        var log = ItemEventLog()
        let myAppId = UUID()
        log.append(ItemEvent(myAppId: myAppId, componentId: "tracker-1", kind: .added, actor: .user))
        #expect(log.count == 1)
    }

    @Test("bounded eviction keeps only the most recent `cap` events")
    func logBoundedEviction() {
        var log = ItemEventLog(cap: 3)
        let myAppId = UUID()
        for i in 0..<5 {
            log.append(ItemEvent(
                myAppId: myAppId,
                componentId: "tracker-\(i)",
                kind: .added,
                actor: .user
            ))
        }
        #expect(log.count == 3)
        // Oldest two were evicted; the remaining three are the last-appended.
        #expect(log.all.map(\.componentId) == ["tracker-2", "tracker-3", "tracker-4"])
    }

    @Test("events(forMyApp:) filters by myAppId")
    func logFilterByMyApp() {
        var log = ItemEventLog()
        let id1 = UUID()
        let id2 = UUID()
        log.append(ItemEvent(myAppId: id1, componentId: "tracker-1", kind: .added, actor: .agent(toolName: "addTrackerItems")))
        log.append(ItemEvent(myAppId: id2, componentId: "calendar-1", kind: .added, actor: .user))
        log.append(ItemEvent(myAppId: id1, componentId: "tracker-1", kind: .patched, actor: .agent(toolName: "patchTrackerItems")))
        #expect(log.events(forMyApp: id1).count == 2)
        #expect(log.events(forMyApp: id2).count == 1)
        #expect(log.events(forMyApp: UUID()).count == 0)
    }

    @Test("ItemEventActor.user round-trips through Codable")
    func actorUserCodable() throws {
        let actor = ItemEventActor.user
        let data = try JSONEncoder().encode(actor)
        let decoded = try JSONDecoder().decode(ItemEventActor.self, from: data)
        #expect(decoded == actor)
    }

    @Test("ItemEventActor.agent round-trips through Codable")
    func actorAgentCodable() throws {
        let actor = ItemEventActor.agent(toolName: "addTrackerItems")
        let data = try JSONEncoder().encode(actor)
        let decoded = try JSONDecoder().decode(ItemEventActor.self, from: data)
        #expect(decoded == actor)
    }

    @Test("ItemEvent round-trips through Codable")
    func eventCodable() throws {
        let event = ItemEvent(
            myAppId: UUID(),
            componentId: "tracker-1",
            kind: .linked,
            payload: "{}".data(using: .utf8)!,
            actor: .agent(toolName: "linkItem")
        )
        let data = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(ItemEvent.self, from: data)
        #expect(decoded.id == event.id)
        #expect(decoded.componentId == event.componentId)
        #expect(decoded.kind == event.kind)
        #expect(decoded.actor == event.actor)
    }
}
