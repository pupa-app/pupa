import Foundation
import Testing
@testable import PupaApp

/// Guards suite isolation on the shared test storage root: background disk
/// writers (debounced mirror reconciles, snapshot captures) must never leak
/// past a quiesce point (`StorageMirror.drain()` / `MyAppStore.clearStorage()`)
/// and fire into a later test's environment.
@MainActor
@Suite("Storage quiescence", .serialized)
struct StorageQuiescenceTests {

    init() { TestStorage.activate() }

    @Test("drain() prevents a leaked debounced reconcile from firing into a later cloud override")
    func drainQuiescesPendingReconcile() async throws {
        await MyAppStore.clearStorage()
        // Arm: any CloudDocument write schedules a 0.5s reconcile (override nil now).
        try CloudDocument.write(
            Data("x".utf8),
            to: PupaStorage.stateRoot.appendingPathComponent("probe.json"))
        await StorageMirror.shared.drain()
        // A "later test" installs a fresh mirror and expects it untouched.
        let cloud = TestStorage.root.appendingPathComponent("cloud-\(UUID().uuidString)", isDirectory: true)
        try await TestStorage.withCloudMirror(cloud) {
            try await Task.sleep(for: .seconds(1))            // past the 0.5s debounce
            #expect(!FileManager.default.fileExists(atPath: cloud.path))
            #expect(!FileManager.default.fileExists(
                atPath: PupaStorage.activeRoot.appendingPathComponent(".mirror-baseline.json").path))
        }
    }

    @Test("clearStorage expires armed snapshot debounces — no late write resurrects state/")
    func lateSnapshotCannotResurrectClearedStorage() async throws {
        let saved = MyAppStore.snapshotDebounceNanos
        MyAppStore.snapshotDebounceNanos = 50_000_000         // 50ms
        defer { MyAppStore.snapshotDebounceNanos = saved }

        await MyAppStore.clearStorage()
        let store = MyAppStore()                              // kept alive past clear
        _ = store.addMyApp(typeId: "tracker", name: "Ghost", iconSystemName: "star")
        await MyAppStore.clearStorage()                       // bumps epoch
        try await Task.sleep(for: .milliseconds(300))         // outlive the debounce
        let snapshots = PupaStorage.stateRoot.appendingPathComponent("snapshots")
        #expect(!FileManager.default.fileExists(atPath: snapshots.path))
        withExtendedLifetime(store) {}
    }
}
