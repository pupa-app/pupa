import Foundation

/// Who created a notification. Distinct from `NotificationRequest.Target`,
/// which says where a *tap* lands: the orchestrator can schedule a
/// notification pointed at a myApp, and the user's own reminders point
/// nowhere at all.
public enum NotificationOrigin: Codable, Sendable, Hashable {
    /// Composed by hand in Settings → Notifications.
    case user
    /// Scheduled by the orchestrator agent (memory scope).
    case orchestrator
    /// Scheduled by a myApp's agent.
    case myApp(UUID)
    /// Adopted from the OS queue carrying no readable origin marker.
    case unknown

    // One serialization, used for both the log file and the `pupa.origin`
    // marker, so the two can't drift apart.
    public init(from decoder: Decoder) throws {
        self = Self.fromUserInfo(try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(userInfoValue)
    }

    /// The string stashed in the notification's `userInfo` so a record can be
    /// rebuilt from the OS queue alone (see `NotificationLogStore.reconcile`).
    public var userInfoValue: String {
        switch self {
        case .user: return "user"
        case .orchestrator: return "orchestrator"
        case .unknown: return "unknown"
        case .myApp(let id): return "myApp:\(id.uuidString)"
        }
    }

    /// Inverse of `userInfoValue`. Missing or unreadable ⇒ `.unknown`; never
    /// guesses a creator.
    public static func fromUserInfo(_ raw: String?) -> NotificationOrigin {
        switch raw {
        case "user": return .user
        case "orchestrator": return .orchestrator
        case let raw?:
            guard raw.hasPrefix("myApp:"),
                  let id = UUID(uuidString: String(raw.dropFirst("myApp:".count)))
            else { return .unknown }
            return .myApp(id)
        default: return .unknown
        }
    }
}

/// One notification's durable Pupa-side row: who scheduled it, what it said,
/// and what became of it.
///
/// `UNUserNotificationCenter` holds only *pending* requests, so a fired
/// one-shot disappears from it entirely. A record outlives delivery, which is
/// what makes the Past list — and telling "fired" apart from "cancelled" —
/// possible at all.
///
/// `id` is stable for the life of the row; `unId` is the OS identifier and
/// churns on every edit, because UN cannot mutate a scheduled request (edit is
/// cancel + reschedule).
public struct NotificationRecord: Codable, Identifiable, Sendable, Hashable {
    public enum Status: String, Codable, Sendable {
        /// Still in the OS pending queue.
        case scheduled
        /// Its delivery instant passed and it left the queue.
        case fired
        /// Removed from the queue before it fired.
        case cancelled
    }

    public let id: UUID
    /// Current `UNNotificationRequest` identifier. Changes on edit.
    public var unId: String
    public var origin: NotificationOrigin
    public var title: String
    public var body: String
    /// Next (or final) delivery instant, refreshed from the OS for repeats.
    public var deliveryAt: Date?
    public var repeats: Bool
    /// Component the banner deep-links to, for the row's "→ x" label.
    public var componentId: String?
    /// Full snapshot of what was scheduled. Nil only for records adopted from
    /// the OS queue that this build didn't schedule — the queue doesn't carry
    /// enough to rebuild a trigger, so those rows can't be edited.
    public var request: NotificationRequest?
    public var status: Status
    /// When this record was last written. Drives eviction, and gates
    /// `reconcile` against a queue snapshot older than the record itself.
    public var statusChangedAt: Date
    /// Set once the user edits a record the agent created, so the Origin
    /// badge isn't a lie.
    public var editedByUser: Bool

    /// Private so no caller can build a record whose flattened fields disagree
    /// with its `request`. Everything funnels through the two below.
    private init(
        id: UUID = UUID(),
        unId: String,
        origin: NotificationOrigin,
        title: String,
        body: String,
        deliveryAt: Date?,
        repeats: Bool,
        componentId: String? = nil,
        request: NotificationRequest?,
        status: Status = .scheduled,
        statusChangedAt: Date = Date(),
        editedByUser: Bool = false
    ) {
        self.id = id
        self.unId = unId
        self.origin = origin
        self.title = title
        self.body = body
        self.deliveryAt = deliveryAt
        self.repeats = repeats
        self.componentId = componentId
        self.request = request
        self.status = status
        self.statusChangedAt = statusChangedAt
        self.editedByUser = editedByUser
    }

    /// Build from a scheduled request plus what the OS assigned it. `id` carries over
    /// when this replaces an edited row.
    init(
        scheduling request: NotificationRequest,
        origin: NotificationOrigin,
        unId: String,
        deliveryAt: Date,
        id: UUID = UUID(),
        now: Date = Date()
    ) {
        self.init(
            id: id,
            unId: unId,
            origin: origin,
            title: request.title,
            body: request.body,
            deliveryAt: deliveryAt,
            repeats: request.trigger.repeats,
            componentId: request.target?.componentId,
            request: request,
            statusChangedAt: now
        )
    }

    /// Build from a pending OS request this store has no record of — the log
    /// file was lost or reset while the OS queue kept going. Keeps such a
    /// notification visible and cancellable; the queue carries no trigger
    /// detail, so `request` stays nil and the row can't be edited.
    init(
        adopting pending: NotificationCenterCoordinator.PendingNotification,
        now: Date = Date()
    ) {
        self.init(
            unId: pending.id,
            origin: NotificationOrigin.fromUserInfo(pending.origin),
            title: pending.title,
            body: pending.body,
            deliveryAt: pending.deliveryAt,
            repeats: pending.repeats,
            componentId: pending.componentId,
            request: nil,
            statusChangedAt: now
        )
    }

    /// Whether the composer can reopen this row. Needs the full request and a
    /// live OS entry to replace.
    public var isEditable: Bool { status == .scheduled && request != nil }

    /// The instant this row's timestamp refers to, and sorts by.
    ///
    /// For `.fired` that is `deliveryAt`, **not** `statusChangedAt`: iOS gives
    /// no callback for an untapped delivery, so the status only changes when
    /// the app next reconciles — which may be days later. A cancel, by
    /// contrast, happens in-app, so its `statusChangedAt` is the real event.
    public var displayDate: Date? {
        switch status {
        case .scheduled: return deliveryAt
        case .fired: return deliveryAt ?? statusChangedAt
        case .cancelled: return statusChangedAt
        }
    }

    /// Finished records, most recent first. `sorted` isn't stable and one
    /// reconcile pass stamps every row it finishes with the same instant, so
    /// the id breaks ties — otherwise a batch reshuffles between redraws.
    public static func byMostRecent(_ a: NotificationRecord, _ b: NotificationRecord) -> Bool {
        let (x, y) = (a.displayDate ?? .distantPast, b.displayDate ?? .distantPast)
        return x == y ? a.id.uuidString > b.id.uuidString : x > y
    }

    /// Scheduled records, soonest first. Same tie-breaking reason.
    public static func bySoonest(_ a: NotificationRecord, _ b: NotificationRecord) -> Bool {
        let (x, y) = (a.deliveryAt ?? .distantFuture, b.deliveryAt ?? .distantFuture)
        return x == y ? a.id.uuidString < b.id.uuidString : x < y
    }
}
