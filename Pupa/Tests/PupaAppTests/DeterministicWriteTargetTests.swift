import Foundation
import Testing
@testable import PupaApp

/// Pins the deterministic write-target resolution added to stop tracker
/// writes from silently routing by the active/view component. Writes now
/// name their target via `componentId`; when omitted the target is only
/// accepted when it is unambiguous. Ambiguity is a `.failure` the tool
/// layer echoes to the agent, never a silent guess.
@MainActor
@Suite("deterministic tracker write targets")
struct DeterministicWriteTargetTests {

    private func makeStore(trackerCount: Int) -> (MyAppStore, UUID, [String]) {
        MyAppTypeRegistry.shared.registerBuiltins()
        let myApp = MyApp(
            name: "T",
            iconSystemName: "list.bullet.rectangle",
            typeId: MyAppType.tracker.id
        )
        let store = MyAppStore(initial: ([myApp], myApp.id))
        var ids: [String] = []
        for i in 0..<trackerCount {
            let id = store.addComponent(
                kind: "tracker",
                name: "T\(i)",
                iconSystemName: "book",
                myAppId: myApp.id
            )!
            store.setTracker(
                title: "T\(i)",
                fields: [FieldDef(name: "title", type: .text)],
                myAppId: myApp.id,
                componentId: id
            )
            ids.append(id)
        }
        return (store, myApp.id, ids)
    }

    private func resolved(_ r: MyAppStore.TrackerTargetResolution) -> String? {
        if case .resolved(let id) = r { return id }
        return nil
    }

    private func failed(_ r: MyAppStore.TrackerTargetResolution) -> Bool {
        if case .failure = r { return true }
        return false
    }

    @Test("one tracker + no componentId → resolves to the sole tracker")
    func singleTrackerNoId() {
        let (store, myAppId, ids) = makeStore(trackerCount: 1)
        let r = store.resolveTrackerWriteTarget(componentId: nil, myAppId: myAppId)
        #expect(resolved(r) == ids[0])
    }

    @Test("multiple trackers + no componentId → ambiguity failure, never a guess")
    func multipleTrackersNoIdIsAmbiguous() {
        let (store, myAppId, _) = makeStore(trackerCount: 2)
        let r = store.resolveTrackerWriteTarget(componentId: nil, myAppId: myAppId)
        #expect(failed(r))
    }

    @Test("explicit componentId is honoured exactly, regardless of which is active")
    func explicitIdHonoured() {
        let (store, myAppId, ids) = makeStore(trackerCount: 2)
        // Active is the last-created tracker; ask for the first one.
        let r = store.resolveTrackerWriteTarget(componentId: ids[0], myAppId: myAppId)
        #expect(resolved(r) == ids[0])
    }

    @Test("unknown componentId → failure, no fallback to active")
    func unknownIdFails() {
        let (store, myAppId, _) = makeStore(trackerCount: 2)
        let r = store.resolveTrackerWriteTarget(componentId: "tracker-999", myAppId: myAppId)
        #expect(failed(r))
    }

    @Test("componentId pointing at a non-tracker kind → failure")
    func wrongKindFails() {
        let (store, myAppId, _) = makeStore(trackerCount: 1)
        let cal = store.addComponent(kind: "calendar", name: "C", iconSystemName: "calendar", myAppId: myAppId)!
        let r = store.resolveTrackerWriteTarget(componentId: cal, myAppId: myAppId)
        #expect(failed(r))
    }

    @Test("no tracker → item write fails with a create-first message")
    func noTrackerFails() {
        MyAppTypeRegistry.shared.registerBuiltins()
        let myApp = MyApp(name: "T", iconSystemName: "x", typeId: MyAppType.tracker.id)
        let store = MyAppStore(initial: ([myApp], myApp.id))
        let r = store.resolveTrackerWriteTarget(componentId: nil, myAppId: myApp.id)
        #expect(failed(r))
    }

    @Test("renderTarget resolves into the lone empty seed (bootstrap preserved)")
    func renderIntoEmptySeed() {
        MyAppTypeRegistry.shared.registerBuiltins()
        let myApp = MyApp(name: "T", iconSystemName: "x", typeId: MyAppType.tracker.id)
        let store = MyAppStore(initial: ([myApp], myApp.id))
        let seedId = store.myApps.first(where: { $0.id == myApp.id })!.components.first!.id
        let r = store.resolveTrackerRenderTarget(componentId: nil, myAppId: myApp.id)
        #expect(resolved(r) == seedId)
    }

    @Test("renderTarget with multiple trackers + no id is ambiguous")
    func renderMultipleTrackersAmbiguous() {
        let (store, myAppId, _) = makeStore(trackerCount: 2)
        let r = store.resolveTrackerRenderTarget(componentId: nil, myAppId: myAppId)
        #expect(failed(r))
    }
}
