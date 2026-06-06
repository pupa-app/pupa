import SwiftUI
import Charts

/// Pure, store-free chart. Plots one or more resolved `ChartSeries` as `kind`
/// (pie / bar / line) using Swift Charts. No store, no lookup — the colour
/// per series is driven by series `name` so multi-series line/bar charts get
/// a distinct colour + legend for free; `colorByName` overrides the auto
/// palette where set. Reusable in chat later (Phase 3, #23). Empty series →
/// caller renders a placeholder (this view assumes non-empty input).
///
/// `pie` is inherently single-series — it plots the FIRST series only.
public struct ChartView: View {
    let series: [ChartSeries]
    let kind: ChartKind
    let colorByName: [String: Color]

    public init(series: [ChartSeries], kind: ChartKind, colorByName: [String: Color] = [:]) {
        self.series = series
        self.kind = kind
        self.colorByName = colorByName
    }

    /// Every plotted point flattened with its owning series name.
    private var flat: [(series: String, point: ChartPoint)] {
        series.flatMap { s in s.points.map { (s.name, $0) } }
    }

    /// Use a numeric x axis only when every plotted point carries an `x`
    /// (numeric / date source) — otherwise plot categorically by `label`.
    private var usesNumericX: Bool {
        !flat.isEmpty && flat.allSatisfy { $0.point.x != nil }
    }

    public var body: some View {
        chart
            .modifier(ColorScaleModifier(colorByName: colorByName))
    }

    @ViewBuilder
    private var chart: some View {
        switch kind {
        case .pie:
            Chart(series.first?.points ?? []) { point in
                SectorMark(
                    angle: .value("Value", point.y),
                    innerRadius: .ratio(0.55),
                    angularInset: 1.5
                )
                .cornerRadius(3)
                .foregroundStyle(by: .value("Label", point.label))
            }
        case .bar:
            Chart(flat, id: \.point.id) { row in
                BarMark(
                    x: .value("Label", row.point.label),
                    y: .value("Value", row.point.y)
                )
                .foregroundStyle(by: .value("Series", row.series))
                .position(by: .value("Series", row.series))
            }
            .chartLegend(series.count > 1 ? .visible : .hidden)
        case .line:
            Chart(flat, id: \.point.id) { row in
                if usesNumericX, let x = row.point.x {
                    LineMark(x: .value("x", x), y: .value("Value", row.point.y))
                        .foregroundStyle(by: .value("Series", row.series))
                    PointMark(x: .value("x", x), y: .value("Value", row.point.y))
                        .foregroundStyle(by: .value("Series", row.series))
                } else {
                    LineMark(x: .value("Label", row.point.label), y: .value("Value", row.point.y))
                        .foregroundStyle(by: .value("Series", row.series))
                    PointMark(x: .value("Label", row.point.label), y: .value("Value", row.point.y))
                        .foregroundStyle(by: .value("Series", row.series))
                }
            }
            .chartLegend(series.count > 1 ? .visible : .hidden)
        }
    }
}

/// Applies an explicit foreground-style scale only when colour overrides
/// exist — otherwise Swift Charts picks its own distinct palette.
private struct ColorScaleModifier: ViewModifier {
    let colorByName: [String: Color]

    func body(content: Content) -> some View {
        if colorByName.isEmpty {
            content
        } else {
            let pairs = colorByName.sorted { $0.key < $1.key }
            content.chartForegroundStyleScale(
                domain: pairs.map(\.key),
                range: pairs.map(\.value)
            )
        }
    }
}

/// Store-bound wrapper: resolves a `ChartData` spec against its MyApp's
/// sibling components every render via `ChartResolver`, then renders a
/// titled `ChartView` — or a placeholder when nothing resolves. Used both by
/// the standalone `chart` component and by the calculator's `inlineChart`.
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
        ChartResolver.resolve(data, components: siblingComponents)
    }

    /// Map resolved series name → overridden colour (only for specs that set
    /// `colorHex`). Matched positionally to the declared specs.
    private var colorByName: [String: Color] {
        var map: [String: Color] = [:]
        for (idx, spec) in data.series.enumerated() {
            guard let hex = spec.colorHex, let color = Color(hex: hex) else { continue }
            if let s = ChartResolver.resolveSeries(spec, index: idx, components: siblingComponents) {
                map[s.name] = color
            }
        }
        return map
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ChartTitleBar(data: data)
            let series = resolved
            if series.isEmpty {
                ChartEmptyHint()
            } else {
                ChartView(series: series, kind: data.kind, colorByName: colorByName)
                    .frame(height: 260)
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
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var subtitle: String {
        let n = data.series.count
        let seriesPart = n == 1 ? "" : " · \(n) series"
        return data.kind.rawValue + seriesPart
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
            Text("Point a series at a tracker field, calculator rows, or a calculator list — try \"Line chart of payment vs rate\" or \"Spend by cuisine\".")
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

// MARK: - Hex colour

extension Color {
    /// Parse `#RRGGBB` / `RRGGBB` (and `#RGB`). Returns nil on a malformed
    /// string so the caller falls back to the auto palette.
    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        guard s.count == 6, let v = UInt64(s, radix: 16) else { return nil }
        self.init(
            red: Double((v >> 16) & 0xFF) / 255,
            green: Double((v >> 8) & 0xFF) / 255,
            blue: Double(v & 0xFF) / 255
        )
    }
}
