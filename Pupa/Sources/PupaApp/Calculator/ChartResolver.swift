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
    public static func resolveSeries(_ spec: ChartSeriesSpec, index: Int, components: [Component]) -> ChartSeries? {
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
