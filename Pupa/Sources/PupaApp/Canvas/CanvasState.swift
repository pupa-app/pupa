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
    /// `MyAppStore.addComponent` so a freshly created component carries the
    /// right `kindString` before any render tool runs — that's what lets the
    /// kind-gated tool filter (see `MyAppType.resolvedToolNames`) advertise the
    /// per-kind tools on the next agent round. Unknown kinds fall back to
    /// `.empty`.
    ///
    /// Kept as a switch (mirrored by each `ComponentModule.makeEmptyBody`)
    /// rather than a registry lookup: `addComponent` is a core, heavily-tested
    /// path, and a nonisolated switch stays correct without depending on the
    /// `@MainActor` registry being bootstrapped first.
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
