import Foundation

/// Resolves the on-disk root for all synced app data.
///
/// One root is active per launch: the iCloud ubiquity container's
/// `Documents/` when iCloud is available, else local Application Support
/// (`~/Library/Application Support/pupa`). Switching is transparent to the
/// stores — they read `memoriesRoot` / `stateRoot` and never branch on it.
///
/// `iCloud.app.pupa.ios` must match the CloudDocuments container declared in
/// the app's entitlements; without that capability `documentsRoot` is `nil`
/// and the app runs entirely local (current behaviour).
///
/// Resolution calls `url(forUbiquityContainerIdentifier:)` once, cached for
/// the process. Tests/demo set `overrideRoot` to a temp dir to stay off both
/// iCloud and the real Application Support.
public enum PupaStorage {
    /// iCloud container id; matches the CloudDocuments entitlement.
    public static let containerID = "iCloud.app.pupa.ios"

    /// Process-wide root override. Set by tests before any store inits.
    nonisolated(unsafe) public static var overrideRoot: URL?

    /// `<container>/Documents`, or `nil` when iCloud is unavailable. Resolved
    /// once. Blocking on first access — warm it off-main at launch via `warm()`.
    public static let documentsRoot: URL? = {
        guard let base = FileManager.default.url(forUbiquityContainerIdentifier: containerID)
        else { return nil }
        return base.appendingPathComponent("Documents", isDirectory: true)
    }()

    /// Local fallback root, used when iCloud is off.
    public static var localRoot: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return support.appendingPathComponent("pupa", isDirectory: true)
    }

    /// The active root for this launch: override → iCloud → local.
    public static var activeRoot: URL {
        overrideRoot ?? documentsRoot ?? localRoot
    }

    /// Whether synced data lives in iCloud this launch.
    public static var iCloudActive: Bool {
        overrideRoot == nil && documentsRoot != nil
    }

    /// Markdown memories tree root: `<active>/memories`.
    public static var memoriesRoot: URL {
        activeRoot.appendingPathComponent("memories", isDirectory: true)
    }

    /// Structured app state root: `<active>/state` (index.json, apps/, settings.json).
    public static var stateRoot: URL {
        activeRoot.appendingPathComponent("state", isDirectory: true)
    }

    /// Warm the iCloud resolution off the main thread so the first store
    /// access doesn't block app launch. Safe to call repeatedly.
    public static func warm() {
        DispatchQueue.global(qos: .userInitiated).async { _ = documentsRoot }
    }

    /// Promote local-fallback files into the iCloud container the first time
    /// iCloud becomes available, so data created offline isn't stranded.
    /// No-op when iCloud is inactive or the local root is empty. Coordinated.
    public static func promoteLocalIfNeeded() {
        guard iCloudActive, let cloud = documentsRoot else { return }
        let local = localRoot
        let fm = FileManager.default
        for sub in ["state", "memories"] {
            let src = local.appendingPathComponent(sub, isDirectory: true)
            let dst = cloud.appendingPathComponent(sub, isDirectory: true)
            guard fm.fileExists(atPath: src.path),
                  !fm.fileExists(atPath: dst.path) else { continue }
            try? fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.setUbiquitous(true, itemAt: src, destinationURL: dst)
        }
    }
}
