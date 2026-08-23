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
///
/// **Shape of a resolve.** The work splits into three reusable stages so a
/// `list` row (which re-reads the model tens of times) never repeats work
/// that cannot have changed:
///
/// 1. `Program` — parse every formula and topo-sort them. Depends only on the
///    row *specs*, so it is built once per resolve and shared by every sweep
///    step and every compared ref.
/// 2. `Base` — the pass-1 leaves (variables, aggregates, linked fields).
///    Depends on the components and the linked refs, but **not** on any
///    swept variable, so a sweep computes it once and reuses it per step.
/// 3. `evaluateFormulas` — the only stage a sweep step actually re-runs.
///
/// Sweeps and linked comparisons substitute values through override
/// parameters rather than copying and mutating the row array.
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
        /// Resolved multi-series for a `linkedSweep` list row (one curve per
        /// linked ref). `nil` for every other row kind. Like `list`, a
        /// `linkedSweep` row carries `value == nil`.
        public var series: [ChartSeries]?

        public init(value: Double?, status: RowStatus, list: [ChartPoint]? = nil, series: [ChartSeries]? = nil) {
            self.value = value
            self.status = status
            self.list = list
            self.series = series
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

    #if DEBUG
    /// Test-only tally of `ExpressionEngine.parse` calls. Backs the perf
    /// invariant that a sweep re-runs only the formula pass — parsing each
    /// expression once per resolve, not once per step.
    static var parseCountForTesting = 0
    /// Test-only tally of `Base` builds — the pass-1 leaves, which re-scan
    /// every aggregate's source tracker. Should track the number of compared
    /// refs, never the number of sweep steps.
    static var baseBuildCountForTesting = 0
    #endif

    /// Resolve every row in `data`, pulling aggregates from `components`
    /// (the sibling components of the same MyApp). Tracker lookups use the
    /// passed components only — store-free so this is unit-testable with a
    /// hand-built component list.
    /// - `computeLists`: when false, `list` rows are skipped (left `nil`) —
    ///   a "scalars only" opt-out for callers that want the numeric rows
    ///   without paying for the sweeps. List rows re-read the model through
    ///   `evaluateFormulas` directly rather than re-entering `resolve`, so
    ///   this is a cost knob, not a recursion guard.
    public static func resolve(
        _ data: CalculatorData,
        components: [Component],
        computeLists: Bool = true
    ) -> Resolved {
        let program = Program(rows: data.rows)
        let base = Base(rows: data.rows, components: components, refOverride: nil)
        var byKey = evaluateFormulas(program, base: base, variableOverride: nil)

        guard computeLists else { return Resolved(byKey: byKey) }

        // Pass 3 — list rows (terminal arrays; they run last and feed off the
        // already-resolved scalars).
        for row in data.rows {
            guard case .list(let spec) = row.kind else { continue }
            byKey[row.key] = resolveList(
                spec, program: program, base: base, rows: data.rows, components: components
            )
        }
        return Resolved(byKey: byKey)
    }

    // MARK: - Program (parse + topo-sort, once per resolve)

    /// The parsed, dependency-ordered formula set for a row list. Built from
    /// the row *specs* alone, so it stays valid across every sweep step and
    /// every compared ref — that's what keeps a 30-step sweep from re-parsing
    /// the same expressions 30 times.
    private struct Program {
        /// Every row key in the calculator — formula dependencies are
        /// intersected with this so unknown identifiers surface as such.
        let knownKeys: Set<String>
        /// Successfully parsed formula ASTs, by row key.
        let parsed: [String: ExpressionEngine.Node]
        /// Each parsed formula's dependencies (already intersected with
        /// `knownKeys`).
        let dependencies: [String: Set<String>]
        /// Safe evaluation order (includes non-formula leaf keys, which are
        /// skipped at eval time).
        let order: [String]
        /// Formula keys caught in a dependency cycle.
        let cyclic: Set<String>
        /// Formula keys whose expression did not parse at all.
        let parseFailed: [String]

        @MainActor
        init(rows: [CalcRow]) {
            let knownKeys = Set(rows.map(\.key))
            self.knownKeys = knownKeys

            var parsed: [String: ExpressionEngine.Node] = [:]
            var dependencies: [String: Set<String>] = [:]
            var parseFailed: [String] = []

            // Parse each formula once; a parse failure is a syntax error we
            // surface as unknownIdentifier (the closest agent-actionable
            // status).
            for row in rows {
                guard case .formula(let expression) = row.kind else { continue }
                #if DEBUG
                CalculatorResolver.parseCountForTesting += 1
                #endif
                if let node = try? ExpressionEngine.parse(expression) {
                    parsed[row.key] = node
                    dependencies[row.key] = ExpressionEngine.identifiers(in: node).intersection(knownKeys)
                } else {
                    parseFailed.append(row.key)
                }
            }
            self.parsed = parsed
            self.dependencies = dependencies
            self.parseFailed = parseFailed

            guard !parsed.isEmpty else {
                self.order = []
                self.cyclic = []
                return
            }

            // Topo-sort only the formulas that parsed. Dependency edges to
            // non-formula keys (variables / aggregates) are already-resolved
            // leaves, so they don't need to be in the sort — but including
            // them as zero-dep nodes keeps the ordering total. We add every
            // dep key as a node so Kahn doesn't treat a leaf as missing.
            var topoInput = dependencies
            for (_, deps) in dependencies {
                for dep in deps where topoInput[dep] == nil {
                    topoInput[dep] = []  // leaf (variable / aggregate / earlier formula)
                }
            }

            switch ExpressionEngine.topologicalSort(dependencies: topoInput) {
            case .ordered(let keys):
                self.order = keys
                self.cyclic = []
            case .cycle(let cyclicKeys):
                // Mark every cyclic formula; order the rest by removing them.
                self.cyclic = Set(cyclicKeys)
                var acyclic = topoInput
                for key in cyclicKeys { acyclic.removeValue(forKey: key) }
                for key in acyclic.keys {
                    acyclic[key] = acyclic[key]?.subtracting(cyclicKeys)
                }
                if case .ordered(let keys) = ExpressionEngine.topologicalSort(dependencies: acyclic) {
                    self.order = keys
                } else {
                    self.order = []
                }
            }
        }
    }

    // MARK: - Base (pass-1 leaves)

    /// The pass-1 leaves: `variable`, `aggregate` and `linkedField` rows,
    /// which carry no inter-row dependencies. Independent of any swept
    /// variable, so a sweep resolves this once and reuses it for every step —
    /// aggregates in particular re-scan their whole source tracker, and that
    /// scan is invariant across the sweep.
    private struct Base {
        var byKey: [String: RowResult]
        /// Numeric environment seeded from `byKey` (only rows that resolved
        /// to a value). Grown in place as formulas evaluate, rather than
        /// rebuilt per formula.
        var env: [String: Double]

        @MainActor
        init(rows: [CalcRow], components: [Component], refOverride: (from: ComponentItemRef?, to: ComponentItemRef)?) {
            #if DEBUG
            CalculatorResolver.baseBuildCountForTesting += 1
            #endif
            var byKey: [String: RowResult] = [:]
            var env: [String: Double] = [:]

            // A row key may appear more than once if the agent mis-keys; the
            // last write wins, mirroring how a dictionary env would resolve
            // it — so a later nil-valued duplicate must also clear `env`.
            func record(_ key: String, _ result: RowResult) {
                byKey[key] = result
                if let value = result.value {
                    env[key] = value
                } else {
                    env.removeValue(forKey: key)
                }
            }

            for row in rows {
                switch row.kind {
                case .variable(let value, _):
                    record(row.key, RowResult(value: value, status: .ok))
                case .aggregate(let spec):
                    record(row.key, resolveAggregate(spec, components: components))
                case .linkedField(var spec):
                    // The anchor swap: every linkedField row bound to the
                    // compared-from ref follows the compared item, so a
                    // multi-field source (price / rate / term) moves together.
                    if let override = refOverride, spec.ref == override.from {
                        spec.ref = override.to
                    }
                    record(row.key, resolveLinkedField(spec, components: components))
                case .formula, .list, .header:
                    break  // formulas in pass 2, lists in pass 3, headers skipped
                }
            }
            self.byKey = byKey
            self.env = env
        }
    }

    // MARK: - Pass 2 (the only stage a sweep step re-runs)

    /// Evaluate every formula in dependency order on top of `base`.
    /// `variableOverride` replaces one `variable` row's value (the sweep
    /// axis) without touching the row array or redoing pass 1.
    private static func evaluateFormulas(
        _ program: Program,
        base: Base,
        variableOverride: (key: String, value: Double)?
    ) -> [String: RowResult] {
        var byKey = base.byKey
        var env = base.env

        if let override = variableOverride {
            byKey[override.key] = RowResult(value: override.value, status: .ok)
            env[override.key] = override.value
        }

        for key in program.parseFailed {
            byKey[key] = RowResult(value: nil, status: .unknownIdentifier)
            env.removeValue(forKey: key)
        }
        for key in program.cyclic where program.parsed[key] != nil {
            byKey[key] = RowResult(value: nil, status: .cycle)
            env.removeValue(forKey: key)
        }

        for key in program.order {
            guard let node = program.parsed[key] else { continue }   // skip leaves
            guard !program.cyclic.contains(key) else { continue }
            // A dependency that resolved to nil (broken aggregate, cyclic,
            // non-numeric, …) poisons this formula — surface brokenRef
            // before attempting eval so the engine doesn't see a phantom
            // unknownIdentifier.
            let deps = program.dependencies[key] ?? []
            if deps.contains(where: { byKey[$0]?.value == nil }) {
                byKey[key] = RowResult(value: nil, status: .brokenRef)
                env.removeValue(forKey: key)
                continue
            }
            let result: RowResult
            do {
                let value = try ExpressionEngine.evaluate(node, variables: env)
                if value.isFinite {
                    result = RowResult(value: value, status: .ok)
                } else {
                    // Non-finite (e.g. log of a negative, overflow) — treat
                    // like a numeric failure rather than surfacing NaN.
                    result = RowResult(value: nil, status: .nonNumeric)
                }
            } catch ExpressionEngine.EvalError.divisionByZero {
                result = RowResult(value: nil, status: .divisionByZero)
            } catch ExpressionEngine.EvalError.unknownIdentifier {
                result = RowResult(value: nil, status: .unknownIdentifier)
            } catch {
                result = RowResult(value: nil, status: .unknownIdentifier)
            }
            byKey[key] = result
            if let value = result.value {
                env[key] = value
            } else {
                env.removeValue(forKey: key)
            }
        }
        return byKey
    }

    // MARK: - List resolution

    /// Resolve a `list` row to its point array. Terminal: `value` stays nil.
    ///
    /// Every variant re-reads the scalar model many times; none of them
    /// rebuild the `Program` (the specs didn't change), and the sweeps don't
    /// rebuild the `Base` either (a swept variable can't change a leaf).
    private static func resolveList(
        _ spec: CalcListSpec,
        program: Program,
        base: Base,
        rows: [CalcRow],
        components: [Component]
    ) -> RowResult {
        switch spec {
        case .sweep(let variableKey, let from, let to, let step, let targetKey):
            // An unusable range is a spec error (nonNumeric); keys that don't
            // name a variable row / a known row are a brokenRef.
            guard step > 0, from <= to else {
                return RowResult(value: nil, status: .nonNumeric)
            }
            guard isSweepable(rows: rows, program: program, variableKey: variableKey, targetKey: targetKey) else {
                return RowResult(value: nil, status: .brokenRef)
            }
            let points = sweepPoints(
                program: program, base: base,
                variableKey: variableKey, from: from, to: to, step: step, targetKey: targetKey
            )
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

        case .linkedCompare(let refs, let targetKey, let linkedRowKey):
            // The anchor row identifies WHICH ref a house is currently bound to;
            // every linkedField row sharing that ref follows the compared house
            // (a house has many fields — price, rate, term — and they must all
            // move together for the target metric to be coherent).
            guard let baseRef = anchorRef(rows: rows, linkedRowKey: linkedRowKey),
                  program.knownKeys.contains(targetKey) else {
                return RowResult(value: nil, status: .brokenRef)
            }
            var points: [ChartPoint] = []
            for ref in refs {
                // A fresh Base per ref — the swap changes the pass-1 leaves.
                let swapped = Base(rows: rows, components: components, refOverride: (baseRef, ref))
                let byKey = evaluateFormulas(program, base: swapped, variableOverride: nil)
                guard let y = byKey[targetKey]?.value, y.isFinite else { continue }
                points.append(ChartPoint(label: linkedItemLabel(ref, components: components), y: y))
            }
            return RowResult(value: nil, status: .ok, list: points)

        case .linkedSweep(let refs, let linkedRowKey, let variableKey, let from, let to, let step, let targetKey):
            // linkedCompare, but each ref reads a swept CURVE instead of a
            // scalar → one ChartSeries per ref.
            // Same two-tier split as `.sweep`, so an identical spec reports an
            // identical status whether it is standalone or nested here.
            guard step > 0, from <= to else {
                return RowResult(value: nil, status: .nonNumeric)
            }
            guard let baseRef = anchorRef(rows: rows, linkedRowKey: linkedRowKey),
                  isSweepable(rows: rows, program: program, variableKey: variableKey, targetKey: targetKey) else {
                return RowResult(value: nil, status: .brokenRef)
            }
            var chartSeries: [ChartSeries] = []
            for ref in refs {
                let swapped = Base(rows: rows, components: components, refOverride: (baseRef, ref))
                let points = sweepPoints(
                    program: program, base: swapped,
                    variableKey: variableKey, from: from, to: to, step: step, targetKey: targetKey
                )
                guard !points.isEmpty else { continue }
                chartSeries.append(ChartSeries(name: linkedItemLabel(ref, components: components), points: points))
            }
            return RowResult(value: nil, status: .ok, series: chartSeries)
        }
    }

    /// Whether `variableKey` names a `variable` row and `targetKey` a known
    /// row — the two spec preconditions every sweep shares.
    ///
    /// Keys are matched **first-wins**, not any-wins: if a duplicate key puts
    /// a formula row ahead of the variable, the formula pass would overwrite
    /// the swept value on every step and the curve would come out flat. That
    /// is a mis-keyed model, so it must surface as `brokenRef` rather than as
    /// a plausible-looking flat line.
    private static func isSweepable(
        rows: [CalcRow], program: Program, variableKey: String, targetKey: String
    ) -> Bool {
        guard program.knownKeys.contains(targetKey) else { return false }
        guard let first = rows.first(where: { $0.key == variableKey }) else { return false }
        guard case .variable = first.kind else { return false }
        return true
    }

    /// Vary `variableKey` across `from…to` by `step`, reading `targetKey` at
    /// each step. Callers validate the spec first via `isSweepable`.
    ///
    /// The `Base` is passed in and reused across every step: only a formula
    /// can see the swept value, so re-running pass 1 per step would re-scan
    /// every aggregate's source tracker for nothing.
    private static func sweepPoints(
        program: Program,
        base: Base,
        variableKey: String,
        from: Double,
        to: Double,
        step: Double,
        targetKey: String
    ) -> [ChartPoint] {
        var points: [ChartPoint] = []
        // Cap iterations so a tiny step over a wide range can't hang.
        let maxSteps = 1000
        var v = from
        var i = 0
        while v <= to + step * 1e-9 && i < maxSteps {
            let byKey = evaluateFormulas(program, base: base, variableOverride: (variableKey, v))
            if let y = byKey[targetKey]?.value, y.isFinite {
                points.append(ChartPoint(label: numberLabel(v), x: v, y: y))
            }
            v += step
            i += 1
        }
        return points
    }

    /// The ref a `linkedField` anchor row is currently bound to — the "from"
    /// side of a compare swap. `nil` when `linkedRowKey` doesn't name a
    /// `linkedField` row.
    ///
    /// First-wins on the key, like `isSweepable`: a duplicate key that puts a
    /// non-linked row first is a mis-keyed model, not an invitation to hunt
    /// further down the list for something swappable.
    ///
    /// Double-optional on purpose — the outer `nil` is "no anchor row", the
    /// inner is "anchor row bound to nothing", and the latter still matches
    /// the nil-ref `linkedField` rows a swap is supposed to repoint.
    private static func anchorRef(rows: [CalcRow], linkedRowKey: String) -> ComponentItemRef?? {
        guard let first = rows.first(where: { $0.key == linkedRowKey }),
              case .linkedField(let spec) = first.kind else { return nil }
        return .some(spec.ref)
    }

    /// Display name for a linked tracker item, resolved store-free from the
    /// component pool (keeps the resolver pure). Falls back to a dash.
    private static func linkedItemLabel(_ ref: ComponentItemRef, components: [Component]) -> String {
        guard let component = components.first(where: { $0.id == ref.componentId }),
              case .tracker(let tracker) = component.body,
              let item = tracker.items.first(where: { $0.id == ref.itemId }) else {
            return "–"
        }
        return item.displayName
    }

    // MARK: - Linked-field resolution

    /// Resolve a `linkedField` row: pull `fieldName` off the linked tracker
    /// item and parse it as a number. nil ref or a missing item → `brokenRef`;
    /// a present-but-unparseable field → `nonNumeric`.
    private static func resolveLinkedField(_ spec: LinkedFieldSpec, components: [Component]) -> RowResult {
        guard let ref = spec.ref else {
            return RowResult(value: nil, status: .brokenRef)
        }
        guard let component = components.first(where: { $0.id == ref.componentId }),
              case .tracker(let tracker) = component.body,
              let item = tracker.items.first(where: { $0.id == ref.itemId }) else {
            return RowResult(value: nil, status: .brokenRef)
        }
        guard let value = TrackerAggregator.parseNumber(item.values[spec.fieldName]) else {
            return RowResult(value: nil, status: .nonNumeric)
        }
        return RowResult(value: value, status: .ok)
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
