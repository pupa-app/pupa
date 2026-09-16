import Foundation
import Testing
@testable import PupaApp

/// Write-bearing non-tracker kinds, shared by the parameterized suite
/// below. Lives at file scope so the `@Test(arguments:)` macro can read
/// it without tripping the suite's `@MainActor` isolation.
private let writeBearingKinds = ["calendar", "checklist", "chart", "slack"]

/// Pins the deterministic write-target resolution added to stop tracker
/// writes from silently routing by the active/view component. Writes now
/// name their target via `componentId`; when omitted the target is only
/// accepted when it is unambiguous. Ambiguity is a `.failure` the tool
/// layer echoes to the agent, never a silent guess.
@MainActor
@Suite("deterministic tracker write targets")
struct DeterministicWriteTargetTests {

    private func makeStore(trackerCount: Int) -> (MiniAppStore, UUID, [String]) {
        MiniAppTypeRegistry.shared.registerBuiltins()
        let miniApp = MiniApp(
            name: "T",
            iconSystemName: "list.bullet.rectangle",
            typeId: MiniAppType.tracker.id
        )
        let store = MiniAppStore(initial: ([miniApp], miniApp.id))
        var ids: [String] = []
        for i in 0..<trackerCount {
            let id = store.addComponent(
                kind: "tracker",
                name: "T\(i)",
                iconSystemName: "book",
                miniAppId: miniApp.id
            )!
            store.setTracker(
                title: "T\(i)",
                fields: [FieldDef(name: "title", type: .text)],
                miniAppId: miniApp.id,
                componentId: id
            )
            ids.append(id)
        }
        return (store, miniApp.id, ids)
    }

    private func resolved(_ r: MiniAppStore.TrackerTargetResolution) -> String? {
        if case .resolved(let id) = r { return id }
        return nil
    }

    private func failed(_ r: MiniAppStore.TrackerTargetResolution) -> Bool {
        if case .failure = r { return true }
        return false
    }

    @Test("one tracker + no componentId → resolves to the sole tracker")
    func singleTrackerNoId() {
        let (store, miniAppId, ids) = makeStore(trackerCount: 1)
        let r = store.resolveTrackerWriteTarget(componentId: nil, miniAppId: miniAppId)
        #expect(resolved(r) == ids[0])
    }

    @Test("multiple trackers + no componentId → ambiguity failure, never a guess")
    func multipleTrackersNoIdIsAmbiguous() {
        let (store, miniAppId, _) = makeStore(trackerCount: 2)
        let r = store.resolveTrackerWriteTarget(componentId: nil, miniAppId: miniAppId)
        #expect(failed(r))
    }

    @Test("explicit componentId is honoured exactly, regardless of which is active")
    func explicitIdHonoured() {
        let (store, miniAppId, ids) = makeStore(trackerCount: 2)
        // Active is the last-created tracker; ask for the first one.
        let r = store.resolveTrackerWriteTarget(componentId: ids[0], miniAppId: miniAppId)
        #expect(resolved(r) == ids[0])
    }

    @Test("unknown componentId → failure, no fallback to active")
    func unknownIdFails() {
        let (store, miniAppId, _) = makeStore(trackerCount: 2)
        let r = store.resolveTrackerWriteTarget(componentId: "tracker-999", miniAppId: miniAppId)
        #expect(failed(r))
    }

    @Test("componentId pointing at a non-tracker kind → failure")
    func wrongKindFails() {
        let (store, miniAppId, _) = makeStore(trackerCount: 1)
        let cal = store.addComponent(kind: "calendar", name: "C", iconSystemName: "calendar", miniAppId: miniAppId)!
        let r = store.resolveTrackerWriteTarget(componentId: cal, miniAppId: miniAppId)
        #expect(failed(r))
    }

    @Test("no tracker → item write fails with a create-first message")
    func noTrackerFails() {
        MiniAppTypeRegistry.shared.registerBuiltins()
        let miniApp = MiniApp(name: "T", iconSystemName: "x", typeId: MiniAppType.tracker.id)
        let store = MiniAppStore(initial: ([miniApp], miniApp.id))
        let r = store.resolveTrackerWriteTarget(componentId: nil, miniAppId: miniApp.id)
        #expect(failed(r))
    }

    @Test("renderTarget resolves into the lone empty seed (bootstrap preserved)")
    func renderIntoEmptySeed() {
        MiniAppTypeRegistry.shared.registerBuiltins()
        let miniApp = MiniApp(name: "T", iconSystemName: "x", typeId: MiniAppType.tracker.id)
        let store = MiniAppStore(initial: ([miniApp], miniApp.id))
        let seedId = store.miniApps.first(where: { $0.id == miniApp.id })!.components.first!.id
        let r = store.resolveTrackerRenderTarget(componentId: nil, miniAppId: miniApp.id)
        #expect(resolved(r) == seedId)
    }

    @Test("renderTarget with multiple trackers + no id is ambiguous")
    func renderMultipleTrackersAmbiguous() {
        let (store, miniAppId, _) = makeStore(trackerCount: 2)
        let r = store.resolveTrackerRenderTarget(componentId: nil, miniAppId: miniAppId)
        #expect(failed(r))
    }
}

/// The tracker resolver generalized to every write-bearing kind
/// (calendar / checklist / chart / slack). Same contract: explicit id
/// honoured or failed loudly; omitted id resolved only when the miniApp
/// holds exactly one component of that kind; ambiguity is a `.failure`,
/// never a silent guess by the active/view component.
@MainActor
@Suite("deterministic write targets — all kinds")
struct DeterministicWriteTargetAllKindsTests {

    /// A miniApp with `count` components of `kind`, returning their ids.
    private func makeStore(kind: String, count: Int) -> (MiniAppStore, UUID, [String]) {
        MiniAppTypeRegistry.shared.registerBuiltins()
        let miniApp = MiniApp(name: "T", iconSystemName: "x", typeId: MiniAppType.tracker.id)
        let store = MiniAppStore(initial: ([miniApp], miniApp.id))
        var ids: [String] = []
        for i in 0..<count {
            ids.append(store.addComponent(kind: kind, name: "\(kind)\(i)", iconSystemName: "x", miniAppId: miniApp.id)!)
        }
        return (store, miniApp.id, ids)
    }

    private func resolved(_ r: MiniAppStore.WriteTargetResolution) -> String? {
        if case .resolved(let id) = r { return id }
        return nil
    }

    private func failed(_ r: MiniAppStore.WriteTargetResolution) -> Bool {
        if case .failure = r { return true }
        return false
    }

    @Test("single component + no id → resolves to the sole one", arguments: writeBearingKinds)
    func singleNoId(kind: String) {
        let (store, miniAppId, ids) = makeStore(kind: kind, count: 1)
        #expect(resolved(store.resolveWriteTarget(kind: kind, componentId: nil, miniAppId: miniAppId)) == ids[0])
    }

    @Test("multiple components + no id → ambiguity failure", arguments: writeBearingKinds)
    func multipleNoIdAmbiguous(kind: String) {
        let (store, miniAppId, _) = makeStore(kind: kind, count: 2)
        #expect(failed(store.resolveWriteTarget(kind: kind, componentId: nil, miniAppId: miniAppId)))
    }

    @Test("explicit id honoured regardless of active", arguments: writeBearingKinds)
    func explicitIdHonoured(kind: String) {
        let (store, miniAppId, ids) = makeStore(kind: kind, count: 2)
        // Active is the last-created; ask for the first.
        #expect(resolved(store.resolveWriteTarget(kind: kind, componentId: ids[0], miniAppId: miniAppId)) == ids[0])
    }

    @Test("unknown id → failure, no fallback to active", arguments: writeBearingKinds)
    func unknownIdFails(kind: String) {
        let (store, miniAppId, _) = makeStore(kind: kind, count: 2)
        #expect(failed(store.resolveWriteTarget(kind: kind, componentId: "\(kind)-999", miniAppId: miniAppId)))
    }

    @Test("id pointing at a different kind → failure", arguments: writeBearingKinds)
    func wrongKindFails(kind: String) {
        let (store, miniAppId, ids) = makeStore(kind: kind, count: 1)
        // Add one tracker; asking for it under `kind` must fail.
        let other = store.addComponent(kind: "tracker", name: "T", iconSystemName: "x", miniAppId: miniAppId)!
        #expect(failed(store.resolveWriteTarget(kind: kind, componentId: other, miniAppId: miniAppId)))
        // The real same-kind component still resolves.
        #expect(resolved(store.resolveWriteTarget(kind: kind, componentId: ids[0], miniAppId: miniAppId)) == ids[0])
    }

    @Test("no component of the kind → create-first failure", arguments: writeBearingKinds)
    func noneFails(kind: String) {
        MiniAppTypeRegistry.shared.registerBuiltins()
        let miniApp = MiniApp(name: "T", iconSystemName: "x", typeId: MiniAppType.tracker.id)
        let store = MiniAppStore(initial: ([miniApp], miniApp.id))
        // Fresh app holds only an empty seed — a write (not a render) fails.
        #expect(failed(store.resolveWriteTarget(kind: kind, componentId: nil, miniAppId: miniApp.id)))
    }

    @Test("renderTarget resolves into the lone empty seed", arguments: writeBearingKinds)
    func renderIntoEmptySeed(kind: String) {
        MiniAppTypeRegistry.shared.registerBuiltins()
        let miniApp = MiniApp(name: "T", iconSystemName: "x", typeId: MiniAppType.tracker.id)
        let store = MiniAppStore(initial: ([miniApp], miniApp.id))
        let seedId = store.miniApps.first(where: { $0.id == miniApp.id })!.components.first!.id
        #expect(resolved(store.resolveRenderTarget(kind: kind, componentId: nil, miniAppId: miniApp.id)) == seedId)
    }

    @Test("renderTarget with multiple same-kind + no id is ambiguous", arguments: writeBearingKinds)
    func renderMultipleAmbiguous(kind: String) {
        let (store, miniAppId, _) = makeStore(kind: kind, count: 2)
        #expect(failed(store.resolveRenderTarget(kind: kind, componentId: nil, miniAppId: miniAppId)))
    }
}
