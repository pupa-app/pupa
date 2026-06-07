# Chart component

A pie / bar / line plot with one or **more overlaid series**, resolved on
every render (never persisted) so an edited source tracker or a tuned
calculator reflects immediately. Non-linkable — a chart holds a `title`, a
`kind`, and an ordered list of `series`.

## Mental model

`kind` ∈ `pie / bar / line`. Multiple series **overlay** (line/bar) — each
gets a distinct colour + a legend; `pie` uses series[0] only. Each series is
`{name?, colorHex?, source}`: `name` defaults from the source, `colorHex`
(`#RRGGBB`) overrides the auto palette. A `source` is one of four arms:

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
  — `@MainActor` → `[ChartSeries]`, one per `ChartSeriesSpec` (empty / broken
  specs drop out), against a MyApp's sibling components. Default series names
  come from the source (`valueField`, calc title / row name, or `Series N`).

## View

[`Canvas/ChartView.swift`](../../Pupa/Sources/PupaApp/Canvas/ChartView.swift):
`ChartView(series:kind:colorByName:)` is a pure Swift Charts view
(`SectorMark`/`BarMark`/`LineMark`) — store-free, reusable in chat. Colour is
keyed by series **name** (`.foregroundStyle(by:)`) so multi-series charts get
a distinct colour + legend for free; `colorByName` applies any `colorHex`
overrides. `ChartContainerView` does the store lookup + resolution and renders
title + placeholder. Used by the standalone `chart` component and the
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

Gated behind `get_skill_chart`. `renderChart` (destructive `{title, kind,
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
