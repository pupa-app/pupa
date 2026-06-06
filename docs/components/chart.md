# Chart component

A pie / bar / line plot whose series are **resolved on every render** (never
persisted) so an edited source tracker or a tuned calculator reflects
immediately. Non-linkable, single-spec — a chart holds a `title`, a `kind`,
and one `source`.

## Mental model

`kind` ∈ `pie / bar / line`. `source` is one of three arms:

- **tracker** — reduce a numeric `valueField` grouped by `groupBy` over a
  tracker: `{componentId, groupBy, valueField, reduce, filter, xIsNumericOrDate}`.
  `reduce` ∈ `sum/avg/min/max/count`; `filter` is the same
  **case-insensitive AND equality** match the calculator uses. Set
  `xIsNumericOrDate` to parse the group key as a number or date
  (ISO-8601 / `yyyy-MM-dd`) and plot it on an **ascending continuous x
  axis** — the "unidirectional x axis" for bar/line over a date field.
- **calculatorRows** — `{componentId, keys}`. Each calculator row's
  live-resolved scalar becomes one point (labelled by the row name).
- **inline** — `{points: [{label, x?, y}]}`. Literal points; the seam Phase 3
  (#23) snapshots into a chat attachment.

## Data model

[`Canvas/CanvasState.swift`](../../Pupa/Sources/PupaApp/Canvas/CanvasState.swift):
`ChartData {title, kind, source}`, `ChartKind`, `ChartSource` (tagged codec),
`ChartSeries {id, name, points}`, `ChartPoint {id, label, x?, y}`. `ChartSeries`
/ `ChartPoint` are **store-decoupled** (no store, no MainActor) so they're
reusable in chat later. `CalculatorData.inlineChart: ChartData?` embeds one
inside a calculator.

## Engines (pure / store-free)

- [`Calculator/TrackerAggregator.swift`](../../Pupa/Sources/PupaApp/Calculator/TrackerAggregator.swift)
  — `series(...)` extends the Phase-1 reducer: group → reduce → one
  `ChartPoint` per bucket, ascending-by-x when `xIsNumericOrDate`.
- [`Calculator/ChartResolver.swift`](../../Pupa/Sources/PupaApp/Calculator/ChartResolver.swift)
  — `@MainActor` → `[ChartSeries]` from any `ChartSource`, against a MyApp's
  sibling components. Broken / empty source → `[]` (the view shows a
  placeholder), never throws.

## View

[`Canvas/ChartView.swift`](../../Pupa/Sources/PupaApp/Canvas/ChartView.swift):
`ChartView(series:kind:)` is a pure Swift Charts view
(`SectorMark`/`BarMark`/`LineMark`) — store-free, reusable in chat.
`ChartContainerView` does the store lookup + resolution and renders the
title + placeholder. Used by both the standalone `chart` component and the
calculator's `inlineChart`. `import Charts` works unconditionally on the
app's iOS 17 / macOS 14 targets — no `@available` guards.

## Mutator surface

[`MyApps/MyAppStore.swift`](../../Pupa/Sources/PupaApp/MyApps/MyAppStore.swift):
`setChart` (destructive), `patchChart` (+`ChartPatch`), `setChartKind`,
`chartComponentId`, `setCalculatorInlineChart`. A chart is single-spec, so
mutations are component-level edits with no per-item event.

## Tool surface

Gated behind `get_skill_chart`. `renderChart` (destructive `{title, kind,
source}`), `patchChart` (in-place), `setChartKind` (flip pie⇄bar⇄line). Every
tool echoes the **resolved point count** so the agent sees how many points
its spec produced.

## Quirks

- Charts hold no `linkedItems` — **non-linkable**, like the calculator.
- Canvas-summary `itemCount` reports a chart's literal **inline** point count;
  tracker / calculatorRows sources report 0 (their data lives elsewhere).
- A broken source (deleted tracker, unknown row keys) plots nothing rather
  than crashing.
