import Foundation

/// Coordinated file IO for data that may live in an iCloud ubiquity
/// container. `NSFileCoordinator` is required for ubiquitous files and is
/// harmless for local ones, so all synced reads/writes route through here.
public enum CloudDocument {
    /// Coordinated read. Returns `nil` if the file is absent or unreadable.
    public static func read(_ url: URL) -> Data? {
        var data: Data?
        var coordErr: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordErr) { u in
            data = try? Data(contentsOf: u)
        }
        return data
    }

    /// Coordinated atomic write; creates intermediate directories.
    public static func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var coordErr: NSError?
        var writeErr: Error?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordErr) { u in
            do { try data.write(to: u, options: .atomic) } catch { writeErr = error }
        }
        if let coordErr { throw coordErr }
        if let writeErr { throw writeErr }
    }

    /// Coordinated move; creates the destination's parent directory.
    public static func move(from src: URL, to dst: URL) throws {
        try FileManager.default.createDirectory(
            at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
        var coordErr: NSError?
        var moveErr: Error?
        NSFileCoordinator().coordinate(
            writingItemAt: src, options: .forMoving,
            writingItemAt: dst, options: .forReplacing, error: &coordErr
        ) { s, d in
            do { try FileManager.default.moveItem(at: s, to: d) } catch { moveErr = error }
        }
        if let coordErr { throw coordErr }
        if let moveErr { throw moveErr }
    }

    /// Coordinated delete. Silent if the file is already gone.
    public static func delete(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        var coordErr: NSError?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forDeleting, error: &coordErr) { u in
            try? FileManager.default.removeItem(at: u)
        }
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
@MainActor
public final class CloudWatcher {
    private let query = NSMetadataQuery()
    private let onChange: @MainActor () -> Void
    private var observers: [NSObjectProtocol] = []

    public init(onChange: @escaping @MainActor () -> Void) {
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
                MainActor.assumeIsolated { self?.onChange() }
            })
        }
        query.start()
    }

    public func stop() {
        query.stop()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
    }
}
