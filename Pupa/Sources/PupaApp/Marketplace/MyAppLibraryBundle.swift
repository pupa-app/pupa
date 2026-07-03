import Foundation

/// A portable, **inert** bundle of *many* MyApps — the multi-app transport
/// unit. A thin container over the per-app `MyAppBundle`: it wraps an array of
/// them plus its own `header`. Same `.pupaapp` extension as a single-app
/// bundle; the two are told apart by the `header.format` magic (see
/// `MyAppImporter.probeFormat`). Import loops the per-app authority unchanged,
/// so every per-app guard (settings allow-list, memory path checks,
/// slug-unique rename, caps) applies to each app for free.
public struct MyAppLibraryBundle: Codable, Sendable {
    public let header: Header
    public let apps: [MyAppBundle]

    public init(header: Header, apps: [MyAppBundle]) {
        self.header = header
        self.apps = apps
    }

    public struct Header: Codable, Sendable {
        /// Magic string, validated on import. Distinct from a single bundle's.
        public let format: String
        /// Container schema version — hard-reject when it exceeds the app.
        public let formatVersion: Int
        /// `PupaAppVersion` that created the bundle.
        public let appVersion: String
        public let exportedAt: Date
        public let appCount: Int
        public let includedRecords: Bool
        public let includedMemories: Bool

        public init(appVersion: String, appCount: Int, includedRecords: Bool,
                    includedMemories: Bool, exportedAt: Date = Date()) {
            self.format = MyAppLibraryBundle.formatMagic
            self.formatVersion = MyAppLibraryBundle.currentFormatVersion
            self.appVersion = appVersion
            self.exportedAt = exportedAt
            self.appCount = appCount
            self.includedRecords = includedRecords
            self.includedMemories = includedMemories
        }
    }

    // MARK: - Format constants

    public static let formatMagic = "pupa.library.bundle"
    public static let currentFormatVersion = 1
    /// Same on-disk extension as a single bundle — format decided by magic.
    public static let fileExtension = MyAppBundle.fileExtension

    // MARK: - Codec (shares the single-bundle stable JSON codec)

    public func encoded() throws -> Data {
        try MyAppBundle.makeEncoder().encode(self)
    }
}
