import Foundation

/// UI-only folder grouping for a MyApp's component tiles. Presentational —
/// never seen by the agent (not in `getCanvasState`) nor exported (not in a
/// marketplace bundle). Persisted off-model in `index.json` via `IndexFile`,
/// keyed by MyApp `id.uuidString`. Not part of per-app History snapshots.
public struct ComponentFolder: Codable, Hashable, Identifiable, Sendable {
    /// `UUID().uuidString`, generated on folder creation.
    public let id: String
    public var name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// Per-MyApp layout: the folders and which component each lives in.
/// `assignments` maps componentId → folderId; unlisted components are loose.
/// Component ids are unique within one MyApp, so they key `assignments`.
public struct ComponentFolderLayout: Codable, Hashable, Sendable {
    public var folders: [ComponentFolder] = []
    public var assignments: [String: String] = [:]

    public init(folders: [ComponentFolder] = [], assignments: [String: String] = [:]) {
        self.folders = folders
        self.assignments = assignments
    }

    /// Ids of components assigned to `folderId`, in folder-agnostic order.
    public func componentIds(inFolder folderId: String) -> [String] {
        assignments.compactMap { $0.value == folderId ? $0.key : nil }
    }

    /// The folder a component lives in, or `nil` if loose.
    public func folderId(forComponent componentId: String) -> String? {
        assignments[componentId]
    }
}
