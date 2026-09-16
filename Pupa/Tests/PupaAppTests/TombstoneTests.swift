import Foundation
import Testing
@testable import PupaApp

/// Durable MiniApp deletion tombstones (`state/tombstones/<uuid>.json`): a delete
/// must survive relaunch + sync, and union-load must never resurrect it.
@MainActor
@Suite("MiniApp deletion tombstones", .serialized)
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
        await MiniAppStore.clearStorage()
        let id = UUID()
        MiniAppStore.writeTombstone(id)
        #expect(FileManager.default.fileExists(atPath: tombstoneURL(id).path))
    }

    @Test("a tombstoned id is absent from the roster even with its body on disk")
    func tombstoneSuppressesBodyInLoad() async throws {
        await MiniAppStore.clearStorage()
        let a = MiniAppStore()
        let kept = a.addMiniApp(typeId: "tracker", name: "Kept", iconSystemName: "star")
        let doomed = a.addMiniApp(typeId: "tracker", name: "Doomed", iconSystemName: "trophy")
        #expect(FileManager.default.fileExists(atPath: bodyURL(doomed).path))

        MiniAppStore.writeTombstone(doomed)          // mark deleted; body deliberately left on disk

        let b = MiniAppStore()                        // reload via union-load
        #expect(!b.miniApps.contains { $0.id == doomed })   // suppressed
        #expect(b.miniApps.contains { $0.id == kept })      // untouched
    }

    @Test("removeMiniApp writes a tombstone and a re-pushed body does not resurrect")
    func removeWritesTombstoneNoResurrect() async throws {
        await MiniAppStore.clearStorage()
        let a = MiniAppStore()
        let kept = a.addMiniApp(typeId: "tracker", name: "Kept", iconSystemName: "star")
        let doomed = a.addMiniApp(typeId: "tracker", name: "Doomed", iconSystemName: "trophy")
        let body = try Data(contentsOf: bodyURL(doomed))   // capture before delete

        a.removeMiniApp(doomed)
        #expect(FileManager.default.fileExists(atPath: tombstoneURL(doomed).path))  // durable marker
        #expect(!FileManager.default.fileExists(atPath: bodyURL(doomed).path))      // body gone

        try body.write(to: bodyURL(doomed))                // another device re-pushes the stale body

        let b = MiniAppStore()                                // reload
        #expect(!b.miniApps.contains { $0.id == doomed })     // still dead (tombstone wins)
        #expect(b.miniApps.contains { $0.id == kept })
    }

    @Test("the orphan sweep reaps a tombstoned body but keeps live ones")
    func sweepReapsTombstonedBody() async throws {
        await MiniAppStore.clearStorage()
        let a = MiniAppStore()
        let live = a.addMiniApp(typeId: "tracker", name: "Live", iconSystemName: "star")
        let doomed = a.addMiniApp(typeId: "tracker", name: "Doomed", iconSystemName: "trophy")
        MiniAppStore.writeTombstone(doomed)                  // fresh body, but tombstoned

        _ = MiniAppStore.sweepOrphanAppFiles(keeping: [])     // nothing pinned as live

        #expect(!FileManager.default.fileExists(atPath: bodyURL(doomed).path))  // reaped despite being fresh + decodable
        #expect(FileManager.default.fileExists(atPath: bodyURL(live).path))     // decodable, not tombstoned → kept
    }

    @Test("GC drops tombstones past the TTL and keeps recent ones")
    func gcDropsExpiredTombstones() async throws {
        await MiniAppStore.clearStorage()
        let old = UUID(), recent = UUID()
        MiniAppStore.writeTombstone(old, at: Date(timeIntervalSinceNow: -200 * 24 * 3600))
        MiniAppStore.writeTombstone(recent)

        let dropped = MiniAppStore.gcTombstones()   // default 180-day TTL, now = Date()

        #expect(dropped == 1)
        #expect(!FileManager.default.fileExists(atPath: tombstoneURL(old).path))     // expired → gone
        #expect(FileManager.default.fileExists(atPath: tombstoneURL(recent).path))   // fresh → kept
    }

    @Test("re-importing a deleted id clears its tombstone and survives relaunch")
    func reimportUndeletesAcrossRelaunch() async throws {
        await MiniAppStore.clearStorage()
        let a = MiniAppStore()
        _ = a.addMiniApp(typeId: "tracker", name: "Kept", iconSystemName: "star")
        let doomed = a.addMiniApp(typeId: "tracker", name: "Doomed", iconSystemName: "trophy")
        let snapshot = try #require(a.miniApps.first { $0.id == doomed })  // capture the body value

        a.removeMiniApp(doomed)
        #expect(FileManager.default.fileExists(atPath: tombstoneURL(doomed).path))

        _ = a.importMiniApp(snapshot)                 // user re-imports the same bundle (same id)
        #expect(!FileManager.default.fileExists(atPath: tombstoneURL(doomed).path))  // tombstone cleared

        let b = MiniAppStore()                        // reload — must NOT re-suppress
        #expect(b.miniApps.contains { $0.id == doomed })
        #expect(FileManager.default.fileExists(atPath: bodyURL(doomed).path))        // body not reaped
    }

    @Test("clearTombstone removes the marker")
    func clearTombstoneRemovesMarker() async throws {
        await MiniAppStore.clearStorage()
        let id = UUID()
        MiniAppStore.writeTombstone(id)
        #expect(FileManager.default.fileExists(atPath: tombstoneURL(id).path))
        MiniAppStore.clearTombstone(id)
        #expect(!FileManager.default.fileExists(atPath: tombstoneURL(id).path))
    }

    @Test("GC ages out a corrupt tombstone via mtime fallback (no permanent suppression)")
    func gcReapsCorruptTombstone() async throws {
        await MiniAppStore.clearStorage()
        let id = UUID()
        MiniAppStore.writeTombstone(id)
        try Data("not-json".utf8).write(to: tombstoneURL(id))   // corrupt: won't decode

        let dropped = MiniAppStore.gcTombstones(ttl: -1)          // any age exceeds -1
        #expect(dropped == 1)
        #expect(!FileManager.default.fileExists(atPath: tombstoneURL(id).path))  // mtime fallback → GC'd
    }
}
