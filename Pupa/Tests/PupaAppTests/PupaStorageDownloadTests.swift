import Foundation
import Testing
@testable import PupaApp

/// Covers `PupaStorage.kickUndownloaded` / `downloadSubtreeUntilSettled` — the
/// forced-download loop that makes a fresh device's `memories/` pull as
/// reliably as `state/` (no reliance on NSMetadataQuery re-triggers).
///
/// Fake cloud dirs are plain (non-ubiquitous), so `startDownloadingUbiquitousItem`
/// no-ops; pending detection is exercised through the iOS `.name.icloud` stub
/// convention, which is pure name-based.
@Suite("PupaStorage forced download")
struct PupaStorageDownloadTests {

    init() { TestStorage.activate() }

    private func tmp() -> URL {
        let u = FileManager.default.temporaryDirectory
            .appendingPathComponent("dl-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    private func put(_ root: URL, _ rel: String, _ content: String = "x") {
        let url = root.appendingPathComponent(rel)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(content.utf8).write(to: url)
    }

    @Test("kickUndownloaded counts .icloud stubs and returns 0 on a materialized tree")
    func kickCountsStubs() {
        let dir = tmp()
        put(dir, "app/.note.md.icloud", "{}")
        put(dir, "app/real.md", "hello")
        #expect(PupaStorage.kickUndownloaded(under: dir) == 1)
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("app/.note.md.icloud"))
        #expect(PupaStorage.kickUndownloaded(under: dir) == 0)
    }

    @Test("kickUndownloaded(subtree:) is 0 when iCloud is off")
    @MainActor
    func kickSubtreeICloudOff() {
        #expect(PupaStorage.cloudMirrorRoot == nil)   // override root set, no mirror override
        #expect(PupaStorage.kickUndownloaded(subtree: "memories") == 0)
    }

    @Test("downloadSubtreeUntilSettled settles and pulls once a stub materializes")
    @MainActor
    func settleAfterMaterialize() async throws {
        let cloud = tmp()
        let scope = "dl-settle-\(UUID().uuidString.prefix(8))"
        put(cloud, "memories/\(scope)/.a.md.icloud", "{}")
        try await TestStorage.withCloudMirror(cloud) {
            let materialize = Task {
                try? await Task.sleep(for: .milliseconds(150))
                put(cloud, "memories/\(scope)/a.md", "landed")
                try? FileManager.default.removeItem(
                    at: cloud.appendingPathComponent("memories/\(scope)/.a.md.icloud"))
            }
            let settled = await PupaStorage.downloadSubtreeUntilSettled(
                "memories", timeout: .seconds(5), initialPoll: .milliseconds(50))
            await materialize.value
            #expect(settled)
            let local = PupaStorage.memoriesRoot.appendingPathComponent("\(scope)/a.md")
            #expect((try? String(contentsOf: local, encoding: .utf8)) == "landed")
        }
        try? FileManager.default.removeItem(
            at: PupaStorage.memoriesRoot.appendingPathComponent(scope, isDirectory: true))
    }

    @Test("downloadSubtreeUntilSettled times out false while a stub persists")
    @MainActor
    func settleTimesOut() async throws {
        let cloud = tmp()
        let scope = "dl-timeout-\(UUID().uuidString.prefix(8))"
        put(cloud, "memories/\(scope)/.stuck.md.icloud", "{}")
        try await TestStorage.withCloudMirror(cloud) {
            let settled = await PupaStorage.downloadSubtreeUntilSettled(
                "memories", timeout: .milliseconds(300), initialPoll: .milliseconds(50))
            #expect(settled == false)
        }
    }
}
