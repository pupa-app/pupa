# Changelog

All notable changes to the Pupa iOS / macOS repo are documented here.
Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) — patch-only bumps (`0.0.X` → `0.0.X+1`).

## [0.0.16] — 2026-06-11

### Added

- **Marketplace (remote read)**. Settings ▸ **Marketplace** browses a remote
  catalog of `.pupaapp` apps and installs one. Host-agnostic: point at any
  HTTPS host serving an `index.json` (GitHub raw by default); repoint to your
  own repo from the screen. Downloads are size- and SHA-256-verified, and the
  detail view previews the agent personas an app carries before you add it.
  Install reuses the existing untrusted-input importer — the network is only a
  byte source. See [docs/marketplace.md](docs/marketplace.md).

## [0.0.15] — 2026-06-10

### Added

- **Guided tour: Share a MyApp step**. A final tour card introduces Export /
  Import and deep-links to Settings ▸ **Import & Export** (new `.sharing`
  tour-settings route).

## [0.0.14] — 2026-06-08

### Added

- **MyApp Export / Import (marketplace foundation)**: share a MyApp as a
  portable, **inert** `.pupaapp` bundle (a versioned-header JSON carrying the
  `Codable` `MyApp` tree + memory files) and rebuild it on another install — no
  code from the bundle is ever executed. Settings ▸ **Import & Export**: pick
  components, toggle records/memories, review the agent prompts being shared,
  export; import validates and rebuilds in dependency order. Cross-component
  references are now enumerated/pruned by a single unified model on `CanvasApp`
  (`componentReferences` / `remapReferences`), shared by the delete cascade and
  the exporter, so a new component declares its refs in one exhaustive switch.
  Each kind registers a `ComponentExportPolicy` (completeness enforced at
  bootstrap + in CI). Import is hardened against hostile bundles: settings
  allow-list (drops e.g. `shell_approval_disabled`), size/count caps,
  duplicate-id / unknown-kind rejection, slug-collision-safe renaming, and
  path-traversal-safe memory writes. (`PupaApp` `0.0.104`)

## [0.0.13] — 2026-06-07

### Fixed

- **Onboarding cards legible in dark mode**: `brandSurface` was a fixed
  light-pink, so white label text became invisible on it in dark mode. Now an
  adaptive color (light-pink / dark plum) that resolves per light/dark trait.
  (`PupaApp` `0.0.103`)

## [0.0.12] — 2026-06-07

### Added

- **Live per-item time-series via `linkedSweep`** (#37): a new calculator
  `list` sub-type that resolves a swept **curve per linked ref** (the
  multi-line analogue of `linkedCompare`'s one-point-per-ref). Self-contained —
  embeds the same sweep params a `sweep` carries plus `refs` + `linkedRowKey`.
  Plotted by a new chart source `calculatorLinkedSweep`, which fans one
  declared spec out to N live series. (`PupaApp` `0.0.102`)
- **Single-source dropdown on the calculator**: when every `linkedField` row
  shares one tracker, the calculator view shows one "source" dropdown at the
  top that repoints all rows together (`setAllCalcRowLinks`) and hides the
  per-row link pills — "pick the house, the whole model follows", no
  per-datapoint drift.
- **Home Buying ships out of the box**: the example is seeded on fresh install
  alongside the Wellbeing Coach (still restorable from Settings).

### Changed

- **Home Buying model reworked into a standard rent-vs-buy comparison**: the
  seed-static cumulative-cost lines are gone. The mortgage model now drives a
  live **Buy-vs-Rent net-worth** chart for the selected house — owning (home
  value − loan owed) vs. renting (down payment + monthly surplus invested at a
  market return). Both paths deploy the same money, so the curves start equal
  and cross when one strategy overtakes the other. New Assumptions sliders:
  home appreciation, rent, investment return, projection year.

## [0.0.11] — 2026-06-07

### Added

- **Linked-field calculator rows + Home Buying example** (#35): a new calculator
  row kind `linkedField` pulls one numeric field off a single linked tracker
  item — swap the linked item (the row's link pill, or the new `setCalcRowLink`
  tool) to re-run the whole model against a different row. A new `list`
  sub-type `linkedCompare` compares a *set* of linked items on a target row
  (swapping every linkedField row that shares the anchor ref per item) and
  plots one point each — the seam for the new **Example: Home Buying**
  workspace: a kanban of candidate houses driving a live mortgage model with an
  embedded bar chart comparing total monthly cost across houses. Deleting a
  house clears its ref from the calculator (cascade). (`PupaApp` `0.0.99`)
- **A calculator can stack extra charts** below its embedded chart via
  `CalculatorData.extraCharts` (seed-declared; `embedComponent` still only
  touches `inlineChart`). The Home Buying model uses it for a per-house
  **cumulative cost over 30 years** line chart under the monthly-cost
  histogram — one line each, P&I stopping at each house's payoff. Seed-static
  (illustrative), unlike the live bar chart. (`PupaApp` `0.0.101`)
- **Per-app bottom dock** for quick page-switching: an icon-only bar (Home +
  one icon per component, tinted the app's color, current page highlighted)
  that reveals when you approach the bottom — macOS slides it up on pointer
  hover; iOS peeks a handle you tap to expand. Lets you hop between a myApp's
  homepage and any component canvas in one tap, scoped to the active app.
  (`PupaApp` `0.0.101`)

### Changed

- The orchestrator's accent color is now a dark neutral grey (was purple) so it
  reads as the "meta" agent without competing with per-MyApp colors.
- **Chat agent dropdown is now color-coded**: the agent selector is a custom
  popover (was a native menu) so each agent row shows its name + icon in that
  agent's color — native menus ignored per-row tints. (`PupaApp` `0.0.101`)
- **Edit-item sheet reads as key → value**: each field now keeps a persistent
  leading label (`LabeledContent` / a caption header for multiline text) instead
  of a placeholder that vanished once a value was typed — the row stays legible
  when filled. (`PupaApp` `0.0.100`)
- The MyApp landing page (`MyAppHomeView`) gains a **History** panel below
  Memories: up to three newest `ItemEventLog` events inline, "View all" opening
  the full Change History sheet (with per-row undo). The onboarding "It
  remembers" slide now names both memories and change history. (`PupaApp`
  `0.0.100`)

## [0.0.10] — 2026-06-06

### Added

- **Inline charts in chat** (#23, Phase 3 of #20): the `embedComponent` tool now
  takes hostKind `"chat"` — it resolves a chart spec to data *now* and drops a
  frozen snapshot into the conversation as its own assistant message, rendered
  by the store-free `ChartView`. The snapshot rides in the tool result, so it
  rebuilds on transcript reload with no extra persistence and never re-resolves
  against a mutated canvas (reproducible / shareable). (`PupaApp` `0.0.98`)

## [0.0.9] — 2026-06-06

### Added

- **Multi-series charts + calculator arrays** (extends #22): a chart now holds
  an ordered list of `series`, overlaid in one plot with a distinct colour +
  legend each (optional `#RRGGBB` override) — multiple lines/bars over a shared
  axis. New series source `calculatorList` plots a calculator **list** row, and
  a new calculator row kind `list` outputs an array: a **sweep** (vary one
  variable across a range holding the others fixed, reading a target each step —
  the payment-vs-rate curve) or a raw tracker column. Tools: `renderChart` /
  `patchChart` take `series:[…]`; `addChartSeries` / `removeChartSeries` edit
  incrementally; `addCalcRows` gains the `list` kind. See
  [docs/components/chart.md](docs/components/chart.md) +
  [docs/components/calculator.md](docs/components/calculator.md). (`PupaApp` `0.0.97`)

## [0.0.8] — 2026-06-06

### Added

- **Chart canvas component** (Phase 2 of #20, via #22): a pie / bar / line
  plot driven by Swift Charts. Its `source` is one of a **tracker** field
  grouped + reduced (sum/avg/min/max/count, with a category filter and an
  optional numeric/date x axis), a list of **calculator rows**, or **inline**
  points. Series resolve live every render via `ChartResolver` (reusing the
  Phase-1 `TrackerAggregator`); the store-free `ChartView(series:kind:)`
  embeds inside a calculator (`inlineChart`) or stands alone. See
  [docs/components/chart.md](docs/components/chart.md). (`PupaApp` `0.0.96`)

## [0.0.7] — 2026-06-06

### Added

- **Calculator canvas component** (Phase 1 of #20, via #21): a live numeric
  shape with three row kinds — tunable **variables** (slider / stepper /
  field), tracker **aggregates** (sum/avg/min/max/count of a numeric field
  with a case-insensitive category filter), and **formulas** over other rows
  by stable `key` (`+ - * / % ^`, fns min/max/abs/round/sqrt/log/exp/pow).
  Results recompute live; cycles and deleted sources degrade gracefully.
  Drives the mortgage-estimate and expense-share scenarios. See
  [docs/components/calculator.md](docs/components/calculator.md). (`PupaApp` `0.0.95`)

## [0.0.6] — 2026-06-06

### Added

- Interactive **Getting started tour**: after first-install onboarding finishes,
  a floating coach card walks you through the live app in nine steps — your
  menu, a Settings overview, Settings · Backend, a MyApp, chatting with your
  agent, switching agents & threads, the orchestrator (with an example "create a
  new myapp" message parked for you), agent settings, and slash commands. It
  programmatically navigates the real surfaces as it goes (no pixel-anchored
  spotlights, so it survives UI redesigns). Back / Next / Skip controls, and the
  card has a grab handle so you can drag it out of the way. It runs once and
  never replays after that. Replay any time from Settings → "Getting started
  tour". Existing users who update are not shown the tour. (`PupaApp` `0.0.94`)

## [0.0.5] — 2026-06-06

### Added

- Chat overlay now has a full-screen expand/restore button (⤢) in the card
  header, next to the close button. Tapping it fills the available view with
  the chat panel; tapping again (or closing) restores the previous size. The
  resize grip is hidden while in full-screen mode. (`PupaApp` `0.0.93`)
- Threads in the conversation dropdown can now be deleted individually without
  switching to them first. When 2+ threads exist each entry becomes a submenu
  with "Open" and "Delete" actions, so any conversation is one extra tap away
  from removal. (`PupaApp` `0.0.93`)

## [0.0.4] — 2026-06-03

### Added

- The chat composer's attachment button now offers "Take Photo" alongside
  "Photo Library", so you can capture an image with the camera without
  leaving the chat. (`PupaApp` `0.0.92`)
- Settings → Agent-to-agent: tune the A2A guardrails — how many conversation
  rounds one agent may have with another, and the maximum agent-call chain
  depth. Changes take effect on the next agent call. (`PupaApp` `0.0.92`)
- Settings → Notifications: lists pending scheduled notifications (from the
  agent's `sendNotification` tool) with their delivery time, and lets you
  cancel one. (`PupaApp` `0.0.92`)

### Changed

- Settings now keeps all tool permissions in one "Tools" submenu (shell-command
  approval + per-tool backend toggles) instead of splitting them across
  separate "Security" and "Developer" sections. (`PupaApp` `0.0.92`)
- The default first-launch example is now the Wellbeing Coach workspace instead
  of Job Search. (`PupaApp` `0.0.92`)
- MyApp rows in the menu start collapsed and only expand when you tap the
  chevron — they no longer auto-open (and no longer re-open when you return from
  a pushed section). (`PupaApp` `0.0.92`)
- Settings → Tools now shows only the global shell-approval toggle; the
  per-MyApp override control was removed from the UI (the underlying per-MyApp
  setting still applies when present). (`PupaApp` `0.0.92`)
- Removed the small Pupa brand icon from the chat panel header to declutter it.
  (`PupaApp` `0.0.92`)

### Fixed

- The Orchestrator landing page icon now uses the same purple as the menu
  row and agent picker, instead of system blue. (`PupaApp` `0.0.92`)
- The Orchestrator footer row blends with the menu's bottom bar (a single
  hairline divider) instead of reading as a raised white card. (`PupaApp`
  `0.0.92`)
- The sidebar info popovers no longer clip their last line of text. (`PupaApp`
  `0.0.92`)
- On iPad (and large iPhones in landscape) the slide-in menu stays a slim
  fixed width instead of covering most of the screen. (`PupaApp` `0.0.92`)
- On iPhone in landscape, the chat composer no longer hides behind the
  keyboard — the floating chat card lifts and shrinks to keep the input
  visible. (`PupaApp` `0.0.92`)
- The slide-in menu's brand header no longer renders under the status-bar
  clock: the panel background still bleeds to the screen edge, but its
  content keeps its safe-area insets. (`PupaApp` `0.0.92`)

## [0.0.3] — 2026-06-02

### Changed

- Conversation threads are now switched from a dropdown in the chat panel
  header instead of a confusing horizontal swipe-pager. The dropdown lists
  every thread (active one checkmarked) and offers "Delete this
  conversation"; the `+` button still starts a new one. (`PupaApp` `0.0.91`)
- Settings is reorganised into drill-down subsections (Backend, Security,
  Examples, Developer): the sheet opens to a category list and each row
  pushes a screen with that category's controls, instead of one long flat
  form. (`PupaApp` `0.0.91`)
- The sidebar's Settings button is larger and easier to hit. (`PupaApp`
  `0.0.91`)
- The Orchestrator collapses into a slim footer row pinned to the bottom of
  the menu (tap the chevron to reveal its memories) instead of a heavy
  separated section, keeping the menu clean. (`PupaApp` `0.0.91`)
- On iOS the menu opens on first launch and then remembers its last
  open/closed state across launches. (`PupaApp` `0.0.91`)

## [0.0.2] — 2026-06-02

### Fixed

- Launch splash no longer lets the app show through (opaque backing
  behind the brand gradient) and now plays as a strict sequence: splash
  fades fully out onto a neutral surface before the onboarding fades in,
  so the splash and onboarding never blend and the app never flashes
  during the handoff. (`PupaApp` `0.0.90`)

## [0.0.1] — 2026-06-01

### Added

- Initial extraction of the Pupa iOS / macOS client into a standalone
  repo. Contains the SwiftUI app (`Pupa/` — `PupaApp` `0.0.89`), the
  standalone AG-UI Swift Package (`AGUIKit/` — `0.0.20`), the Xcode host
  project (`PupaHost/`) used for TestFlight builds, the
  `testflight-release` skill under `.claude/skills/`, and the
  architecture + "adding a new component" docs.

  Internal sub-package versions (in `Pupa/Sources/PupaApp/Version.swift`
  and `AGUIKit/Sources/AGUIKit/Version.swift`) carry forward from the
  monorepo so TestFlight build tracking and AGUIKit consumers keep
  working. Only the **root project version** restarts at `0.0.1` here.
  The backend now lives in its own repo
  ([pupa-app/pupa-backend](https://github.com/pupa-app/pupa-backend)).
