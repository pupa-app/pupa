import Foundation

/// File IO for the local canonical store. Every synced read/write routes
/// through here; each mutation schedules a debounced `StorageMirror` pass so
/// the change propagates to iCloud (no-op when iCloud is off). The mirror uses
/// its own primitives, so its copies never re-enter here.
///
/// **Writes are plain atomic, not `NSFileCoordinator`-coordinated.** The store
/// of record is always the *local* Application Support tree (`PupaStorage`),
/// which is single-process and has no `NSFilePresenter`, so there is no
/// coordinating counterpart to synchronise with — the iCloud container is
/// touched only by `StorageMirror`, which already treats this local tree as
/// uncoordinated and relies on atomic writes + its baseline-aware 3-way merge
/// for consistency. A coordinated write here only bought a synchronous XPC
/// round-trip to `filecoordinationd`, which on device can stall the calling
/// thread (here the main actor, via `MyAppStore.persist`) for hundreds of ms —
/// the intermittent freeze in pupa#120. Atomic writes still guarantee no reader
/// ever sees a torn file.
public enum CloudDocument {
    /// Read. Returns `nil` if the file is absent or unreadable.
    public static func read(_ url: URL) -> Data? {
        try? Data(contentsOf: url)
    }

    /// Atomic write; creates intermediate directories.
    public static func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        StorageMirror.shared.scheduleReconcile()
    }

    /// Move; creates the destination's parent directory.
    public static func move(from src: URL, to dst: URL) throws {
        try FileManager.default.createDirectory(
            at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: src, to: dst)
        StorageMirror.shared.scheduleReconcile()
    }

    /// Delete. Silent if the file is already gone.
    public static func delete(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try? FileManager.default.removeItem(at: url)
        StorageMirror.shared.scheduleReconcile()
    }

    // MARK: - iCloud conflict versions

    /// Unresolved `NSFileVersion` conflicts for `url` (the losing sides iCloud
    /// preserved after a last-writer-wins merge). Empty when there's no
    /// conflict or iCloud is inactive.
    public static func conflictVersions(at url: URL) -> [NSFileVersion] {
        NSFileVersion.unresolvedConflictVersionsOfItem(at: url) ?? []
    }

    /// Raw bytes of one conflict version.
    public static func readVersion(_ version: NSFileVersion) -> Data? {
        try? Data(contentsOf: version.url)
    }

    /// Mark every conflict version resolved and prune them, so the item no
    /// longer reports an unresolved conflict. Call after the losing sides
    /// have been captured (e.g. into `SnapshotStore`).
    public static func resolveConflicts(at url: URL) {
        for version in NSFileVersion.unresolvedConflictVersionsOfItem(at: url) ?? [] {
            version.isResolved = true
        }
        try? NSFileVersion.removeOtherVersionsOfItem(at: url)
    }
}

/// Watches the iCloud ubiquitous documents scope and fires `onChange` when
/// remote edits land, so stores can reload and republish for live SwiftUI
/// updates. A no-op when iCloud is inactive (no ubiquitous items to observe).
///
/// Updates are **coalesced**: during an initial iCloud download (or any burst
/// of remote writes) `NSMetadataQuery` posts `DidUpdate` many times a second,
/// and each `onChange` here drives a store reload whose heavy file IO
/// (re-encode every MyApp, per-file `NSFileVersion` conflict probes,
/// coordinated reads of the whole tree — see `MyAppStore.reloadFromDisk`) is
/// the leading suspect for the iPhone-only slowdown in pupa#110 (the iPad
/// rarely does a big initial download, so it never sees the storm). Two
/// defences stack:
///   1. `disableUpdates()` the moment a change arrives, so the query batches
///      further changes instead of posting a notification per file, and
///   2. debounce the actual `onChange` so a burst collapses into one reload,
///      then `enableUpdates()` — which flushes anything that accumulated and
///      re-arms the cycle, converging once the download settles.
/// `onChange` is **async**: each store runs its reload IO off the main actor
/// (only the final republish touches main state), and `enableUpdates()` is
/// deferred until it finishes — so a fresh burst can't overlap an in-flight
/// reload.
@MainActor
public final class CloudWatcher {
    private let query = NSMetadataQuery()
    private let onChange: @MainActor () async -> Void
    private var observers: [NSObjectProtocol] = []
    /// Pending coalesced reload; cancelled and rescheduled on each new update.
    private var pendingReload: Task<Void, Never>?
    /// Debounce window. Long enough to swallow a sync burst, short enough that
    /// a single remote edit still lands live within a beat.
    private static let debounceNanos: UInt64 = 400_000_000  // 0.4s

    public init(onChange: @escaping @MainActor () async -> Void) {
        self.onChange = onChange
    }

    public func start() {
        guard PupaStorage.iCloudActive else { return }
        query.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope]
        query.predicate = NSPredicate(format: "%K LIKE '*'", NSMetadataItemFSNameKey)
        let center = NotificationCenter.default
        for name in [NSNotification.Name.NSMetadataQueryDidUpdate,
                     NSNotification.Name.NSMetadataQueryDidFinishGathering] {
            observers.append(center.addObserver(forName: name, object: query, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleCoalescedReload() }
            })
        }
        query.start()
    }

    /// Suppress further per-file notifications and (re)arm a single debounced
    /// reload. Balanced by `enableUpdates()` when the reload finally runs.
    private func scheduleCoalescedReload() {
        query.disableUpdates()
        pendingReload?.cancel()
        pendingReload = Task { [weak self] in
            try? await Task.sleep(nanoseconds: CloudWatcher.debounceNanos)
            guard let self, !Task.isCancelled else { return }
            await self.onChange()
            // Flush whatever accumulated while disabled; if anything did, this
            // posts a fresh DidUpdate and the cycle coalesces again.
            self.query.enableUpdates()
        }
    }

    public func stop() {
        pendingReload?.cancel()
        pendingReload = nil
        query.stop()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
    }
}
