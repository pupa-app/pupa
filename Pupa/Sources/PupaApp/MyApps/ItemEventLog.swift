import Foundation

public enum ItemEventKind: String, Codable, Sendable {
    case added
    case patched
    case removed
    case linked
    case unlinked
}

/// Who triggered an item mutation — a human gesture or an agent tool call.
public enum ItemEventActor: Codable, Sendable, Equatable {
    case user
    case agent(toolName: String)

    enum CodingKeys: String, CodingKey { case kind, toolName }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "agent":
            self = .agent(toolName: try c.decodeIfPresent(String.self, forKey: .toolName) ?? "")
        default:
            self = .user
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .user:
            try c.encode("user", forKey: .kind)
        case .agent(let toolName):
            try c.encode("agent", forKey: .kind)
            try c.encode(toolName, forKey: .toolName)
        }
    }
}

/// Typed descriptor of the inverse of a mutation. Encoded as JSON into
/// `ItemEvent.payload` so old events (empty payload) remain decodable and
/// simply yield `notReversible`.
public enum ItemEventInverse: Codable, Sendable {
    // Tracker
    case trackerAdded(itemId: UUID)
    case trackerRemoved(snapshot: TrackerItem, index: Int)
    case trackerPatched(snapshot: TrackerItem)
    // Calendar
    case calendarAdded(itemId: UUID)
    case calendarRemoved(snapshot: CalendarEvent, index: Int)
    case calendarPatched(snapshot: CalendarEvent)
    // Checklist
    case checklistAdded(itemId: UUID)
    case checklistRemoved(snapshot: ChecklistItem, index: Int)
    case checklistPatched(snapshot: ChecklistItem)
    // Links
    case linked(source: ComponentItemRef, target: ComponentItemRef)
    case unlinked(source: ComponentItemRef, target: ComponentItemRef)
    // Components
    case componentAdded(componentId: String)
    case componentRemoved(snapshot: Component, index: Int)

    private enum CodingKeys: String, CodingKey { case type, itemId, snapshot, index, source, target, componentId }
    private enum TypeTag: String, Codable {
        case trackerAdded, trackerRemoved, trackerPatched
        case calendarAdded, calendarRemoved, calendarPatched
        case checklistAdded, checklistRemoved, checklistPatched
        case linked, unlinked
        case componentAdded, componentRemoved
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let tag = try c.decode(TypeTag.self, forKey: .type)
        switch tag {
        case .trackerAdded:
            self = .trackerAdded(itemId: try c.decode(UUID.self, forKey: .itemId))
        case .trackerRemoved:
            self = .trackerRemoved(snapshot: try c.decode(TrackerItem.self, forKey: .snapshot),
                                   index: try c.decode(Int.self, forKey: .index))
        case .trackerPatched:
            self = .trackerPatched(snapshot: try c.decode(TrackerItem.self, forKey: .snapshot))
        case .calendarAdded:
            self = .calendarAdded(itemId: try c.decode(UUID.self, forKey: .itemId))
        case .calendarRemoved:
            self = .calendarRemoved(snapshot: try c.decode(CalendarEvent.self, forKey: .snapshot),
                                    index: try c.decode(Int.self, forKey: .index))
        case .calendarPatched:
            self = .calendarPatched(snapshot: try c.decode(CalendarEvent.self, forKey: .snapshot))
        case .checklistAdded:
            self = .checklistAdded(itemId: try c.decode(UUID.self, forKey: .itemId))
        case .checklistRemoved:
            self = .checklistRemoved(snapshot: try c.decode(ChecklistItem.self, forKey: .snapshot),
                                     index: try c.decode(Int.self, forKey: .index))
        case .checklistPatched:
            self = .checklistPatched(snapshot: try c.decode(ChecklistItem.self, forKey: .snapshot))
        case .linked:
            self = .linked(source: try c.decode(ComponentItemRef.self, forKey: .source),
                           target: try c.decode(ComponentItemRef.self, forKey: .target))
        case .unlinked:
            self = .unlinked(source: try c.decode(ComponentItemRef.self, forKey: .source),
                             target: try c.decode(ComponentItemRef.self, forKey: .target))
        case .componentAdded:
            self = .componentAdded(componentId: try c.decode(String.self, forKey: .componentId))
        case .componentRemoved:
            self = .componentRemoved(snapshot: try c.decode(Component.self, forKey: .snapshot),
                                     index: try c.decode(Int.self, forKey: .index))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .trackerAdded(let id):
            try c.encode(TypeTag.trackerAdded, forKey: .type)
            try c.encode(id, forKey: .itemId)
        case .trackerRemoved(let snap, let idx):
            try c.encode(TypeTag.trackerRemoved, forKey: .type)
            try c.encode(snap, forKey: .snapshot)
            try c.encode(idx, forKey: .index)
        case .trackerPatched(let snap):
            try c.encode(TypeTag.trackerPatched, forKey: .type)
            try c.encode(snap, forKey: .snapshot)
        case .calendarAdded(let id):
            try c.encode(TypeTag.calendarAdded, forKey: .type)
            try c.encode(id, forKey: .itemId)
        case .calendarRemoved(let snap, let idx):
            try c.encode(TypeTag.calendarRemoved, forKey: .type)
            try c.encode(snap, forKey: .snapshot)
            try c.encode(idx, forKey: .index)
        case .calendarPatched(let snap):
            try c.encode(TypeTag.calendarPatched, forKey: .type)
            try c.encode(snap, forKey: .snapshot)
        case .checklistAdded(let id):
            try c.encode(TypeTag.checklistAdded, forKey: .type)
            try c.encode(id, forKey: .itemId)
        case .checklistRemoved(let snap, let idx):
            try c.encode(TypeTag.checklistRemoved, forKey: .type)
            try c.encode(snap, forKey: .snapshot)
            try c.encode(idx, forKey: .index)
        case .checklistPatched(let snap):
            try c.encode(TypeTag.checklistPatched, forKey: .type)
            try c.encode(snap, forKey: .snapshot)
        case .linked(let src, let tgt):
            try c.encode(TypeTag.linked, forKey: .type)
            try c.encode(src, forKey: .source)
            try c.encode(tgt, forKey: .target)
        case .unlinked(let src, let tgt):
            try c.encode(TypeTag.unlinked, forKey: .type)
            try c.encode(src, forKey: .source)
            try c.encode(tgt, forKey: .target)
        case .componentAdded(let id):
            try c.encode(TypeTag.componentAdded, forKey: .type)
            try c.encode(id, forKey: .componentId)
        case .componentRemoved(let snap, let idx):
            try c.encode(TypeTag.componentRemoved, forKey: .type)
            try c.encode(snap, forKey: .snapshot)
            try c.encode(idx, forKey: .index)
        }
    }
}

/// One entry in an item's append-only audit trail. `payload` encodes an
/// `ItemEventInverse` (JSON) used by `MyAppStore.undo(eventId:)`. Legacy
/// events with empty payload are read-only (not reversible).
public struct ItemEvent: Codable, Sendable, Identifiable {
    public let id: UUID
    public let timestamp: Date
    public let myAppId: UUID
    public let componentId: String
    public let kind: ItemEventKind
    /// JSON-encoded `ItemEventInverse`. Empty for legacy hollow events.
    public let payload: Data
    public let actor: ItemEventActor
    /// The item this event affects (nil for component-level events).
    public let itemId: UUID?
    /// Thread that triggered the mutation (nil for pre-v1 events).
    public let threadId: String?
    /// Reserved for future per-message attribution; always nil in v1.
    public let messageId: String?
    /// True after `undo(eventId:)` has reversed this event.
    public var undone: Bool
    /// True when this event was itself produced by an undo operation —
    /// prevents undo-of-undo loops; enables future redo.
    public let isUndo: Bool

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        myAppId: UUID,
        componentId: String,
        kind: ItemEventKind,
        payload: Data = Data(),
        actor: ItemEventActor,
        itemId: UUID? = nil,
        threadId: String? = nil,
        messageId: String? = nil,
        undone: Bool = false,
        isUndo: Bool = false
    ) {
        self.id = id
        self.timestamp = timestamp
        self.myAppId = myAppId
        self.componentId = componentId
        self.kind = kind
        self.payload = payload
        self.actor = actor
        self.itemId = itemId
        self.threadId = threadId
        self.messageId = messageId
        self.undone = undone
        self.isUndo = isUndo
    }

    enum CodingKeys: String, CodingKey {
        case id, timestamp, myAppId, componentId, kind, payload, actor
        case itemId, threadId, messageId, undone, isUndo
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.timestamp = try c.decode(Date.self, forKey: .timestamp)
        self.myAppId = try c.decode(UUID.self, forKey: .myAppId)
        self.componentId = try c.decode(String.self, forKey: .componentId)
        self.kind = try c.decode(ItemEventKind.self, forKey: .kind)
        self.payload = try c.decodeIfPresent(Data.self, forKey: .payload) ?? Data()
        self.actor = try c.decode(ItemEventActor.self, forKey: .actor)
        self.itemId = try c.decodeIfPresent(UUID.self, forKey: .itemId)
        self.threadId = try c.decodeIfPresent(String.self, forKey: .threadId)
        self.messageId = try c.decodeIfPresent(String.self, forKey: .messageId)
        self.undone = try c.decodeIfPresent(Bool.self, forKey: .undone) ?? false
        self.isUndo = try c.decodeIfPresent(Bool.self, forKey: .isUndo) ?? false
    }
}

/// Returns the inverse descriptor encoded in this event's payload, or nil
/// if the payload is empty (legacy hollow event) or cannot be decoded.
extension ItemEvent {
    public func inverse() -> ItemEventInverse? {
        guard !payload.isEmpty else { return nil }
        return try? JSONDecoder().decode(ItemEventInverse.self, from: payload)
    }
}

/// Append-only event log with configurable size cap and 30-day TTL.
/// When the log grows past `cap`, the oldest entries are evicted to keep
/// memory bounded. `prune(now:ttl:)` additionally drops events older than
/// `defaultTTL` (30 days).
public struct ItemEventLog: Codable, Sendable {
    public static let defaultCap = 500
    public static let defaultTTL: TimeInterval = 30 * 24 * 60 * 60

    public let cap: Int
    private var events: [ItemEvent] = []

    public init(cap: Int = defaultCap) {
        self.cap = cap
    }

    public var count: Int { events.count }
    public var all: [ItemEvent] { events }

    public mutating func append(_ event: ItemEvent) {
        events.append(event)
        if events.count > cap {
            events.removeFirst(events.count - cap)
        }
    }

    public func events(forMyApp myAppId: UUID) -> [ItemEvent] {
        events.filter { $0.myAppId == myAppId }
    }

    /// Drop events older than `ttl` seconds, then enforce the FIFO cap.
    public mutating func prune(now: Date = Date(), ttl: TimeInterval = defaultTTL) {
        let cutoff = now.addingTimeInterval(-ttl)
        events.removeAll { $0.timestamp < cutoff }
        if events.count > cap {
            events.removeFirst(events.count - cap)
        }
    }

    /// Mark the event with `id` as undone (called after a successful undo).
    public mutating func markUndone(id: UUID) {
        guard let idx = events.firstIndex(where: { $0.id == id }) else { return }
        events[idx].undone = true
    }

    // MARK: Codable

    enum CodingKeys: String, CodingKey { case cap, events }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.cap = try c.decodeIfPresent(Int.self, forKey: .cap) ?? Self.defaultCap
        self.events = try c.decodeIfPresent([ItemEvent].self, forKey: .events) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(cap, forKey: .cap)
        try c.encode(events, forKey: .events)
    }
}
