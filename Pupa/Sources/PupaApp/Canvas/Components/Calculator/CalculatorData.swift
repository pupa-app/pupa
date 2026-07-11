import Foundation

// Calculator component data model. Moved out of CanvasState (issue #162).
// The `CanvasApp.calculator` enum arm + its Codable stay in CanvasState.

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
