# Chart component

A pie / bar / line plot with one or **more overlaid series**, resolved on
every render (never persisted) so an edited source tracker or a tuned
calculator reflects immediately. Non-linkable — a chart holds a `title`, a
`kind`, and an ordered list of `series`.

## Mental model

`kind` ∈ `pie / bar / line`. Multiple series **overlay** (line/bar) — each
gets a distinct colour + a legend; `pie` uses series[0] only. Each series is
`{name?, colorHex?, source}`: `name` defaults from the source, `colorHex`
(`#RRGGBB`) overrides the auto palette — **except on a spec that fans out**
(`calculatorLinkedSweep` becomes a curve per ref), where one colour across
every curve would defeat the point, so the override is dropped and the palette
assigns per curve. A `source` is one of five arms:

- **tracker** — reduce a numeric `valueField` grouped by `groupBy` over a
  tracker: `{componentId, groupBy, valueField, reduce, filter, xIsNumericOrDate}`.
  `reduce` ∈ `sum/avg/min/max/count`; `filter` is the same
  **case-insensitive AND equality** match the calculator uses. Set
  `xIsNumericOrDate` to parse the group key as a number or date
  (ISO-8601 / `yyyy-MM-dd`) and plot it on an **ascending continuous x
  axis** — the "unidirectional x axis" for bar/line over a date field.
- **calculatorRows** — `{componentId, keys}`. Each calculator row's
  live-resolved scalar becomes one point (labelled by the row name).
- **calculatorList** — `{componentId, key}`. Plots a single calculator
  `.list` row (a **sweep** or tracker column — see
  [calculator.md](calculator.md)). This is how a computed curve (payment vs
  rate) becomes a line; several `calculatorList` series over a shared x axis
  give a multi-line projection.
- **calculatorLinkedSweep** — `{componentId, key}` pointing at a calculator
  `.linkedSweep` `.list` row. Unlike every other arm (one series), this **fans
  out to one line per linked ref** at resolve time — the multi-line analogue of
  `calculatorList`. One declared spec → N `ChartSeries`. Use it for "a live
  curve per house/item" without declaring a series each.
- **inline** — `{points: [{label, x?, y}]}`. Literal points; the seam Phase 3
  (#23) snapshots into a chat attachment.

## Data model

[`Canvas/CanvasState.swift`](../../Pupa/Sources/PupaApp/Canvas/CanvasState.swift):
`ChartData {title, kind, series: [ChartSeriesSpec]}`, `ChartSeriesSpec {id,
name?, colorHex?, source}`, `ChartKind`, `ChartSeriesSource` (tagged codec),
`ChartSeries {id, name, points}`, `ChartPoint {id, label, x?, y}`. `ChartSeries`
/ `ChartPoint` are **store-decoupled** (no store, no MainActor) so they're
reusable in chat later. `CalculatorData.inlineChart: ChartData?` embeds one
inside a calculator.

## Engines (pure / store-free)

- [`Calculator/TrackerAggregator.swift`](../../Pupa/Sources/PupaApp/Calculator/TrackerAggregator.swift)
  — `series(...)` extends the Phase-1 reducer: group → reduce → one
  `ChartPoint` per bucket, ascending-by-x when `xIsNumericOrDate`.
- [`Calculator/ChartResolver.swift`](../../Pupa/Sources/PupaApp/Calculator/ChartResolver.swift)
  — `@MainActor` → `[ChartSeries]` against a MyApp's sibling components. Mostly
  one series per `ChartSeriesSpec` (empty / broken specs drop out), but
  `calculatorLinkedSweep` fans **one** spec out to a curve per ref. Default
  series names come from the source (`valueField`, calc title / row name, or
  `Series N`).

  **Views render through `displaySeries`**, not `resolve`: it adds the two
  things a drawn chart needs. `disambiguated` suffixes repeated names (`(2)`,
  `(3)`, …) — Swift Charts groups colour and legend by name, and names come
  from user data, so two tracker items both called "Maple" would otherwise
  merge into one style group. And it carries `colorHex` across to the renamed
  series, dropping it for a fanned-out spec. The one-spec-one-series arm is
  private: it cannot express a fan-out and silently returns nothing for one,
  which is exactly how `linkedSweep` charts came to render blank.

## View

[`Canvas/ChartView.swift`](../../Pupa/Sources/PupaApp/Canvas/Components/Chart/ChartView.swift):
`ChartView(series:kind:colorByName:showsLegend:showsPoints:)` is a pure Swift
Charts view (`SectorMark`/`BarMark`/`LineMark`) — store-free, reusable in chat.
Colour is keyed by series **name** (`.foregroundStyle(by:)`) so multi-series
charts get a distinct colour + legend for free.

`colorByName` is all-or-nothing by design: with no overrides at all the view
leaves Swift Charts' own palette alone, but **one** override switches on an
explicit scale — and that scale then has to span *every* series, filling the
un-overridden ones from `CategoricalPalette`. A domain listing only the
overridden names leaves the rest outside it, sharing one indeterminate style.

`showsLegend` / `showsPoints` both default true. The calculator's list-row
sparkline passes false to both: at 120×36 a legend eats the plot and the point
glyphs outnumber the line.

`ChartContainerView` does the store lookup + resolution (through
`ChartResolver.displaySeries` — see Engines) and renders title + placeholder;
`ChartContainerView.drawable` is that mapping as a pure function, so tests can
assert what the view draws. Used by the standalone `chart` component and the
calculator's `inlineChart` (and the list-row sparkline). `import Charts` works
unconditionally on the app's iOS 17 / macOS 14 targets — no `@available`
guards.

## Mutator surface

[`MyApps/MyAppStore.swift`](../../Pupa/Sources/PupaApp/MyApps/MyAppStore.swift):
`setChart` (destructive), `patchChart` (+`ChartPatch`), `setChartKind`,
`addChartSeries`, `removeChartSeries`, `chartComponentId`,
`setCalculatorInlineChart`. Mutations are component-level edits, no per-item
event.

## Tool surface

Gated behind `get_tools_chart`. `renderChart` (destructive `{title, kind,
series}`), `patchChart` (in-place), `addChartSeries` / `removeChartSeries`
(incremental), `setChartKind` (flip pie⇄bar⇄line). Every tool echoes
`{seriesCount, pointCount}` so the agent sees what its spec produced.

## Quirks

- Charts hold no `linkedItems` — **non-linkable**, like the calculator.
- Canvas-summary `itemCount` sums a chart's literal **inline** points;
  tracker / calculator sources report 0 (their data lives elsewhere).
- A broken source (deleted tracker, unknown row keys) plots nothing rather
  than crashing.
- `pie` is inherently single-series — it plots series[0] only.
