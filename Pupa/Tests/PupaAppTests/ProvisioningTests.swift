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

    // MARK: - Awaiting a roster that didn't arrive in the window

    /// The window can expire with a roster still up there, and that branch must
    /// NOT disarm the seed-race guard: until the roster is adopted, one edit to
    /// the placeholder must not push a one-app index over the real one. The
    /// cloud index is deliberately undecodable so the retry never adopts.
    @Test("a roster still inbound keeps the seed-race guard armed")
    func awaitingRosterKeepsGuardArmed() async throws {
        await MyAppStore.clearStorage()
        let saved = MyAppStore.provisioningTimeout
        MyAppStore.provisioningTimeout = .zero          // expire the window immediately
        defer { MyAppStore.provisioningTimeout = saved }

        let cloud = TestStorage.root.appendingPathComponent("cloud-\(UUID().uuidString)", isDirectory: true)
        let cloudIndex = cloud.appendingPathComponent("state/index.json")
        try FileManager.default.createDirectory(
            at: cloudIndex.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: cloudIndex)

        try await TestStorage.withCloudMirror(cloud) {
            let store = MyAppStore()
            #expect(store.isProvisioning)
            await store.finishProvisioning()

            #expect(store.awaitingCloudRoster)
            #expect(store.isProvisioning, "placeholder must stay barred from disk")
            #expect(StorageMirror.provisioning, "placeholder index must stay barred from the cloud")

            // Edit the placeholder and force a converge: neither layer may let
            // it become the cloud roster.
            store.renameMyApp(store.myApps[0].id, to: "Edited placeholder")
            _ = await StorageMirror.shared.reconcile()
            let afterConverge = try Data(contentsOf: cloudIndex)
            #expect(afterConverge == Data("{ not json".utf8),
                    "the placeholder index must never overwrite the cloud roster")

            store.cloudRosterRetry?.cancel()
            await store.cloudRosterRetry?.value
            // Giving up unblocks local writes, but still refuses to let the
            // placeholder win `state/index.json` against a roster we never got.
            #expect(!store.isProvisioning)
            #expect(!store.awaitingCloudRoster)
            #expect(store.pendingCloudDownloads == 0)
            #expect(StorageMirror.provisioning)
        }
    }

    /// The retry's success path. The roster lands on a later poll and only then
    /// do the guards come down.
    @Test("the background retry adopts the roster and only then disarms")
    func retryAdoptsRosterAndDisarms() async throws {
        await MyAppStore.clearStorage()

        // Device 1 puts a real roster in the cloud.
        let d1 = MyAppStore()
        let a = d1.addMyApp(typeId: "tracker", name: "Alpha", iconSystemName: "a.circle")
        let cloud = TestStorage.root.appendingPathComponent("cloud-\(UUID().uuidString)", isDirectory: true)
        _ = try await TestStorage.withCloudMirror(cloud) {
            StorageMirror.converge(localRoot: PupaStorage.activeRoot, cloudRoot: cloud)
        }

        // Device 2 wakes with an empty local store and a window that expires
        // before it can pull — the "stuck on Daily Briefing" report.
        await MyAppStore.clearStorage()
        let saved = MyAppStore.provisioningTimeout
        MyAppStore.provisioningTimeout = .zero
        defer { MyAppStore.provisioningTimeout = saved }

        try await TestStorage.withCloudMirror(cloud) {
            let store = MyAppStore()
            await store.finishProvisioning()
            await store.cloudRosterRetry?.value         // let the retry land it

            #expect(store.myApps.contains { $0.id == a })
            #expect(!store.awaitingCloudRoster)
            #expect(store.pendingCloudDownloads == 0)
            #expect(!store.isProvisioning, "the roster is here — writes are safe again")
            #expect(!StorageMirror.provisioning)
            #expect(PupaStorage.rosterEstablished)
        }
    }

    /// The watcher's reload can land the roster before the retry's next tick.
    /// The retry then has nothing left to find and must stop, taking both
    /// guards with it — else `persist()` stays a no-op for a roster we have.
    @Test("a reload that lands the roster first stops the retry and disarms")
    func reloadDuringWaitStopsRetry() async throws {
        await MyAppStore.clearStorage()

        let d1 = MyAppStore()
        let a = d1.addMyApp(typeId: "tracker", name: "Alpha", iconSystemName: "a.circle")
        let cloud = TestStorage.root.appendingPathComponent("cloud-\(UUID().uuidString)", isDirectory: true)
        _ = try await TestStorage.withCloudMirror(cloud) {
            StorageMirror.converge(localRoot: PupaStorage.activeRoot, cloudRoot: cloud)
        }

        await MyAppStore.clearStorage()
        let saved = MyAppStore.provisioningTimeout
        MyAppStore.provisioningTimeout = .zero
        defer { MyAppStore.provisioningTimeout = saved }

        try await TestStorage.withCloudMirror(cloud) {
            let store = MyAppStore()
            // A long interval so the retry cannot be what adopts the roster.
            store.beginAwaitingCloudRoster(timeout: .seconds(600), interval: .seconds(600))
            #expect(store.awaitingCloudRoster)
            let retry = store.cloudRosterRetry

            _ = await StorageMirror.shared.reconcile()
            await store.reloadFromDisk()

            #expect(store.myApps.contains { $0.id == a })
            #expect(!store.awaitingCloudRoster)
            #expect(!store.isProvisioning)
            #expect(!StorageMirror.provisioning)
            #expect(store.cloudRosterRetry == nil)
            #expect(retry?.isCancelled == true)
            await retry?.value
        }
    }

    /// `state/apps/<uuid>.json` — the body file whose mere existence makes an
    /// app real to union-load.
    private func bodyURL(_ id: UUID) -> URL {
        PupaStorage.stateRoot
            .appendingPathComponent("apps", isDirectory: true)
            .appendingPathComponent("\(id.uuidString).json")
    }

    /// Giving up unblocks local writes, but the stand-in carries a launch-fresh
    /// UUID: persisting it makes it real to union-load, which then lists it
    /// *beside* the real roster on arrival — a duplicate on every device.
    @Test("the placeholder stays off disk after the retry gives up")
    func givenUpPlaceholderNeverPersists() async throws {
        await MyAppStore.clearStorage()
        let saved = MyAppStore.provisioningTimeout
        MyAppStore.provisioningTimeout = .zero
        defer { MyAppStore.provisioningTimeout = saved }

        // A cloud roster that exists but never decodes, so the retry can't adopt.
        let cloud = TestStorage.root.appendingPathComponent("cloud-\(UUID().uuidString)", isDirectory: true)
        let cloudIndex = cloud.appendingPathComponent("state/index.json")
        try FileManager.default.createDirectory(
            at: cloudIndex.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: cloudIndex)

        try await TestStorage.withCloudMirror(cloud) {
            let store = MyAppStore()
            await store.finishProvisioning()
            #expect(store.awaitingCloudRoster)

            // Drive the retry to its deadline: writes unblock, waiting clears.
            store.cloudRosterRetry?.cancel()
            await store.cloudRosterRetry?.value
            #expect(!store.isProvisioning)

            let placeholder = store.myApps[0].id
            store.renameMyApp(placeholder, to: "Edited after giving up")

            #expect(!FileManager.default.fileExists(atPath: bodyURL(placeholder).path),
                    "the stand-in roster must not become a real app on disk")

            // A real roster arriving must not find a duplicate waiting for it:
            // a relaunch reads back no roster at all and provisions again.
            let relaunched = MyAppStore()
            #expect(!relaunched.myApps.contains { $0.id == placeholder })
            #expect(relaunched.isProvisioning, "nothing was committed, so still standing in")
        }
    }

    /// The hold is scoped to the stand-in. Anything the user makes after the
    /// give-up is real intent and must survive a relaunch — recovered by
    /// union-load from its body, since the index is still held back.
    @Test("apps created after the give-up still persist")
    func appsCreatedAfterGivingUpPersist() async throws {
        await MyAppStore.clearStorage()
        let saved = MyAppStore.provisioningTimeout
        MyAppStore.provisioningTimeout = .zero
        defer { MyAppStore.provisioningTimeout = saved }

        let cloud = TestStorage.root.appendingPathComponent("cloud-\(UUID().uuidString)", isDirectory: true)
        let cloudIndex = cloud.appendingPathComponent("state/index.json")
        try FileManager.default.createDirectory(
            at: cloudIndex.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: cloudIndex)

        try await TestStorage.withCloudMirror(cloud) {
            let store = MyAppStore()
            await store.finishProvisioning()
            store.cloudRosterRetry?.cancel()
            await store.cloudRosterRetry?.value

            let placeholder = store.myApps[0].id
            let mine = store.addMyApp(typeId: "tracker", name: "Mine", iconSystemName: "m.circle")

            #expect(FileManager.default.fileExists(atPath: bodyURL(mine).path))
            let relaunched = MyAppStore().myApps.map(\.id)
            #expect(relaunched.contains(mine), "the user's own app must survive")
            #expect(!relaunched.contains(placeholder))
        }
    }

    /// Holding the stand-in off disk is right, but silent: the user is looking
    /// at an app whose every edit is dropped. `isRosterUnsaved` is what tells
    /// them, so it must hold for the whole wait — give-up included.
    @Test("the unsaveable stand-in roster is flagged for the whole wait")
    func standInRosterIsFlagged() async throws {
        await MyAppStore.clearStorage()
        let saved = MyAppStore.provisioningTimeout
        MyAppStore.provisioningTimeout = .zero
        defer { MyAppStore.provisioningTimeout = saved }

        let cloud = TestStorage.root.appendingPathComponent("cloud-\(UUID().uuidString)", isDirectory: true)
        let cloudIndex = cloud.appendingPathComponent("state/index.json")
        try FileManager.default.createDirectory(
            at: cloudIndex.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: cloudIndex)

        try await TestStorage.withCloudMirror(cloud) {
            let store = MyAppStore()
            #expect(store.isRosterUnsaved, "the seeded placeholder is already unsaveable")
            await store.finishProvisioning()
            #expect(store.isRosterUnsaved, "still a stand-in while the retry runs")

            store.cloudRosterRetry?.cancel()
            await store.cloudRosterRetry?.value
            // The give-up is exactly where the old code went quiet: writes
            // resume, the "restoring" status clears, and the placeholder is
            // still a black hole.
            #expect(!store.awaitingCloudRoster)
            #expect(store.isRosterUnsaved, "giving up doesn't make the stand-in saveable")

            // Retry re-arms the poller so the banner's button has something to do.
            store.retryCloudRoster()
            #expect(store.awaitingCloudRoster)
            store.cloudRosterRetry?.cancel()
            await store.cloudRosterRetry?.value
        }
    }

    @Test("adopting a real roster clears the unsaved flag")
    func adoptingRosterClearsUnsavedFlag() async throws {
        await MyAppStore.clearStorage()
        let d1 = MyAppStore()
        _ = d1.addMyApp(typeId: "tracker", name: "Alpha", iconSystemName: "a.circle")
        #expect(!d1.isRosterUnsaved, "a normal seeded install saves normally")

        let cloud = TestStorage.root.appendingPathComponent("cloud-\(UUID().uuidString)", isDirectory: true)
        _ = try await TestStorage.withCloudMirror(cloud) {
            StorageMirror.converge(localRoot: PupaStorage.activeRoot, cloudRoot: cloud)
        }

        await MyAppStore.clearStorage()
        let saved = MyAppStore.provisioningTimeout
        MyAppStore.provisioningTimeout = .zero
        defer { MyAppStore.provisioningTimeout = saved }

        try await TestStorage.withCloudMirror(cloud) {
            let store = MyAppStore()
            #expect(store.isRosterUnsaved)
            await store.finishProvisioning()
            await store.cloudRosterRetry?.value
            #expect(!store.isRosterUnsaved, "the real roster is here — writes are real again")
        }
    }

    /// The banner must not cry failure during the ordinary opening wait — that
    /// window ends in an adopted roster on the common path, so warning there
    /// put "Couldn't reach your apps in iCloud" on every successful restore.
    @Test("the roster banner stays silent until the opening wait has actually failed")
    func rosterWarningSkipsTheOpeningWait() async throws {
        await MyAppStore.clearStorage()
        let saved = MyAppStore.provisioningTimeout
        MyAppStore.provisioningTimeout = .zero
        defer { MyAppStore.provisioningTimeout = saved }

        let cloud = TestStorage.root.appendingPathComponent("cloud-\(UUID().uuidString)", isDirectory: true)
        let cloudIndex = cloud.appendingPathComponent("state/index.json")
        try FileManager.default.createDirectory(
            at: cloudIndex.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: cloudIndex)

        try await TestStorage.withCloudMirror(cloud) {
            let store = MyAppStore()
            #expect(store.isRosterUnsaved, "the stand-in is unsaveable from the start")
            #expect(store.rosterWarning == nil, "but nothing has failed yet")

            await store.finishProvisioning()
            #expect(store.rosterWarning == .restoring, "the retry is running — say so")

            store.cloudRosterRetry?.cancel()
            await store.cloudRosterRetry?.value
            #expect(store.rosterWarning == .unreachable, "gave up — offer the retry")

            store.retryCloudRoster()
            #expect(store.rosterWarning == .restoring)
            store.cloudRosterRetry?.cancel()
            await store.cloudRosterRetry?.value
        }
    }

    /// Two `finishProvisioning`/CloudWatcher passes must not stack two pollers
    /// on the same store.
    @Test("the roster retry never starts twice")
    func retryStartsOnce() async {
        await MyAppStore.clearStorage()
        let store = MyAppStore()
        // No suspension between these: the first task cannot have finished and
        // cleared the handle, so a second handle would mean a second poller.
        store.beginAwaitingCloudRoster(timeout: .milliseconds(200), interval: .milliseconds(10))
        let first = store.cloudRosterRetry
        store.beginAwaitingCloudRoster()
        #expect(first != nil)
        #expect(store.cloudRosterRetry == first)

        first?.cancel()
        await first?.value
    }
}
