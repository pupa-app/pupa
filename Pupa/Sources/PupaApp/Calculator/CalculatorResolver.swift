import Foundation

/// Glue that turns a `CalculatorData` spec into per-row `{value, status}`
/// results, live. It wires the two pure engines together:
///
/// - `TrackerAggregator` for `aggregate` rows (resolving `sourceComponentId`
///   against the MyApp's sibling components),
/// - `ExpressionEngine` for `formula` rows (topo-ordered so dependencies
///   compute first; cycles and broken refs are flagged, never crash).
///
/// Results are computed on demand — never persisted — so a tuned variable
/// or an edited source tracker reflects immediately on the next render.
@MainActor
public enum CalculatorResolver {

    /// Why a row's value is (un)available. Drives the calculator UI subtitle
    /// / warning. `ok` carries a value; every other status carries `nil`.
    public enum RowStatus: String, Sendable, Equatable {
        case ok
        /// A formula is part of (or downstream of) a dependency cycle.
        case cycle
        /// An aggregate's `sourceComponentId` no longer resolves to a
        /// tracker (the source was deleted / changed kind), OR a formula
        /// depends on a row that itself failed to resolve.
        case brokenRef
        /// An aggregate matched items but none of the field values parsed
        /// as numbers (sum/avg/min/max over non-numeric data).
        case nonNumeric
        /// A formula references an identifier that is not a known row key
        /// (nor a built-in function).
        case unknownIdentifier
        /// A formula divided by zero (or took modulo zero).
        case divisionByZero
    }

    public struct RowResult: Sendable, Equatable {
        public var value: Double?
        public var status: RowStatus
        /// Resolved points for a `list` row (sweep / tracker column). `nil`
        /// for scalar rows. A list row carries `value == nil` (it's a terminal
        /// array output), so scalar formulas that reference a list key resolve
        /// to `brokenRef` via the normal nil-dependency path.
        public var list: [ChartPoint]?

        public init(value: Double?, status: RowStatus, list: [ChartPoint]? = nil) {
            self.value = value
            self.status = status
            self.list = list
        }
    }

    /// Resolved calculator: every row keyed by its stable `key`, plus the
    /// row order so the view can render results alongside the spec.
    public struct Resolved: Sendable, Equatable {
        public var byKey: [String: RowResult]

        public init(byKey: [String: RowResult]) {
            self.byKey = byKey
        }

        public func result(forKey key: String) -> RowResult? { byKey[key] }
    }

    /// Resolve every row in `data`, pulling aggregates from `components`
    /// (the sibling components of the same MyApp). Tracker lookups use the
    /// passed components only — store-free so this is unit-testable with a
    /// hand-built component list.
    /// - `computeLists`: when false, `list` rows are skipped (left `nil`).
    ///   The sweep resolution re-resolves the whole calculator with one
    ///   variable overridden — it passes `false` so a sweep never re-enters
    ///   list computation (no recursion, no exponential blow-up).
    public static func resolve(
        _ data: CalculatorData,
        components: [Component],
        computeLists: Bool = true
    ) -> Resolved {
        var byKey: [String: RowResult] = [:]
        // A row key may appear more than once if the agent mis-keys; the
        // last write wins, mirroring how a dictionary env would resolve it.
        let knownKeys = Set(data.rows.map(\.key))

        // Pass 1 — variables and aggregates (no inter-row dependencies).
        for row in data.rows {
            switch row.kind {
            case .variable(let value, _):
                byKey[row.key] = RowResult(value: value, status: .ok)
            case .aggregate(let spec):
                byKey[row.key] = resolveAggregate(spec, components: components)
            case .formula, .list:
                break  // formulas in pass 2, lists in pass 3
            }
        }

        // Pass 2 — formulas, in dependency order. Skipped when there are no
        // formula rows, but we must still fall through to the list pass (a
        // calculator can have list rows and no formulas at all).
        let formulaRows = data.rows.filter { if case .formula = $0.kind { return true } else { return false } }
        guard !formulaRows.isEmpty else {
            Self.computeLists(computeLists, data: data, components: components, into: &byKey)
            return Resolved(byKey: byKey)
        }

        // Parse each formula once; a parse failure is a syntax error we
        // surface as unknownIdentifier (the closest agent-actionable status).
        var parsed: [String: ExpressionEngine.Node] = [:]
        var dependencies: [String: Set<String>] = [:]
        for row in formulaRows {
            guard case .formula(let expression) = row.kind else { continue }
            if let node = try? ExpressionEngine.parse(expression) {
                parsed[row.key] = node
                dependencies[row.key] = ExpressionEngine.identifiers(in: node).intersection(knownKeys)
            } else {
                byKey[row.key] = RowResult(value: nil, status: .unknownIdentifier)
            }
        }

        // Topo-sort only the formulas that parsed. Dependency edges to
        // non-formula keys (variables / aggregates) are already-resolved
        // leaves, so they don't need to be in the sort — but including them
        // as zero-dep nodes keeps the ordering total. We add every dep key
        // as a node so Kahn doesn't treat a leaf as missing.
        var topoInput = dependencies
        for (_, deps) in dependencies {
            for dep in deps where topoInput[dep] == nil {
                topoInput[dep] = []  // leaf (variable / aggregate / earlier formula)
            }
        }

        let order: [String]
        switch ExpressionEngine.topologicalSort(dependencies: topoInput) {
        case .ordered(let keys):
            order = keys
        case .cycle(let cyclic):
            // Mark every cyclic formula; order the rest by removing them.
            for key in cyclic where parsed[key] != nil {
                byKey[key] = RowResult(value: nil, status: .cycle)
            }
            // Re-sort with the cyclic keys dropped so the acyclic remainder
            // still evaluates.
            var acyclic = topoInput
            for key in cyclic { acyclic.removeValue(forKey: key) }
            for key in acyclic.keys {
                acyclic[key] = acyclic[key]?.subtracting(cyclic)
            }
            if case .ordered(let keys) = ExpressionEngine.topologicalSort(dependencies: acyclic) {
                order = keys
            } else {
                order = []
            }
        }

        // Evaluate formulas in order. The env holds every already-resolved
        // numeric value (variables, aggregates, earlier formulas).
        for key in order {
            guard let node = parsed[key] else { continue }   // skip leaves
            guard byKey[key]?.status != .cycle else { continue }
            // A dependency that resolved to nil (broken aggregate, cyclic,
            // non-numeric, …) poisons this formula — surface brokenRef
            // before attempting eval so the engine doesn't see a phantom
            // unknownIdentifier.
            let deps = dependencies[key] ?? []
            if let broken = deps.first(where: { byKey[$0]?.value == nil }) {
                _ = broken
                byKey[key] = RowResult(value: nil, status: .brokenRef)
                continue
            }
            var env: [String: Double] = [:]
            for (k, result) in byKey {
                if let v = result.value { env[k] = v }
            }
            do {
                let value = try ExpressionEngine.evaluate(node, variables: env)
                if value.isFinite {
                    byKey[key] = RowResult(value: value, status: .ok)
                } else {
                    // Non-finite (e.g. log of a negative, overflow) — treat
                    // like a numeric failure rather than surfacing NaN.
                    byKey[key] = RowResult(value: nil, status: .nonNumeric)
                }
            } catch ExpressionEngine.EvalError.divisionByZero {
                byKey[key] = RowResult(value: nil, status: .divisionByZero)
            } catch ExpressionEngine.EvalError.unknownIdentifier {
                byKey[key] = RowResult(value: nil, status: .unknownIdentifier)
            } catch {
                byKey[key] = RowResult(value: nil, status: .unknownIdentifier)
            }
        }

        // Pass 3 — list rows (sweep / tracker column).
        Self.computeLists(computeLists, data: data, components: components, into: &byKey)

        return Resolved(byKey: byKey)
    }

    // MARK: - List resolution

    /// Resolve every `list` row (terminal arrays — they run last and feed off
    /// the already-resolved scalars). No-op when `enabled` is false (i.e.
    /// inside a sweep's re-resolve, so a sweep never re-enters list work).
    private static func computeLists(
        _ enabled: Bool,
        data: CalculatorData,
        components: [Component],
        into byKey: inout [String: RowResult]
    ) {
        guard enabled else { return }
        for row in data.rows {
            guard case .list(let spec) = row.kind else { continue }
            byKey[row.key] = resolveList(spec, data: data, components: components)
        }
    }

    /// Resolve a `list` row to its point array. Terminal: `value` stays nil.
    private static func resolveList(
        _ spec: CalcListSpec,
        data: CalculatorData,
        components: [Component]
    ) -> RowResult {
        switch spec {
        case .sweep(let variableKey, let from, let to, let step, let targetKey):
            guard step > 0, from <= to else {
                return RowResult(value: nil, status: .nonNumeric)
            }
            guard let varIdx = data.rows.firstIndex(where: { $0.key == variableKey }),
                  case .variable(_, let control) = data.rows[varIdx].kind,
                  data.rows.contains(where: { $0.key == targetKey }) else {
                return RowResult(value: nil, status: .brokenRef)
            }
            var points: [ChartPoint] = []
            // Cap iterations so a tiny step over a wide range can't hang.
            let maxSteps = 1000
            var v = from
            var i = 0
            while v <= to + step * 1e-9 && i < maxSteps {
                var swept = data
                swept.rows[varIdx].kind = .variable(value: v, control: control)
                let r = resolve(swept, components: components, computeLists: false)
                if let y = r.result(forKey: targetKey)?.value, y.isFinite {
                    points.append(ChartPoint(label: numberLabel(v), x: v, y: y))
                }
                v += step
                i += 1
            }
            return RowResult(value: nil, status: .ok, list: points)

        case .trackerColumn(let sourceComponentId, let valueField, let labelField, let filter):
            guard let component = components.first(where: { $0.id == sourceComponentId }),
                  case .tracker(let tracker) = component.body else {
                return RowResult(value: nil, status: .brokenRef)
            }
            let matched = tracker.items.filter { TrackerAggregator.matches($0, filter: filter) }
            var points: [ChartPoint] = []
            for (idx, item) in matched.enumerated() {
                guard let y = TrackerAggregator.parseNumber(item.values[valueField]) else { continue }
                let label = labelField.flatMap { item.values[$0]?.nonEmpty } ?? "\(idx + 1)"
                points.append(ChartPoint(label: label, x: TrackerAggregator.parseXAxis(label), y: y))
            }
            return RowResult(value: nil, status: .ok, list: points)
        }
    }

    /// Compact label for a swept numeric value (trailing zeros trimmed).
    private static func numberLabel(_ v: Double) -> String {
        if v == v.rounded() && abs(v) < 1e15 { return String(format: "%.0f", v) }
        var s = String(format: "%.4f", v)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }

    // MARK: - Aggregate resolution

    private static func resolveAggregate(_ spec: AggregateSpec, components: [Component]) -> RowResult {
        guard let component = components.first(where: { $0.id == spec.sourceComponentId }),
              case .tracker(let tracker) = component.body else {
            return RowResult(value: nil, status: .brokenRef)
        }
        let outcome = TrackerAggregator.reduce(spec, over: tracker)
        // count always resolves; the numeric reduces need at least one
        // parseable value, otherwise the field isn't numeric (or is empty).
        if spec.reduce != .count, outcome.matchedItems > 0, outcome.numericValues == 0 {
            return RowResult(value: nil, status: .nonNumeric)
        }
        return RowResult(value: outcome.value, status: .ok)
    }
}
