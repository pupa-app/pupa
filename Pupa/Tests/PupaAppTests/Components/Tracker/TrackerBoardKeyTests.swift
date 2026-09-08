import Foundation
import Testing
import AGUIKit
@testable import PupaApp

/// `CanvasComponentKey` is what scopes `TrackerView` / `KanbanView` `@State`
/// (search query, filter-panel disclosure) to one board. These tests pin the
/// premise it exists for: component ids are unique per MyApp, not globally.
@MainActor
@Suite("Tracker board key")
struct CanvasComponentKeyTests {

    private func makeMyApp(_ name: String) -> MyApp {
        MyAppTypeRegistry.shared.registerBuiltins()
        return MyApp(name: name, iconSystemName: "list.bullet.rectangle", typeId: MyAppType.tracker.id)
    }

    /// The bug this type fixes: `MyAppStore.addComponent` uniques the id
    /// against that MyApp's own components only, so the first tracker in every
    /// MyApp is `"tracker-1"`. Keying view state on the component id alone
    /// therefore aliases two different boards — one MyApp's search query
    /// rendered the next MyApp's tracker after a sidebar switch.
    @Test("Two MyApps each mint tracker-1; their board keys still differ")
    func componentIdsRepeatAcrossMyApps() {
        let a = makeMyApp("A")
        let b = makeMyApp("B")
        let store = MyAppStore(initial: ([a, b], a.id))

        let idA = store.addComponent(kind: "tracker", name: "Board A", iconSystemName: "tablecells", myAppId: a.id)
        let idB = store.addComponent(kind: "tracker", name: "Board B", iconSystemName: "tablecells", myAppId: b.id)

        // The premise, asserted against the real store — not assumed.
        #expect(idA == "tracker-1")
        #expect(idB == "tracker-1")

        // ... which is exactly why the component id cannot be the key.
        #expect(idA == idB)
        #expect(
            CanvasComponentKey(myAppId: a.id, componentId: idA)
            != CanvasComponentKey(myAppId: b.id, componentId: idB)
        )
    }

    /// Within one MyApp ids do stay distinct, so board keys separate those
    /// boards too — a MyApp with two trackers must not share a query.
    @Test("Second tracker in the same MyApp gets a distinct id and key")
    func componentIdsAreUniqueWithinOneMyApp() {
        let a = makeMyApp("A")
        let store = MyAppStore(initial: ([a], a.id))

        let first = store.addComponent(kind: "tracker", name: "One", iconSystemName: "tablecells", myAppId: a.id)
        let second = store.addComponent(kind: "tracker", name: "Two", iconSystemName: "tablecells", myAppId: a.id)

        #expect(first == "tracker-1")
        #expect(second == "tracker-2")
        #expect(
            CanvasComponentKey(myAppId: a.id, componentId: first)
            != CanvasComponentKey(myAppId: a.id, componentId: second)
        )
    }

    /// Same board, two lookups: equal and same hash, so a dictionary read
    /// written by `TrackerView` finds its own entry.
    @Test("Same myApp + component id is one key")
    func sameBoardIsOneKey() {
        let id = UUID()
        let lhs = CanvasComponentKey(myAppId: id, componentId: "tracker-1")
        let rhs = CanvasComponentKey(myAppId: id, componentId: "tracker-1")

        #expect(lhs == rhs)
        #expect(lhs.hashValue == rhs.hashValue)
        var state: [CanvasComponentKey: String] = [:]
        state[lhs] = "urgent"
        #expect(state[rhs] == "urgent")
    }

    /// Legacy init paths pass `componentId: nil`. It normalises to `""`, so nil
    /// and empty are one slot — matching the `?? ""` the views used before.
    @Test("nil and empty component ids alias")
    func nilAndEmptyComponentIdAlias() {
        let id = UUID()
        #expect(
            CanvasComponentKey(myAppId: id, componentId: nil)
            == CanvasComponentKey(myAppId: id, componentId: "")
        )
        #expect(CanvasComponentKey(myAppId: id, componentId: nil).componentId == "")
    }

    /// The other half of the identity: two MyApps sharing a component id must
    /// not read each other's state out of a board-keyed dictionary.
    @Test("Different myAppIds with the same component id do not collide")
    func differentMyAppIdsDoNotCollide() {
        let lhs = CanvasComponentKey(myAppId: UUID(), componentId: "tracker-1")
        let rhs = CanvasComponentKey(myAppId: UUID(), componentId: "tracker-1")

        #expect(lhs != rhs)
        var state: [CanvasComponentKey: String] = [:]
        state[lhs] = "A's query"
        // Board B reads its own (absent) entry rather than inheriting A's.
        #expect(state[rhs] == nil)
        #expect(state.count == 1)
    }
}
