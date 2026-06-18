import Foundation
import Testing
@testable import PupaApp

/// Tests for `MyAppStore.updateComponentMeta` — the in-place name / icon /
/// description (summary) editor behind the `setComponentMeta` agent tool and
/// the sidebar "Rename / icon…" sheet. Pins that the constant `id` and the
/// component's data survive (the whole point: no delete-and-re-add), that
/// partial edits leave other fields alone, and that edits round-trip through
/// the Codable bundle format.
@MainActor
@Suite("Component metadata editing")
struct ComponentMetaTests {

    private struct Fixture {
        let store: MyAppStore
        let myAppId: UUID
        let compId: String
    }

    private func freshFixture() -> Fixture {
        MyAppTypeRegistry.shared.registerBuiltins()
        let myApp = MyApp(
            name: "T",
            iconSystemName: "list.bullet.rectangle",
            typeId: MyAppType.tracker.id
        )
        let store = MyAppStore(initial: ([myApp], myApp.id))
        store.addComponent(kind: "tracker", name: "Books", iconSystemName: "book", myAppId: myApp.id)
        store.setTracker(
            title: "Books",
            fields: [FieldDef(name: "title", type: .text)],
            myAppId: myApp.id
        )
        _ = store.addItem(["title": "Hail Mary"], myAppId: myApp.id)
        let compId = store.myApps[0].components.first(where: { $0.kindString == "tracker" })!.id
        return Fixture(store: store, myAppId: myApp.id, compId: compId)
    }

    private func component(_ f: Fixture) -> Component {
        f.store.myApps[0].components.first(where: { $0.id == f.compId })!
    }

    @Test("Rename + re-icon + describe keeps the id and the data")
    func updatesMetaPreservingData() {
        let f = freshFixture()
        let changed = f.store.updateComponentMeta(
            componentId: f.compId,
            name: "Reading",
            iconSystemName: "books.vertical",
            summary: "Books I'm reading",
            myAppId: f.myAppId
        )
        #expect(changed)
        let comp = component(f)
        #expect(comp.id == f.compId)
        #expect(comp.name == "Reading")
        #expect(comp.iconSystemName == "books.vertical")
        #expect(comp.summary == "Books I'm reading")
        guard case .tracker(let t) = comp.body else {
            Issue.record("expected tracker body")
            return
        }
        #expect(t.items.count == 1)
    }

    @Test("nil arguments leave fields untouched; whitespace summary clears")
    func partialEditsAndClear() {
        let f = freshFixture()
        _ = f.store.updateComponentMeta(componentId: f.compId, summary: "note", myAppId: f.myAppId)
        _ = f.store.updateComponentMeta(componentId: f.compId, name: "Renamed", myAppId: f.myAppId)
        var comp = component(f)
        #expect(comp.name == "Renamed")
        #expect(comp.iconSystemName == "book")   // never passed → untouched
        #expect(comp.summary == "note")          // the rename call didn't touch it

        _ = f.store.updateComponentMeta(componentId: f.compId, summary: "   ", myAppId: f.myAppId)
        comp = component(f)
        #expect(comp.summary == nil)             // whitespace clears
    }

    @Test("A no-op edit reports no change")
    func noOpReturnsFalse() {
        let f = freshFixture()
        let changed = f.store.updateComponentMeta(
            componentId: f.compId, name: "Books", iconSystemName: "book", myAppId: f.myAppId)
        #expect(!changed)
    }

    @Test("An all-whitespace name is ignored")
    func blankNameIgnored() {
        let f = freshFixture()
        _ = f.store.updateComponentMeta(componentId: f.compId, name: "   ", myAppId: f.myAppId)
        #expect(component(f).name == "Books")
    }

    @Test("Edited metadata survives a Codable round-trip")
    func codableRoundTrip() throws {
        let f = freshFixture()
        _ = f.store.updateComponentMeta(
            componentId: f.compId,
            name: "Reading",
            iconSystemName: "books.vertical",
            summary: "desc",
            myAppId: f.myAppId
        )
        let original = component(f)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Component.self, from: data)
        #expect(decoded.id == f.compId)
        #expect(decoded.name == "Reading")
        #expect(decoded.iconSystemName == "books.vertical")
        #expect(decoded.summary == "desc")
    }
}
