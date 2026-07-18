import Foundation
import Testing
@testable import PupaApp

/// Covers the load-time sweep of orphaned `state/apps/*.json` files — files
/// whose UUID isn't in the index (leaked by earlier persist bugs or test runs
/// against the real root). The sweep is age-gated so an app file that landed
/// from iCloud *before* the index referencing it is never deleted mid-merge.
@MainActor
@Suite("Orphan app-file sweep", .serialized)
struct OrphanSweepTests {

    init() { TestStorage.activate() }

    private var appsDir: URL {
        PupaStorage.stateRoot.appendingPathComponent("apps", isDirectory: true)
    }

    private func writeOrphan(_ name: String, age: TimeInterval = 0) throws -> URL {
        try FileManager.default.createDirectory(at: appsDir, withIntermediateDirectories: true)
        let url = appsDir.appendingPathComponent(name)
        try Data("{}".utf8).write(to: url)
        if age > 0 {
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSinceNow: -age)],
                ofItemAtPath: url.path)
        }
        return url
    }

    @Test("deletes stale orphans; keeps live, fresh, and non-app files")
    func sweepDeletesOnlyStaleOrphans() async throws {
        await MyAppStore.clearStorage()
        let store = MyAppStore()  // fresh install → seeds one app + index
        let live = Set(store.myApps.map(\.id))
        let fm = FileManager.default

        let week: TimeInterval = 7 * 24 * 3600
        let stale = try writeOrphan("\(UUID().uuidString).json", age: week + 3600)
        // A fresh orphan stands in for an in-flight iCloud merge: the app file
        // can land before the index that references it.
        let fresh = try writeOrphan("\(UUID().uuidString).json")
        let foreign = try writeOrphan("notes.txt", age: week + 3600)

        let deleted = MyAppStore.sweepOrphanAppFiles(keeping: live)

        #expect(deleted == 1)
        #expect(!fm.fileExists(atPath: stale.path))
        #expect(fm.fileExists(atPath: fresh.path))
        #expect(fm.fileExists(atPath: foreign.path))
        for id in live {
            let url = appsDir.appendingPathComponent("\(id.uuidString).json")
            #expect(fm.fileExists(atPath: url.path))
        }
    }

    @Test("store init runs the sweep")
    func initSweeps() async throws {
        await MyAppStore.clearStorage()
        _ = MyAppStore()  // seed state + index

        let week: TimeInterval = 7 * 24 * 3600
        let stale = try writeOrphan("\(UUID().uuidString).json", age: week + 3600)

        _ = MyAppStore()  // relaunch → sweep
        #expect(!FileManager.default.fileExists(atPath: stale.path))
    }

    @Test("no readable index (fresh-install fallback) → sweep must not run")
    func noSweepWithoutIndex() async throws {
        await MyAppStore.clearStorage()
        // App files exist but index.json is gone (corruption / partial sync).
        // load() falls back to the fresh-install seed; sweeping here would
        // delete files a hand-repaired index could still recover.
        let week: TimeInterval = 7 * 24 * 3600
        let unreferenced = try writeOrphan("\(UUID().uuidString).json", age: week + 3600)

        _ = MyAppStore()  // seeds fresh — index was unreadable
        #expect(FileManager.default.fileExists(atPath: unreferenced.path))
    }

    /// Defense-in-depth for A2 (issue #200): a file that still decodes as a real
    /// MyApp body is recovery material (union-load restores it), never an orphan
    /// — so the sweep must keep it even when it's aged and absent from `live`.
    /// Only genuine junk ages out.
    @Test("a decodable MyApp body is never swept, even when aged and not in the live set")
    func keepsDecodableAppBodyNotLive() async throws {
        await MyAppStore.clearStorage()
        let ghost = DailyBriefingExample.make()
        try FileManager.default.createDirectory(at: appsDir, withIntermediateDirectories: true)
        let url = appsDir.appendingPathComponent("\(ghost.id.uuidString).json")
        try JSONEncoder().encode(ghost).write(to: url)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -(8 * 24 * 3600))],
            ofItemAtPath: url.path)

        let deleted = MyAppStore.sweepOrphanAppFiles(keeping: [])  // ghost aged + not live
        #expect(deleted == 0)                                      // real app body preserved
        #expect(FileManager.default.fileExists(atPath: url.path))
    }
}
