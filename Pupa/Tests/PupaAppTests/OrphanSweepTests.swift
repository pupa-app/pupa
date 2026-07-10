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
}
