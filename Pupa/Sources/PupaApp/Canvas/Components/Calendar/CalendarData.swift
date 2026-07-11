import Foundation

// Calendar component data model. Moved out of the CanvasState monolith into
// the Calendar component folder (issue #162). The `CanvasApp.calendar` enum arm
// and its Codable stay in CanvasState — the persistence discriminator.

/// One event on a calendar component. `start` is an ISO-8601 instant (the
/// agent emits strings; the view formats locally). `end` and `notes` are
/// optional. Stable `id` so the agent can refer to an event across
/// reorderings or partial updates.
///
/// `linkedItems` attaches the event to zero or more tracker items —
/// rendered as inline pills below the title. Edits to the linked tracker
/// item update the pill (the tracker item's display name is pulled
/// fresh at render time), but the event's own fields stay independent.
/// Deleting a tracker item drops it from every event's `linkedItems` so
/// no dangling references survive.
public struct CalendarEvent: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public var title: String
    public var start: String       // ISO-8601, e.g. "2026-05-14T10:00:00Z"
    public var end: String?        // ISO-8601, optional
    public var location: String?
    public var notes: String?
    public var linkedItems: [ComponentItemRef]

    public init(
        id: UUID = UUID(),
        title: String,
        start: String,
        end: String? = nil,
        location: String? = nil,
        notes: String? = nil,
        linkedItems: [ComponentItemRef] = []
    ) {
        self.id = id
        self.title = title
        self.start = start
        self.end = end
        self.location = location
        self.notes = notes
        self.linkedItems = linkedItems
    }

    enum CodingKeys: String, CodingKey {
        case id, title, start, end, location, notes, linkedItems, schemaVersion
    }

    /// Backward-compatible decoder. Pre-link persisted blobs have no
    /// `linkedItems` field; `decodeIfPresent` returns nil so we default
    /// to an empty array. The event then behaves as a normal ad-hoc
    /// event with no attached references. `schemaVersion` is read but
    /// not acted on here; migrations are applied at a higher level via
    /// `MigrationRegistry` before decoding.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.title = try c.decode(String.self, forKey: .title)
        self.start = try c.decode(String.self, forKey: .start)
        self.end = try c.decodeIfPresent(String.self, forKey: .end)
        self.location = try c.decodeIfPresent(String.self, forKey: .location)
        self.notes = try c.decodeIfPresent(String.self, forKey: .notes)
        self.linkedItems = try c.decodeIfPresent([ComponentItemRef].self, forKey: .linkedItems) ?? []
        _ = try c.decodeIfPresent(Int.self, forKey: .schemaVersion)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(title, forKey: .title)
        try c.encode(start, forKey: .start)
        try c.encodeIfPresent(end, forKey: .end)
        try c.encodeIfPresent(location, forKey: .location)
        try c.encodeIfPresent(notes, forKey: .notes)
        try c.encode(linkedItems, forKey: .linkedItems)
        try c.encode(schemaVersion, forKey: .schemaVersion)
    }
}

extension CalendarEvent: Item {
    public static var kind: String { "calendar" }
    public var displayName: String { title.nonEmpty ?? "–" }
}

/// How a calendar renders its events. Same underlying `CalendarData` —
/// only the SwiftUI view differs. Switching modes is non-destructive.
public enum CalendarViewMode: String, Codable, Hashable, Sendable {
    case list    // upcoming-events list grouped by day (default)
    case month   // 7-column grid with selected-day expansion below
}

public struct CalendarData: Codable, Hashable, Sendable {
    public var title: String
    public var events: [CalendarEvent]
    public var viewMode: CalendarViewMode

    public init(
        title: String,
        events: [CalendarEvent] = [],
        viewMode: CalendarViewMode = .list
    ) {
        self.title = title
        self.events = events
        self.viewMode = viewMode
    }

    /// Events sorted ascending by `start`. The view renders this; the
    /// underlying `events` array preserves insertion order so the agent can
    /// address events by stable id without worrying about reorderings.
    public var sortedEvents: [CalendarEvent] {
        events.sorted { $0.start < $1.start }
    }

    enum CodingKeys: String, CodingKey {
        case title, events, viewMode
    }

    /// Backward-compatible decoder. `viewMode` defaults to `.list` when
    /// absent — covers any pre-toggle persisted blob.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.title = try c.decode(String.self, forKey: .title)
        self.events = try c.decodeIfPresent([CalendarEvent].self, forKey: .events) ?? []
        self.viewMode = try c.decodeIfPresent(CalendarViewMode.self, forKey: .viewMode) ?? .list
    }
}
