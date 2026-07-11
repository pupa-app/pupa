import Foundation

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

/// A cross-component reference of any kind, used by the unified ref model
/// (`CanvasApp.componentReferences` / `remapReferences`). `itemId == nil`
/// marks a *component-level* pointer (a calculator aggregate source, a chart
/// series source); a non-nil `itemId` is an *item-level* link
/// (`ComponentItemRef`). One vocabulary so export validation and the delete
/// cascade enumerate refs the same way.
public struct ComponentRef: Hashable, Sendable {
    public let componentId: String
    public let itemId: UUID?
    public init(componentId: String, itemId: UUID? = nil) {
        self.componentId = componentId
        self.itemId = itemId
    }
    public init(_ ref: ComponentItemRef) {
        self.init(componentId: ref.componentId, itemId: ref.itemId)
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

// Slack agents are generic filesystem subagents — `pupa/agents/<slug>/AGENTS.md`
// discovered by `AgentStore`. A Slack component's workspace roster is *all*
// subagents in the MyApp; the component holds no agent list of its own.
// Channels reference agents by their subagent slug.

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
    public var channels: [SlackChannel]
    public var messagesByChannel: [String: [SlackMessage]]
    public var activeChannelId: String?

    public init(
        channels: [SlackChannel] = [],
        messagesByChannel: [String: [SlackMessage]] = [:],
        activeChannelId: String? = nil
    ) {
        self.channels = channels
        self.messagesByChannel = messagesByChannel
        self.activeChannelId = activeChannelId
    }

    enum CodingKeys: String, CodingKey {
        case channels, messagesByChannel, activeChannelId
    }

    /// Backward-compatible decoder — every field defaults so a
    /// pre-Slack on-disk blob or a freshly-seeded empty body decodes
    /// cleanly. A legacy `agents` key (pre-subagent) is simply ignored;
    /// agents now live at `pupa/agents/<slug>/AGENTS.md`.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.channels = try c.decodeIfPresent([SlackChannel].self, forKey: .channels) ?? []
        self.messagesByChannel = try c.decodeIfPresent([String: [SlackMessage]].self, forKey: .messagesByChannel) ?? [:]
        self.activeChannelId = try c.decodeIfPresent(String.self, forKey: .activeChannelId)
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
    /// Plots a calculator `.list` row of kind `linkedSweep`: it resolves to
    /// MANY series (one curve per linked ref), so this single declared spec
    /// fans out to N `ChartSeries` at render time — the multi-line analogue of
    /// `calculatorList` (which is one series). `key` is the linkedSweep row key.
    case calculatorLinkedSweep(componentId: String, key: String)
    case inline(points: [ChartPoint])

    enum CodingKeys: String, CodingKey {
        case type, componentId, groupBy, valueField, reduce, filter, xIsNumericOrDate, keys, key, points
    }
    enum Kind: String, Codable { case tracker, calculatorRows, calculatorList, calculatorLinkedSweep, inline }

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
        case .calculatorLinkedSweep:
            self = .calculatorLinkedSweep(
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
        case .calculatorLinkedSweep(let componentId, let key):
            try c.encode(Kind.calculatorLinkedSweep, forKey: .type)
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

// MARK: - Unified cross-component reference model

extension ChartSeriesSource {
    /// The component this series sources its data from, or `nil` for `inline`
    /// (literal points). Drives chart-series dangling-ref pruning on export.
    public var referencedComponentId: String? {
        switch self {
        case .tracker(let cid, _, _, _, _, _): return cid
        case .calculatorRows(let cid, _): return cid
        case .calculatorList(let cid, _): return cid
        case .calculatorLinkedSweep(let cid, _): return cid
        case .inline: return nil
        }
    }
}

extension CanvasApp {
    /// Every cross-component reference this body holds, across ALL mechanisms:
    /// `linkedItems` on items; calculator `aggregate` / `linkedField` / `list`
    /// source refs; chart series source componentIds — **including charts
    /// embedded in a calculator** (`inlineChart` / `extraCharts`). The single
    /// source of truth for ref enumeration, shared by export validation and the
    /// delete cascade. The switch is exhaustive (no `default`) so a new
    /// `CanvasApp` arm fails the build until its refs are declared here.
    public func componentReferences() -> [ComponentRef] {
        var out: [ComponentRef] = []
        switch self {
        case .tracker(let t):
            for it in t.items { out.append(contentsOf: it.linkedItems.map { ComponentRef($0) }) }
        case .calendar(let cal):
            for e in cal.events { out.append(contentsOf: e.linkedItems.map { ComponentRef($0) }) }
        case .checklist(let cl):
            for it in cl.items { out.append(contentsOf: it.linkedItems.map { ComponentRef($0) }) }
        case .calculator(let c):
            for row in c.rows { out.append(contentsOf: Self.calcRowRefs(row.kind)) }
            if let ch = c.inlineChart { out.append(contentsOf: Self.chartRefs(ch)) }
            for ch in c.extraCharts { out.append(contentsOf: Self.chartRefs(ch)) }
        case .chart(let ch):
            out.append(contentsOf: Self.chartRefs(ch))
        case .slack, .empty:
            break
        }
        return out
    }

    /// Drop every reference whose target isn't kept. Item-level refs
    /// (`linkedItems`, `linkedField`, `linkedCompare`/`linkedSweep`) are
    /// removed when the component is dropped *or* the item is gone; chart
    /// series are dropped when their source component is gone — recursing into
    /// a calculator's embedded charts. Scalar component sources
    /// (`aggregate` / `trackerColumn`) degrade to broken-but-tolerated rather
    /// than cascading row deletion (the resolver already renders them as
    /// `brokenRef`). Used by both `cascadeRemoveRefs` (item deletion) and the
    /// exporter (component subset).
    public mutating func remapReferences(
        keepComponent: (String) -> Bool,
        keepItem: (ComponentItemRef) -> Bool
    ) {
        // Universal item-ref graph (tracker / calendar / checklist).
        mapLinkedItems { refs in
            refs.removeAll { !keepComponent($0.componentId) || !keepItem($0) }
        }
        switch self {
        case .calculator(var c):
            for rIdx in c.rows.indices {
                c.rows[rIdx].kind = Self.remapCalcRowKind(
                    c.rows[rIdx].kind, keepComponent: keepComponent, keepItem: keepItem)
            }
            if var chart = c.inlineChart {
                Self.dropDanglingSeries(&chart, keepComponent: keepComponent)
                c.inlineChart = chart
            }
            for cIdx in c.extraCharts.indices { Self.dropDanglingSeries(&c.extraCharts[cIdx], keepComponent: keepComponent) }
            self = .calculator(c)
        case .chart(var ch):
            Self.dropDanglingSeries(&ch, keepComponent: keepComponent)
            self = .chart(ch)
        case .tracker, .calendar, .checklist, .slack, .empty:
            break
        }
    }

    private static func calcRowRefs(_ kind: CalcRowKind) -> [ComponentRef] {
        switch kind {
        case .aggregate(let spec):
            return [ComponentRef(componentId: spec.sourceComponentId)]
        case .linkedField(let spec):
            return spec.ref.map { [ComponentRef($0)] } ?? []
        case .list(.trackerColumn(let cid, _, _, _)):
            return [ComponentRef(componentId: cid)]
        case .list(.linkedCompare(let refs, _, _)):
            return refs.map(ComponentRef.init)
        case .list(.linkedSweep(let refs, _, _, _, _, _, _)):
            return refs.map(ComponentRef.init)
        case .list(.sweep), .variable, .formula, .header:
            return []
        }
    }

    private static func chartRefs(_ chart: ChartData) -> [ComponentRef] {
        chart.series.compactMap { spec in
            spec.source.referencedComponentId.map { ComponentRef(componentId: $0) }
        }
    }

    private static func remapCalcRowKind(
        _ kind: CalcRowKind,
        keepComponent: (String) -> Bool,
        keepItem: (ComponentItemRef) -> Bool
    ) -> CalcRowKind {
        func kept(_ r: ComponentItemRef) -> Bool { keepComponent(r.componentId) && keepItem(r) }
        switch kind {
        case .linkedField(var spec):
            if let r = spec.ref, !kept(r) { spec.ref = nil }
            return .linkedField(spec)
        case .list(.linkedCompare(let refs, let targetKey, let linkedRowKey)):
            return .list(.linkedCompare(refs: refs.filter(kept), targetKey: targetKey, linkedRowKey: linkedRowKey))
        case .list(.linkedSweep(let refs, let linkedRowKey, let variableKey, let from, let to, let step, let targetKey)):
            return .list(.linkedSweep(refs: refs.filter(kept), linkedRowKey: linkedRowKey,
                                      variableKey: variableKey, from: from, to: to, step: step, targetKey: targetKey))
        case .aggregate, .formula, .variable, .header, .list(.sweep), .list(.trackerColumn):
            return kind
        }
    }

    private static func dropDanglingSeries(_ chart: inout ChartData, keepComponent: (String) -> Bool) {
        chart.series.removeAll { spec in
            if let cid = spec.source.referencedComponentId { return !keepComponent(cid) }
            return false
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

    /// User lock. When true, all non-read (mutating) operations on this
    /// component are refused — via the `mutate` backstop in `MyAppStore` and
    /// a "locked" result surfaced to the agent (see `ClientTool.readOnly`).
    /// Defaults false; older persisted/imported components decode as unlocked.
    public var isLocked: Bool

    public init(
        id: String,
        name: String,
        iconSystemName: String,
        body: CanvasApp,
        summary: String? = nil,
        isLocked: Bool = false
    ) {
        self.id = id
        self.name = name
        self.iconSystemName = iconSystemName
        self.body = body
        self.summary = summary
        self.isLocked = isLocked
    }

    // Custom decode so old / imported components without `isLocked` still
    // load (defaults to unlocked); `encode` stays synthesized.
    enum CodingKeys: String, CodingKey {
        case id, name, iconSystemName, body, summary, isLocked
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.name = try c.decode(String.self, forKey: .name)
        self.iconSystemName = try c.decode(String.self, forKey: .iconSystemName)
        self.body = try c.decode(CanvasApp.self, forKey: .body)
        self.summary = try c.decodeIfPresent(String.self, forKey: .summary)
        self.isLocked = try c.decodeIfPresent(Bool.self, forKey: .isLocked) ?? false
    }

    /// Convenience: kind string of the component's body, matching the
    /// `CanvasApp` discriminator written by the encoder.
    public var kindString: String { body.kindString }
}
