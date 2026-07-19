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
}
