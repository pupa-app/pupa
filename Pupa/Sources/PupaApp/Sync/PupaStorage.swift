import Foundation

/// Resolves the on-disk roots for all synced app data.
///
/// **The local Application Support tree is always the store of record.** The
/// stores read and write `stateRoot` / `memoriesRoot` (under `activeRoot`,
/// which is local) directly and never block on iCloud, so turning iCloud off
/// in iOS Settings — which relaunches the app onto whatever root is available
/// — can't hide MyApps ("app looks lost") or strand offline edits. See
/// `StorageMirror`, which converges that local tree with iCloud in the
/// background when iCloud is available.
///
/// iCloud is a **mirror target**, resolved lazily off the main thread only
/// when the mirror runs. `iCloud.com.pupa-app.pupa` must match the
/// CloudDocuments container in the app's entitlements; without that
/// capability `documentsRoot` is `nil` and the app runs local-only.
///
/// Tests set `overrideRoot` (local canonical) and optionally
/// `cloudMirrorOverride` (a fake iCloud tree) to exercise the mirror without a
/// real ubiquity container.
public enum PupaStorage {
    /// iCloud container id; matches the CloudDocuments entitlement.
    public static let containerID = "iCloud.com.pupa-app.pupa"

    /// Process-wide canonical-root override. Set by tests before any store
    /// inits so file IO stays off the developer's real Application Support.
    nonisolated(unsafe) public static var overrideRoot: URL?

    /// Test hook: pretend this directory is the iCloud mirror. Only consulted
    /// when `overrideRoot` is set, so tests never touch a real container.
    nonisolated(unsafe) public static var cloudMirrorOverride: URL?

    /// `<container>/Documents`, or `nil` when iCloud is unavailable. Resolved
    /// once (blocking on first access) — only ever touched by the background
    /// mirror, never on the launch/store-load path.
    public static let documentsRoot: URL? = {
        guard let base = FileManager.default.url(forUbiquityContainerIdentifier: containerID)
        else { return nil }
        return base.appendingPathComponent("Documents", isDirectory: true)
    }()

    /// Local canonical root: `~/Library/Application Support/pupa`. `PupaHost` is
    /// sandboxed on macOS, so there that resolves inside the app container.
    public static var localRoot: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return support.appendingPathComponent("pupa", isDirectory: true)
    }

    /// The canonical root the stores read and write: always local (override in
    /// tests). Never iCloud — that's a mirror, resolved separately.
    public static var activeRoot: URL {
        overrideRoot ?? localRoot
    }

    /// The iCloud mirror root, or `nil` when iCloud is unavailable. Under a
    /// test `overrideRoot` this is *only* the injected `cloudMirrorOverride`
    /// (never the real container). The subtree layout mirrors `activeRoot`.
    public static var cloudMirrorRoot: URL? {
        if overrideRoot != nil { return cloudMirrorOverride }
        return documentsRoot
    }

    /// Whether an iCloud mirror is available to sync with this launch.
    public static var iCloudActive: Bool { cloudMirrorRoot != nil }

    /// Durable "this install has committed a definitive MyApp roster" marker.
    /// Local-only (lives at `activeRoot`, outside the mirrored `state/`), so it
    /// never syncs. Its purpose: tell "genuinely fresh install" apart from
    /// "local store is momentarily empty while awaiting the first iCloud pull".
    /// While absent + iCloud active, an empty local store must NOT seed-and-push
    /// a default roster — that clobbers the real apps on every device.
    public static var rosterEstablishedURL: URL {
        activeRoot.appendingPathComponent(".roster-established")
    }

    /// True once this install has adopted a real roster (from iCloud) or seeded
    /// one against a genuinely empty cloud.
    public static var rosterEstablished: Bool {
        FileManager.default.fileExists(atPath: rosterEstablishedURL.path)
    }

    /// Stamp the roster-established marker. Idempotent.
    public static func markRosterEstablished() {
        try? FileManager.default.createDirectory(at: activeRoot, withIntermediateDirectories: true)
        try? Data().write(to: rosterEstablishedURL, options: .atomic)
    }

    /// Clear the marker (test isolation — `MyAppStore.clearStorage`).
    public static func clearRosterEstablished() {
        try? FileManager.default.removeItem(at: rosterEstablishedURL)
    }

    /// Kick a download of every not-yet-materialized item under `dir` and
    /// return how many are still pending (0 = subtree fully materialized).
    /// FileManager-enumeration based — never gated on `NSMetadataQuery` (which
    /// is unreliable on macOS). Detects iOS `.name.icloud` stubs by name and
    /// macOS dataless items via `ubiquitousItemDownloadingStatus != .current`.
    /// No-op returning 0 on a plain non-ubiquitous dir (tests, iCloud off).
    @discardableResult
    public static func kickUndownloaded(under dir: URL) -> Int {
        let fm = FileManager.default
        guard let en = fm.enumerator(
            at: dir, includingPropertiesForKeys: [.ubiquitousItemDownloadingStatusKey])
        else { return 0 }
        var pending = 0
        for case let url as URL in en {
            if let real = StorageMirror.materializedName(forPlaceholder: url.lastPathComponent) {
                pending += 1
                try? fm.startDownloadingUbiquitousItem(
                    at: url.deletingLastPathComponent().appendingPathComponent(real))
                continue
            }
            let status = (try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]))?
                .ubiquitousItemDownloadingStatus
            if let status, status != .current { pending += 1 }
            // Kick unconditionally (materialized items no-op): the status
            // resource value can under-report dataless items on macOS, and the
            // always-kick behavior is what made the state/ pull reliable.
            try? fm.startDownloadingUbiquitousItem(at: url)
        }
        return pending
    }

    /// `kickUndownloaded` over a mirrored subtree of the iCloud container.
    /// 0 when iCloud is off.
    @discardableResult
    public static func kickUndownloaded(subtree: String) -> Int {
        guard let cloud = cloudMirrorRoot else { return 0 }
        return kickUndownloaded(under: cloud.appendingPathComponent(subtree, isDirectory: true))
    }

    /// Force-download every item under the iCloud mirror's `state/` subtree so
    /// a device awaiting its first sync materializes the real `index.json` +
    /// app files instead of racing ahead on placeholders. No-op when iCloud is
    /// off or the items aren't ubiquitous (tests use a plain mirror dir).
    /// Returns how many items are still pending, so a caller can report "N
    /// left" instead of an open-ended spinner.
    @discardableResult
    public static func startDownloadingState() -> Int {
        kickUndownloaded(subtree: "state")
    }

    /// Force-download a mirrored subtree, reconciling between kicks so landed
    /// bytes pull into the local tree. Settles when nothing is pending (after a
    /// final reconcile) or `timeout` elapses. Runs its sleeps in the caller's
    /// task — each `reconcile()` is an ordinary serialized actor call, so the
    /// `StorageMirror` actor is never blocked waiting on a download.
    @discardableResult
    public static func downloadSubtreeUntilSettled(
        _ subtree: String,
        timeout: Duration = .seconds(60),
        initialPoll: Duration = .milliseconds(500)
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        var poll = initialPoll
        while true {
            let pending = kickUndownloaded(subtree: subtree)
            await StorageMirror.shared.reconcile()
            if pending == 0 { return true }
            if clock.now + poll > deadline { return false }
            try? await Task.sleep(for: poll)
            poll = min(poll * 2, .seconds(4))
        }
    }

    /// Markdown memories tree root: `<active>/memories`.
    public static var memoriesRoot: URL {
        activeRoot.appendingPathComponent("memories", isDirectory: true)
    }

    /// Derived local caches: `<active>/cache`. Deliberately **outside**
    /// `mirroredSubtrees` — everything here is a pure function of the synced
    /// tree, so it must never sync, conflict, or need a merge story. Same
    /// reasoning as the local-only `rosterEstablishedURL`.
    public static var cacheRoot: URL {
        activeRoot.appendingPathComponent("cache", isDirectory: true)
    }

    /// Structured app state root: `<active>/state` (index.json, apps/, settings.json).
    public static var stateRoot: URL {
        activeRoot.appendingPathComponent("state", isDirectory: true)
    }

    /// Subtrees the mirror keeps in sync between local and iCloud. The
    /// preserved losing sides of a merge live under a separate local-only
    /// `conflicts/` tree (see `StorageMirror`) — deliberately **not** mirrored,
    /// so recovery copies don't double storage or propagate between devices.
    public static let mirroredSubtrees = ["state", "memories"]

    /// Resolve the iCloud container off the main thread so the first mirror
    /// pass doesn't block, and kick a background converge. Safe to call
    /// repeatedly. No-op for the canonical (local) read path, which never
    /// waits on this.
    public static func warm() {
        DispatchQueue.global(qos: .utility).async {
            _ = documentsRoot
            StorageMirror.shared.scheduleReconcile()
        }
    }
}
