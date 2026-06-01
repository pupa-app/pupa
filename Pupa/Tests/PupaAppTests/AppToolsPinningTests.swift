import Foundation
import Testing
import AGUIKit
@testable import PupaApp

/// Tests for the multi-myApp race fix in `AppTools.registerMyAppTools`.
/// Tools registered for a myApp close over a fixed `myAppId` at construction
/// time and route every mutator through that pinned id — so a tool firing
/// while the user has switched the visible myApp to a different one still
/// mutates the myApp the stream was started in. This is the property that
/// makes per-myApp concurrent streams safe (issue #17).
@MainActor
@Suite("AppTools myApp pinning")
struct AppToolsPinningTests {

    private func makeStore() -> (store: MyAppStore, a: UUID, b: UUID) {
        MyAppTypeRegistry.shared.registerBuiltins()
        let myAppA = MyApp(name: "A", iconSystemName: "circle", typeId: MyAppType.tracker.id)
        let myAppB = MyApp(name: "B", iconSystemName: "square", typeId: MyAppType.tracker.id)
        let store = MyAppStore(initial: ([myAppA, myAppB], myAppA.id))
        return (store, myAppA.id, myAppB.id)
    }

    private func renderTracker(_ registry: ToolRegistry) async throws {
        guard let render = registry.resolve("renderTracker") else {
            Issue.record("renderTracker not registered")
            return
        }
        _ = try await render.handler(.object([
            "title": .string("T"),
            "fields": .array([
                .object([
                    "name": .string("note"),
                    "type": .string("text"),
                ])
            ]),
        ]))
    }

    private func addItem(_ registry: ToolRegistry, note: String) async throws {
        guard let add = registry.resolve("addTrackerItems") else {
            Issue.record("addTrackerItems not registered")
            return
        }
        _ = try await add.handler(.object([
            "items": .array([.object(["note": .string(note)])]),
        ]))
    }

    private func itemCount(_ store: MyAppStore, myAppId: UUID) -> Int {
        guard let myApp = store.myApps.first(where: { $0.id == myAppId }) else { return -1 }
        if case .tracker(let t) = myApp.canvas { return t.items.count }
        return 0
    }

    @Test("Tool pinned to myApp A mutates A even when active myApp is B")
    func toolHonoursPinnedSpaceId() async throws {
        let (store, idA, idB) = makeStore()
        let registry = ToolRegistry()
        AppTools.registerMyAppTools(on: registry, store: store, myAppId: idA)

        try await renderTracker(registry)
        store.setActive(idB)  // user navigates away mid-turn
        try await addItem(registry, note: "from-A-stream")

        #expect(itemCount(store, myAppId: idA) == 1)
        #expect(itemCount(store, myAppId: idB) == 0)
    }

    @Test("Two registries pinned to different myApps mutate independently")
    func twoRegistriesAreIndependent() async throws {
        let (store, idA, idB) = makeStore()
        let regA = ToolRegistry()
        let regB = ToolRegistry()
        AppTools.registerMyAppTools(on: regA, store: store, myAppId: idA)
        AppTools.registerMyAppTools(on: regB, store: store, myAppId: idB)

        try await renderTracker(regA)
        try await renderTracker(regB)
        try await addItem(regA, note: "a1")
        try await addItem(regA, note: "a2")
        try await addItem(regB, note: "b1")

        #expect(itemCount(store, myAppId: idA) == 2)
        #expect(itemCount(store, myAppId: idB) == 1)
    }

    @Test("getCanvasState resolves the pinned myApp's canvas, ignoring active selection")
    func getCanvasStateReadsPinned() async throws {
        let (store, idA, idB) = makeStore()
        let regA = ToolRegistry()
        AppTools.registerMyAppTools(on: regA, store: store, myAppId: idA)

        try await renderTracker(regA)
        try await addItem(regA, note: "x")
        store.setActive(idB)

        guard let get = regA.resolve("getCanvasState") else {
            Issue.record("getCanvasState not registered")
            return
        }
        let result = try await get.handler(.object([:]))
        // Canvas encodes as {components: [{id, name, iconSystemName, body: {kind, data}}],
        // activeComponentId} — multi-component shape. Tracker components
        // hold their data under `body.data.items`, where each item encodes
        // as {id, values}.
        let canvas = result.objectValue?["canvas"]
        let components = canvas?.objectValue?["components"]?.arrayValue ?? []
        #expect(components.count >= 1)
        let trackerComp = components.first { $0.objectValue?["body"]?.objectValue?["kind"]?.stringValue == "tracker" }
        #expect(trackerComp != nil, "expected at least one tracker component")
        let items = trackerComp?.objectValue?["body"]?.objectValue?["data"]?.objectValue?["items"]?.arrayValue ?? []
        #expect(items.count == 1)
        #expect(items.first?.objectValue?["values"]?.objectValue?["note"]?.stringValue == "x")
        #expect(items.first?.objectValue?["id"]?.stringValue != nil)
    }

    @Test("clearCanvas only resets the pinned myApp")
    func clearCanvasIsPinned() async throws {
        let (store, idA, idB) = makeStore()
        let regA = ToolRegistry()
        let regB = ToolRegistry()
        AppTools.registerMyAppTools(on: regA, store: store, myAppId: idA)
        AppTools.registerMyAppTools(on: regB, store: store, myAppId: idB)

        try await renderTracker(regA)
        try await renderTracker(regB)
        try await addItem(regA, note: "keep")
        try await addItem(regB, note: "wipe-me")

        guard let clear = regB.resolve("clearCanvas") else {
            Issue.record("clearCanvas not registered")
            return
        }
        _ = try await clear.handler(.object([:]))

        // B is now empty; A is untouched.
        if case .empty = store.myApps.first(where: { $0.id == idB })?.canvas {
            // ok
        } else {
            Issue.record("myApp B canvas should be .empty after clearCanvas")
        }
        #expect(itemCount(store, myAppId: idA) == 1)
    }
}
