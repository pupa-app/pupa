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
    /// Multi-series charts legend themselves. A caller drawing into a space
    /// too small for one — the calculator's inline sparkline — turns it off;
    /// the legend would otherwise eat most of a 36pt-tall plot.
    let showsLegend: Bool
    /// Per-point glyphs on a line chart. Off for a sparkline: three curves over
    /// thirty steps is ninety glyphs in 120pt of width, which reads as noise
    /// rather than as data.
    let showsPoints: Bool

    public init(
        series: [ChartSeries],
        kind: ChartKind,
        colorByName: [String: Color] = [:],
        showsLegend: Bool = true,
        showsPoints: Bool = true
    ) {
        self.series = series
        self.kind = kind
        self.colorByName = colorByName
        self.showsLegend = showsLegend
        self.showsPoints = showsPoints
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
            .modifier(ColorScaleModifier(names: series.map(\.name), colorByName: colorByName))
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
            .chartLegend(showsLegend && series.count > 1 ? .visible : .hidden)
        case .line:
            Chart(flat, id: \.point.id) { row in
                if usesNumericX, let x = row.point.x {
                    LineMark(x: .value("x", x), y: .value("Value", row.point.y))
                        .foregroundStyle(by: .value("Series", row.series))
                    if showsPoints {
                        PointMark(x: .value("x", x), y: .value("Value", row.point.y))
                            .foregroundStyle(by: .value("Series", row.series))
                    }
                } else {
                    LineMark(x: .value("Label", row.point.label), y: .value("Value", row.point.y))
                        .foregroundStyle(by: .value("Series", row.series))
                    if showsPoints {
                        PointMark(x: .value("Label", row.point.label), y: .value("Value", row.point.y))
                            .foregroundStyle(by: .value("Series", row.series))
                    }
                }
            }
            .chartLegend(showsLegend && series.count > 1 ? .visible : .hidden)
        }
    }
}

/// Applies an explicit foreground-style scale only when colour overrides
/// exist — otherwise Swift Charts picks its own distinct palette.
///
/// When it does apply, the scale must span **every** series on the chart.
/// `chartForegroundStyleScale(domain:range:)` is categorical: a series whose
/// name is missing from the domain gets no slot and renders in an undefined
/// style, so a chart mixing one overridden series with several un-overridden
/// ones would draw the rest identically. Names without an override are filled
/// from the fallback palette, in the order they appear.
struct ColorScaleModifier: ViewModifier {
    /// Every series name on the chart, in draw order.
    let names: [String]
    let colorByName: [String: Color]

    func body(content: Content) -> some View {
        if colorByName.isEmpty {
            // No overrides at all: leave Swift Charts' own palette alone. It
            // adapts to the series count better than a fixed list, and forcing
            // ours here would restyle every existing chart in the app.
            content
        } else {
            content.chartForegroundStyleScale(domain: names, range: Self.range(names: names, colorByName: colorByName))
        }
    }

    /// One colour per name, in draw order: the author's override where there is
    /// one, otherwise the next **unused** fallback — an overridden name must not
    /// consume a palette slot, or the remaining series skip colours and wrap
    /// sooner than they need to.
    ///
    /// Internal so this is testable: it is the logic that keeps a partly
    /// coloured chart from rendering its un-overridden series identically.
    static func range(names: [String], colorByName: [String: Color]) -> [Color] {
        var next = 0
        var out: [Color] = []
        for name in names {
            if let override = colorByName[name] {
                out.append(override)
            } else {
                out.append(CategoricalPalette.colors[next % CategoricalPalette.colors.count])
                next += 1
            }
        }
        return out
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

    /// Resolve every series ONCE per render via `ChartResolver.displaySeries`,
    /// which owns the fan-out (`calculatorLinkedSweep` becomes one curve per
    /// linked item), the duplicate-name disambiguation and the `colorHex`
    /// carry-across. All this view does is turn hex into `Color`.
    private var resolved: (series: [ChartSeries], colorByName: [String: Color]) {
        Self.drawable(data, components: siblingComponents)
    }

    /// What `body` draws, as a pure function of the spec and the component
    /// pool. Separate from the view so a test can assert this goes through
    /// `displaySeries` — i.e. that a fanned-out source really reaches the
    /// chart, which is the regression this file exists to prevent.
    static func drawable(
        _ data: ChartData,
        components: [Component]
    ) -> (series: [ChartSeries], colorByName: [String: Color]) {
        var series: [ChartSeries] = []
        var colorByName: [String: Color] = [:]
        for entry in ChartResolver.displaySeries(data, components: components) {
            series.append(entry.series)
            if let hex = entry.colorHex, let color = Color(hex: hex) {
                colorByName[entry.series.name] = color
            }
        }
        return (series, colorByName)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ChartTitleBar(data: data)
            let r = resolved
            if r.series.isEmpty {
                ChartEmptyHint()
            } else {
                ChartView(series: r.series, kind: data.kind, colorByName: r.colorByName)
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
