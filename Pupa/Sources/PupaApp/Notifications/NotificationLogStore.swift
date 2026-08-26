import Foundation

/// Durable log of every notification Pupa has scheduled, and what became of it.
///
/// Exists because `UNUserNotificationCenter` is not a history: it holds only
/// pending requests, so a one-shot vanishes the instant it fires. Without a
/// record there is no way to tell "it fired" from "it was cancelled" from "it
/// never existed", and no way to say who scheduled it.
///
/// **Local-only** — `activeRoot/notifications/log.json`, written with plain
/// `FileManager` rather than `CloudDocument` so it stays outside the mirrored
/// `state/` subtree. A record's identity is a UN identifier in *this* device's
/// queue; mirrored, a second device would find every id missing from its own
/// queue and `reconcile` would mark the lot fired.
///
/// Reached through `shared` (the coordinator that writes to it is itself a
/// singleton); tests construct their own instances after `clearStorage()`.
@MainActor
@Observable
public final class NotificationLogStore {
    public static let shared = NotificationLogStore()

    /// FIFO cap on *finished* records. A `.scheduled` record is never evicted
    /// however old — it still exists in the OS queue, so dropping it would
    /// orphan a live notification.
    public static let cap = 200

    public private(set) var records: [NotificationRecord]

    /// OS identifiers this store has dropped — replaced by an edit, or deleted
    /// from history. Not persisted; they exist only to stop a queue snapshot
    /// older than the removal from re-adopting them as phantom rows.
    @ObservationIgnored private var retiredUnIds: Set<String> = []

    public init() {
        records = Self.load()
    }

    // MARK: - Mutation

    /// Record a notification this app just handed to the OS.
    public func noteScheduled(
        _ request: NotificationRequest,
        origin: NotificationOrigin,
        unId: String,
        deliveryAt: Date,
        now: Date = Date()
    ) {
        records.append(
            NotificationRecord(
                scheduling: request, origin: origin, unId: unId,
                deliveryAt: deliveryAt, now: now
            )
        )
        trim()
        persist()
    }

    /// Mark the record holding `unId` cancelled. No-op if unknown or already
    /// finished — cancellation is idempotent everywhere else too.
    public func markCancelled(unId: String, now: Date = Date()) {
        guard let i = records.firstIndex(where: { $0.unId == unId && $0.status == .scheduled })
        else { return }
        records[i].status = .cancelled
        records[i].statusChangedAt = now
        trim()
        persist()
    }

    /// Re-point a record at the replacement the OS just accepted. Edit is
    /// cancel + reschedule, so the row keeps its `id` and Origin while `unId`
    /// churns. A row that fired while the composer was open comes back as
    /// `.scheduled` — the user asked for it to run again, so that's right.
    public func noteEdited(
        id: UUID,
        request: NotificationRequest,
        unId: String,
        deliveryAt: Date,
        now: Date = Date()
    ) {
        guard let i = records.firstIndex(where: { $0.id == id }) else { return }
        let old = records[i]
        retiredUnIds.insert(old.unId)
        records[i] = NotificationRecord(
            scheduling: request, origin: old.origin, unId: unId, deliveryAt: deliveryAt,
            id: old.id, now: now
        )
        // Only worth flagging on someone else's reminder — the badge exists so
        // an agent's row doesn't silently read as untouched.
        records[i].editedByUser = old.origin != .user
        persist()
    }

    public func deleteFromHistory(id: UUID) {
        guard let i = records.firstIndex(where: { $0.id == id }), records[i].status != .scheduled
        else { return }
        retiredUnIds.insert(records[i].unId)
        records.remove(at: i)
        persist()
    }

    public func clearHistory() {
        let finished = records.filter { $0.status != .scheduled }
        guard !finished.isEmpty else { return }
        // Retire the ids too, or a queue snapshot taken before this re-adopts
        // them as rows for notifications that no longer exist.
        retiredUnIds.formUnion(finished.map(\.unId))
        records.removeAll { $0.status != .scheduled }
        persist()
    }

    // MARK: - Reconcile

    /// Fold the OS pending queue into the log: notice what fired, refresh
    /// repeats, adopt anything scheduled by a build that predates this store.
    ///
    /// The only way to learn a notification fired — iOS never calls back for a
    /// delivery the user didn't tap — is to see it leave the queue. Takes
    /// `pending` as an argument rather than reading the coordinator so it stays
    /// testable on hosts where `UNUserNotificationCenter` can't be touched.
    ///
    /// Reading the queue is `async`, so both edges of the suspension matter.
    /// `capturedAt` precedes it: a record written during the read is newer
    /// than the snapshot and is left alone rather than judged absent from a
    /// queue that predates it. `now` follows it: a notification that fired
    /// during the read is past due, so it reads as delivered, not cancelled.
    public func reconcile(
        pending: [NotificationCenterCoordinator.PendingNotification],
        capturedAt: Date,
        now: Date
    ) {
        var changed = false
        var live: [String: NotificationCenterCoordinator.PendingNotification] = [:]
        for p in pending { live[p.id] = p }

        for i in records.indices
        where records[i].status == .scheduled && records[i].statusChangedAt <= capturedAt {
            if let entry = live[records[i].unId] {
                // Repeats move their next fire date forward on every delivery.
                if records[i].deliveryAt != entry.deliveryAt {
                    records[i].deliveryAt = entry.deliveryAt
                    changed = true
                }
            } else {
                // Gone from the queue: delivered if its instant has passed,
                // otherwise removed behind our back (another device's iCloud
                // reset, a user clearing Notification Center, a crash).
                let delivered = (records[i].deliveryAt ?? .distantFuture) <= now
                records[i].status = delivered ? .fired : .cancelled
                records[i].statusChangedAt = now
                changed = true
            }
        }

        let known = Set(records.map(\.unId)).union(retiredUnIds)
        for p in pending where !known.contains(p.id) {
            records.append(NotificationRecord(adopting: p, now: now))
            changed = true
        }

        guard changed else { return }
        trim()
        persist()
    }

    // MARK: - Files

    nonisolated static var dir: URL {
        PupaStorage.activeRoot.appendingPathComponent("notifications", isDirectory: true)
    }

    nonisolated static var url: URL {
        dir.appendingPathComponent("log.json")
    }

    private nonisolated static func load() -> [NotificationRecord] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([NotificationRecord].self, from: data)) ?? []
    }

    private func persist() {
        let enc = JSONEncoder()
        // Stable key order so the file diffs readably when debugging.
        enc.outputFormatting = [.sortedKeys]
        guard let data = try? enc.encode(records) else { return }
        try? FileManager.default.createDirectory(at: Self.dir, withIntermediateDirectories: true)
        try? data.write(to: Self.url, options: .atomic)
    }

    /// Evict the oldest finished records past `cap`. Scheduled rows are never
    /// counted or evicted — they're live notifications, not history.
    private func trim() {
        let finished = records.filter { $0.status != .scheduled }
        guard finished.count > Self.cap else { return }
        // Same order the Past list shows, so eviction drops what reads as
        // oldest. `statusChangedAt` would not: one reconcile pass stamps every
        // row it finishes with the same instant.
        let keep = Set(
            finished.sorted(by: NotificationRecord.byMostRecent).prefix(Self.cap).map(\.id)
        )
        records.removeAll { $0.status != .scheduled && !keep.contains($0.id) }
    }

    public static func clearStorage() {
        try? FileManager.default.removeItem(at: dir)
    }
}
