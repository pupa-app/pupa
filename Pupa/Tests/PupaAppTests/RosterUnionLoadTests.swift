import Foundation
import Testing
@testable import PupaApp

/// A2 (issue #200): the MyApp roster is the **union** of `index.json`'s `order`
/// and every decodable app body on disk. The index supplies ORDER; the disk
/// supplies EXISTENCE. A stale/shrunk index (a bad merge, a seed pushed over
/// real data) can de-list an app but must no longer hide it — and then let the
/// 7-day orphan sweep delete it. A genuine delete removes the body file, so a
/// deleted app is absent from disk and never resurrects.
@MainActor
@Suite("Roster union load (A2)", .serialized)
struct RosterUnionLoadTests {

    init() { TestStorage.activate() }

    private var indexURL: URL {
        PupaStorage.stateRoot.appendingPathComponent("index.json")
    }

    private func bodyURL(_ id: UUID) -> URL {
        PupaStorage.stateRoot.appendingPathComponent("apps/\(id.uuidString).json")
    }

    /// Drop an id from the persisted `index.json` `order` WITHOUT deleting its
    /// app body — simulates a stale/seed index overwriting the real roster while
    /// the real app files stay on disk.
    private func delistFromIndex(_ id: UUID) throws {
        let data = try Data(contentsOf: indexURL)
        var obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        var order = obj["order"] as! [String]
        order.removeAll { $0.caseInsensitiveCompare(id.uuidString) == .orderedSame }
        obj["order"] = order
        try JSONSerialization.data(withJSONObject: obj).write(to: indexURL)
    }

    @Test("a stale index that de-lists an app still loads it from its on-disk body")
    func staleIndexDoesNotOrphanRealApp() async throws {
        await MyAppStore.clearStorage()
        let a = MyAppStore()                                       // seeds + persists
        let id1 = a.addMyApp(typeId: "tracker", name: "One", iconSystemName: "star")
        let id2 = a.addMyApp(typeId: "tracker", name: "Two", iconSystemName: "trophy")
        #expect(a.myApps.contains { $0.id == id2 })

        try delistFromIndex(id2)                                   // bad merge drops id2

        let b = MyAppStore()                                       // reload from disk
        #expect(b.myApps.contains { $0.id == id2 })                // recovered via union
        #expect(b.myApps.contains { $0.id == id1 })                // untouched
    }

    @Test("a de-listed app survives the orphan sweep because union-load keeps it live")
    func delistedAppSurvivesSweep() async throws {
        await MyAppStore.clearStorage()
        let a = MyAppStore()
        let id2 = a.addMyApp(typeId: "tracker", name: "Two", iconSystemName: "trophy")
        try delistFromIndex(id2)
        // Age the body past the sweep threshold — old behavior would delete it.
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -(8 * 24 * 3600))],
            ofItemAtPath: bodyURL(id2).path)

        _ = MyAppStore()                                           // init runs the sweep
        #expect(FileManager.default.fileExists(atPath: bodyURL(id2).path))  // kept
    }

    @Test("a genuinely deleted app does not resurrect via union-load")
    func deletedAppDoesNotResurrect() async throws {
        await MyAppStore.clearStorage()
        let a = MyAppStore()
        let id1 = a.addMyApp(typeId: "tracker", name: "One", iconSystemName: "star")
        let id2 = a.addMyApp(typeId: "tracker", name: "Two", iconSystemName: "trophy")
        a.removeMyApp(id2)                                         // deletes body + index entry
        #expect(!a.myApps.contains { $0.id == id2 })
        #expect(!FileManager.default.fileExists(atPath: bodyURL(id2).path))  // body gone

        let b = MyAppStore()                                       // reload
        #expect(!b.myApps.contains { $0.id == id2 })               // not resurrected
        #expect(b.myApps.contains { $0.id == id1 })
    }
}
