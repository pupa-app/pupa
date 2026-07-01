import Foundation

public enum ItemEventKind: String, Codable, Sendable {
    case added
    case patched
    case removed
    case linked
    case unlinked
    /// The MyApp was reverted to an earlier snapshot (see `SnapshotStore`).
    case restored
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

/// One entry in a MyApp's append-only change feed. Captions the History
/// timeline (see `MyAppStore.changeSummary`); the restore unit is the
/// snapshot, not the event (see `SnapshotStore`).
public struct ItemEvent: Codable, Sendable, Identifiable {
    public let id: UUID
    public let timestamp: Date
    public let myAppId: UUID
    public let componentId: String
    public let kind: ItemEventKind
    public let actor: ItemEventActor
    /// The item this event affects (nil for component-level events).
    public let itemId: UUID?
    /// Thread that triggered the mutation (nil for pre-v1 events).
    public let threadId: String?

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        myAppId: UUID,
        componentId: String,
        kind: ItemEventKind,
        actor: ItemEventActor,
        itemId: UUID? = nil,
        threadId: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.myAppId = myAppId
        self.componentId = componentId
        self.kind = kind
        self.actor = actor
        self.itemId = itemId
        self.threadId = threadId
    }

    enum CodingKeys: String, CodingKey {
        case id, timestamp, myAppId, componentId, kind, actor, itemId, threadId
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.timestamp = try c.decode(Date.self, forKey: .timestamp)
        self.myAppId = try c.decode(UUID.self, forKey: .myAppId)
        self.componentId = try c.decode(String.self, forKey: .componentId)
        self.kind = try c.decode(ItemEventKind.self, forKey: .kind)
        self.actor = try c.decode(ItemEventActor.self, forKey: .actor)
        self.itemId = try c.decodeIfPresent(UUID.self, forKey: .itemId)
        self.threadId = try c.decodeIfPresent(String.self, forKey: .threadId)
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
