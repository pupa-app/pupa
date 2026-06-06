# Calculator component

A live numeric canvas shape: a titled, ordered list of rows whose results
are **recomputed on every render** (never persisted) so tuning a variable or
editing a source tracker reflects immediately.

## Mental model

Three row kinds, each addressed by a stable slug `key` (formulas reference
rows by `key`, never by display `name`, so renames never break them):

- **variable** — a tunable input `{value, control}`. The `control` is
  `plain` (field), `stepper(step)`, or `slider(min, max, step)`.
- **aggregate** — a scalar reduce of a numeric field on another tracker:
  `{sourceComponentId, fieldName, reduce, filter}`. `reduce` ∈
  `sum/avg/min/max/count`. `filter` is a **case-insensitive AND equality**
  match (isolate "spend on African restaurants" with
  `{cuisine: "African"}`). `count` ignores numeric parsing.
- **formula** — arithmetic over other rows' keys: `+ - * / % ^` (with `^`
  right-associative, binding tighter than unary minus), parentheses, and
  the functions `min max abs round sqrt log exp pow`.
- **list** — a terminal **array** output for charts (`CalcListSpec`). Either a
  **sweep** — vary `variableKey` across `from…to` by `step`, holding every
  other variable fixed, reading `targetKey` at each step (x = swept value,
  y = target; the payment-vs-rate sensitivity curve) — or a **trackerColumn**
  pulling a raw per-item array off a tracker. Scalar formulas can't reference
  a list key (a list has no scalar value → referencing it is `brokenRef`).
  Plot one via a chart's `calculatorList` source.

## Data model

[`Canvas/CanvasState.swift`](../../Pupa/Sources/PupaApp/Canvas/CanvasState.swift):
`CalculatorData {title, rows: [CalcRow]}`,
`CalcRow {id, key, name, unit?, format?, kind}`,
`CalcRowKind` (tagged codec), `CalcControl` (tagged codec),
`AggregateSpec`, `CalcReduce`. Phase 2 (#22) adds `inlineChart: ChartData?`
— the `decodeIfPresent` decoders mean that lands without a migration.

## Engines (pure, store-free)

- [`Calculator/ExpressionEngine.swift`](../../Pupa/Sources/PupaApp/Calculator/ExpressionEngine.swift)
  — recursive-descent parse + evaluate, identifier extraction, and a Kahn
  topological sort with cycle detection.
- [`Calculator/TrackerAggregator.swift`](../../Pupa/Sources/PupaApp/Calculator/TrackerAggregator.swift)
  — the reduce + filter + tolerant numeric parse (currency / commas /
  percent). Reused by Phase 2 charts.
- [`Calculator/CalculatorResolver.swift`](../../Pupa/Sources/PupaApp/Calculator/CalculatorResolver.swift)
  — `@MainActor` glue → per-row `{value, status}` where status ∈
  `ok / cycle / brokenRef / nonNumeric / unknownIdentifier / divisionByZero`.

## Mutator surface

[`MyApps/MyAppStore.swift`](../../Pupa/Sources/PupaApp/MyApps/MyAppStore.swift):
`setCalculator`, `addCalcRow` (slug-dedupes, returns the key),
`patchCalcRow` (+`CalcRowPatch`), `removeCalcRow`, `setCalculatorVariable`
(UI tuning path — emits no event so slider drags don't flood History),
`calculatorComponentId`. Row edits emit an `ItemEvent` with no inverse —
calc rows are not in the undo graph in Phase 1.

## Tool surface

Gated behind `get_skill_calculator`. `renderCalculator` (destructive full
render or `summary`-only), bulk `addCalcRows` / `patchCalcRows` /
`removeCalcRows`, and discovery `listCalcRows` / `getCalcRow`. Every
mutating tool echoes the live-resolved `{key, value, status}` results.

## Quirks

- Calculator rows hold no `linkedItems` — the shape is **non-linkable** (it
  references trackers via `AggregateSpec`, not the universal item-ref graph).
- Deleting a source tracker leaves aggregates resolving to `brokenRef`
  ("(source removed)" in the UI) and poisons dependent formulas the same
  way — no crash, no stale numbers.
