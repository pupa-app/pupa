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
/// when the mirror runs. `iCloud.com.pupa-app.client` must match the
/// CloudDocuments container in the app's entitlements; without that
/// capability `documentsRoot` is `nil` and the app runs local-only.
///
/// Tests set `overrideRoot` (local canonical) and optionally
/// `cloudMirrorOverride` (a fake iCloud tree) to exercise the mirror without a
/// real ubiquity container.
public enum PupaStorage {
    /// iCloud container id; matches the CloudDocuments entitlement.
    public static let containerID = "iCloud.com.pupa-app.client"

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

    /// Local canonical root: `~/Library/Application Support/pupa`.
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

    /// Force-download every item under the iCloud mirror's `state/` subtree so
    /// a device awaiting its first sync materializes the real `index.json` +
    /// app files instead of racing ahead on placeholders. No-op when iCloud is
    /// off or the items aren't ubiquitous (tests use a plain mirror dir).
    public static func startDownloadingState() {
        guard let cloud = cloudMirrorRoot else { return }
        let stateDir = cloud.appendingPathComponent("state", isDirectory: true)
        guard let en = FileManager.default.enumerator(at: stateDir, includingPropertiesForKeys: nil)
        else { return }
        for case let url as URL in en {
            try? FileManager.default.startDownloadingUbiquitousItem(at: url)
        }
    }

    /// Markdown memories tree root: `<active>/memories`.
    public static var memoriesRoot: URL {
        activeRoot.appendingPathComponent("memories", isDirectory: true)
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
