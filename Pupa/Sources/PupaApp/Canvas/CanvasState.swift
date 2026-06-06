import Foundation

public enum FieldType: String, Codable, Sendable {
    case text
    case number
    case select
    /// A URL or emoji that the card grid renders as a hero. Stored as a
    /// `[String: String]` value like every other field — the view layer decides
    /// how to display it.
    case image
    /// A URL the user wants quick access to (Amazon product page, recipe
    /// source, GitHub repo, …). Rendered on each card as a clickable pill
    /// that opens the URL in the default browser. Stored as a plain string;
    /// invalid URLs fall back to a non-clickable text pill.
    case link
}

public struct FieldDef: Codable, Hashable, Sendable, Identifiable {
    public var name: String
    public var label: String?
    public var type: FieldType
    public var options: [String]?
    /// When `true`, the field disappears from form / card / filter / kanban
    /// group-by UI but its values are kept on every item so unhide is fully
    /// reversible. Soft-hide is the only "remove" verb on a tracker field —
    /// hard removal would orphan item data, which is incompatible with the
    /// "items are hard to delete" invariant. `nil` decodes as visible.
    public var hidden: Bool?
    public var id: String { name }

    public init(
        name: String,
        label: String? = nil,
        type: FieldType,
        options: [String]? = nil,
        hidden: Bool? = nil
    ) {
        self.name = name
        self.label = label
        self.type = type
        self.options = options
        self.hidden = hidden
    }
}

/// One row in a tracker. `id` is stable across every schema mutation so the
/// agent (and SwiftUI) can refer to a row without depending on its array
/// position. `values` is sparse — a missing key for any field is treated as
/// empty by the view layer, which is what lets `addTrackerField` /
/// `hideTrackerField` etc. mutate `TrackerData.fields` without ever touching
/// items.
///
/// `linkedItems` (added in project `0.0.41`) holds inline references to
/// items in other components (tracker rows, calendar events, or other
/// checklist rows). Each ref renders as a chain-link pill on the row's
/// card; deleting the target sweeps the ref via
/// `MyAppStore.cascadeRemoveRefs`.
public struct TrackerItem: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public var values: [String: String]
    public var linkedItems: [ComponentItemRef]

    public init(
        id: UUID = UUID(),
        values: [String: String],
        linkedItems: [ComponentItemRef] = []
    ) {
        self.id = id
        self.values = values
        self.linkedItems = linkedItems
    }

    enum CodingKeys: String, CodingKey {
        case id, values, linkedItems, schemaVersion
    }

    /// Backward-compatible decoder. `linkedItems` defaults to empty when
    /// absent so on-disk blobs from before `0.0.41` decode cleanly.
    /// `schemaVersion` is read but not acted on here; migrations are applied
    /// at a higher level via `MigrationRegistry` before decoding.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.values = try c.decode([String: String].self, forKey: .values)
        self.linkedItems = try c.decodeIfPresent([ComponentItemRef].self, forKey: .linkedItems) ?? []
        _ = try c.decodeIfPresent(Int.self, forKey: .schemaVersion)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(values, forKey: .values)
        try c.encode(linkedItems, forKey: .linkedItems)
        try c.encode(schemaVersion, forKey: .schemaVersion)
    }
}

extension TrackerItem: Item {
    public static var kind: String { "tracker" }

    /// Best-effort display name for pills and pickers. Prefers well-known
    /// keys ("title", "name", "label") then falls back to the first
    /// non-empty value in sorted-key order. Callers with full field
    /// metadata should prefer `MyAppStore.displayNameForTrackerItem`.
    public var displayName: String {
        let preferred = ["title", "name", "label", "text"]
        for key in preferred {
            if let v = values[key]?.nonEmpty { return v }
        }
        return values.sorted(by: { $0.key < $1.key })
                     .first(where: { $0.value.nonEmpty != nil })?
                     .value ?? "–"
    }
}

/// How a tracker renders its items. Same underlying `TrackerData` —
/// only the SwiftUI view differs. Switching modes is non-destructive.
public enum TrackerViewMode: String, Codable, Hashable, Sendable {
    case grid    // adaptive card grid (default)
    case kanban  // Jira-style swimlanes grouped by a select field's options
}

public struct TrackerData: Codable, Hashable, Sendable {
    public var title: String
    public var fields: [FieldDef]
    /// Stable-id rows. Each `TrackerItem.values` is sparse `[String: String]`
    /// keyed by `FieldDef.name`; missing keys are treated as empty at the
    /// view layer, which is what lets the field-schema mutators stay
    /// non-destructive to existing items.
    public var items: [TrackerItem]
    public var filter: [String: String]
    public var viewMode: TrackerViewMode
    /// Name of the `select` field whose options are used as kanban columns when
    /// `viewMode == .kanban`. Nil means "auto-pick first eligible select field"
    /// at switch time. Retained across grid/kanban toggles so the user's
    /// column choice survives.
    public var columnField: String?

    public init(
        title: String,
        fields: [FieldDef],
        items: [TrackerItem] = [],
        filter: [String: String] = [:],
        viewMode: TrackerViewMode = .grid,
        columnField: String? = nil
    ) {
        self.title = title
        self.fields = fields
        self.items = items
        self.filter = filter
        self.viewMode = viewMode
        self.columnField = columnField
    }

    /// Non-hidden fields only. Every UI read site (form, card, filter,
    /// kanban group-by, "usable select" guards) should walk this — hidden
    /// fields keep their item values but disappear from the UI.
    public var visibleFields: [FieldDef] {
        fields.filter { !($0.hidden ?? false) }
    }

    enum CodingKeys: String, CodingKey {
        case title, fields, items, filter, viewMode, columnField
    }

    /// Custom decoder. Handles two backward-compat concerns:
    /// - Pre-`viewMode` blobs default `viewMode` / `columnField` to `.grid` / `nil`.
    /// - Pre-stable-id blobs stored `items` as `[[String: String]]`; we probe
    ///   for that shape first and stamp fresh UUIDs once at decode time
    ///   (never lazily — lazy assignment would regenerate IDs on every relaunch
    ///   and silently re-key UI state). The next `persist()` writes the new
    ///   `[TrackerItem]` shape and the legacy branch never runs again for
    ///   that blob.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.title = try c.decode(String.self, forKey: .title)
        self.fields = try c.decode([FieldDef].self, forKey: .fields)
        self.items = (try? c.decodeIfPresent([TrackerItem].self, forKey: .items)) ?? []
        self.filter = try c.decodeIfPresent([String: String].self, forKey: .filter) ?? [:]
        self.viewMode = try c.decodeIfPresent(TrackerViewMode.self, forKey: .viewMode) ?? .grid
        self.columnField = try c.decodeIfPresent(String.self, forKey: .columnField)
    }
}

/// Kind-agnostic pointer to an item in another component (or in the
/// same component for a self-link). Stored on every link-bearing item
/// kind — tracker rows, calendar events, and checklist rows — and
/// rendered as an inline chain-link pill with the target's live display
/// name (resolved by `MyAppStore.displayNameForRefTarget`). The
/// underlying on-disk JSON shape (`{componentId, itemId}`) is identical
/// to the pre-`0.0.41` `TrackerItemRef`, so persisted blobs decode
/// untouched.
public struct ComponentItemRef: Codable, Hashable, Sendable {
    public var componentId: String
    public var itemId: UUID

    public init(componentId: String, itemId: UUID) {
        self.componentId = componentId
        self.itemId = itemId
    }
}

/// Pre-`0.0.41` name for `ComponentItemRef`. Kept as a typealias for
/// one release so call sites in app code that haven't been updated yet
/// keep compiling. Remove in the next major refactor.
public typealias TrackerItemRef = ComponentItemRef

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

/// One row in a checklist. `id` is stable across reorderings so the agent
/// (and SwiftUI) can refer to a row without depending on its array
/// position. `done` is the checkbox state; `text` the displayed line.
///
/// `linkedItems` attaches the row to zero or more items in other
/// components (today: tracker items and calendar events) — rendered as
/// inline chain-link pills under the row's text, with the linked item's
/// live display name pulled at render time. Deleting the target item
/// drops its ref from every checklist row's `linkedItems` automatically.
public struct ChecklistItem: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public var text: String
    public var done: Bool
    public var linkedItems: [ComponentItemRef]

    public init(
        id: UUID = UUID(),
        text: String,
        done: Bool = false,
        linkedItems: [ComponentItemRef] = []
    ) {
        self.id = id
        self.text = text
        self.done = done
        self.linkedItems = linkedItems
    }

    enum CodingKeys: String, CodingKey {
        case id, text, done, linkedItems, schemaVersion
    }

    /// Backward-compatible decoder. `linkedItems` defaults to empty when
    /// absent so any pre-link persisted blob decodes cleanly.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.text = try c.decode(String.self, forKey: .text)
        self.done = try c.decodeIfPresent(Bool.self, forKey: .done) ?? false
        self.linkedItems = try c.decodeIfPresent([ComponentItemRef].self, forKey: .linkedItems) ?? []
        _ = try c.decodeIfPresent(Int.self, forKey: .schemaVersion)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(text, forKey: .text)
        try c.encode(done, forKey: .done)
        try c.encode(linkedItems, forKey: .linkedItems)
        try c.encode(schemaVersion, forKey: .schemaVersion)
    }
}

extension ChecklistItem: Item {
    public static var kind: String { "checklist" }
    public var displayName: String { text.nonEmpty ?? "–" }
}

public struct ChecklistData: Codable, Hashable, Sendable {
    public var title: String
    public var items: [ChecklistItem]

    public init(title: String, items: [ChecklistItem] = []) {
        self.title = title
        self.items = items
    }

    enum CodingKeys: String, CodingKey {
        case title, items
    }

    /// Backward-compatible decoder — `items` defaults to `[]` when
    /// absent so a freshly-seeded empty body decodes cleanly.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.title = try c.decode(String.self, forKey: .title)
        self.items = try c.decodeIfPresent([ChecklistItem].self, forKey: .items) ?? []
    }
}

// MARK: - Slack component

/// One agent in a Slack component. `id` is stable and used as the
/// memory-namespace key (memory tools rebase paths under
/// `memories/agents/{id}/` when invoked on this agent's behalf).
/// `role` is short-form ("marketing", "dev"); `systemPromptAddition`
/// is the persona text appended to the base system prompt for any
/// invocation of this agent.
public struct SlackAgent: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public var name: String
    public var role: String
    public var systemPromptAddition: String
    /// Per-agent LLM provider override (one of `KnownLLMProvider.*`). When
    /// `nil` the agent inherits its parent MyApp's choice (or the backend
    /// default when neither is set). Paired with `llmModel` — both must be
    /// non-nil for the override to apply.
    public var llmProvider: String?
    /// Per-agent logical LLM model id (e.g. `"claude-sonnet-4-6"`). See `llmProvider`.
    public var llmModel: String?

    public init(
        id: String = UUID().uuidString,
        name: String,
        role: String,
        systemPromptAddition: String,
        llmProvider: String? = nil,
        llmModel: String? = nil
    ) {
        self.id = id
        self.name = name
        self.role = role
        self.systemPromptAddition = systemPromptAddition
        self.llmProvider = llmProvider
        self.llmModel = llmModel
    }

    enum CodingKeys: String, CodingKey {
        case id, name, role, systemPromptAddition, llmProvider, llmModel
    }

    /// Backward-compatible decoder — `llmProvider` / `llmModel` were added
    /// later, so any persisted SlackAgent blob lacking them decodes cleanly
    /// with `nil` for both.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.name = try c.decode(String.self, forKey: .name)
        self.role = try c.decode(String.self, forKey: .role)
        self.systemPromptAddition = try c.decode(String.self, forKey: .systemPromptAddition)
        self.llmProvider = try c.decodeIfPresent(String.self, forKey: .llmProvider)
        self.llmModel = try c.decodeIfPresent(String.self, forKey: .llmModel)
    }
}

/// How a Slack channel is presented in the sidebar and which members
/// can post. `channel` is an open public room; `groupDM` is a fixed
/// roster of 3+ members; `dm` is a fixed pair (one user + one agent,
/// or two agents).
public enum SlackChannelType: String, Codable, Hashable, Sendable {
    case channel
    case groupDM
    case dm
}

/// One room in a Slack component. `memberAgentIds` is the assigned
/// roster (agents that can post + are auto-eligible to be `@`-mentioned);
/// `subscriberAgentIds` is informational only in v1 (used by the
/// sidebar to show "subscribed channels" per agent).
public struct SlackChannel: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public var name: String
    public var type: SlackChannelType
    public var memberAgentIds: [String]
    public var subscriberAgentIds: [String]

    public init(
        id: String = UUID().uuidString,
        name: String,
        type: SlackChannelType,
        memberAgentIds: [String] = [],
        subscriberAgentIds: [String] = []
    ) {
        self.id = id
        self.name = name
        self.type = type
        self.memberAgentIds = memberAgentIds
        self.subscriberAgentIds = subscriberAgentIds
    }
}

/// Who authored a `SlackMessage`. `user` is the human typing in the
/// composer; `agent` is any `SlackAgent` posting via `slackPostMessage`.
public enum SlackAuthorKind: String, Codable, Hashable, Sendable {
    case user
    case agent
}

/// One message in a Slack channel. `authorId` is the user identifier
/// ("user" for the human; an agent's stable id for agents).
/// `mentionedAgentIds` is the parsed `@`-mention list — for user
/// messages it drives which agents the composer invokes; for agent
/// messages it's informational (rendered as pills in the view).
public struct SlackMessage: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let channelId: String
    public var authorKind: SlackAuthorKind
    public var authorId: String
    public var text: String
    public var timestamp: Date
    public var mentionedAgentIds: [String]

    public init(
        id: String = UUID().uuidString,
        channelId: String,
        authorKind: SlackAuthorKind,
        authorId: String,
        text: String,
        timestamp: Date = Date(),
        mentionedAgentIds: [String] = []
    ) {
        self.id = id
        self.channelId = channelId
        self.authorKind = authorKind
        self.authorId = authorId
        self.text = text
        self.timestamp = timestamp
        self.mentionedAgentIds = mentionedAgentIds
    }
}

/// Body of a Slack canvas component — the full state of the
/// multi-agent room: every agent, every channel, the message history
/// per channel, and which channel the user is currently viewing.
/// Persists as part of the enclosing `CanvasApp` via `MyAppStore`'s
/// UserDefaults blob.
public struct SlackData: Codable, Hashable, Sendable {
    public var agents: [SlackAgent]
    public var channels: [SlackChannel]
    public var messagesByChannel: [String: [SlackMessage]]
    public var activeChannelId: String?

    public init(
        agents: [SlackAgent] = [],
        channels: [SlackChannel] = [],
        messagesByChannel: [String: [SlackMessage]] = [:],
        activeChannelId: String? = nil
    ) {
        self.agents = agents
        self.channels = channels
        self.messagesByChannel = messagesByChannel
        self.activeChannelId = activeChannelId
    }

    enum CodingKeys: String, CodingKey {
        case agents, channels, messagesByChannel, activeChannelId
    }

    /// Backward-compatible decoder — every field defaults so a
    /// pre-Slack on-disk blob or a freshly-seeded empty body decodes
    /// cleanly.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.agents = try c.decodeIfPresent([SlackAgent].self, forKey: .agents) ?? []
        self.channels = try c.decodeIfPresent([SlackChannel].self, forKey: .channels) ?? []
        self.messagesByChannel = try c.decodeIfPresent([String: [SlackMessage]].self, forKey: .messagesByChannel) ?? [:]
        self.activeChannelId = try c.decodeIfPresent(String.self, forKey: .activeChannelId)
    }
}

// MARK: - Calculator component

/// How a tracker aggregate folds the numeric values it pulls from a field
/// into a single scalar. `count` is the only reduce that doesn't need the
/// values to parse as numbers — it counts the items that pass the filter.
public enum CalcReduce: String, Codable, Hashable, Sendable, CaseIterable {
    case sum
    case avg
    case min
    case max
    case count
}

/// Spec for an `aggregate` calc row: pull `fieldName` from every item in
/// the tracker component `sourceComponentId`, keep only the items matching
/// `filter` (case-insensitive AND equality across every key/value pair —
/// this is the "spend on African restaurants" isolation), then `reduce`
/// the surviving numeric values down to one scalar. `filter` empty = no
/// filter (aggregate over every item). Pure data; the actual reduce lives
/// in `TrackerAggregator` and the source lookup in `CalculatorResolver`.
public struct AggregateSpec: Codable, Hashable, Sendable {
    public var sourceComponentId: String
    public var fieldName: String
    public var reduce: CalcReduce
    public var filter: [String: String]

    public init(
        sourceComponentId: String,
        fieldName: String,
        reduce: CalcReduce,
        filter: [String: String] = [:]
    ) {
        self.sourceComponentId = sourceComponentId
        self.fieldName = fieldName
        self.reduce = reduce
        self.filter = filter
    }

    enum CodingKeys: String, CodingKey {
        case sourceComponentId, fieldName, reduce, filter
    }

    /// Backward-compatible decoder — `filter` defaults to empty and
    /// `reduce` to `.sum` so a partial blob still decodes.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.sourceComponentId = try c.decodeIfPresent(String.self, forKey: .sourceComponentId) ?? ""
        self.fieldName = try c.decodeIfPresent(String.self, forKey: .fieldName) ?? ""
        self.reduce = try c.decodeIfPresent(CalcReduce.self, forKey: .reduce) ?? .sum
        self.filter = try c.decodeIfPresent([String: String].self, forKey: .filter) ?? [:]
    }
}

/// How a `variable` calc row surfaces its tuning affordance in the
/// calculator UI. `plain` is a free numeric text field; `stepper` adds
/// −/+ buttons stepping by `step`; `slider` is a bounded drag between
/// `min` and `max` snapping to `step`. Persisted with an explicit tagged
/// codec so adding a control kind later stays backward-compatible.
public enum CalcControl: Codable, Hashable, Sendable {
    case plain
    case stepper(step: Double)
    case slider(min: Double, max: Double, step: Double)

    enum CodingKeys: String, CodingKey { case type, step, min, max }
    enum Kind: String, Codable { case plain, stepper, slider }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // A missing/unknown discriminator decodes as `.plain` so a partial
        // or future blob degrades to the simplest control rather than
        // failing the whole calculator decode.
        let kind = (try? c.decodeIfPresent(Kind.self, forKey: .type)) ?? .plain
        switch kind {
        case .plain:
            self = .plain
        case .stepper:
            let step = try c.decodeIfPresent(Double.self, forKey: .step) ?? 1
            self = .stepper(step: step)
        case .slider:
            let lo = try c.decodeIfPresent(Double.self, forKey: .min) ?? 0
            let hi = try c.decodeIfPresent(Double.self, forKey: .max) ?? 100
            let step = try c.decodeIfPresent(Double.self, forKey: .step) ?? 1
            self = .slider(min: lo, max: hi, step: step)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .plain:
            try c.encode(Kind.plain, forKey: .type)
        case .stepper(let step):
            try c.encode(Kind.stepper, forKey: .type)
            try c.encode(step, forKey: .step)
        case .slider(let lo, let hi, let step):
            try c.encode(Kind.slider, forKey: .type)
            try c.encode(lo, forKey: .min)
            try c.encode(hi, forKey: .max)
            try c.encode(step, forKey: .step)
        }
    }
}

/// How a `list` calc row produces its array of points. The array is a
/// terminal output — scalar formulas can't reference a list key. Two arms,
/// tagged-codec:
/// - `sweep` is the headline: vary `variableKey` across `from...to` by
///   `step`, holding every OTHER variable fixed, and read `targetKey`'s
///   resolved value at each step. x = swept value, y = target — the
///   sensitivity / projection curve (mortgage payment vs interest rate).
///   `variableKey` must be a `variable` row; `targetKey` any scalar row.
/// - `trackerColumn` pulls a raw per-item column off a tracker as an ordered
///   array: `valueField` → y, optional `labelField` → label (else the row
///   index), `filter` isolates a subset.
public enum CalcListSpec: Codable, Hashable, Sendable {
    case sweep(variableKey: String, from: Double, to: Double, step: Double, targetKey: String)
    case trackerColumn(sourceComponentId: String, valueField: String, labelField: String?, filter: [String: String])

    enum CodingKeys: String, CodingKey {
        case type, variableKey, from, to, step, targetKey, sourceComponentId, valueField, labelField, filter
    }
    enum Kind: String, Codable { case sweep, trackerColumn }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = (try? c.decodeIfPresent(Kind.self, forKey: .type)) ?? .sweep
        switch kind {
        case .sweep:
            self = .sweep(
                variableKey: try c.decodeIfPresent(String.self, forKey: .variableKey) ?? "",
                from: try c.decodeIfPresent(Double.self, forKey: .from) ?? 0,
                to: try c.decodeIfPresent(Double.self, forKey: .to) ?? 0,
                step: try c.decodeIfPresent(Double.self, forKey: .step) ?? 1,
                targetKey: try c.decodeIfPresent(String.self, forKey: .targetKey) ?? ""
            )
        case .trackerColumn:
            self = .trackerColumn(
                sourceComponentId: try c.decodeIfPresent(String.self, forKey: .sourceComponentId) ?? "",
                valueField: try c.decodeIfPresent(String.self, forKey: .valueField) ?? "",
                labelField: try c.decodeIfPresent(String.self, forKey: .labelField),
                filter: try c.decodeIfPresent([String: String].self, forKey: .filter) ?? [:]
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .sweep(let variableKey, let from, let to, let step, let targetKey):
            try c.encode(Kind.sweep, forKey: .type)
            try c.encode(variableKey, forKey: .variableKey)
            try c.encode(from, forKey: .from)
            try c.encode(to, forKey: .to)
            try c.encode(step, forKey: .step)
            try c.encode(targetKey, forKey: .targetKey)
        case .trackerColumn(let sourceComponentId, let valueField, let labelField, let filter):
            try c.encode(Kind.trackerColumn, forKey: .type)
            try c.encode(sourceComponentId, forKey: .sourceComponentId)
            try c.encode(valueField, forKey: .valueField)
            try c.encodeIfPresent(labelField, forKey: .labelField)
            try c.encode(filter, forKey: .filter)
        }
    }
}

/// The shapes a calculator row can take. `variable` is a tunable input
/// (value + control); `aggregate` pulls a scalar off a tracker via
/// `AggregateSpec`; `formula` is an arithmetic expression over other rows'
/// `key`s (see `ExpressionEngine`); `list` produces an ARRAY of points
/// (`CalcListSpec` — a sweep or a tracker column) that a chart plots as one
/// series. Explicit tagged codec so the on-disk shape is stable and
/// self-describing.
///
/// `header` is a non-computing decoration: its `name` becomes the section
/// label; the calculator view collapses every row below it until the next
/// header. Formulas never reference a header key; the resolver skips it.
public enum CalcRowKind: Codable, Hashable, Sendable {
    case variable(value: Double, control: CalcControl)
    case aggregate(AggregateSpec)
    case formula(expression: String)
    case list(CalcListSpec)
    case header

    enum CodingKeys: String, CodingKey { case type, value, control, aggregate, expression, list }
    enum Kind: String, Codable { case variable, aggregate, formula, list, header }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(Kind.self, forKey: .type)
        switch kind {
        case .variable:
            let value = try c.decodeIfPresent(Double.self, forKey: .value) ?? 0
            let control = try c.decodeIfPresent(CalcControl.self, forKey: .control) ?? .plain
            self = .variable(value: value, control: control)
        case .aggregate:
            let spec = try c.decode(AggregateSpec.self, forKey: .aggregate)
            self = .aggregate(spec)
        case .formula:
            let expression = try c.decodeIfPresent(String.self, forKey: .expression) ?? ""
            self = .formula(expression: expression)
        case .list:
            let spec = try c.decode(CalcListSpec.self, forKey: .list)
            self = .list(spec)
        case .header:
            self = .header
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .variable(let value, let control):
            try c.encode(Kind.variable, forKey: .type)
            try c.encode(value, forKey: .value)
            try c.encode(control, forKey: .control)
        case .aggregate(let spec):
            try c.encode(Kind.aggregate, forKey: .type)
            try c.encode(spec, forKey: .aggregate)
        case .formula(let expression):
            try c.encode(Kind.formula, forKey: .type)
            try c.encode(expression, forKey: .expression)
        case .list(let spec):
            try c.encode(Kind.list, forKey: .type)
            try c.encode(spec, forKey: .list)
        case .header:
            try c.encode(Kind.header, forKey: .type)
        }
    }
}

/// One row in a calculator. `key` is a stable slug that formulas reference
/// (`african / total`), so renaming the human-facing `name` never breaks a
/// downstream formula. `unit` (e.g. "$", "%") and `format` (a printf-style
/// hint like "%.2f") are optional presentation. `kind` carries the row's
/// behaviour. `id` is stable across reorderings for SwiftUI / addressing.
public struct CalcRow: Codable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public var key: String
    public var name: String
    public var unit: String?
    public var format: String?
    public var kind: CalcRowKind

    public init(
        id: UUID = UUID(),
        key: String,
        name: String,
        unit: String? = nil,
        format: String? = nil,
        kind: CalcRowKind
    ) {
        self.id = id
        self.key = key
        self.name = name
        self.unit = unit
        self.format = format
        self.kind = kind
    }

    enum CodingKeys: String, CodingKey { case id, key, name, unit, format, kind }

    /// Backward-compatible decoder — `id` regenerates if absent, `name`
    /// falls back to `key`, and `unit` / `format` stay optional.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.key = try c.decode(String.self, forKey: .key)
        self.name = try c.decodeIfPresent(String.self, forKey: .name) ?? self.key
        self.unit = try c.decodeIfPresent(String.self, forKey: .unit)
        self.format = try c.decodeIfPresent(String.self, forKey: .format)
        self.kind = try c.decode(CalcRowKind.self, forKey: .kind)
    }
}

/// Body of a calculator canvas component — a titled, ordered list of
/// `CalcRow`s. Results are NEVER persisted: `CalculatorResolver` recomputes
/// every row's `{value, status}` live on each render so a tuned variable or
/// an edited source tracker is reflected immediately. Phase 2 (#22) adds an
/// `inlineChart: ChartData?` field here; the `decodeIfPresent` decoder means
/// that field can land without a migration of Phase-1 blobs.
public struct CalculatorData: Codable, Hashable, Sendable {
    public var title: String
    public var rows: [CalcRow]
    /// Optional chart embedded below the rows (Phase 2, #22). When set, the
    /// calculator view renders a `ChartContainerView` after the row list —
    /// the same store-free `ChartView` a standalone `chart` component uses,
    /// so a chart can live inside the calculator or on its own. `nil` =
    /// no embedded chart; `decodeIfPresent` means Phase-1 blobs decode
    /// untouched.
    public var inlineChart: ChartData?

    public init(title: String, rows: [CalcRow] = [], inlineChart: ChartData? = nil) {
        self.title = title
        self.rows = rows
        self.inlineChart = inlineChart
    }

    enum CodingKeys: String, CodingKey { case title, rows, inlineChart }

    /// Backward-compatible decoder — `rows` defaults to `[]` and
    /// `inlineChart` to `nil` so a freshly-seeded (or Phase-1) body decodes
    /// cleanly.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.title = try c.decode(String.self, forKey: .title)
        self.rows = try c.decodeIfPresent([CalcRow].self, forKey: .rows) ?? []
        self.inlineChart = try c.decodeIfPresent(ChartData.self, forKey: .inlineChart)
    }
}

// MARK: - Chart component

/// How a chart plots its series. `pie` is a single-series sector breakdown;
/// `bar` / `line` plot over an x axis (categorical, or numeric/date when the
/// source sets `xIsNumericOrDate`).
public enum ChartKind: String, Codable, Hashable, Sendable, CaseIterable {
    case pie
    case bar
    case line
}

/// One plotted point. `label` is the categorical key (sector name, x-axis
/// tick); `x` is the numeric/date position for `bar` / `line` over a
/// continuous axis (nil = categorical, plotted by `label`); `y` is the
/// value. Store-decoupled (no store, no MainActor) so Phase 3 (#23) can
/// snapshot a point list straight into a chat attachment.
public struct ChartPoint: Codable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public var label: String
    public var x: Double?
    public var y: Double

    public init(id: UUID = UUID(), label: String, x: Double? = nil, y: Double) {
        self.id = id
        self.label = label
        self.x = x
        self.y = y
    }

    enum CodingKeys: String, CodingKey { case id, label, x, y }

    /// Backward-compatible decoder — `id` regenerates if absent, `x` stays
    /// optional, `label` / `y` default so a partial blob still decodes.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.label = try c.decodeIfPresent(String.self, forKey: .label) ?? ""
        self.x = try c.decodeIfPresent(Double.self, forKey: .x)
        self.y = try c.decodeIfPresent(Double.self, forKey: .y) ?? 0
    }
}

/// A named run of points. A pie / single-metric chart is one series; the
/// model keeps the array shape so multi-series line/bar charts are a pure
/// data extension later. Store-decoupled like `ChartPoint`.
public struct ChartSeries: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public var name: String
    public var points: [ChartPoint]

    public init(id: String = UUID().uuidString, name: String, points: [ChartPoint]) {
        self.id = id
        self.name = name
        self.points = points
    }
}

/// Where a single series' data comes from. Each arm resolves (via
/// `ChartResolver`) to exactly one `ChartSeries`. Tagged-codec like
/// `CalcRowKind`:
/// - `tracker` reduces a numeric `valueField` grouped by `groupBy` on a
///   tracker (reusing `TrackerAggregator.series`); `xIsNumericOrDate` makes
///   the group key the continuous, ascending x axis for line/bar.
/// - `calculatorRows` plots a fixed list of calculator row `keys` (each row's
///   resolved scalar becomes one point).
/// - `calculatorList` plots a single calculator `.list` row (a sweep /
///   tracker column) — the row's resolved point array becomes the series.
/// - `inline` carries literal points (the seam for Phase 3 chat embedding).
public enum ChartSeriesSource: Codable, Hashable, Sendable {
    case tracker(componentId: String, groupBy: String, valueField: String, reduce: CalcReduce, filter: [String: String], xIsNumericOrDate: Bool)
    case calculatorRows(componentId: String, keys: [String])
    case calculatorList(componentId: String, key: String)
    case inline(points: [ChartPoint])

    enum CodingKeys: String, CodingKey {
        case type, componentId, groupBy, valueField, reduce, filter, xIsNumericOrDate, keys, key, points
    }
    enum Kind: String, Codable { case tracker, calculatorRows, calculatorList, inline }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = (try? c.decodeIfPresent(Kind.self, forKey: .type)) ?? .inline
        switch kind {
        case .tracker:
            self = .tracker(
                componentId: try c.decodeIfPresent(String.self, forKey: .componentId) ?? "",
                groupBy: try c.decodeIfPresent(String.self, forKey: .groupBy) ?? "",
                valueField: try c.decodeIfPresent(String.self, forKey: .valueField) ?? "",
                reduce: try c.decodeIfPresent(CalcReduce.self, forKey: .reduce) ?? .sum,
                filter: try c.decodeIfPresent([String: String].self, forKey: .filter) ?? [:],
                xIsNumericOrDate: try c.decodeIfPresent(Bool.self, forKey: .xIsNumericOrDate) ?? false
            )
        case .calculatorRows:
            self = .calculatorRows(
                componentId: try c.decodeIfPresent(String.self, forKey: .componentId) ?? "",
                keys: try c.decodeIfPresent([String].self, forKey: .keys) ?? []
            )
        case .calculatorList:
            self = .calculatorList(
                componentId: try c.decodeIfPresent(String.self, forKey: .componentId) ?? "",
                key: try c.decodeIfPresent(String.self, forKey: .key) ?? ""
            )
        case .inline:
            self = .inline(points: try c.decodeIfPresent([ChartPoint].self, forKey: .points) ?? [])
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .tracker(let componentId, let groupBy, let valueField, let reduce, let filter, let xIsNumericOrDate):
            try c.encode(Kind.tracker, forKey: .type)
            try c.encode(componentId, forKey: .componentId)
            try c.encode(groupBy, forKey: .groupBy)
            try c.encode(valueField, forKey: .valueField)
            try c.encode(reduce, forKey: .reduce)
            try c.encode(filter, forKey: .filter)
            try c.encode(xIsNumericOrDate, forKey: .xIsNumericOrDate)
        case .calculatorRows(let componentId, let keys):
            try c.encode(Kind.calculatorRows, forKey: .type)
            try c.encode(componentId, forKey: .componentId)
            try c.encode(keys, forKey: .keys)
        case .calculatorList(let componentId, let key):
            try c.encode(Kind.calculatorList, forKey: .type)
            try c.encode(componentId, forKey: .componentId)
            try c.encode(key, forKey: .key)
        case .inline(let points):
            try c.encode(Kind.inline, forKey: .type)
            try c.encode(points, forKey: .points)
        }
    }

    /// Points carried literally by an `inline` source (0 for the resolved
    /// arms) — used by the canvas summary's `itemCount`.
    public var inlinePointCount: Int {
        if case .inline(let points) = self { return points.count }
        return 0
    }
}

/// One declared series in a chart — a `source` plus presentation. `name` is
/// the legend label (defaults from the source at resolve time when nil);
/// `colorHex` overrides the auto palette (`#RRGGBB`), nil = let Swift Charts
/// pick a distinct colour per series. `id` is stable for SwiftUI / addressing.
public struct ChartSeriesSpec: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public var name: String?
    public var colorHex: String?
    public var source: ChartSeriesSource

    public init(id: String = UUID().uuidString, name: String? = nil, colorHex: String? = nil, source: ChartSeriesSource) {
        self.id = id
        self.name = name
        self.colorHex = colorHex
        self.source = source
    }

    enum CodingKeys: String, CodingKey { case id, name, colorHex, source }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        self.name = try c.decodeIfPresent(String.self, forKey: .name)
        self.colorHex = try c.decodeIfPresent(String.self, forKey: .colorHex)
        self.source = try c.decode(ChartSeriesSource.self, forKey: .source)
    }
}

/// Body of a chart canvas component. Non-linkable: a `title`, a `kind`
/// (pie/bar/line), and an ordered list of `series` (each a `ChartSeriesSpec`).
/// Multiple series overlay in one plot — line/bar render one colour per
/// series with a legend; `pie` uses only the FIRST series (a pie is
/// inherently single-series). Results are NEVER persisted — `ChartResolver`
/// resolves every series live each render.
public struct ChartData: Codable, Hashable, Sendable {
    public var title: String
    public var kind: ChartKind
    public var series: [ChartSeriesSpec]

    public init(title: String, kind: ChartKind = .line, series: [ChartSeriesSpec] = []) {
        self.title = title
        self.kind = kind
        self.series = series
    }

    /// Convenience: a single-series chart.
    public init(title: String, kind: ChartKind, source: ChartSeriesSource) {
        self.init(title: title, kind: kind, series: [ChartSeriesSpec(source: source)])
    }

    enum CodingKeys: String, CodingKey { case title, kind, series }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.title = try c.decode(String.self, forKey: .title)
        self.kind = try c.decodeIfPresent(ChartKind.self, forKey: .kind) ?? .line
        self.series = try c.decodeIfPresent([ChartSeriesSpec].self, forKey: .series) ?? []
    }

    /// Literal inline points across every series — the canvas summary's
    /// `itemCount` for a chart (resolved data lives elsewhere).
    public var inlinePointCount: Int {
        series.reduce(0) { $0 + $1.source.inlinePointCount }
    }
}

public enum CanvasApp: Codable, Hashable, Sendable {
    case empty
    case tracker(TrackerData)
    case calendar(CalendarData)
    case checklist(ChecklistData)
    case slack(SlackData)
    case calculator(CalculatorData)
    case chart(ChartData)

    enum CodingKeys: String, CodingKey { case kind, data }
    enum Kind: String, Codable { case empty, tracker, calendar, checklist, slack, calculator, chart }

    /// Stable string used by tool dispatch and component-kind routing.
    /// Matches the `Kind.rawValue` written by the encoder.
    public var kindString: String {
        switch self {
        case .empty: return "empty"
        case .tracker: return "tracker"
        case .calendar: return "calendar"
        case .checklist: return "checklist"
        case .slack: return "slack"
        case .calculator: return "calculator"
        case .chart: return "chart"
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(Kind.self, forKey: .kind)
        switch kind {
        case .empty: self = .empty
        case .tracker:
            let data = try c.decode(TrackerData.self, forKey: .data)
            self = .tracker(data)
        case .calendar:
            let data = try c.decode(CalendarData.self, forKey: .data)
            self = .calendar(data)
        case .checklist:
            let data = try c.decode(ChecklistData.self, forKey: .data)
            self = .checklist(data)
        case .slack:
            let data = try c.decode(SlackData.self, forKey: .data)
            self = .slack(data)
        case .calculator:
            let data = try c.decode(CalculatorData.self, forKey: .data)
            self = .calculator(data)
        case .chart:
            let data = try c.decode(ChartData.self, forKey: .data)
            self = .chart(data)
        }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .empty:
            try c.encode(Kind.empty, forKey: .kind)
        case .tracker(let d):
            try c.encode(Kind.tracker, forKey: .kind)
            try c.encode(d, forKey: .data)
        case .calendar(let d):
            try c.encode(Kind.calendar, forKey: .kind)
            try c.encode(d, forKey: .data)
        case .checklist(let d):
            try c.encode(Kind.checklist, forKey: .kind)
            try c.encode(d, forKey: .data)
        case .slack(let d):
            try c.encode(Kind.slack, forKey: .kind)
            try c.encode(d, forKey: .data)
        case .calculator(let d):
            try c.encode(Kind.calculator, forKey: .kind)
            try c.encode(d, forKey: .data)
        case .chart(let d):
            try c.encode(Kind.chart, forKey: .kind)
            try c.encode(d, forKey: .data)
        }
    }

    /// Empty typed body for a component of the given kind. Used by
    /// `MyAppStore.addComponent` and `MyApp.init` so a freshly created
    /// component carries the right `kindString` before any render tool
    /// runs — that's what lets the kind-gated tool filter (see
    /// `MyAppType.resolvedToolNames`) advertise the per-kind tools on the
    /// next agent round. Unknown kinds fall back to `.empty`.
    public static func emptyBody(forKind kind: String) -> CanvasApp {
        switch kind {
        case "tracker": return .tracker(TrackerData(title: "", fields: []))
        case "calendar": return .calendar(CalendarData(title: "", events: []))
        case "checklist": return .checklist(ChecklistData(title: "", items: []))
        case "slack": return .slack(SlackData())
        case "calculator": return .calculator(CalculatorData(title: "", rows: []))
        case "chart": return .chart(ChartData(title: ""))
        default: return .empty
        }
    }

    /// Apply `transform` to every `linkedItems` array inside this component
    /// body. Used by `cascadeRemoveRefs` to sweep ref deletions without a
    /// per-kind switch at the call site.
    mutating func mapLinkedItems(_ transform: (inout [ComponentItemRef]) -> Void) {
        switch self {
        case .tracker(var t):
            for i in t.items.indices { transform(&t.items[i].linkedItems) }
            self = .tracker(t)
        case .calendar(var cal):
            for i in cal.events.indices { transform(&cal.events[i].linkedItems) }
            self = .calendar(cal)
        case .checklist(var cl):
            for i in cl.items.indices { transform(&cl.items[i].linkedItems) }
            self = .checklist(cl)
        case .slack, .empty, .calculator, .chart:
            // Calculator rows and charts hold no `linkedItems` — they
            // reference tracker fields / rows via specs, not via the
            // universal item-ref graph — so there is nothing to sweep here.
            break
        }
    }
}

/// One slot in a MyApp's component list. A MyApp can contain multiple
/// components of different kinds (a tracker plus a calendar, say); the
/// sidebar expands the MyApp into a child row per component. `id` is a
/// stable, agent-addressable string like `"tracker-1"` or `"calendar-1"`.
public struct Component: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public var name: String
    public var iconSystemName: String
    public var body: CanvasApp
    /// LLM-populated content-summary slot — the agent's running summary
    /// of what this component is for AND what's currently in it
    /// ("Q1 OKR tracker; rows are individual key results, status field
    /// encodes RAG; 12 rows, 4 done"). The app NEVER auto-fills this —
    /// it stays `nil` until the agent writes to it via the kind's render
    /// tool (`renderTracker(summary: "…")`, `renderCalendar(summary: "…")`,
    /// `renderChecklist(summary: "…")`). Surfaced in the canvas summary
    /// context entry on every turn so the agent's own notes round-trip
    /// across turns without depending on chat history. Passing only
    /// `summary` to a render tool is a valid "update note" call that
    /// leaves the body untouched.
    public var summary: String?

    public init(
        id: String,
        name: String,
        iconSystemName: String,
        body: CanvasApp,
        summary: String? = nil
    ) {
        self.id = id
        self.name = name
        self.iconSystemName = iconSystemName
        self.body = body
        self.summary = summary
    }

    /// Convenience: kind string of the component's body, matching the
    /// `CanvasApp` discriminator written by the encoder.
    public var kindString: String { body.kindString }
}
