import Foundation

/// UI-only folder grouping for the MiniApps sidebar. Presentational — never seen
/// by the agent (no tool writes it) nor exported (not a `MiniApp` field, so a
/// marketplace bundle cannot carry it). Persisted off-model in `index.json`
/// via `IndexFile`. One layout for the whole sidebar, unlike the per-MiniApp
/// `ComponentFolderLayout`.
public struct MiniAppFolder: Codable, Hashable, Identifiable, Sendable {
    /// `UUID().uuidString`, generated on folder creation.
    public let id: String
    public var name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// The sidebar's folders and which folder each MiniApp lives in.
/// `assignments` maps MiniApp `id.uuidString` → folderId; unlisted apps are loose.
public struct MiniAppFolderLayout: Codable, Hashable, Sendable {
    public var folders: [MiniAppFolder] = []
    public var assignments: [String: String] = [:]

    public init(folders: [MiniAppFolder] = [], assignments: [String: String] = [:]) {
        self.folders = folders
        self.assignments = assignments
    }

    /// Ids of MiniApps assigned to `folderId`, in folder-agnostic order.
    public func miniAppIds(inFolder folderId: String) -> [String] {
        assignments.compactMap { $0.value == folderId ? $0.key : nil }
    }

    /// The folder a MiniApp lives in, or `nil` if loose.
    public func folderId(forMiniApp miniAppId: UUID) -> String? {
        assignments[miniAppId.uuidString]
    }

    /// The folder record for `folderId`, or `nil` if unknown.
    public func folder(id folderId: String) -> MiniAppFolder? {
        folders.first { $0.id == folderId }
    }
}
