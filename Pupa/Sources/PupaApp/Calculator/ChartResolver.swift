import Foundation

/// Resolves a `ChartData` spec to `[ChartSeries]` live, against a MyApp's
/// sibling components. Store-free (takes a `[Component]` pool) so it's
/// unit-testable with a hand-built list, mirroring `CalculatorResolver`.
///
/// One `ChartSeries` per declared `ChartSeriesSpec` (empty / broken specs
/// drop out). Never persisted — the view calls this every render so an
/// edited source tracker or a tuned calculator reflects immediately.
@MainActor
public enum ChartResolver {

    /// Resolve every series in `data`. Empty / broken series are dropped, so
    /// the result holds only series with at least one point.
    public static func resolve(_ data: ChartData, components: [Component]) -> [ChartSeries] {
        data.series.enumerated().flatMap { idx, spec in
            resolveSeriesAll(spec, index: idx, components: components)
        }
    }

    /// One drawable line/bar group: the series, with its display name already
    /// disambiguated, plus the colour the spec asked for (if it applies).
    public struct DisplaySeries: Sendable, Equatable {
        public var series: ChartSeries
        /// The spec's `colorHex`, carried across to the deduped name. `nil`
        /// when the spec fanned out to several series — see `displaySeries`.
        public var colorHex: String?

        public init(series: ChartSeries, colorHex: String?) {
            self.series = series
            self.colorHex = colorHex
        }
    }

    /// Everything a chart view needs to draw `data`, in declared order.
    ///
    /// This is the entry point for **rendering** — `resolveSeries` handles one
    /// spec and cannot express `calculatorLinkedSweep`, which fans one spec out
    /// to a curve per linked item. Drawing through the single-series path meant
    /// a `linkedSweep` chart silently rendered nothing at all.
    ///
    /// Two things happen here that the raw resolve doesn't do:
    ///
    /// - **Name disambiguation.** Swift Charts groups colour and legend entries
    ///   by series name, so two series sharing a name would collapse into one.
    ///   Repeats get a `(2)`, `(3)`, … suffix.
    /// - **Colour carry-across.** A spec's `colorHex` follows its series to the
    ///   deduped name — unless its source `fansOut`, in which case it keeps
    ///   `nil` so Swift Charts assigns a distinct colour per item. Forcing one
    ///   colour across every curve would defeat the point of a line per item,
    ///   and the rule keys off the source kind so a spec doesn't change colour
    ///   behaviour just because a ref was added or removed.
    public static func displaySeries(_ data: ChartData, components: [Component]) -> [DisplaySeries] {
        var resolvedPerSpec: [(spec: ChartSeriesSpec, series: [ChartSeries])] = []
        for (idx, spec) in data.series.enumerated() {
            resolvedPerSpec.append((spec, resolveSeriesAll(spec, index: idx, components: components)))
        }
        // One colour slot per resolved series, flattened in the same order, so
        // pairing is a zip rather than two loops that could drift apart. A spec
        // whose source fans out keeps no colour override — see above.
        let colors: [String?] = resolvedPerSpec.flatMap { entry in
            Array(repeating: entry.spec.source.fansOut ? nil : entry.spec.colorHex,
                  count: entry.series.count)
        }
        let renamed = disambiguated(resolvedPerSpec.flatMap(\.series))
        return zip(renamed, colors).map(DisplaySeries.init)
    }

    /// Give every series a name unique within the set, preserving order and
    /// identity. Repeats get a `(2)`, `(3)`, … suffix.
    ///
    /// Swift Charts groups colour and legend entries by the *name* a mark is
    /// styled by, so two series sharing one would silently merge into a single
    /// style group and render as one tangled line. Names come from user data —
    /// two tracker items really can both be called "Maple" — so this is not a
    /// rare case. Every surface that hands a set of series to `ChartView` must
    /// go through here.
    public static func disambiguated(_ series: [ChartSeries]) -> [ChartSeries] {
        // Track what has actually been emitted. Counting source names instead
        // would let a generated "Maple (2)" collide with a literal "Maple (2)"
        // further down the list — people number their own duplicates by hand.
        var used: Set<String> = []
        return series.map { s in
            var name = s.name
            var n = 1
            while !used.insert(name).inserted {
                n += 1
                name = "\(s.name) (\(n))"
            }
            guard name != s.name else { return s }
            return ChartSeries(id: s.id, name: name, points: s.points)
        }
    }

    /// Resolve one spec to ONE OR MORE series. Every source resolves to a
    /// single series except `calculatorLinkedSweep`, which fans out to one
    /// curve per linked ref (read straight off the `.series` the resolver
    /// computed for the linkedSweep row).
    private static func resolveSeriesAll(_ spec: ChartSeriesSpec, index: Int, components: [Component]) -> [ChartSeries] {
        if case .calculatorLinkedSweep(let componentId, let key) = spec.source {
            guard let component = components.first(where: { $0.id == componentId }),
                  case .calculator(let calc) = component.body else { return [] }
            let resolved = CalculatorResolver.resolve(calc, components: components)
            return resolved.result(forKey: key)?.series ?? []
        }
        return resolveSeries(spec, index: index, components: components).map { [$0] } ?? []
    }

    /// Resolve one spec to a named series, or nil when it produces no points.
    /// `index` seeds a default name (`Series N`) when the spec / source give
    /// none.
    ///
    /// **Private on purpose.** This arm cannot represent a
    /// `calculatorLinkedSweep`, which is one spec and many series — it reports
    /// no points for one, so anything drawing through here renders a
    /// `linkedSweep` chart as empty. That is exactly the bug this replaced.
    /// Render through `displaySeries`; ask `resolve` for the raw series.
    private static func resolveSeries(_ spec: ChartSeriesSpec, index: Int, components: [Component]) -> ChartSeries? {
        let (points, defaultName) = resolvePoints(spec.source, components: components)
        guard !points.isEmpty else { return nil }
        let name = spec.name?.nonEmpty ?? defaultName.nonEmpty ?? "Series \(index + 1)"
        return ChartSeries(id: spec.id, name: name, points: points)
    }

    /// Points + a default series name for one source.
    private static func resolvePoints(_ source: ChartSeriesSource, components: [Component]) -> ([ChartPoint], String) {
        switch source {
        case .inline(let points):
            return (points, "")

        case .tracker(let componentId, let groupBy, let valueField, let reduce, let filter, let xIsNumericOrDate):
            guard let component = components.first(where: { $0.id == componentId }),
                  case .tracker(let tracker) = component.body else { return ([], "") }
            let points = TrackerAggregator.series(
                valueField: valueField,
                groupBy: groupBy,
                reduce: reduce,
                items: tracker.items,
                filter: filter,
                xIsNumericOrDate: xIsNumericOrDate
            )
            return (points, valueField)

        case .calculatorRows(let componentId, let keys):
            guard let component = components.first(where: { $0.id == componentId }),
                  case .calculator(let calc) = component.body else { return ([], "") }
            let resolved = CalculatorResolver.resolve(calc, components: components)
            let points: [ChartPoint] = keys.compactMap { key in
                guard let row = calc.rows.first(where: { $0.key == key }),
                      let value = resolved.result(forKey: key)?.value else { return nil }
                return ChartPoint(label: row.name.nonEmpty ?? key, y: value)
            }
            return (points, calc.title)

        case .calculatorList(let componentId, let key):
            guard let component = components.first(where: { $0.id == componentId }),
                  case .calculator(let calc) = component.body else { return ([], "") }
            let resolved = CalculatorResolver.resolve(calc, components: components)
            let points = resolved.result(forKey: key)?.list ?? []
            let name = calc.rows.first(where: { $0.key == key })?.name ?? key
            return (points, name)

        case .calculatorLinkedSweep:
            // Multi-series — fanned out in `resolveSeriesAll`, never here.
            return ([], "")
        }
    }

    /// Total resolved point count across every series — echoed by the chart
    /// tools so the agent sees how many points its spec produced.
    public static func pointCount(_ data: ChartData, components: [Component]) -> Int {
        resolve(data, components: components).reduce(0) { $0 + $1.points.count }
    }
}
