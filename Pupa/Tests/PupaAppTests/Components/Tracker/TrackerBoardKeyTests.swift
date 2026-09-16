import Foundation
import Testing
import AGUIKit
@testable import PupaApp

/// `TrackerBoardKey` is what scopes `TrackerView` / `KanbanView` `@State`
/// (search query, filter-panel disclosure) to one board. These tests pin the
/// premise it exists for: component ids are unique per MiniApp, not globally.
@MainActor
@Suite("Tracker board key")
struct TrackerBoardKeyTests {

    private func makeMiniApp(_ name: String) -> MiniApp {
        MiniAppTypeRegistry.shared.registerBuiltins()
        return MiniApp(name: name, iconSystemName: "list.bullet.rectangle", typeId: MiniAppType.tracker.id)
    }

    /// The bug this type fixes: `MiniAppStore.addComponent` uniques the id
    /// against that MiniApp's own components only, so the first tracker in every
    /// MiniApp is `"tracker-1"`. Keying view state on the component id alone
    /// therefore aliases two different boards — one MiniApp's search query
    /// rendered the next MiniApp's tracker after a sidebar switch.
    @Test("Two MiniApps each mint tracker-1; their board keys still differ")
    func componentIdsRepeatAcrossMiniApps() {
        let a = makeMiniApp("A")
        let b = makeMiniApp("B")
        let store = MiniAppStore(initial: ([a, b], a.id))

        let idA = store.addComponent(kind: "tracker", name: "Board A", iconSystemName: "tablecells", miniAppId: a.id)
        let idB = store.addComponent(kind: "tracker", name: "Board B", iconSystemName: "tablecells", miniAppId: b.id)

        // The premise, asserted against the real store — not assumed.
        #expect(idA == "tracker-1")
        #expect(idB == "tracker-1")

        // ... which is exactly why the component id cannot be the key.
        #expect(idA == idB)
        #expect(
            TrackerBoardKey(miniAppId: a.id, componentId: idA)
            != TrackerBoardKey(miniAppId: b.id, componentId: idB)
        )
    }

    /// Within one MiniApp ids do stay distinct, so board keys separate those
    /// boards too — a MiniApp with two trackers must not share a query.
    @Test("Second tracker in the same MiniApp gets a distinct id and key")
    func componentIdsAreUniqueWithinOneMiniApp() {
        let a = makeMiniApp("A")
        let store = MiniAppStore(initial: ([a], a.id))

        let first = store.addComponent(kind: "tracker", name: "One", iconSystemName: "tablecells", miniAppId: a.id)
        let second = store.addComponent(kind: "tracker", name: "Two", iconSystemName: "tablecells", miniAppId: a.id)

        #expect(first == "tracker-1")
        #expect(second == "tracker-2")
        #expect(
            TrackerBoardKey(miniAppId: a.id, componentId: first)
            != TrackerBoardKey(miniAppId: a.id, componentId: second)
        )
    }

    /// Same board, two lookups: equal and same hash, so a dictionary read
    /// written by `TrackerView` finds its own entry.
    @Test("Same miniApp + component id is one key")
    func sameBoardIsOneKey() {
        let id = UUID()
        let lhs = TrackerBoardKey(miniAppId: id, componentId: "tracker-1")
        let rhs = TrackerBoardKey(miniAppId: id, componentId: "tracker-1")

        #expect(lhs == rhs)
        #expect(lhs.hashValue == rhs.hashValue)
        var state: [TrackerBoardKey: String] = [:]
        state[lhs] = "urgent"
        #expect(state[rhs] == "urgent")
    }

    /// Legacy init paths pass `componentId: nil`. It normalises to `""`, so nil
    /// and empty are one slot — matching the `?? ""` the views used before.
    @Test("nil and empty component ids alias")
    func nilAndEmptyComponentIdAlias() {
        let id = UUID()
        #expect(
            TrackerBoardKey(miniAppId: id, componentId: nil)
            == TrackerBoardKey(miniAppId: id, componentId: "")
        )
        #expect(TrackerBoardKey(miniAppId: id, componentId: nil).componentId == "")
    }

    /// The other half of the identity: two MiniApps sharing a component id must
    /// not read each other's state out of a board-keyed dictionary.
    @Test("Different miniAppIds with the same component id do not collide")
    func differentMiniAppIdsDoNotCollide() {
        let lhs = TrackerBoardKey(miniAppId: UUID(), componentId: "tracker-1")
        let rhs = TrackerBoardKey(miniAppId: UUID(), componentId: "tracker-1")

        #expect(lhs != rhs)
        var state: [TrackerBoardKey: String] = [:]
        state[lhs] = "A's query"
        // Board B reads its own (absent) entry rather than inheriting A's.
        #expect(state[rhs] == nil)
        #expect(state.count == 1)
    }
}
