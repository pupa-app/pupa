import SwiftUI
import Charts

/// Pure, store-free chart. Plots `series` as `kind` (pie / bar / line) using
/// Swift Charts. No store, no lookup — `ChartContainerView` does resolution
/// and hands it the already-resolved series, so this view is reusable in
/// chat later (Phase 3, #23). Empty series → caller renders a placeholder
/// (this view assumes non-empty input).
public struct ChartView: View {
    let series: [ChartSeries]
    let kind: ChartKind

    public init(series: [ChartSeries], kind: ChartKind) {
        self.series = series
        self.kind = kind
    }

    /// Flattened points of the first series — pie / single-metric charts
    /// plot one run.
    private var points: [ChartPoint] { series.first?.points ?? [] }

    public var body: some View {
        switch kind {
        case .pie:
            Chart(points) { point in
                SectorMark(
                    angle: .value("Value", point.y),
                    innerRadius: .ratio(0.55),
                    angularInset: 1.5
                )
                .cornerRadius(3)
                .foregroundStyle(by: .value("Label", point.label))
            }
            .frame(height: 240)
        case .bar:
            Chart(points) { point in
                BarMark(
                    x: .value("Label", point.label),
                    y: .value("Value", point.y)
                )
                .foregroundStyle(by: .value("Label", point.label))
            }
            .chartLegend(.hidden)
            .frame(height: 240)
        case .line:
            Chart(points) { point in
                LineMark(
                    x: .value("Label", point.label),
                    y: .value("Value", point.y)
                )
                PointMark(
                    x: .value("Label", point.label),
                    y: .value("Value", point.y)
                )
            }
            .frame(height: 240)
        }
    }
}

/// Store-bound wrapper: resolves a `ChartData` spec against its MyApp's
/// sibling components every render via `ChartResolver`, then renders a
/// titled `ChartView` — or a placeholder when the source resolves to no
/// points (empty / broken source). Used both by the standalone `chart`
/// component and by the calculator's `inlineChart`.
public struct ChartContainerView: View {
    @Bindable var store: MyAppStore
    let data: ChartData
    let myAppId: UUID

    public init(store: MyAppStore, data: ChartData, myAppId: UUID) {
        self.store = store
        self.data = data
        self.myAppId = myAppId
    }

    private var siblingComponents: [Component] {
        store.myApps.first(where: { $0.id == myAppId })?.components ?? []
    }

    private var resolved: [ChartSeries] {
        ChartResolver.resolve(data.source, components: siblingComponents)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ChartTitleBar(data: data)
            let series = resolved
            if series.allSatisfy({ $0.points.isEmpty }) {
                ChartEmptyHint()
            } else {
                ChartView(series: series, kind: data.kind)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Title bar

private struct ChartTitleBar: View {
    let data: ChartData

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.secondary)
            Text(data.title.isEmpty ? "Chart" : data.title)
                .font(.title2)
                .fontWeight(.semibold)
            Spacer()
            Text(data.kind.rawValue)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var icon: String {
        switch data.kind {
        case .pie: return "chart.pie"
        case .bar: return "chart.bar"
        case .line: return "chart.xyaxis.line"
        }
    }
}

// MARK: - Empty hint

private struct ChartEmptyHint: View {
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "chart.pie")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("No data to plot")
                .font(.headline)
            Text("Point this chart at a tracker field or calculator rows — try \"Pie chart of spend by cuisine\" or \"Bar chart of monthly totals\".")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
        }
        .padding(32)
        .frame(maxWidth: .infinity)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.gray.opacity(0.3), style: StrokeStyle(lineWidth: 1, dash: [6, 4]))
        )
    }
}
