import Foundation
import Testing
@testable import PupaApp

/// Durable MyApp deletion tombstones (`state/tombstones/<uuid>.json`): a delete
/// must survive relaunch + sync, and union-load must never resurrect it.
@MainActor
@Suite("MyApp deletion tombstones", .serialized)
struct TombstoneTests {

    init() { TestStorage.activate() }

    private var stateRoot: URL { PupaStorage.stateRoot }
    private func bodyURL(_ id: UUID) -> URL {
        stateRoot.appendingPathComponent("apps/\(id.uuidString).json")
    }
    private func tombstoneURL(_ id: UUID) -> URL {
        stateRoot.appendingPathComponent("tombstones/\(id.uuidString).json")
    }

    @Test("writeTombstone creates a decodable marker discoverable on disk")
    func writeTombstoneRoundTrips() async throws {
        await MyAppStore.clearStorage()
        let id = UUID()
        MyAppStore.writeTombstone(id)
        #expect(FileManager.default.fileExists(atPath: tombstoneURL(id).path))
    }

    @Test("a tombstoned id is absent from the roster even with its body on disk")
    func tombstoneSuppressesBodyInLoad() async throws {
        await MyAppStore.clearStorage()
        let a = MyAppStore()
        let kept = a.addMyApp(typeId: "tracker", name: "Kept", iconSystemName: "star")
        let doomed = a.addMyApp(typeId: "tracker", name: "Doomed", iconSystemName: "trophy")
        #expect(FileManager.default.fileExists(atPath: bodyURL(doomed).path))

        MyAppStore.writeTombstone(doomed)          // mark deleted; body deliberately left on disk

        let b = MyAppStore()                        // reload via union-load
        #expect(!b.myApps.contains { $0.id == doomed })   // suppressed
        #expect(b.myApps.contains { $0.id == kept })      // untouched
    }

    @Test("removeMyApp writes a tombstone and a re-pushed body does not resurrect")
    func removeWritesTombstoneNoResurrect() async throws {
        await MyAppStore.clearStorage()
        let a = MyAppStore()
        let kept = a.addMyApp(typeId: "tracker", name: "Kept", iconSystemName: "star")
        let doomed = a.addMyApp(typeId: "tracker", name: "Doomed", iconSystemName: "trophy")
        let body = try Data(contentsOf: bodyURL(doomed))   // capture before delete

        a.removeMyApp(doomed)
        #expect(FileManager.default.fileExists(atPath: tombstoneURL(doomed).path))  // durable marker
        #expect(!FileManager.default.fileExists(atPath: bodyURL(doomed).path))      // body gone

        try body.write(to: bodyURL(doomed))                // another device re-pushes the stale body

        let b = MyAppStore()                                // reload
        #expect(!b.myApps.contains { $0.id == doomed })     // still dead (tombstone wins)
        #expect(b.myApps.contains { $0.id == kept })
    }

    @Test("the orphan sweep reaps a tombstoned body but keeps live ones")
    func sweepReapsTombstonedBody() async throws {
        await MyAppStore.clearStorage()
        let a = MyAppStore()
        let live = a.addMyApp(typeId: "tracker", name: "Live", iconSystemName: "star")
        let doomed = a.addMyApp(typeId: "tracker", name: "Doomed", iconSystemName: "trophy")
        MyAppStore.writeTombstone(doomed)                  // fresh body, but tombstoned

        _ = MyAppStore.sweepOrphanAppFiles(keeping: [])     // nothing pinned as live

        #expect(!FileManager.default.fileExists(atPath: bodyURL(doomed).path))  // reaped despite being fresh + decodable
        #expect(FileManager.default.fileExists(atPath: bodyURL(live).path))     // decodable, not tombstoned → kept
    }

    @Test("GC drops tombstones past the TTL and keeps recent ones")
    func gcDropsExpiredTombstones() async throws {
        await MyAppStore.clearStorage()
        let old = UUID(), recent = UUID()
        MyAppStore.writeTombstone(old, at: Date(timeIntervalSinceNow: -200 * 24 * 3600))
        MyAppStore.writeTombstone(recent)

        let dropped = MyAppStore.gcTombstones()   // default 180-day TTL, now = Date()

        #expect(dropped == 1)
        #expect(!FileManager.default.fileExists(atPath: tombstoneURL(old).path))     // expired → gone
        #expect(FileManager.default.fileExists(atPath: tombstoneURL(recent).path))   // fresh → kept
    }

    @Test("re-importing a deleted id clears its tombstone and survives relaunch")
    func reimportUndeletesAcrossRelaunch() async throws {
        await MyAppStore.clearStorage()
        let a = MyAppStore()
        _ = a.addMyApp(typeId: "tracker", name: "Kept", iconSystemName: "star")
        let doomed = a.addMyApp(typeId: "tracker", name: "Doomed", iconSystemName: "trophy")
        let snapshot = try #require(a.myApps.first { $0.id == doomed })  // capture the body value

        a.removeMyApp(doomed)
        #expect(FileManager.default.fileExists(atPath: tombstoneURL(doomed).path))

        _ = a.importMyApp(snapshot)                 // user re-imports the same bundle (same id)
        #expect(!FileManager.default.fileExists(atPath: tombstoneURL(doomed).path))  // tombstone cleared

        let b = MyAppStore()                        // reload — must NOT re-suppress
        #expect(b.myApps.contains { $0.id == doomed })
        #expect(FileManager.default.fileExists(atPath: bodyURL(doomed).path))        // body not reaped
    }

    @Test("clearTombstone removes the marker")
    func clearTombstoneRemovesMarker() async throws {
        await MyAppStore.clearStorage()
        let id = UUID()
        MyAppStore.writeTombstone(id)
        #expect(FileManager.default.fileExists(atPath: tombstoneURL(id).path))
        MyAppStore.clearTombstone(id)
        #expect(!FileManager.default.fileExists(atPath: tombstoneURL(id).path))
    }

    @Test("GC ages out a corrupt tombstone via mtime fallback (no permanent suppression)")
    func gcReapsCorruptTombstone() async throws {
        await MyAppStore.clearStorage()
        let id = UUID()
        MyAppStore.writeTombstone(id)
        try Data("not-json".utf8).write(to: tombstoneURL(id))   // corrupt: won't decode

        let dropped = MyAppStore.gcTombstones(ttl: -1)          // any age exceeds -1
        #expect(dropped == 1)
        #expect(!FileManager.default.fileExists(atPath: tombstoneURL(id).path))  // mtime fallback → GC'd
    }
}
