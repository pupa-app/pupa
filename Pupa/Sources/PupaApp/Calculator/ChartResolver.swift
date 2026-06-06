import Foundation

/// Resolves a `ChartSource` to `[ChartSeries]` live, against a MyApp's
/// sibling components. Store-free (takes a `[Component]` pool) so it's
/// unit-testable with a hand-built list, mirroring `CalculatorResolver`.
///
/// Never persisted — `ChartView` / `ChartContainerView` call this every
/// render so an edited source tracker or a tuned calculator reflects
/// immediately. A broken / empty source resolves to `[]` (the view shows a
/// placeholder) rather than throwing.
@MainActor
public enum ChartResolver {

    public static func resolve(_ source: ChartSource, components: [Component]) -> [ChartSeries] {
        switch source {
        case .inline(let points):
            return points.isEmpty ? [] : [ChartSeries(name: "", points: points)]

        case .tracker(let componentId, let groupBy, let valueField, let reduce, let filter, let xIsNumericOrDate):
            guard let component = components.first(where: { $0.id == componentId }),
                  case .tracker(let tracker) = component.body else { return [] }
            let points = TrackerAggregator.series(
                valueField: valueField,
                groupBy: groupBy,
                reduce: reduce,
                items: tracker.items,
                filter: filter,
                xIsNumericOrDate: xIsNumericOrDate
            )
            return points.isEmpty ? [] : [ChartSeries(name: valueField, points: points)]

        case .calculatorRows(let componentId, let keys):
            guard let component = components.first(where: { $0.id == componentId }),
                  case .calculator(let calc) = component.body else { return [] }
            let resolved = CalculatorResolver.resolve(calc, components: components)
            let points: [ChartPoint] = keys.compactMap { key in
                guard let row = calc.rows.first(where: { $0.key == key }),
                      let value = resolved.result(forKey: key)?.value else { return nil }
                return ChartPoint(label: row.name.nonEmpty ?? key, y: value)
            }
            return points.isEmpty ? [] : [ChartSeries(name: calc.title, points: points)]
        }
    }

    /// Total resolved point count across every series — echoed by the chart
    /// tools so the agent sees how many points its spec produced.
    public static func pointCount(_ source: ChartSource, components: [Component]) -> Int {
        resolve(source, components: components).reduce(0) { $0 + $1.points.count }
    }
}
