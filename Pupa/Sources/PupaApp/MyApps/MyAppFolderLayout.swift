import Foundation

/// UI-only folder grouping for the MyApps sidebar. Presentational — never seen
/// by the agent (no tool writes it) nor exported (not a `MyApp` field, so a
/// marketplace bundle cannot carry it). Persisted off-model in `index.json`
/// via `IndexFile`. One layout for the whole sidebar, unlike the per-MyApp
/// `ComponentFolderLayout`.
public struct MyAppFolder: Codable, Hashable, Identifiable, Sendable {
    /// `UUID().uuidString`, generated on folder creation.
    public let id: String
    public var name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// The sidebar's folders and which folder each MyApp lives in.
/// `assignments` maps MyApp `id.uuidString` → folderId; unlisted apps are loose.
public struct MyAppFolderLayout: Codable, Hashable, Sendable {
    public var folders: [MyAppFolder] = []
    public var assignments: [String: String] = [:]

    public init(folders: [MyAppFolder] = [], assignments: [String: String] = [:]) {
        self.folders = folders
        self.assignments = assignments
    }

    /// Ids of MyApps assigned to `folderId`, in folder-agnostic order.
    public func myAppIds(inFolder folderId: String) -> [String] {
        assignments.compactMap { $0.value == folderId ? $0.key : nil }
    }

    /// The folder a MyApp lives in, or `nil` if loose.
    public func folderId(forMyApp myAppId: UUID) -> String? {
        assignments[myAppId.uuidString]
    }

    /// The folder record for `folderId`, or `nil` if unknown.
    public func folder(id folderId: String) -> MyAppFolder? {
        folders.first { $0.id == folderId }
    }
}
