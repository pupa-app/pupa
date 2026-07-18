import Foundation
import Testing
@testable import PupaApp

/// The seed-race data-loss fix. A device whose local store is empty at launch
/// must NOT seed-and-push a default roster over the real one already in iCloud —
/// that is the reported "all MyApps replaced by Daily Briefing" wipe. Instead it
/// *provisions* (holds an in-memory placeholder, persists nothing) and
/// `finishProvisioning()` either adopts the pulled cloud roster or seeds only
/// when the cloud is genuinely empty.
@MainActor
@Suite("Provisioning (seed-race fix)", .serialized)
struct ProvisioningTests {
    init() { TestStorage.activate() }

    /// THE regression: a fresh device against a populated cloud must adopt the
    /// real roster and leave the cloud index untouched (no seed pushed).
    @Test("fresh device + populated cloud adopts the roster and never clobbers it")
    func freshDeviceWithPopulatedCloudAdoptsAndDoesNotClobber() async throws {
        await MyAppStore.clearStorage()

        // Device 1 (iCloud off): seed + two more = a 3-app roster on local disk.
        let d1 = MyAppStore()
        let a = d1.addMyApp(typeId: "tracker", name: "Alpha", iconSystemName: "a.circle")
        let b = d1.addMyApp(typeId: "tracker", name: "Bravo", iconSystemName: "b.circle")
        #expect(d1.myApps.count == 3)

        // Push that roster up into the iCloud mirror.
        let cloud = TestStorage.root.appendingPathComponent("cloud-\(UUID().uuidString)", isDirectory: true)
        _ = try await TestStorage.withCloudMirror(cloud) {
            StorageMirror.converge(localRoot: PupaStorage.activeRoot, cloudRoot: cloud)
        }
        let cloudApps = cloud.appendingPathComponent("state/apps")
        func cloudAppFileCount() -> Int {
            (try? FileManager.default.contentsOfDirectory(atPath: cloudApps.path))?
                .filter { $0.hasSuffix(".json") }.count ?? 0
        }
        #expect(cloudAppFileCount() == 3)

        // Device 2: wipe local (the cloud dir survives) → empty local + iCloud on.
        await MyAppStore.clearStorage()
        #expect(!PupaStorage.rosterEstablished)

        try await TestStorage.withCloudMirror(cloud) {
            let d2 = MyAppStore()
            // Provisions instead of seeding: nothing written locally yet.
            #expect(d2.isProvisioning)
            #expect(!FileManager.default.fileExists(
                atPath: PupaStorage.stateRoot.appendingPathComponent("index.json").path))

            await d2.finishProvisioning()

            #expect(!d2.isProvisioning)
            #expect(d2.myApps.count == 3)                       // adopted, not seeded-over
            #expect(d2.myApps.contains { $0.id == a })
            #expect(d2.myApps.contains { $0.id == b })
            #expect(PupaStorage.rosterEstablished)
            // Cloud roster still intact — the seed never overwrote it.
            #expect(cloudAppFileCount() == 3)
        }
    }

    /// A genuinely fresh device (empty cloud too) seeds the default after the
    /// provisioning wait — never left empty.
    @Test("fresh device + empty cloud seeds the default once")
    func freshDeviceEmptyCloudSeeds() async throws {
        await MyAppStore.clearStorage()
        let saved = MyAppStore.provisioningTimeout
        MyAppStore.provisioningTimeout = .milliseconds(300)   // don't burn the full wait
        defer { MyAppStore.provisioningTimeout = saved }
        let cloud = TestStorage.root.appendingPathComponent("cloud-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: cloud, withIntermediateDirectories: true)

        try await TestStorage.withCloudMirror(cloud) {
            let store = MyAppStore()
            #expect(store.isProvisioning)
            await store.finishProvisioning()
            #expect(!store.isProvisioning)
            #expect(store.myApps.count == 1)                    // seeded Daily Briefing
            #expect(PupaStorage.rosterEstablished)
            #expect(FileManager.default.fileExists(
                atPath: PupaStorage.stateRoot.appendingPathComponent("index.json").path))
        }
    }

    /// With iCloud off there's nothing to wait for — seed immediately as before.
    @Test("iCloud off still seeds immediately (no provisioning)")
    func iCloudOffStillSeedsImmediately() async throws {
        await MyAppStore.clearStorage()
        #expect(PupaStorage.cloudMirrorRoot == nil)
        let store = MyAppStore()
        #expect(!store.isProvisioning)
        #expect(store.myApps.count == 1)
        #expect(PupaStorage.rosterEstablished)
    }
}
