import Foundation
import os

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

    /// Sync diagnostics — filter Console.app by subsystem `com.pupa-app.client`,
    /// category `sync`. One line per subtree, never per file (avoids spam).
    static let log = Logger(subsystem: "com.pupa-app.client", category: "sync")

    /// Pending debounced reconcile. Lock-protected rather than actor state so
    /// `scheduleReconcile()` registers it *synchronously* — a `drain()` ordered
    /// after a write in program order is guaranteed to observe it.
    private nonisolated let pending = OSAllocatedUnfairLock<Task<Void, Never>?>(initialState: nil)
    private static let debounceNanos: UInt64 = 500_000_000  // 0.5s

    /// Seed-race guard. Set true while a device is provisioning (empty local
    /// store, awaiting its first iCloud pull). While set, `converge` refuses to
    /// push the local `state/index.json` up or let it win a conflict — a
    /// not-yet-adopted device must never overwrite the real roster in iCloud.
    /// Static + lock-protected because `converge` is `static` (also driven
    /// directly by tests). Reset by `MyAppStore.clearStorage` for test isolation.
    private static let provisioningLock = OSAllocatedUnfairLock<Bool>(initialState: false)
    public static var provisioning: Bool {
        get { provisioningLock.withLock { $0 } }
        set { provisioningLock.withLock { $0 = newValue } }
    }

    // MARK: - Trigger

    /// Debounced converge — coalesces a burst of writes into one pass. Cheap
    /// no-op when iCloud is unavailable. Safe to call from anywhere.
    nonisolated public func scheduleReconcile() {
        pending.withLock { task in
            task?.cancel()
            task = Task { [weak self] in
                try? await Task.sleep(nanoseconds: Self.debounceNanos)
                guard let self, !Task.isCancelled else { return }
                await self.reconcile()
            }
        }
    }

    /// Quiesce: cancel any armed debounced reconcile and wait for an in-flight
    /// pass to finish. After this returns, no mirror write scheduled before the
    /// call can land. Tests call it at suite-isolation points
    /// (`MyAppStore.clearStorage`) and before tearing down `cloudMirrorOverride`.
    nonisolated public func drain() async {
        let task = pending.withLock { t -> Task<Void, Never>? in
            defer { t = nil }
            t?.cancel()
            return t
        }
        await task?.value
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
        log.debug("converge start subtrees=\(PupaStorage.mirroredSubtrees, privacy: .public)")
        let conflictsRoot = local.appendingPathComponent("conflicts", isDirectory: true)

        var baseline = loadBaseline(local)
        var localChanged = false
        var pendingDownloads = 0

        for sub in PupaStorage.mirroredSubtrees {
            let lRoot = local.appendingPathComponent(sub, isDirectory: true)
            let cRoot = cloud.appendingPathComponent(sub, isDirectory: true)
            let scoped = slice(baseline, prefix: sub)

            // One walk of the cloud subtree yields both its tree snapshot and
            // any not-yet-materialized files. Kick their download in the
            // background (non-blocking) — this pass can't see bytes that haven't
            // landed yet; they arrive under their stub as `unresolved`, and
            // iCloud's NSMetadataQuery update re-triggers converge once they're
            // `.current`.
            let (cloudTree, pending) = scanCloud(cRoot)
            let unresolved = kickDownloads(pending, cloudRoot: cRoot)
            pendingDownloads += unresolved.count

            var counts = (push: 0, pull: 0, delLocal: 0, delCloud: 0, conflict: 0)
            // While provisioning, protect the `state` roster index: never let an
            // un-adopted device's local `index.json` overwrite the real one.
            let protectIndex = (sub == "state") && Self.provisioning
            for action in plan(local: tree(lRoot), cloud: cloudTree, baseline: scoped,
                               protectIndexPush: protectIndex) {
                // Eviction guard: a file iCloud evicted back to a placeholder
                // reads as "cloud absent". Never let that masquerade as a remote
                // delete of a still-present cloud file.
                if case let .deleteLocal(r) = action, unresolved.contains(r) {
                    log.error("skip deleteLocal \(sub, privacy: .public)/\(r, privacy: .public): cloud copy not downloaded")
                    continue
                }
                // Same guard for the write direction: a cloud file that hasn't
                // downloaded also reads as "cloud absent", so a brand-new
                // (no-baseline) local file — e.g. a fresh-install seed — plans as
                // `.pushUp` and would clobber the real cloud copy before it lands.
                // Skip it; once the download completes a later pass converges them.
                if case let .pushUp(r) = action, unresolved.contains(r) {
                    log.error("skip pushUp \(sub, privacy: .public)/\(r, privacy: .public): cloud copy not downloaded — would clobber")
                    continue
                }
                switch action {
                case .pushUp: counts.push += 1
                case .pullDown: counts.pull += 1
                case .deleteLocal: counts.delLocal += 1
                case .deleteCloud: counts.delCloud += 1
                case .conflict: counts.conflict += 1
                }
                let (rel, newHash, touchedLocal) = apply(
                    action, subtree: sub, localRoot: lRoot, cloudRoot: cRoot,
                    conflictsRoot: conflictsRoot.appendingPathComponent(sub, isDirectory: true))
                baseline["\(sub)/\(rel)"] = newHash
                localChanged = localChanged || touchedLocal
            }
            log.notice("plan \(sub, privacy: .public) push=\(counts.push) pull=\(counts.pull) delLocal=\(counts.delLocal) delCloud=\(counts.delCloud) conflict=\(counts.conflict)")
        }

        pruneConflictsByAge(conflictsRoot)
        saveBaseline(baseline, local)
        log.debug("converge done localChanged=\(localChanged) pendingDownloads=\(pendingDownloads)")
        SyncStatus.record(localChanged: localChanged, pendingDownloads: pendingDownloads)
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
        local: [String: Meta], cloud: [String: Meta], baseline: [String: UInt64],
        protectIndexPush: Bool = false
    ) -> [Action] {
        var out: [Action] = []
        for rel in Set(local.keys).union(cloud.keys).sorted() {
            let l = local[rel]
            let c = cloud[rel]
            let b = baseline[rel]
            // Seed-race guard (provisioning only): the roster index must never be
            // pushed up or win a conflict from an un-adopted device — the cloud
            // side is authoritative until we've pulled it.
            let guardedIndex = protectIndexPush && rel == "index.json"
            switch (l, c) {
            case let (l?, c?):
                if l.hash == c.hash { break }                // already identical
                let lChanged = (b == nil) || (l.hash != b)
                let cChanged = (b == nil) || (c.hash != b)
                if guardedIndex {
                    out.append(.pullDown(rel))               // provisioning: cloud roster wins
                } else if lChanged && !cChanged {
                    out.append(.pushUp(rel))                 // only local moved
                } else if cChanged && !lChanged {
                    out.append(.pullDown(rel))               // only cloud moved
                } else {
                    out.append(.conflict(rel: rel, localNewer: l.modified >= c.modified))
                }
            case let (l?, nil):
                if guardedIndex {
                    break                                    // provisioning: never clobber a not-yet-pulled cloud roster
                } else if b == nil {
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
            // Quarantine before unlink: a "remote delete" can also be iCloud
            // renaming a whole dir away (conflict twin), so the bytes must
            // stay recoverable under local-only `conflicts/`.
            let url = localRoot.appendingPathComponent(rel)
            if let data = read(url, coordinate: false) {
                preserveLoser(data, rel: rel, under: conflictsRoot)
            }
            remove(url, coordinate: false)
            return (rel, nil, true)

        case let .deleteCloud(rel):
            remove(cloudRoot.appendingPathComponent(rel), coordinate: true)
            return (rel, nil, false)

        case let .conflict(rel, localNewer):
            let localURL = localRoot.appendingPathComponent(rel)
            let cloudURL = cloudRoot.appendingPathComponent(rel)
            let winnerURL = localNewer ? localURL : cloudURL
            let loserURL = localNewer ? cloudURL : localURL
            // Preserve the losing side (deduped + capped) so no edit is lost,
            // then make the winner canonical on both sides. The cloud side is
            // the one needing coordination: it's the loser when local won, the
            // winner otherwise.
            if let loserData = read(loserURL, coordinate: localNewer) {
                preserveLoser(loserData, rel: rel, under: conflictsRoot)
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

    // MARK: - Conflict preservation budget

    /// Newest preserved copies kept per conflicted path. Older ones are pruned
    /// so a repeatedly-conflicting file can't accumulate unboundedly.
    static let maxConflictCopiesPerPath = 5
    /// Preserved copies older than this are pruned on the next pass.
    static let conflictMaxAge: TimeInterval = 30 * 24 * 60 * 60  // 30 days

    /// Store the losing side under `conflicts/<sub>/<rel>/<stamp>` — one folder
    /// per conflicted path. Two guards keep this from ballooning:
    ///   1. **dedup** — reuse the copy if this exact content is already
    ///      preserved for the path (an oscillating conflict re-presents the same
    ///      loser each pass), but touch it: this is a *new* loss, and the mtime
    ///      is the preservation time both `preservedFiles` and
    ///      `pruneConflictsByAge` read,
    ///   2. **cap** — keep only the newest `maxConflictCopiesPerPath`.
    /// Combined with the periodic age prune and the fact that `conflicts/` is
    /// local-only (never mirrored), preserved data stays bounded.
    private static func preserveLoser(_ data: Data, rel: String, under conflictsRoot: URL) {
        let dir = conflictsRoot.appendingPathComponent(rel, isDirectory: true)
        let loserHash = hash(data)
        let existing = conflictCopies(in: dir)
        if let dup = existing.first(where: { read($0, coordinate: false).map(hash) == loserHash }) {
            // Without this a repeat loss of unchanged content is unrecoverable:
            // no new copy is written, and the old one's mtime already sits
            // outside the recovery window.
            try? FileManager.default.setAttributes(
                [.modificationDate: Date()], ofItemAtPath: dup.path)
            return
        }
        let ext = (rel as NSString).pathExtension
        // Timestamp sorts lexically = chronologically; random suffix avoids a
        // same-second filename collision.
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let unique = "\(stamp)-\(UUID().uuidString.prefix(4))"
        let name = ext.isEmpty ? unique : "\(unique).\(ext)"
        write(data, to: dir.appendingPathComponent(name), coordinate: false)
        // Cap: drop all but the newest N for this path. Ordered by preservation
        // time, not by the stamp in the name — a deduped copy is touched but
        // keeps its original name, so the two disagree and only the mtime is
        // what the recovery window and the age prune read.
        let all = conflictCopies(in: dir).sorted {
            let (a, b) = (preservedAt($0), preservedAt($1))
            return a == b ? $0.lastPathComponent > $1.lastPathComponent : a > b
        }
        for stale in all.dropFirst(maxConflictCopiesPerPath) { remove(stale, coordinate: false) }
    }

    /// Newest quarantined copy of every path under `prefix` (a `<subtree>/<rel>`
    /// path fragment) preserved at or after `since`, keyed by its original rel.
    ///
    /// The read side of `preserveLoser`: `.deleteLocal` stashes bytes before it
    /// unlinks, so a file iCloud took away is recoverable — until
    /// `pruneConflictsByAge` reaps it at `conflictMaxAge`. Preservation time is
    /// the copy's mtime; the stamped filename is for ordering and collisions.
    ///
    /// `since` is the whole safety story: quarantine can't tell a file the user
    /// deliberately deleted elsewhere from one a bad sync took, so only copies
    /// made around the loss are eligible.
    static func preservedFiles(
        underPrefix prefix: String, since: Date, localRoot: URL
    ) -> [String: URL] {
        // Walk the prefix's own folder, not all of `conflicts/`: the prefix is a
        // literal path, so scoping is a subtree walk rather than a filter over
        // every quarantined file on the device.
        let scope = localRoot
            .appendingPathComponent("conflicts", isDirectory: true)
            .appendingPathComponent(prefix, isDirectory: true)
        // Resolved on both sides: the enumerator hands back canonical URLs
        // (`/private/var/…`) for a root that may be a symlink (`/var/…`).
        let base = scope.resolvingSymlinksInPath().path
        guard let en = FileManager.default.enumerator(
            at: scope, includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey])
        else { return [:] }
        var newest: [String: (url: URL, at: Date)] = [:]
        for case let url as URL in en {
            if url.lastPathComponent.hasPrefix(".") { continue }
            let vals = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey])
            guard vals?.isRegularFile == true,
                  let at = vals?.contentModificationDate, at >= since else { continue }
            // The copy's *parent* is the folder named after the original rel;
            // under `scope`, so the tail is what extends the prefix.
            let dir = url.deletingLastPathComponent().resolvingSymlinksInPath().path
            let rel: String
            if dir == base {
                rel = prefix
            } else if dir.hasPrefix(base + "/") {
                rel = "\(prefix)/\(dir.dropFirst(base.count + 1))"
            } else {
                continue
            }
            if let existing = newest[rel], existing.at >= at { continue }
            newest[rel] = (url, at)
        }
        return newest.mapValues(\.url)
    }

    /// When a path's data was last quarantined — the newest preserved copy's
    /// mtime, nil if nothing is preserved for it. `path` is a `<subtree>/<rel>`
    /// fragment. Callers use it as the instant a loss happened.
    static func preservationTime(ofPath path: String, localRoot: URL) -> Date? {
        conflictCopies(in: localRoot
            .appendingPathComponent("conflicts", isDirectory: true)
            .appendingPathComponent(path, isDirectory: true))
            .map(preservedAt).max()
    }

    /// Forget every copy preserved for `path`. Call once the loss it recorded
    /// is repaired, so its preservation time stops standing for an open one.
    static func dropPreserved(path: String, localRoot: URL) {
        try? FileManager.default.removeItem(at: localRoot
            .appendingPathComponent("conflicts", isDirectory: true)
            .appendingPathComponent(path, isDirectory: true))
    }

    /// Regular files directly inside a conflict path's folder (skips hidden).
    private static func conflictCopies(in dir: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))?
            .filter { !$0.lastPathComponent.hasPrefix(".") } ?? []
    }

    /// A preserved copy's preservation time. `.distantPast` if it won't stat,
    /// so an unreadable copy sorts and prunes as the oldest.
    private static func preservedAt(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate ?? .distantPast
    }

    /// Delete preserved copies older than `conflictMaxAge`, then remove any
    /// folders left empty. Runs once per reconcile.
    static func pruneConflictsByAge(_ conflictsRoot: URL, now: Date = Date()) {
        let fm = FileManager.default
        guard let en = fm.enumerator(at: conflictsRoot, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey]) else { return }
        for case let url as URL in en {
            let vals = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey])
            guard vals?.isRegularFile == true else { continue }
            let age = now.timeIntervalSince(vals?.contentModificationDate ?? now)
            if age > conflictMaxAge { try? fm.removeItem(at: url) }
        }
        removeEmptyDirs(conflictsRoot)
    }

    /// Depth-first removal of empty directories under (and including) `root`.
    private static func removeEmptyDirs(_ root: URL) {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey]) else { return }
        for child in contents where (try? child.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            removeEmptyDirs(child)
        }
        if (try? fm.contentsOfDirectory(atPath: root.path))?.isEmpty == true {
            try? fm.removeItem(at: root)
        }
    }

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

    // MARK: - iCloud materialization

    /// `.Foo.json.icloud` → `Foo.json`. Nil when `name` isn't an iCloud
    /// not-downloaded placeholder stub (a real name, `.DS_Store`,
    /// `.mirror-baseline.json`, …). Pure — no filesystem/container needed.
    static func materializedName(forPlaceholder name: String) -> String? {
        let suffix = ".icloud"
        guard name.hasPrefix("."), name.hasSuffix(suffix), name.count > 1 + suffix.count
        else { return nil }
        return String(name.dropFirst().dropLast(suffix.count))
    }

    /// Single-pass scan of a **cloud** subtree: the `rel → Meta` map (as `tree`)
    /// *and* every not-yet-materialized item, from one enumeration. Collapses
    /// what used to be two full walks (a placeholder scan + `tree`) so the cloud
    /// subtree is traversed once per converge. Local subtrees never hold
    /// placeholders, so they keep using `tree()`.
    ///
    /// Not-downloaded is detected two ways: the iOS dot-`.icloud` stub name, or
    /// (macOS-style, present under its real name) `downloadingStatus != .current`.
    /// Empty `notDownloaded` on a plain non-ubiquitous dir → the fake-container
    /// tests no-op.
    static func scanCloud(_ root: URL) -> (tree: [String: Meta], notDownloaded: [(placeholder: URL, real: URL)]) {
        let fm = FileManager.default
        var tree: [String: Meta] = [:]
        var notDownloaded: [(placeholder: URL, real: URL)] = []
        // Resolve symlinks on the base so the `/var`→`/private/var` alias can't
        // corrupt the relative path we key on.
        let base = root.resolvingSymlinksInPath().path
        guard let en = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey, .ubiquitousItemDownloadingStatusKey])
        else { return (tree, notDownloaded) }
        for case let url as URL in en {
            let name = url.lastPathComponent
            // iOS placeholder stub: not materialized, and dot-prefixed so it
            // never enters the tree map.
            if let realName = materializedName(forPlaceholder: name) {
                notDownloaded.append((url, url.deletingLastPathComponent().appendingPathComponent(realName)))
                continue
            }
            if name.hasPrefix(".") { continue }   // other hidden (baseline, .DS_Store)
            let vals = try? url.resourceValues(
                forKeys: [.isRegularFileKey, .contentModificationDateKey, .ubiquitousItemDownloadingStatusKey])
            guard vals?.isRegularFile == true else { continue }
            // macOS-style not-downloaded (present under its real name). `!= .current`
            // also re-fetches an item with a newer cloud version — desirable for
            // convergence. Narrow to `== .notDownloaded` if this churns on device.
            if let status = vals?.ubiquitousItemDownloadingStatus, status != .current {
                notDownloaded.append((url, url))
            }
            // Tree entry (skip unreadable — e.g. a dataless evicted file).
            guard let data = read(url, coordinate: false) else { continue }
            let path = url.resolvingSymlinksInPath().path
            guard path.hasPrefix(base + "/") else { continue }
            let rel = String(path.dropFirst(base.count + 1))
            tree[rel] = Meta(hash: Self.hash(data), modified: vals?.contentModificationDate ?? .distantPast)
        }
        return (tree, notDownloaded)
    }

    /// Kick a background download of every not-yet-materialized item and return
    /// their rels (relative to `cloudRoot`) as *unresolved* — none are `.current`
    /// yet, so the caller treats each as "cloud copy not present here": skip
    /// `deleteLocal`, don't count as pulled. **Non-blocking** — no wait on the
    /// actor's cooperative thread; downloads land asynchronously and iCloud's
    /// `NSMetadataQuery` update re-triggers `converge` once they're `.current`,
    /// which is when they actually pull. `[]` fast path when nothing is pending.
    @discardableResult
    static func kickDownloads(_ notDownloaded: [(placeholder: URL, real: URL)], cloudRoot: URL) -> Set<String> {
        guard !notDownloaded.isEmpty else { return [] }
        let reals = notDownloaded.map(\.real)
        DispatchQueue.global(qos: .utility).async {
            for u in reals { try? FileManager.default.startDownloadingUbiquitousItem(at: u) }
        }
        let base = cloudRoot.resolvingSymlinksInPath().path
        let unresolved = Set(notDownloaded.compactMap { rel(forPlaceholder: $0.placeholder, base: base) })
        log.notice("materialize kick root=\(cloudRoot.lastPathComponent, privacy: .public) pending=\(notDownloaded.count) unresolved=\(unresolved.count)")
        return unresolved
    }

    /// Subtree-relative materialized rel for a not-downloaded item, keyed off
    /// the on-disk *placeholder* URL. Its real sibling may not exist yet, and
    /// resolving a missing path leaves `/var` vs `/private/var` mismatched —
    /// which would silently drop the rel and defeat the eviction guard. Nil only
    /// if the placeholder isn't under `base` (defensive; shouldn't happen).
    private static func rel(forPlaceholder placeholder: URL, base: String) -> String? {
        let p = placeholder.resolvingSymlinksInPath().path
        guard p.hasPrefix(base + "/") else { return nil }
        let rel = String(p.dropFirst(base.count + 1))
        guard let realName = materializedName(forPlaceholder: placeholder.lastPathComponent)
        else { return rel }                                  // macOS-style: already the real name
        let dir = (rel as NSString).deletingLastPathComponent
        return dir.isEmpty ? realName : "\(dir)/\(realName)"
    }

    // MARK: - Baseline persistence (local, hidden, never mirrored)

    private static func baselineURL(_ localRoot: URL) -> URL {
        localRoot.appendingPathComponent(".mirror-baseline.json")
    }

    /// Delete the persisted 3-way-merge baseline for `localRoot`. Test-isolation
    /// hook: `clearStorage()` wipes `state/` but the baseline lives beside it in
    /// the storage root and would otherwise poison the next converge.
    static func removeBaseline(localRoot: URL) {
        try? FileManager.default.removeItem(at: baselineURL(localRoot))
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
