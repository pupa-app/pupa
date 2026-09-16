import Foundation
import Testing
@testable import PupaApp

/// A MiniApp's accent color is a stable, stored palette slot — not its position
/// in a list. Deleting one app must never slide another app's color onto a
/// neighbour, and the slot is user-settable (choosable).
@MainActor
@Suite("MiniApp color")
struct MiniAppColorTests {

    init() { TestStorage.activate() }

    private func store(_ names: [String]) -> (MiniAppStore, [UUID]) {
        MiniAppTypeRegistry.shared.registerBuiltins()
        let base = Date(timeIntervalSince1970: 1_000)
        let apps = names.enumerated().map { i, n in
            MiniApp(name: n, iconSystemName: "list.bullet.rectangle",
                  typeId: MiniAppType.tracker.id,
                  createdAt: base.addingTimeInterval(Double(i)))
        }
        let store = MiniAppStore(initial: (apps, apps[0].id))
        return (store, apps.map(\.id))
    }

    @Test("injected apps are backfilled with creation-order slots")
    func backfillOnInject() {
        let (store, ids) = store(["A", "B", "C"])
        #expect(store.colorIndex(for: ids[0]) == 0)
        #expect(store.colorIndex(for: ids[1]) == 1)
        #expect(store.colorIndex(for: ids[2]) == 2)
    }

    @Test("deleting a middle app does not slide its neighbours' colors")
    func deleteDoesNotSlide() {
        let (store, ids) = store(["A", "B", "C"])
        let cSlotBefore = store.colorIndex(for: ids[2])   // 2

        store.removeMiniApp(ids[1])                          // delete the middle app

        // C keeps its own slot instead of sliding down into B's old slot (1).
        #expect(store.colorIndex(for: ids[2]) == cSlotBefore)
        #expect(store.colorIndex(for: ids[2]) == 2)
        #expect(store.colorIndex(for: ids[0]) == 0)
    }

    @Test("a newly added app takes the next free slot, never a live app's")
    func addTakesNextFreeSlot() {
        let (store, ids) = store(["A", "B", "C"])
        store.removeMiniApp(ids[1])                          // frees slot 1, max slot now 2
        let newId = store.addMiniApp(typeId: MiniAppType.tracker.id, name: "D", iconSystemName: "star")
        #expect(store.colorIndex(for: newId) == 3)         // one past the highest live slot
        #expect(store.colorIndex(for: newId) != store.colorIndex(for: ids[0]))
        #expect(store.colorIndex(for: newId) != store.colorIndex(for: ids[2]))
    }

    @Test("color is choosable via setColorIndex")
    func colorIsChoosable() {
        let (store, ids) = store(["A", "B"])
        store.setColorIndex(7, for: ids[0])
        #expect(store.colorIndex(for: ids[0]) == 7)
        #expect(store.colorIndex(for: ids[1]) == 1)        // unaffected
    }

    @Test("colorIndex round-trips through the MiniApp Codable layer; legacy blobs decode nil")
    func codableRoundTrip() throws {
        var app = MiniApp(name: "X", iconSystemName: "list", typeId: MiniAppType.tracker.id)
        app.colorIndex = 5
        let data = try JSONEncoder().encode(app)
        #expect(try JSONDecoder().decode(MiniApp.self, from: data).colorIndex == 5)

        // A blob written before the field existed decodes as nil (then the
        // store backfills it from creation order on load).
        let legacy = MiniApp(name: "Y", iconSystemName: "list", typeId: MiniAppType.tracker.id)
        let plain = try JSONEncoder().encode(legacy)       // encodes no colorIndex key
        #expect(try JSONDecoder().decode(MiniApp.self, from: plain).colorIndex == nil)
    }
}
