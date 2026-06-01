import Foundation

/// Versioned decode-migration helpers, keyed by `(kind, fromVersion)`.
///
/// Each entry is a `(Data) throws -> Data` function that transforms the
/// raw JSON of one item version into the next. `migrate(data:kind:from:to:)`
/// chains entries in order, skipping version slots that have no registered
/// migration (sparse registration is allowed).
///
/// Usage in a `Codable` decoder (Phases 2–4):
/// ```swift
/// let raw = try encoder.encode(container)           // intermediate Data
/// let migrated = try MigrationRegistry.shared.migrate(
///     data: raw, kind: "tracker",
///     fromVersion: schemaVersion ?? 0, toVersion: TrackerItem.currentSchemaVersion)
/// let item = try decoder.decode(TrackerItem.self, from: migrated)
/// ```
///
/// Old blobs with no `schemaVersion` field are treated as version 0 by the
/// calling decoder; the first registered migration (fromVersion: 0) handles
/// them, and subsequent saves write `schemaVersion: 1` so the migration
/// path runs only once per blob.
public struct MigrationRegistry: @unchecked Sendable {
    public typealias Migration = (Data) throws -> Data

    private var migrations: [String: [Int: Migration]] = [:]

    public init() {}

    /// Register a migration from `fromVersion` to `fromVersion + 1` for the
    /// given item kind. Registering the same `(kind, fromVersion)` pair twice
    /// silently replaces the earlier entry.
    public mutating func register(
        kind: String,
        fromVersion: Int,
        migration: @escaping Migration
    ) {
        migrations[kind, default: [:]][fromVersion] = migration
    }

    /// Apply all registered migrations for `kind` in order from `fromVersion`
    /// up to (but not including) `toVersion`. Version slots without a
    /// registered migration pass the data through unchanged.
    public func migrate(
        data: Data,
        kind: String,
        fromVersion: Int,
        toVersion: Int
    ) throws -> Data {
        var current = data
        for version in fromVersion..<toVersion {
            if let migration = migrations[kind]?[version] {
                current = try migration(current)
            }
        }
        return current
    }
}
