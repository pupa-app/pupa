import Foundation
import Testing
import AGUIKit
@testable import PupaApp

/// Pins the bulk tracker mutators (`addTrackerItems` / `patchTrackerItems` /
/// `removeTrackerItems`). Each one collapses what would otherwise be N model
/// round-trips into a single tool call.
@MainActor
@Suite("Bulk tracker tools")
struct BulkTrackerToolsTests {

    private func makeStore() -> (store: MyAppStore, myAppId: UUID) {
        MyAppTypeRegistry.shared.registerBuiltins()
        let myApp = MyApp(
            name: "T",
            iconSystemName: "list.bullet.rectangle",
            typeId: MyAppType.tracker.id
        )
        let store = MyAppStore(initial: ([myApp], myApp.id))
        return (store, myApp.id)
    }

    private func renderTracker(_ registry: ToolRegistry) async throws {
        guard let render = registry.resolve("renderTracker") else {
            Issue.record("renderTracker not registered"); return
        }
        _ = try await render.handler(.object([
            "title": .string("T"),
            "fields": .array([
                .object(["name": .string("note"), "type": .string("text")]),
                .object(["name": .string("priority"), "type": .string("text")]),
            ]),
        ]))
    }

    private func trackerItems(_ store: MyAppStore, _ myAppId: UUID) -> [TrackerItem] {
        guard let myApp = store.myApps.first(where: { $0.id == myAppId }) else { return [] }
        if case .tracker(let t) = myApp.canvas { return t.items }
        return []
    }

    // MARK: - addTrackerItems

    @Test("addTrackerItems appends every item in one call and echoes their ids + total")
    func addTrackerItems_appendsAllInOneCall() async throws {
        let (store, myAppId) = makeStore()
        let registry = ToolRegistry()
        AppTools.registerMyAppTools(on: registry, store: store, myAppId: myAppId)
        try await renderTracker(registry)

        guard let add = registry.resolve("addTrackerItems") else {
            Issue.record("addTrackerItems not registered"); return
        }
        let result = try await add.handler(.object([
            "items": .array([
                .object(["note": .string("a"), "priority": .string("hi")]),
                .object(["note": .string("b")]),
                .object(["note": .string("c"), "priority": .string("lo")]),
            ]),
        ]))

        #expect(result.objectValue?["ok"]?.boolValue == true)
        let ids = result.objectValue?["ids"]?.arrayValue ?? []
        #expect(ids.count == 3)
        let added = result.objectValue?["added"]?.arrayValue ?? []
        #expect(added.count == 3)
        #expect(result.objectValue?["totalItems"]?.intValue == 3)

        let items = trackerItems(store, myAppId)
        #expect(items.map { $0.values["note"] ?? "" } == ["a", "b", "c"])
    }

    @Test("addTrackerItems with empty array is a no-op that reports totalItems")
    func addTrackerItems_emptyArrayNoop() async throws {
        let (store, myAppId) = makeStore()
        let registry = ToolRegistry()
        AppTools.registerMyAppTools(on: registry, store: store, myAppId: myAppId)
        try await renderTracker(registry)

        // Seed one item so totalItems > 0.
        _ = try await registry.resolve("addTrackerItems")!.handler(.object([
            "items": .array([.object(["note": .string("seed")])]),
        ]))

        let result = try await registry.resolve("addTrackerItems")!.handler(.object([
            "items": .array([]),
        ]))

        #expect(result.objectValue?["ok"]?.boolValue == true)
        #expect(result.objectValue?["ids"]?.arrayValue?.count == 0)
        #expect(result.objectValue?["totalItems"]?.intValue == 1)
        #expect(trackerItems(store, myAppId).count == 1)
    }

    @Test("addTrackerItems with missing items returns ok=false")
    func addTrackerItems_missingArrayIsError() async throws {
        let (store, myAppId) = makeStore()
        let registry = ToolRegistry()
        AppTools.registerMyAppTools(on: registry, store: store, myAppId: myAppId)
        try await renderTracker(registry)

        let result = try await registry.resolve("addTrackerItems")!.handler(.object([:]))
        #expect(result.objectValue?["ok"]?.boolValue == false)
        #expect(result.objectValue?["error"]?.stringValue?.isEmpty == false)
    }

    // MARK: - patchTrackerItems

    @Test("patchTrackerItems applies each patch and echoes per-entry results")
    func patchTrackerItems_appliesAll() async throws {
        let (store, myAppId) = makeStore()
        let registry = ToolRegistry()
        AppTools.registerMyAppTools(on: registry, store: store, myAppId: myAppId)
        try await renderTracker(registry)

        // Seed three items.
        let bulkAdd = try await registry.resolve("addTrackerItems")!.handler(.object([
            "items": .array([
                .object(["note": .string("a")]),
                .object(["note": .string("b")]),
                .object(["note": .string("c")]),
            ]),
        ]))
        let ids = bulkAdd.objectValue?["ids"]?.arrayValue?.compactMap { $0.stringValue } ?? []
        #expect(ids.count == 3)

        let result = try await registry.resolve("patchTrackerItems")!.handler(.object([
            "patches": .array([
                .object([
                    "id": .string(ids[0]),
                    "patch": .object(["priority": .string("hi")]),
                ]),
                .object([
                    "id": .string(ids[2]),
                    "patch": .object(["priority": .string("lo")]),
                ]),
            ]),
        ]))

        #expect(result.objectValue?["ok"]?.boolValue == true)
        let results = result.objectValue?["results"]?.arrayValue ?? []
        #expect(results.count == 2)
        #expect(results.allSatisfy { $0.objectValue?["ok"]?.boolValue == true })

        let items = trackerItems(store, myAppId)
        #expect(items[0].values["priority"] == "hi")
        #expect(items[1].values["priority"] == nil)
        #expect(items[2].values["priority"] == "lo")
    }

    @Test("patchTrackerItems reports partial failures without aborting later patches")
    func patchTrackerItems_partialFailure() async throws {
        let (store, myAppId) = makeStore()
        let registry = ToolRegistry()
        AppTools.registerMyAppTools(on: registry, store: store, myAppId: myAppId)
        try await renderTracker(registry)

        let bulkAdd = try await registry.resolve("addTrackerItems")!.handler(.object([
            "items": .array([
                .object(["note": .string("a")]),
                .object(["note": .string("b")]),
            ]),
        ]))
        let ids = bulkAdd.objectValue?["ids"]?.arrayValue?.compactMap { $0.stringValue } ?? []

        let result = try await registry.resolve("patchTrackerItems")!.handler(.object([
            "patches": .array([
                .object([
                    "id": .string(ids[0]),
                    "patch": .object(["priority": .string("hi")]),
                ]),
                .object([
                    "id": .string("00000000-0000-0000-0000-000000000000"),
                    "patch": .object(["priority": .string("x")]),
                ]),
                .object([
                    "id": .string(ids[1]),
                    "patch": .object(["priority": .string("lo")]),
                ]),
            ]),
        ]))

        let results = result.objectValue?["results"]?.arrayValue ?? []
        #expect(results.count == 3)
        #expect(results[0].objectValue?["ok"]?.boolValue == true)
        #expect(results[1].objectValue?["ok"]?.boolValue == false)
        #expect(results[2].objectValue?["ok"]?.boolValue == true)
        #expect(result.objectValue?["ok"]?.boolValue == false)  // overall ok=false on partial

        let items = trackerItems(store, myAppId)
        #expect(items[0].values["priority"] == "hi")
        #expect(items[1].values["priority"] == "lo")
    }

    // MARK: - removeTrackerItems

    @Test("removeTrackerItems removes every target in one call, indices resolved before mutation")
    func removeTrackerItems_resolvesIndicesUpfront() async throws {
        let (store, myAppId) = makeStore()
        let registry = ToolRegistry()
        AppTools.registerMyAppTools(on: registry, store: store, myAppId: myAppId)
        try await renderTracker(registry)

        _ = try await registry.resolve("addTrackerItems")!.handler(.object([
            "items": .array([
                .object(["note": .string("a")]),
                .object(["note": .string("b")]),
                .object(["note": .string("c")]),
                .object(["note": .string("d")]),
            ]),
        ]))

        // Remove indices 0 and 2 — if indices were resolved lazily after the
        // first remove, index 2 would shift and we'd hit "c" instead of "c".
        // (Resolve up front: index 0 → "a", index 2 → "c"; both correct.)
        let result = try await registry.resolve("removeTrackerItems")!.handler(.object([
            "targets": .array([
                .object(["index": .int(0)]),
                .object(["index": .int(2)]),
            ]),
        ]))

        #expect(result.objectValue?["ok"]?.boolValue == true)
        let results = result.objectValue?["results"]?.arrayValue ?? []
        #expect(results.count == 2)
        #expect(result.objectValue?["totalItems"]?.intValue == 2)

        let remaining = trackerItems(store, myAppId).map { $0.values["note"] ?? "" }
        #expect(remaining == ["b", "d"])
    }

    @Test("removeTrackerItems reports partial failures without aborting")
    func removeTrackerItems_partialFailure() async throws {
        let (store, myAppId) = makeStore()
        let registry = ToolRegistry()
        AppTools.registerMyAppTools(on: registry, store: store, myAppId: myAppId)
        try await renderTracker(registry)

        let bulkAdd = try await registry.resolve("addTrackerItems")!.handler(.object([
            "items": .array([
                .object(["note": .string("a")]),
                .object(["note": .string("b")]),
            ]),
        ]))
        let ids = bulkAdd.objectValue?["ids"]?.arrayValue?.compactMap { $0.stringValue } ?? []

        let result = try await registry.resolve("removeTrackerItems")!.handler(.object([
            "targets": .array([
                .object(["id": .string(ids[0])]),
                .object(["id": .string("00000000-0000-0000-0000-000000000000")]),
                .object(["id": .string(ids[1])]),
            ]),
        ]))

        let results = result.objectValue?["results"]?.arrayValue ?? []
        #expect(results.count == 3)
        #expect(results[0].objectValue?["ok"]?.boolValue == true)
        #expect(results[1].objectValue?["ok"]?.boolValue == false)
        #expect(results[2].objectValue?["ok"]?.boolValue == true)
        #expect(result.objectValue?["ok"]?.boolValue == false)
        #expect(result.objectValue?["totalItems"]?.intValue == 0)
    }

    // MARK: - Tool surface

    @Test("Bulk tools are registered in MyAppType.tracker.toolNamesByKind[\"tracker\"]")
    func bulkToolNamesAdvertised() {
        let tracker = MyAppType.tracker
        let names = tracker.toolNamesByKind["tracker"] ?? []
        #expect(names.contains("addTrackerItems"))
        #expect(names.contains("patchTrackerItems"))
        #expect(names.contains("removeTrackerItems"))
    }
}
