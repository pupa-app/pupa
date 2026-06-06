# Changelog

All notable changes to the Pupa iOS / macOS repo are documented here.
Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) — patch-only bumps (`0.0.X` → `0.0.X+1`).

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
