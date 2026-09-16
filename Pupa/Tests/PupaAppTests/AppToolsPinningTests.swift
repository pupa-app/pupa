import Foundation
import Testing
import AGUIKit
@testable import PupaApp

/// Tests for the multi-miniApp race fix in `AppTools.registerMiniAppTools`.
/// Tools registered for a miniApp close over a fixed `miniAppId` at construction
/// time and route every mutator through that pinned id — so a tool firing
/// while the user has switched the visible miniApp to a different one still
/// mutates the miniApp the stream was started in. This is the property that
/// makes per-miniApp concurrent streams safe (issue #17).
@MainActor
@Suite("AppTools miniApp pinning")
struct AppToolsPinningTests {

    private func makeStore() -> (store: MiniAppStore, a: UUID, b: UUID) {
        MiniAppTypeRegistry.shared.registerBuiltins()
        let miniAppA = MiniApp(name: "A", iconSystemName: "circle", typeId: MiniAppType.tracker.id)
        let miniAppB = MiniApp(name: "B", iconSystemName: "square", typeId: MiniAppType.tracker.id)
        let store = MiniAppStore(initial: ([miniAppA, miniAppB], miniAppA.id))
        return (store, miniAppA.id, miniAppB.id)
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

    private func itemCount(_ store: MiniAppStore, miniAppId: UUID) -> Int {
        guard let miniApp = store.miniApps.first(where: { $0.id == miniAppId }) else { return -1 }
        if case .tracker(let t) = miniApp.canvas { return t.items.count }
        return 0
    }

    @Test("Tool pinned to miniApp A mutates A even when active miniApp is B")
    func toolHonoursPinnedSpaceId() async throws {
        let (store, idA, idB) = makeStore()
        let registry = ToolRegistry()
        AppTools.registerMiniAppTools(on: registry, store: store, miniAppId: idA)

        try await renderTracker(registry)
        store.setActive(idB)  // user navigates away mid-turn
        try await addItem(registry, note: "from-A-stream")

        #expect(itemCount(store, miniAppId: idA) == 1)
        #expect(itemCount(store, miniAppId: idB) == 0)
    }

    @Test("Two registries pinned to different miniApps mutate independently")
    func twoRegistriesAreIndependent() async throws {
        let (store, idA, idB) = makeStore()
        let regA = ToolRegistry()
        let regB = ToolRegistry()
        AppTools.registerMiniAppTools(on: regA, store: store, miniAppId: idA)
        AppTools.registerMiniAppTools(on: regB, store: store, miniAppId: idB)

        try await renderTracker(regA)
        try await renderTracker(regB)
        try await addItem(regA, note: "a1")
        try await addItem(regA, note: "a2")
        try await addItem(regB, note: "b1")

        #expect(itemCount(store, miniAppId: idA) == 2)
        #expect(itemCount(store, miniAppId: idB) == 1)
    }

    @Test("getCanvasState resolves the pinned miniApp's canvas, ignoring active selection")
    func getCanvasStateReadsPinned() async throws {
        let (store, idA, idB) = makeStore()
        let regA = ToolRegistry()
        AppTools.registerMiniAppTools(on: regA, store: store, miniAppId: idA)

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

    @Test("clearCanvas only resets the pinned miniApp")
    func clearCanvasIsPinned() async throws {
        let (store, idA, idB) = makeStore()
        let regA = ToolRegistry()
        let regB = ToolRegistry()
        AppTools.registerMiniAppTools(on: regA, store: store, miniAppId: idA)
        AppTools.registerMiniAppTools(on: regB, store: store, miniAppId: idB)

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
        if case .empty = store.miniApps.first(where: { $0.id == idB })?.canvas {
            // ok
        } else {
            Issue.record("miniApp B canvas should be .empty after clearCanvas")
        }
        #expect(itemCount(store, miniAppId: idA) == 1)
    }

    @Test("getActiveComponent reports the pinned miniApp's focused component")
    func getActiveComponentReadsView() async throws {
        let (store, idA, _) = makeStore()
        let regA = ToolRegistry()
        AppTools.registerMiniAppTools(on: regA, store: store, miniAppId: idA)

        try await renderTracker(regA)
        let compId = store.miniApps.first(where: { $0.id == idA })!.components.first!.id
        _ = store.setActiveComponent(componentId: compId, miniAppId: idA)

        guard let get = regA.resolve("getActiveComponent") else {
            Issue.record("getActiveComponent not registered")
            return
        }
        let result = try await get.handler(.object([:]))
        #expect(result.objectValue?["activeComponentId"]?.stringValue == compId)
        #expect(result.objectValue?["kind"]?.stringValue == "tracker")
    }
}
