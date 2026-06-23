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
}
