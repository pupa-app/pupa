import Foundation
import CryptoKit
import AGUIKit

/// Why a snapshot was captured. Drives the History timeline's badge and the
/// conflict-recovery affordance.
public enum SnapshotReason: String, Codable, Sendable {
    /// Debounced capture after the user/agent edited the MyApp.
    case edit
    /// A losing side of an iCloud `NSFileVersion` conflict, preserved so no
    /// offline work is ever lost.
    case conflict
    /// The local state just before a remote reload overwrote it.
    case preReload
    /// A user restore — the new head produced by reverting to an earlier
    /// snapshot (restore is append-only; see `MyAppStore.restore`).
    case restored
}

/// One history entry. Identity is a unique `id` (so a restore can add a new
/// node even when its content matches an earlier one — git-`revert`, not
/// `git reset`); `contentHash` is used only to dedup consecutive identical
/// edits. Carries either a full `base` state or a `diff` from `parentId`,
/// diff-chained so history stores only what changed. A full base is written
/// at the chain root and periodically so restore never walks an unbounded
/// chain.
public struct Snapshot: Codable, Sendable {
    public let id: UUID
    public let contentHash: String
    public let appId: UUID
    public let timestamp: Date
    public let device: String
    public let parentId: UUID?
    public let reason: SnapshotReason
    /// Full state — set on chain roots and every `baseInterval` links.
    public let base: AnyJSON?
    /// Delta from `parentId`'s resolved state — set otherwise.
    public let diff: JSONPatch?
}

/// Lightweight listing entry (no resolved state) for the History timeline.
public struct SnapshotMeta: Sendable, Identifiable, Hashable {
    public let id: UUID
    public let contentHash: String
    public let appId: UUID
    public let timestamp: Date
    public let device: String
    public let parentId: UUID?
    public let reason: SnapshotReason
    public let isBase: Bool
}

/// Git-style snapshot history per MyApp. Files live at
/// `state/snapshots/<appId>/<snapshotId>.json` and ride the same
/// `CloudDocument`/`PupaStorage` seam as everything else, so history syncs
/// across devices and stays `NSFileCoordinator`-safe.
///
/// Storage is minimal: consecutive identical edits dedup (by `contentHash`)
/// and non-root snapshots store a `JSONPatch` delta from their parent
/// (`JSONDiff`). Pruning mirrors `ItemEventLog.prune` — TTL + per-app cap —
/// and re-bases the oldest surviving snapshot so deleting old links never
/// breaks restore.
public enum SnapshotStore {
    public static let defaultCap = 100
    public static let defaultTTL: TimeInterval = 90 * 24 * 60 * 60
    /// Force a full base at least this often along a diff chain.
    static let baseInterval = 20

    // MARK: - Layout

    static var root: URL {
        PupaStorage.stateRoot.appendingPathComponent("snapshots", isDirectory: true)
    }
    static func dir(_ appId: UUID) -> URL {
        root.appendingPathComponent(appId.uuidString, isDirectory: true)
    }
    static func url(_ appId: UUID, _ id: UUID) -> URL {
        dir(appId).appendingPathComponent("\(id.uuidString).json")
    }

    /// Stable, privacy-clean per-install label used to distinguish conflict
    /// sides in the UI ("this device" vs "another device"). Deliberately an
    /// opaque random id — never a personal/host name.
    public static let deviceLabel: String = {
        let key = "pupa.snapshot.deviceLabel"
        let defaults = UserDefaults.standard
        if let existing = defaults.string(forKey: key) { return existing }
        let label = "device-" + UUID().uuidString.prefix(8)
        defaults.set(String(label), forKey: key)
        return String(label)
    }()

    // MARK: - Public API

    /// Newest-first history listing for `appId` (metadata only).
    public static func metas(_ appId: UUID) -> [SnapshotMeta] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir(appId), includingPropertiesForKeys: nil) else { return [] }
        var out: [SnapshotMeta] = []
        for file in files where file.pathExtension == "json" {
            guard let rec = readRecord(at: file) else { continue }
            out.append(meta(rec))
        }
        return out.sorted { $0.timestamp > $1.timestamp }
    }

    /// The current head (most recent snapshot) for `appId`, if any.
    public static func head(_ appId: UUID) -> SnapshotMeta? { metas(appId).first }

    /// Record `app`'s current state as a new snapshot; returns its id. On the
    /// `.edit` path, a state identical to the current head dedups (no write,
    /// returns the head id). Chooses a full base at the chain root / every
    /// `baseInterval` links, else a diff from the current head.
    @discardableResult
    public static func record(
        _ app: MyApp, reason: SnapshotReason, now: Date = Date()
    ) -> UUID? {
        guard let json = stateJSON(app) else { return nil }
        let contentHash = hash(json)
        let headMeta = head(app.id)
        if reason == .edit, let headMeta, headMeta.contentHash == contentHash {
            return headMeta.id  // no-op: identical to current head
        }

        let sid = UUID()
        let parentId = headMeta?.id
        let record: Snapshot
        if let parentId,
           chainDepth(app.id, id: parentId) + 1 < baseInterval,
           let parentState = resolve(app.id, id: parentId),
           let d = JSONDiff.diff(parentState, json) {
            record = Snapshot(id: sid, contentHash: contentHash, appId: app.id,
                              timestamp: now, device: deviceLabel, parentId: parentId,
                              reason: reason, base: nil, diff: d)
        } else {
            record = Snapshot(id: sid, contentHash: contentHash, appId: app.id,
                              timestamp: now, device: deviceLabel, parentId: parentId,
                              reason: reason, base: json, diff: nil)
        }
        try? writeRecord(record, to: url(app.id, sid))
        prune(app.id, now: now)
        return sid
    }

    /// Reconstruct the MyApp captured by snapshot `id`, or nil if the chain
    /// is missing/corrupt.
    public static func restoredApp(_ appId: UUID, id: UUID) -> MyApp? {
        guard let json = resolve(appId, id: id),
              let data = try? JSONEncoder().encode(json) else { return nil }
        return try? JSONDecoder().decode(MyApp.self, from: data)
    }

    /// Drop all history for `appId` (called when the MyApp is deleted).
    public static func deleteAll(_ appId: UUID) {
        try? FileManager.default.removeItem(at: dir(appId))
    }

    // MARK: - Resolution

    /// Full state for a snapshot: walk parent links to the nearest base, then
    /// apply diffs forward.
    public static func resolve(_ appId: UUID, id: UUID) -> AnyJSON? {
        var chain: [Snapshot] = []
        var cursor: UUID? = id
        var guardCount = 0
        while let cid = cursor, guardCount < 100_000 {
            guardCount += 1
            guard let rec = readRecord(appId, cid) else { return nil }
            chain.append(rec)
            if rec.base != nil { break }
            cursor = rec.parentId
        }
        guard let baseRec = chain.last, var state = baseRec.base else { return nil }
        // chain is head → … → base; apply diffs base → head.
        for rec in chain.dropLast().reversed() {
            guard let d = rec.diff else { return nil }
            state = JSONDiff.apply(d, to: state)
        }
        return state
    }

    /// Number of diffs between `id` and its base (0 if `id` is a base).
    private static func chainDepth(_ appId: UUID, id: UUID) -> Int {
        var depth = 0
        var cursor: UUID? = id
        var guardCount = 0
        while let cid = cursor, guardCount < 100_000 {
            guardCount += 1
            guard let rec = readRecord(appId, cid) else { return .max }
            if rec.base != nil { return depth }
            depth += 1
            cursor = rec.parentId
        }
        return .max
    }

    // MARK: - Prune

    /// TTL + cap eviction. Before deleting old links, re-base the oldest
    /// surviving snapshot to a full base so no survivor's diff chain dangles.
    public static func prune(
        _ appId: UUID, now: Date = Date(),
        ttl: TimeInterval = defaultTTL, cap: Int = defaultCap
    ) {
        let all = metas(appId)  // newest-first
        guard !all.isEmpty else { return }

        let cutoff = now.addingTimeInterval(-ttl)
        var survivors = all.filter { $0.timestamp >= cutoff }
        if survivors.count > cap { survivors = Array(survivors.prefix(cap)) }
        // Never evict the whole history — always keep the newest snapshot.
        if survivors.isEmpty, let newest = all.first { survivors = [newest] }

        let survivorIds = Set(survivors.map(\.id))
        let losers = all.filter { !survivorIds.contains($0.id) }
        guard !losers.isEmpty else { return }

        // Re-base the oldest survivor (survivors are newest-first → `.last`)
        // so it no longer depends on any about-to-be-deleted loser.
        if let oldest = survivors.last, !oldest.isBase {
            guard let state = resolve(appId, id: oldest.id) else { return }
            let rebased = Snapshot(
                id: oldest.id, contentHash: oldest.contentHash, appId: appId,
                timestamp: oldest.timestamp, device: oldest.device, parentId: nil,
                reason: oldest.reason, base: state, diff: nil)
            try? writeRecord(rebased, to: url(appId, oldest.id))
        }
        for loser in losers { CloudDocument.delete(url(appId, loser.id)) }
    }

    // MARK: - IO helpers

    private static func meta(_ rec: Snapshot) -> SnapshotMeta {
        SnapshotMeta(id: rec.id, contentHash: rec.contentHash, appId: rec.appId,
                     timestamp: rec.timestamp, device: rec.device, parentId: rec.parentId,
                     reason: rec.reason, isBase: rec.base != nil)
    }

    private static func stateJSON(_ app: MyApp) -> AnyJSON? {
        guard let data = try? JSONEncoder().encode(app) else { return nil }
        return try? JSONDecoder().decode(AnyJSON.self, from: data)
    }

    private static func hash(_ json: AnyJSON) -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        let data = (try? enc.encode(json)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func readRecord(_ appId: UUID, _ id: UUID) -> Snapshot? {
        readRecord(at: url(appId, id))
    }

    private static func readRecord(at url: URL) -> Snapshot? {
        guard let data = CloudDocument.read(url) else { return nil }
        return try? JSONDecoder().decode(Snapshot.self, from: data)
    }

    private static func writeRecord(_ record: Snapshot, to url: URL) throws {
        try CloudDocument.write(JSONEncoder().encode(record), to: url)
    }
}
