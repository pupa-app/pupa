import Foundation

// Chart component data model. Moved out of CanvasState (issue #162).
// The `CanvasApp.chart` enum arm + its Codable stay in CanvasState; the
// unified cross-component ref extensions also stay there.

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
