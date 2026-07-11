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

/// Spec for a `linkedField` calc row: extract `fieldName` from a single
/// linked tracker item (`ref`) and parse it as a number. `ref == nil` means
/// "not linked yet" — the row resolves to `brokenRef`. Unlike `aggregate`
/// (which folds every matching item), this row tracks ONE item, so swapping
/// `ref` (via the link pill or `setCalcRowLink`) re-runs the whole model
/// against a different source row — the "pick a house, the mortgage updates"
/// seam. The ref lives in the spec (like `AggregateSpec.sourceComponentId`),
/// NOT in the universal `linkedItems` graph, because a calc row is not a
/// link-bearing item kind. `CalculatorResolver` does the lookup + parse.
public struct LinkedFieldSpec: Codable, Hashable, Sendable {
    public var ref: ComponentItemRef?
    public var fieldName: String

    public init(ref: ComponentItemRef? = nil, fieldName: String) {
        self.ref = ref
        self.fieldName = fieldName
    }

    enum CodingKeys: String, CodingKey { case ref, fieldName }

    /// Backward-compatible decoder — `ref` optional, `fieldName` defaults to
    /// empty so a partial blob still decodes.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.ref = try c.decodeIfPresent(ComponentItemRef.self, forKey: .ref)
        self.fieldName = try c.decodeIfPresent(String.self, forKey: .fieldName) ?? ""
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
/// - `linkedCompare` compares a SET of linked tracker items on a computed
///   metric: for each ref, swap every `linkedField` row that shares the
///   anchor row's (`linkedRowKey`) ref to that item, re-resolve, and read
///   `targetKey` → one point per item (label = item display name, y =
///   metric). This is the "compare the houses you picked on monthly payment"
///   row; the embedded chart plots it via a `calculatorList` source.
public enum CalcListSpec: Codable, Hashable, Sendable {
    case sweep(variableKey: String, from: Double, to: Double, step: Double, targetKey: String)
    case trackerColumn(sourceComponentId: String, valueField: String, labelField: String?, filter: [String: String])
    case linkedCompare(refs: [ComponentItemRef], targetKey: String, linkedRowKey: String)
    /// `linkedCompare` whose per-ref read is a swept CURVE rather than a
    /// scalar: for each `ref`, swap every `linkedField` sharing the anchor
    /// (`linkedRowKey`) ref, then sweep `variableKey` across `from…to` by
    /// `step` reading `targetKey` → one curve per ref. Self-contained (embeds
    /// the sweep params; no reference to a separate sweep row). Plotted as
    /// multi-line via a chart's `calculatorLinkedSweep` source.
    case linkedSweep(refs: [ComponentItemRef], linkedRowKey: String,
                     variableKey: String, from: Double, to: Double, step: Double, targetKey: String)

    enum CodingKeys: String, CodingKey {
        case type, variableKey, from, to, step, targetKey, sourceComponentId, valueField, labelField, filter, refs, linkedRowKey
    }
    enum Kind: String, Codable { case sweep, trackerColumn, linkedCompare, linkedSweep }

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
        case .linkedCompare:
            self = .linkedCompare(
                refs: try c.decodeIfPresent([ComponentItemRef].self, forKey: .refs) ?? [],
                targetKey: try c.decodeIfPresent(String.self, forKey: .targetKey) ?? "",
                linkedRowKey: try c.decodeIfPresent(String.self, forKey: .linkedRowKey) ?? ""
            )
        case .linkedSweep:
            self = .linkedSweep(
                refs: try c.decodeIfPresent([ComponentItemRef].self, forKey: .refs) ?? [],
                linkedRowKey: try c.decodeIfPresent(String.self, forKey: .linkedRowKey) ?? "",
                variableKey: try c.decodeIfPresent(String.self, forKey: .variableKey) ?? "",
                from: try c.decodeIfPresent(Double.self, forKey: .from) ?? 0,
                to: try c.decodeIfPresent(Double.self, forKey: .to) ?? 0,
                step: try c.decodeIfPresent(Double.self, forKey: .step) ?? 1,
                targetKey: try c.decodeIfPresent(String.self, forKey: .targetKey) ?? ""
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
        case .linkedCompare(let refs, let targetKey, let linkedRowKey):
            try c.encode(Kind.linkedCompare, forKey: .type)
            try c.encode(refs, forKey: .refs)
            try c.encode(targetKey, forKey: .targetKey)
            try c.encode(linkedRowKey, forKey: .linkedRowKey)
        case .linkedSweep(let refs, let linkedRowKey, let variableKey, let from, let to, let step, let targetKey):
            try c.encode(Kind.linkedSweep, forKey: .type)
            try c.encode(refs, forKey: .refs)
            try c.encode(linkedRowKey, forKey: .linkedRowKey)
            try c.encode(variableKey, forKey: .variableKey)
            try c.encode(from, forKey: .from)
            try c.encode(to, forKey: .to)
            try c.encode(step, forKey: .step)
            try c.encode(targetKey, forKey: .targetKey)
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
    /// Pulls one numeric field off a single linked tracker item; swap the
    /// linked item to re-run the model against a different source row.
    case linkedField(LinkedFieldSpec)
    case header

    enum CodingKeys: String, CodingKey { case type, value, control, aggregate, expression, list, linkedField }
    enum Kind: String, Codable { case variable, aggregate, formula, list, linkedField, header }

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
        case .linkedField:
            let spec = try c.decode(LinkedFieldSpec.self, forKey: .linkedField)
            self = .linkedField(spec)
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
        case .linkedField(let spec):
            try c.encode(Kind.linkedField, forKey: .type)
            try c.encode(spec, forKey: .linkedField)
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
    /// Extra charts stacked below `inlineChart` (seed-declared; the
    /// `embedComponent` tool only ever touches `inlineChart`). Lets an
    /// example pair a live comparison chart with a second view of the same
    /// model — e.g. a per-house cost-over-time line plot under the histogram.
    /// `decodeIfPresent` → older blobs decode to `[]`.
    public var extraCharts: [ChartData]

    public init(title: String, rows: [CalcRow] = [], inlineChart: ChartData? = nil, extraCharts: [ChartData] = []) {
        self.title = title
        self.rows = rows
        self.inlineChart = inlineChart
        self.extraCharts = extraCharts
    }

    enum CodingKeys: String, CodingKey { case title, rows, inlineChart, extraCharts }

    /// Backward-compatible decoder — `rows` defaults to `[]`, `inlineChart`
    /// to `nil`, and `extraCharts` to `[]` so a freshly-seeded (or Phase-1)
    /// body decodes cleanly.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.title = try c.decode(String.self, forKey: .title)
        self.rows = try c.decodeIfPresent([CalcRow].self, forKey: .rows) ?? []
        self.inlineChart = try c.decodeIfPresent(ChartData.self, forKey: .inlineChart)
        self.extraCharts = try c.decodeIfPresent([ChartData].self, forKey: .extraCharts) ?? []
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
