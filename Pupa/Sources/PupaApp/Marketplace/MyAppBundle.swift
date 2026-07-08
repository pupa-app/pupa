import Foundation

/// One memory file in a bundle. `path` is relative to the app's memory root
/// (the `<slug>/` prefix is stripped), so import re-roots under the new app's
/// slug by writing each path into a scoped `MemoryStore`.
public struct MemoryFile: Codable, Hashable, Sendable {
    public let path: String
    public let content: String
    public init(path: String, content: String) {
        self.path = path
        self.content = content
    }
}

/// A portable, **inert** MyApp artifact — the marketplace transport unit. It
/// carries only data (a `Codable` `MyApp` tree + memory files); all rebuild
/// logic lives in the app and is dispatched by component `kind`. The `header`
/// is written first and validated first on import. Single source of truth is
/// the nested `MyApp` (no parallel relational schema to drift).
public struct MyAppBundle: Codable, Sendable {
    public let header: Header
    public let app: MyApp
    public let memories: [MemoryFile]

    public init(header: Header, app: MyApp, memories: [MemoryFile]) {
        self.header = header
        self.app = app
        self.memories = memories
    }

    public struct Header: Codable, Sendable {
        /// Magic string, validated on import.
        public let format: String
        /// Bundle schema version — hard-reject when it exceeds the running app.
        public let formatVersion: Int
        /// `PupaAppVersion` that created the bundle — soft-warn when newer.
        public let appVersion: String
        public let exportedAt: Date
        public let includedRecords: Bool
        public let includedMemories: Bool

        public init(appVersion: String, includedRecords: Bool, includedMemories: Bool, exportedAt: Date = Date()) {
            self.format = MyAppBundle.formatMagic
            self.formatVersion = MyAppBundle.currentFormatVersion
            self.appVersion = appVersion
            self.exportedAt = exportedAt
            self.includedRecords = includedRecords
            self.includedMemories = includedMemories
        }
    }

    // MARK: - Format constants

    public static let formatMagic = "pupa.myapp.bundle"
    public static let currentFormatVersion = 1
    public static let fileExtension = "pupa"

    // MARK: - Codec (stable, human-diffable JSON)

    public static func makeEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }

    public static func makeDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    public func encoded() throws -> Data {
        try Self.makeEncoder().encode(self)
    }
}
