import Foundation

/// Two-way file mirror between the local canonical store
/// (`PupaStorage.activeRoot`) and the iCloud container
/// (`PupaStorage.cloudMirrorRoot`).
///
/// The local tree is always the store of record — the app reads and writes it
/// directly and never blocks on iCloud — so turning iCloud off in iOS Settings
/// can't hide MyApps or strand offline edits (pupa#110 follow-up). When iCloud
/// is available, `reconcile()` converges the two trees.
///
/// **Merge is baseline-aware (3-way), not naive newest-wins.** A persisted
/// `.mirror-baseline.json` records each file's hash as of the last successful
/// sync, so we can tell an ordinary sequential edit (one side changed, the
/// other still matches the baseline → just propagate) from a genuine conflict
/// (both sides changed since the baseline). Without the baseline every second
/// edit to an already-synced file would look like a conflict, and deletes
/// couldn't be told apart from "not yet downloaded". Genuine conflicts resolve
/// newest-wins and the losing side is preserved under `conflicts/` — nothing is
/// ever silently dropped. Deletes propagate; a delete racing an edit keeps the
/// edit (data survives).
///
/// Reconcile is serialized on the actor and runs off the main thread. It's
/// triggered three ways, all debounced into one pass: at launch (`warm()`),
/// after any local write (`CloudDocument` calls `scheduleReconcile`), and when
/// the `CloudWatcher` sees a remote change.
public actor StorageMirror {
    public static let shared = StorageMirror()
    private init() {}

    private var pending: Task<Void, Never>?
    private static let debounceNanos: UInt64 = 500_000_000  // 0.5s

    // MARK: - Trigger

    /// Debounced converge — coalesces a burst of writes into one pass. Cheap
    /// no-op when iCloud is unavailable. Safe to call from anywhere.
    nonisolated public func scheduleReconcile() {
        Task { await self.debounceReconcile() }
    }

    private func debounceReconcile() {
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.debounceNanos)
            guard let self, !Task.isCancelled else { return }
            await self.reconcile()
        }
    }

    // MARK: - Reconcile

    /// Converge the local canonical tree with the iCloud mirror. Returns `true`
    /// if the **local** tree changed (so the caller can reload the stores).
    /// No-op returning `false` when iCloud is unavailable.
    @discardableResult
    public func reconcile() -> Bool {
        Self.converge(localRoot: PupaStorage.activeRoot, cloudRoot: PupaStorage.cloudMirrorRoot)
    }

    /// The convergence pass over explicit roots — the actor's `reconcile()` is
    /// a thin wrapper that supplies the live `PupaStorage` roots. Split out so
    /// tests drive it against isolated temp dirs without mutating process-wide
    /// storage overrides (which would clobber sibling suites). `cloudRoot == nil`
    /// models "iCloud off": a no-op that leaves the local tree untouched.
    @discardableResult
    static func converge(localRoot local: URL, cloudRoot: URL?) -> Bool {
        guard let cloud = cloudRoot else { return false }
        let conflictsRoot = local.appendingPathComponent("conflicts", isDirectory: true)

        var baseline = loadBaseline(local)
        var localChanged = false

        for sub in PupaStorage.mirroredSubtrees {
            let lRoot = local.appendingPathComponent(sub, isDirectory: true)
            let cRoot = cloud.appendingPathComponent(sub, isDirectory: true)
            let scoped = slice(baseline, prefix: sub)

            for action in plan(local: tree(lRoot), cloud: tree(cRoot), baseline: scoped) {
                let (rel, newHash, touchedLocal) = apply(
                    action, subtree: sub, localRoot: lRoot, cloudRoot: cRoot,
                    conflictsRoot: conflictsRoot.appendingPathComponent(sub, isDirectory: true))
                baseline["\(sub)/\(rel)"] = newHash
                localChanged = localChanged || touchedLocal
            }
        }

        saveBaseline(baseline, local)
        return localChanged
    }

    // MARK: - Pure plan

    /// Metadata for one file: a deterministic content hash plus its mtime
    /// (used only to pick the winner of a genuine conflict).
    public struct Meta: Equatable, Sendable {
        public let hash: UInt64
        public let modified: Date
        public init(hash: UInt64, modified: Date) {
            self.hash = hash
            self.modified = modified
        }
    }

    /// One convergence step for a single relative path.
    public enum Action: Equatable, Sendable {
        case pushUp(String)                        // copy local → cloud
        case pullDown(String)                      // copy cloud → local
        case deleteLocal(String)                   // remote delete reached us
        case deleteCloud(String)                   // local delete propagates
        case conflict(rel: String, localNewer: Bool)  // both changed; newest wins, loser preserved
    }

    /// Decide, purely, what to do for every path present in either tree, using
    /// the last-synced `baseline`. Deterministic and total — this is the
    /// safety-critical core and is exercised directly by the tests.
    public static func plan(
        local: [String: Meta], cloud: [String: Meta], baseline: [String: UInt64]
    ) -> [Action] {
        var out: [Action] = []
        for rel in Set(local.keys).union(cloud.keys).sorted() {
            let l = local[rel]
            let c = cloud[rel]
            let b = baseline[rel]
            switch (l, c) {
            case let (l?, c?):
                if l.hash == c.hash { break }                // already identical
                let lChanged = (b == nil) || (l.hash != b)
                let cChanged = (b == nil) || (c.hash != b)
                if lChanged && !cChanged {
                    out.append(.pushUp(rel))                 // only local moved
                } else if cChanged && !lChanged {
                    out.append(.pullDown(rel))               // only cloud moved
                } else {
                    out.append(.conflict(rel: rel, localNewer: l.modified >= c.modified))
                }
            case let (l?, nil):
                if b == nil {
                    out.append(.pushUp(rel))                 // brand-new local file
                } else if l.hash == b {
                    out.append(.deleteLocal(rel))            // cloud deleted an unchanged file
                } else {
                    out.append(.pushUp(rel))                 // delete-vs-edit → edit wins
                }
            case let (nil, c?):
                if b == nil {
                    out.append(.pullDown(rel))               // brand-new cloud file
                } else if c.hash == b {
                    out.append(.deleteCloud(rel))            // we deleted an unchanged file
                } else {
                    out.append(.pullDown(rel))               // delete-vs-edit → edit wins
                }
            case (nil, nil):
                break
            }
        }
        return out
    }

    // MARK: - Apply (IO)

    /// Perform one action. Returns the path's converged content hash (nil if it
    /// ends up deleted) for the new baseline, and whether the **local** tree
    /// was touched (so the caller knows to reload the stores).
    private static func apply(
        _ action: Action, subtree: String, localRoot: URL, cloudRoot: URL, conflictsRoot: URL
    ) -> (rel: String, newHash: UInt64?, touchedLocal: Bool) {
        switch action {
        case let .pushUp(rel):
            let src = localRoot.appendingPathComponent(rel)
            copy(from: src, to: cloudRoot.appendingPathComponent(rel), coordinateDst: true)
            return (rel, readHash(src), false)

        case let .pullDown(rel):
            let dst = localRoot.appendingPathComponent(rel)
            copy(from: cloudRoot.appendingPathComponent(rel), to: dst, coordinateSrc: true)
            return (rel, readHash(dst), true)

        case let .deleteLocal(rel):
            remove(localRoot.appendingPathComponent(rel), coordinate: false)
            return (rel, nil, true)

        case let .deleteCloud(rel):
            remove(cloudRoot.appendingPathComponent(rel), coordinate: true)
            return (rel, nil, false)

        case let .conflict(rel, localNewer):
            let localURL = localRoot.appendingPathComponent(rel)
            let cloudURL = cloudRoot.appendingPathComponent(rel)
            let winnerURL = localNewer ? localURL : cloudURL
            let loserURL = localNewer ? cloudURL : localURL
            // Preserve the losing side so no edit is lost, then make the winner
            // canonical on both sides. The cloud side is the one needing
            // coordination: it's the loser when local won, the winner otherwise.
            if let loserData = read(loserURL, coordinate: localNewer) {
                let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
                let ext = (rel as NSString).pathExtension
                let base = (rel as NSString).deletingPathExtension
                let name = ext.isEmpty ? "\(base)__\(stamp)" : "\(base)__\(stamp).\(ext)"
                write(loserData, to: conflictsRoot.appendingPathComponent(name), coordinate: false)
            }
            if let winnerData = read(winnerURL, coordinate: !localNewer) {
                if !localNewer { write(winnerData, to: localURL, coordinate: false) }
                write(winnerData, to: cloudURL, coordinate: true)
                return (rel, Self.hash(winnerData), touchedLocalConflict(localNewer))
            }
            return (rel, nil, false)
        }
    }

    /// A conflict touches local only when the cloud side won (we rewrote local).
    private static func touchedLocalConflict(_ localNewer: Bool) -> Bool { !localNewer }

    // MARK: - Tree snapshot

    /// Map of `rel → Meta` for every non-hidden file under `root` (recursive).
    /// Missing root → empty. Hidden (dot-prefixed) files are skipped so the
    /// baseline and `conflicts/` scaffolding never mirror themselves.
    static func tree(_ root: URL) -> [String: Meta] {
        let fm = FileManager.default
        var out: [String: Meta] = [:]
        // Resolve symlinks on the base so the `/var`→`/private/var` alias (and
        // similar) can't corrupt the relative path we key on.
        let base = root.resolvingSymlinksInPath().path
        guard let en = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey])
        else { return out }
        for case let url as URL in en {
            if url.lastPathComponent.hasPrefix(".") { continue }
            let vals = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey])
            guard vals?.isRegularFile == true else { continue }
            guard let data = read(url, coordinate: false) else { continue }
            let path = url.resolvingSymlinksInPath().path
            guard path.hasPrefix(base + "/") else { continue }
            let rel = String(path.dropFirst(base.count + 1))
            out[rel] = Meta(hash: Self.hash(data), modified: vals?.contentModificationDate ?? .distantPast)
        }
        return out
    }

    // MARK: - Baseline persistence (local, hidden, never mirrored)

    private static func baselineURL(_ localRoot: URL) -> URL {
        localRoot.appendingPathComponent(".mirror-baseline.json")
    }

    static func loadBaseline(_ localRoot: URL) -> [String: UInt64] {
        guard let data = try? Data(contentsOf: baselineURL(localRoot)),
              let map = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }
        return map.reduce(into: [:]) { $0[$1.key] = UInt64($1.value) }
    }

    static func saveBaseline(_ baseline: [String: UInt64], _ localRoot: URL) {
        // Encode as strings — UInt64 exceeds JSON's safe integer range.
        let map = baseline.reduce(into: [String: String]()) { $0[$1.key] = String($1.value) }
        guard let data = try? JSONEncoder().encode(map) else { return }
        try? FileManager.default.createDirectory(at: localRoot, withIntermediateDirectories: true)
        try? data.write(to: baselineURL(localRoot), options: .atomic)
    }

    private static func slice(_ baseline: [String: UInt64], prefix: String) -> [String: UInt64] {
        let p = prefix + "/"
        return baseline.reduce(into: [:]) { acc, kv in
            if kv.key.hasPrefix(p) { acc[String(kv.key.dropFirst(p.count))] = kv.value }
        }
    }

    // MARK: - Deterministic content hash (FNV-1a 64-bit)

    /// Stable across processes — required, since the baseline is persisted and
    /// compared on the next launch. (Swift's `Hashable` is per-process seeded.)
    static func hash(_ data: Data) -> UInt64 {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in data { h = (h ^ UInt64(byte)) &* 0x0000_0100_0000_01b3 }
        return h
    }

    private static func readHash(_ url: URL) -> UInt64? {
        read(url, coordinate: false).map(Self.hash)
    }

    // MARK: - Coordinated file primitives (mirror-internal; never re-trigger)

    private static func read(_ url: URL, coordinate: Bool) -> Data? {
        guard coordinate else { return try? Data(contentsOf: url) }
        var data: Data?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: nil) { data = try? Data(contentsOf: $0) }
        return data
    }

    private static func write(_ data: Data, to url: URL, coordinate: Bool) {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard coordinate else { try? data.write(to: url, options: .atomic); return }
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: nil) {
            try? data.write(to: $0, options: .atomic)
        }
    }

    private static func copy(from src: URL, to dst: URL, coordinateSrc: Bool = false, coordinateDst: Bool = false) {
        guard let data = read(src, coordinate: coordinateSrc) else { return }
        write(data, to: dst, coordinate: coordinateDst)
    }

    private static func remove(_ url: URL, coordinate: Bool) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        guard coordinate else { try? FileManager.default.removeItem(at: url); return }
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forDeleting, error: nil) {
            try? FileManager.default.removeItem(at: $0)
        }
    }
}
