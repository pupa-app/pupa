import Foundation
@testable import PupaApp

/// Redirects all `PupaStorage` file IO to a process-unique temp directory so
/// tests never read or clobber the developer's real app data under
/// `~/Library/Application Support/pupa`. The override is set once for the
/// process the first time any suite activates it.
enum TestStorage {
    static let root: URL = {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pupa-tests-\(UUID().uuidString)", isDirectory: true)
        PupaStorage.overrideRoot = url
        return url
    }()

    /// Ensure the override is installed. Call from a disk-touching suite's init.
    static func activate() { _ = root }

    /// Run `body` with a fake iCloud mirror installed. Drains the mirror BEFORE
    /// clearing the override, so a reconcile debounced during `body` either
    /// completes here or is cancelled — it can never fire into a later test's
    /// environment or leave a half-written mirror/baseline behind.
    @MainActor
    static func withCloudMirror<T>(_ cloud: URL, _ body: () async throws -> T) async throws -> T {
        PupaStorage.cloudMirrorOverride = cloud
        do {
            let result = try await body()
            await StorageMirror.shared.drain()
            PupaStorage.cloudMirrorOverride = nil
            return result
        } catch {
            await StorageMirror.shared.drain()
            PupaStorage.cloudMirrorOverride = nil
            throw error
        }
    }
}
