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
    /// The state just before the user deleted the MyApp — the restore point
    /// behind Settings → Recently deleted.
    case deleted
    /// A user-pinned permanent snapshot: labelled, always stored as a full
    /// base, and never evicted by `prune`. The "keep this state forever"
    /// milestone.
    case pinned
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
    /// User-supplied caption for a `.pinned` snapshot; `nil` otherwise and on
    /// legacy records.
    public let label: String?

    public init(
        id: UUID, contentHash: String, appId: UUID, timestamp: Date,
        device: String, parentId: UUID?, reason: SnapshotReason,
        base: AnyJSON?, diff: JSONPatch?, label: String? = nil
    ) {
        self.id = id
        self.contentHash = contentHash
        self.appId = appId
        self.timestamp = timestamp
        self.device = device
        self.parentId = parentId
        self.reason = reason
        self.base = base
        self.diff = diff
        self.label = label
    }
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
    /// User caption for a `.pinned` snapshot; `nil` otherwise.
    public let label: String?
}

/// Header-only view of a snapshot record: everything `SnapshotMeta` needs,
/// decoded without materialising `base`/`diff`. Listing a MyApp's history must
/// not decode every full app state it has ever held.
private struct SnapshotHeader: Decodable {
    let meta: SnapshotMeta

    private enum CodingKeys: String, CodingKey {
        case id, contentHash, appId, timestamp, device, parentId, reason, base, label
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // `base` is skipped, not decoded — its presence alone marks a chain
        // root. `JSONEncoder` omits nil optionals, so an absent key means diff.
        let isBase = c.contains(.base) && !((try? c.decodeNil(forKey: .base)) ?? true)
        meta = SnapshotMeta(
            id: try c.decode(UUID.self, forKey: .id),
            contentHash: try c.decode(String.self, forKey: .contentHash),
            appId: try c.decode(UUID.self, forKey: .appId),
            timestamp: try c.decode(Date.self, forKey: .timestamp),
            device: try c.decode(String.self, forKey: .device),
            parentId: try c.decodeIfPresent(UUID.self, forKey: .parentId),
            reason: try c.decode(SnapshotReason.self, forKey: .reason),
            isBase: isBase,
            label: try c.decodeIfPresent(String.self, forKey: .label))
    }
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

    /// Newest-first history listing for `appId` (metadata only). Decodes only
    /// each record's header — never its `base`/`diff` payload, which is the
    /// whole serialized MyApp and dwarfs everything else on disk.
    public static func metas(_ appId: UUID) -> [SnapshotMeta] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir(appId), includingPropertiesForKeys: nil) else { return [] }
        var out: [SnapshotMeta] = []
        out.reserveCapacity(files.count)
        for file in files where file.pathExtension == "json" {
            guard let h = readHeader(at: file) else { continue }
            out.append(h.meta)
        }
        return out.sorted { $0.timestamp > $1.timestamp }
    }

    /// The current head (most recent snapshot) for `appId`, if any.
    public static func head(_ appId: UUID) -> SnapshotMeta? { metas(appId).first }

    /// Newest-first listing of the user's permanent pinned snapshots.
    public static func pinnedMetas(_ appId: UUID) -> [SnapshotMeta] {
        metas(appId).filter { $0.reason == .pinned }
    }

    /// How many permanent pins `appId` currently has.
    public static func pinnedCount(_ appId: UUID) -> Int { pinnedMetas(appId).count }

    /// Record `app`'s current state as a new snapshot; returns its id. On the
    /// `.edit` path, a state identical to the current head dedups (no write,
    /// returns the head id). A `.pinned` snapshot never dedups and is always
    /// written as a full `base` (self-contained → survives neighbour prune and
    /// exports standalone), carrying the user `label`. Otherwise chooses a
    /// full base at the chain root / every `baseInterval` links, else a diff
    /// from the current head.
    @discardableResult
    public static func record(
        _ app: MyApp, reason: SnapshotReason, label: String? = nil, now: Date = Date()
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
        if !survivesDeletion.contains(reason),
           let parentId,
           chainDepth(app.id, id: parentId) + 1 < baseInterval,
           let parentState = resolve(app.id, id: parentId),
           let d = JSONDiff.diff(parentState, json) {
            record = Snapshot(id: sid, contentHash: contentHash, appId: app.id,
                              timestamp: now, device: deviceLabel, parentId: parentId,
                              reason: reason, base: nil, diff: d)
        } else {
            record = Snapshot(id: sid, contentHash: contentHash, appId: app.id,
                              timestamp: now, device: deviceLabel, parentId: parentId,
                              reason: reason, base: json, diff: nil, label: label)
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

    /// Reasons whose records outlive the MyApp: the user's permanent pins, and
    /// the `.deleted` restore point that backs Settings → Recently deleted.
    public static let survivesDeletion: Set<SnapshotReason> = [.pinned, .deleted]

    /// Drop the automatic history for `appId`, keeping the reasons in `keeping`
    /// — by default everything that must survive deleting the MyApp. Removes
    /// the whole dir when nothing survives.
    ///
    /// `gcTombstones` passes `[.pinned]`: once the tombstone ages out the app
    /// can never be listed under Recently deleted again, so its `.deleted`
    /// restore point is dead weight and would otherwise be orphaned forever.
    ///
    /// Every kept kind is written as a self-contained full base (see `record`),
    /// so dropping their siblings never dangles a chain.
    public static func deleteNonPinned(
        _ appId: UUID,
        keeping: Set<SnapshotReason> = survivesDeletion
    ) {
        let all = metas(appId)
        guard all.contains(where: { keeping.contains($0.reason) }) else {
            deleteAll(appId); return
        }
        for m in all where !keeping.contains(m.reason) {
            CloudDocument.delete(url(appId, m.id))
        }
    }

    /// Whether `appId` has a snapshot directory at all. One `stat` — the cheap
    /// gate to put in front of `head`, which lists the directory and decodes
    /// every header in it.
    public static func hasHistory(_ appId: UUID) -> Bool {
        FileManager.default.fileExists(atPath: dir(appId).path)
    }

    /// Delete every `appId` record whose reason is in `reasons`, re-basing any
    /// survivor that diffed off one of them first so no chain dangles.
    ///
    /// `restoreDeletedMyApp` drops `.deleted` this way. Those records are
    /// permanent (`survivesDeletion`) and `gcTombstones` is the only thing that
    /// collects them — via the tombstone a restore has just cleared. Without
    /// this, every delete/restore cycle strands one full base forever, mirrored
    /// to iCloud.
    ///
    /// Unlike `prune`'s single oldest-survivor re-base, losers here can sit
    /// anywhere in the chain, so each break is repaired at its own link.
    public static func dropRecords(_ appId: UUID, reasons: Set<SnapshotReason>) {
        let all = metas(appId)
        let losers = all.filter { reasons.contains($0.reason) }
        guard !losers.isEmpty else { return }
        let loserIds = Set(losers.map(\.id))
        let survivors = all.filter { !loserIds.contains($0.id) }

        // Resolve while the losers are still readable — this must precede the
        // deletes below.
        for s in survivors where !s.isBase && s.parentId.map(loserIds.contains) == true {
            guard let state = resolve(appId, id: s.id) else { continue }
            try? writeRecord(Snapshot(
                id: s.id, contentHash: s.contentHash, appId: appId,
                timestamp: s.timestamp, device: s.device, parentId: nil,
                reason: s.reason, base: state, diff: nil, label: s.label),
                to: url(appId, s.id))
        }
        for loser in losers { CloudDocument.delete(url(appId, loser.id)) }
        if survivors.isEmpty { deleteAll(appId) }   // don't leave an empty dir
    }

    /// Every app id that currently has a snapshot directory on disk — including
    /// deleted apps whose pins were kept. Backs the "pinned snapshots survive
    /// deletion" Settings list.
    public static func allAppIds() -> [UUID] {
        guard let dirs = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil) else { return [] }
        return dirs.compactMap { UUID(uuidString: $0.lastPathComponent) }
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
    /// The `survivesDeletion` reasons are permanent: never aged out, never
    /// counted toward the cap, always kept. (They are stored as full bases, so
    /// keeping them while evicting neighbours never dangles a chain.) The
    /// `.deleted` restore point is in that set for the same reason
    /// `deleteNonPinned` keeps it — its app's tombstone outlives the snapshot
    /// TTL, so a Recently deleted row must not go stale under it. Being exempt
    /// from TTL + cap, a `.deleted` record is collected only by whatever
    /// retires its tombstone: `gcTombstones` at 180 days, or `dropRecords` on
    /// restore.
    public static func prune(
        _ appId: UUID, now: Date = Date(),
        ttl: TimeInterval = defaultTTL, cap: Int = defaultCap
    ) {
        let all = metas(appId)  // newest-first
        guard !all.isEmpty else { return }

        let cutoff = now.addingTimeInterval(-ttl)
        // Permanent reasons always survive and don't consume the cap; only the
        // automatic snapshots are subject to TTL + cap eviction.
        let evictable = all.filter { !survivesDeletion.contains($0.reason) }
        var keptEvictable = evictable.filter { $0.timestamp >= cutoff }
        if keptEvictable.count > cap { keptEvictable = Array(keptEvictable.prefix(cap)) }
        // Never evict the whole automatic history — keep the newest snapshot
        // if it isn't already permanent.
        if keptEvictable.isEmpty, let newest = all.first,
           !survivesDeletion.contains(newest.reason) {
            keptEvictable = [newest]
        }

        var survivorIds = Set(keptEvictable.map(\.id))
        survivorIds.formUnion(all.filter { survivesDeletion.contains($0.reason) }.map(\.id))
        let losers = all.filter { !survivorIds.contains($0.id) }
        guard !losers.isEmpty else { return }

        // Newest-first survivors, for the oldest-survivor re-base below.
        let survivors = all.filter { survivorIds.contains($0.id) }

        // Re-base the oldest *non-base* survivor (survivors are newest-first →
        // `.last(where:)`) so its diff chain no longer walks back through an
        // about-to-be-deleted loser. Parent links are strictly chronological,
        // so every newer diff survivor terminates at this new base (or an even
        // newer pin/base). Pins older than it are already self-contained bases.
        if let oldest = survivors.last(where: { !$0.isBase }) {
            guard let state = resolve(appId, id: oldest.id) else { return }
            let rebased = Snapshot(
                id: oldest.id, contentHash: oldest.contentHash, appId: appId,
                timestamp: oldest.timestamp, device: oldest.device, parentId: nil,
                reason: oldest.reason, base: state, diff: nil, label: oldest.label)
            try? writeRecord(rebased, to: url(appId, oldest.id))
        }
        for loser in losers { CloudDocument.delete(url(appId, loser.id)) }
    }

    // MARK: - IO helpers

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

    #if DEBUG
    /// Full-record decodes performed. Tests assert the History listing never
    /// leaves the metadata-only path.
    nonisolated(unsafe) static var fullDecodeCount = 0
    #endif

    private static func readHeader(at url: URL) -> SnapshotHeader? {
        guard let data = CloudDocument.read(url) else { return nil }
        return try? JSONDecoder().decode(SnapshotHeader.self, from: data)
    }

    private static func readRecord(_ appId: UUID, _ id: UUID) -> Snapshot? {
        readRecord(at: url(appId, id))
    }

    private static func readRecord(at url: URL) -> Snapshot? {
        #if DEBUG
        fullDecodeCount += 1
        #endif
        guard let data = CloudDocument.read(url) else { return nil }
        return try? JSONDecoder().decode(Snapshot.self, from: data)
    }

    private static func writeRecord(_ record: Snapshot, to url: URL) throws {
        try CloudDocument.write(JSONEncoder().encode(record), to: url)
    }
}
