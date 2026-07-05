# Changelog

All notable changes to the Pupa iOS / macOS repo are documented here.
Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) — patch-only bumps (`0.0.X` → `0.0.X+1`).

## [0.0.54] — 2026-07-05

### Changed

- **iCloud sync reworked to a local-canonical store + background mirror.** The
  local Application Support tree is now always the store of record — the app
  reads and writes it directly and never blocks on iCloud. iCloud became a
  mirror (`StorageMirror`) that converges the two trees off the main thread.

### Fixed

- **Turning iCloud off no longer makes MyApps vanish or strands edits.**
  Previously the storage root switched per launch (iCloud when available, else
  an empty local root), so toggling iCloud off in iOS Settings relaunched the
  app onto the empty root — the app seeded a lone fresh MyApp ("app looks
  lost") and any edits made while off were never synced back. The canonical
  root is now always local, so it can't switch out from under the app. The
  mirror merges **baseline-aware**: ordinary edits propagate, genuine conflicts
  resolve newest-wins with the losing side preserved under `conflicts/` (never
  dropped), and deletes propagate (a delete racing an edit keeps the edit).
  (`PupaApp` `0.0.151`)

## [0.0.53] — 2026-07-05

### Fixed

- **iCloud sync no longer janks the iPhone.** During an initial iCloud
  download `NSMetadataQuery` fires a storm of update notifications; each one
  drove a full store reload on the main thread. The watcher now coalesces the
  storm (suppress query updates + 0.4s debounce → one reload per burst) **and**
  runs each reload's heavy file IO — the whole-tree `NSFileVersion` conflict
  scan and coordinated reads of every MyApp, the memory tree, and settings —
  off the main actor, touching main state only to republish the result. Fixes
  the iPhone-only slowdown / stutter seen with iCloud sync on, where the iPad
  (rarely doing a big initial download) stayed smooth (pupa#110).
  (`PupaApp` `0.0.150`)

## [0.0.52] — 2026-07-03

### Added

- **Share / import all apps in one file.** The Share screen's app dropdown gains
  an **All apps** option that exports every MyApp into a single `.pupaapp`
  *library* bundle; open it (Files picker or tap-to-open) to import them all in
  one go. Same `.pupaapp` extension as a single-app bundle — the two are told
  apart by a header magic.
  Each app runs through the existing per-app import validator, so every guard
  (settings allow-list, memory path checks, slug-unique rename, caps) applies
  per app; a malformed app in a library is skipped with a note rather than
  sinking the rest. (`PupaApp` `0.0.149`)

## [0.0.51] — 2026-07-03

### Added

- **Every new MyApp ships a `/pupa-internals` skill** that orients the agent on
  Pupa's object model (canvas components, memory, skills, `AGENTS.md`) and the
  app(on-device)/backend boundary, so it writes the right thing in the right
  place with the right tool. Seeded at app birth alongside `/to-memory`, and
  loadable on demand via `app_skill_view`. Fully user-editable and deletable
  like any app skill. (`PupaApp` `0.0.148`)

## [0.0.50] — 2026-07-01

### Added

- **Per-thread model.** Each conversation thread can pin its own LLM,
  overriding the agent's default. A compact model dropdown sits beside the
  thread-name selector in the chat header. A pinned thread is independent of
  the general default — changing the default later leaves it untouched; an
  untouched thread follows the default until you pin one. Pick the backend
  default to clear a pin. (`PupaApp` `0.0.146`)
- **Thread IDs in the Agents overview.** Each thread row under Settings →
  Agents → Threads now shows its backend LangGraph `threadId` (monospaced,
  selectable, long-press / right-click to copy) for debugging.
  (`PupaApp` `0.0.147`)

## [0.0.49] — 2026-07-01

### Added

- **Component lock.** A lock icon on top of each canvas component toggles a
  read-only lock. A locked component refuses every mutating operation — its
  in-canvas edit controls are disabled (reads and scrolling still work), and
  mutating agent tools return a clear "locked" result asking the user to
  unlock first. Each frontend tool now declares its read/write intent
  (`ClientTool.readOnly`); enforcement is centralized in `MyAppStore`'s
  mutation backstop, so nothing slips through. The agent can lock/unlock on
  request via `setComponentLocked`. The MyApp **home** page also has a
  lock-all toggle that locks/unlocks every component at once.
  (`PupaApp` `0.0.145`, `AGUIKit` `0.0.22`)

## [0.0.48] — 2026-07-01

### Changed

- **History is now git-style snapshots instead of per-command undo.** Each
  MyApp keeps a diff-chained snapshot timeline (`SnapshotStore`, syncing via
  iCloud like the rest of state); the **History** page lists restore points
  and every older entry has a **Restore** button. Restore is append-only — the
  current state is snapshotted first, so you can always switch back and nothing
  is ever lost. Snapshots are captured on a debounced edit, before a remote
  sync overwrites local changes, and on iCloud conflicts (every side is kept).
  The old per-command Undo (and the agent's `undoChanges` tool) is removed.
  (`PupaApp` `0.0.144`, `AGUIKit` `0.0.21`)

## [0.0.47] — 2026-06-29

### Changed

- **The per-agent model picker always names a concrete model.** The dropdown no
  longer offers a "Backend default" entry — it lists only the backend's real
  models (grouped by provider) plus "Reload models". An agent with no explicit
  override now shows the catalog's primary model (the effective backend default)
  instead of an abstract "Backend default" label; the inherited-model note still
  flags that it isn't an explicit override. (`PupaApp` `0.0.143`)
- **Removed the Agents preview panel from the MyApp and Orchestrator home
  pages.** It duplicated the dedicated **Agents** bottom-bar page and was
  confusing; the home now shows only the Outline and Components. (`PupaApp`
  `0.0.143`)

## [0.0.46] — 2026-06-29

### Fixed

- **The model picker now reflects the backend's full catalog after pairing or
  changing the backend URL — no relaunch required.** The catalog only
  re-fetched `GET /models` on cold launch or when switching to a *different*
  saved backend entry. Editing a backend's URL in place or completing a pairing
  mutates the entry without changing its id, so the picker stayed stuck on the
  static fallback (Anthropic/Bedrock Sonnet only) until the app was force-quit
  — even though the backend served every registered model. The refresh now keys
  on the whole active `BackendEntry`, so URL edits and re-pairs re-fetch
  immediately. (`PupaApp` `0.0.142`)

### Added

- **"Reload models" in the model picker, plus a stale indicator.** A failed
  `/models` fetch previously fell back to the static catalog silently, looking
  identical to "the backend only has these models". The picker now shows a
  spinner while refreshing and an amber warning when the last fetch failed, and
  offers an explicit "Reload models" action to recover in place. (`PupaApp`
  `0.0.142`)

## [0.0.45] — 2026-06-25

### Added

- **Every project now ships with a built-in `/to-memory` skill.** New MyApps
  get `pupa/skills/to-memory/SKILL.md`, a slash command that asks the agent to
  distil durable, app-level learnings from the conversation (conventions,
  preferences, and especially mid-task realignments) into `pupa/MEMORIES.md`.
  The file lives under `pupa/`, so the growing playbook rides the `.pupaapp`
  export bundle. Seeded **once at app birth** (new app, example restore,
  fresh install) rather than every launch — together with example persona
  `AGENTS.md` files — so a user's edits *and deletions* of either stick
  instead of being resurrected on the next launch. (`PupaApp` `0.0.141`)

## [0.0.43] — 2026-06-24

### Fixed

- **Tapping a MyApp in the iOS sidebar lands on the right app every time.**
  Rows relied on `List(selection:)`, which only tap-selects in edit mode on
  iOS, so taps updated the binding unreliably and routed to a stale MyApp. Rows
  now drive selection from an explicit full-row tap. (`PupaApp` `0.0.138`)
- **Bottom-bar Agents / Memories / component tabs no longer bounce back to
  Home on iOS.** Tapping them flashed the page then dropped straight back to the
  canvas: the drawer clears `selection` to nil after each tap, and every MyApp
  page was treated as "resolves to the home", so only Home and History (pushed
  separately) survived. Non-home pages now push onto the navigation stack
  (`SidebarSelection.iOSDetailStack`), like History already did. (`PupaApp`
  `0.0.137`)
- **Switching iOS bottom-bar tabs from a non-home page no longer blanks the
  page.** Once non-home pages were pushed, tapping a tab while already on one
  (e.g. Agents → Memories) flashed the target then landed on a blank page: the
  bottom bar cleared `detailPath` to empty *and* the selection `onChange`
  re-pushed it, two stack mutations across transactions that glitched
  `NavigationStack`. The `onChange` is now the sole stack driver
  (`SidebarSelection.detailStack(picking:from:)`); the bar only sets
  `selection`. (`PupaApp` `0.0.139`)

### Changed

- **Neutral grey base-app chrome; MyApp names no longer coloured.** Base chrome
  (sidebar `+`, footer glyphs, Settings) reads a warm neutral grey (`appBase`,
  themed around `DCDAD6`) instead of system blue. In the sidebar only the MyApp
  icon carries its per-app colour — the name is now default text. (`PupaApp`
  `0.0.138`)
- **Guided tour's closing card opens Settings · Examples.** Instead of a single
  "Add Home Buying" button, the final step deep-links to the Examples list and
  rings it, inviting you to tap Restore on whichever example you like and
  explore it. (`PupaApp` `0.0.136`)

### Removed

- **"Devices on backend" list dropped from Connect backend.** The sheet no
  longer lists/revokes other devices registered with a backend — the route is
  operator-only (needs `PUPA_API_KEY`), so paired-device tokens always got a
  403. Pairing and Unpair (which still revokes this device) are unaffected.
  (`PupaApp` `0.0.135`)

## [0.0.42] — 2026-06-24

### Added

- **Each MyApp page labels itself.** Home, Agents, Memories and History now show
  a small tinted page name above the MyApp name, so it's always clear which page
  you're on. (`PupaApp` `0.0.134`)

### Changed

- **Daily Briefing is the default example.** A fresh install now opens on a
  single Daily Briefing workspace; the guided tour ends with a card that adds a
  second example (Home Buying) to explore, and every example stays restorable
  from Settings → Examples. (`PupaApp` `0.0.134`)
- **Example workspaces drop the "Example:" prefix.** They now read as plain
  names (Daily Briefing, Home Buying, …) in the sidebar and Settings.
  (`PupaApp` `0.0.134`)
- **Guided tour walks the MyApp bottom bar in order.** The tour now steps
  through Home → Agents → Memories → History → Pupa left to right, opening each
  page and ringing the tab as it describes it; the agents & threads step rings
  the chat's agent switcher + thread picker. It then introduces the Orchestrator
  from its menu button before opening it, and points out screen share and
  Import & Export by ringing their sidebar icons. The example chat message types
  itself into the composer with a short lead-in instead of appearing all at
  once. The highlight ring never blocks input — you can tap what it points at —
  and the coach card lifts clear of the bar so it never covers the ring. Reduce
  Motion keeps the ring static and the prefill instant. (`PupaApp` `0.0.134`)

## [0.0.41] — 2026-06-24

### Changed

- **New app icon, and the sidebar drops its brand header.** The iOS drawer
  now opens straight onto MyApps without the redundant "Pupa" header row.
- **Sidebar footer is now three evenly-spaced, centered icons.** Orchestrator,
  screen-share, and Settings render at the same size and tint — Orchestrator
  was a wide tinted text label before. (`PupaApp` `0.0.133`)

### Fixed

- **The footer's Orchestrator and Screen-share buttons now open their pages on
  iOS.** They set a selection with no active-MyApp fallback, so once the drawer
  cleared the selection after a tap they dropped back to the active MyApp's
  canvas. Selections without a MyApp now push onto the navigation stack.
  (`PupaApp` `0.0.133`)

## [0.0.40] — 2026-06-24

### Fixed

- **Re-tapping a MyApp in the iOS drawer now reopens it.** A selected MyApp row
  stayed highlighted after navigating back, and tapping it again did nothing —
  you had to pick a different app first. The drawer's `List(selection:)` never
  reset, so SwiftUI swallowed the identical re-tap. Selection now clears after
  each tap. (`PupaApp` `0.0.132`)

## [0.0.39] — 2026-06-24

### Added

- **Per-agent model + tool overrides, glanceable on the Agents page.** Each
  agent row now shows its model and tool count at a glance, without opening the
  detail page. Inside, the tool surface is editable: toggle any tool off to hide
  it from that agent only (unioned with the global Settings → Tools set and sent
  as `disabled_tools` per turn). Fixes a gap where a sub-agent's stored model was
  never forwarded — Slack/orchestrated sub-runs now run on their configured
  model instead of the backend default. (`PupaApp` `0.0.131`)

## [0.0.38] — 2026-06-24

### Added

- **Account screen in Settings.** A new read-only **Account** row at the top of
  the Settings sheet shows iCloud sync status, this device, a data overview
  (MyApps / memories / backends) and the app version. Honest by design: Pupa has
  no login of its own, so there's no editable name, email or device list — only
  what iCloud and the app actually know. (`PupaApp` `0.0.130`)

## [0.0.37] — 2026-06-24

### Changed

- **Agent pages keep the bottom bar; History is now a full page.** The bottom
  bar gains a dedicated **Agents** tab (order: Home · Agents · Memories ·
  History · chat · ⋯), so agent pages show the bar instead of reverting to the
  old floating chat bubble. History opens as a pushed page with a back button
  instead of a slide-up sheet, consistent with the rest of the app.
  (`PupaApp` `0.0.129`)

## [0.0.36] — 2026-06-24

### Changed

- **Agent name moves to the chat card's top bar.** The agent selector now sits
  on the card's top row next to the resize / expand / close controls — reading
  as the card title — while the conversation (thread) dropdown and its `+` stay
  on the row below. (`PupaApp` `0.0.128`)

## [0.0.35] — 2026-06-23

### Changed

- **Chat card floats above the bottom bar.** The floating chat overlay now
  reserves the per-MyApp bottom bar's height, so the card and composer always
  sit above the bar — collapsed, resized, and fullscreen — instead of covering
  it. The bottom bar is also a touch thinner. (`PupaApp` `0.0.127`)

## [0.0.34] — 2026-06-23

### Added

- **Component-kind menu in every agent turn.** The agent now sees a short
  capability line per supported component kind (e.g. `calculator — live
  numeric model…`) before any component of that kind exists, so it knows it
  can grow a MyApp into a calculator/chart/etc. Previously the rich per-kind
  guidance only appeared once a component of that kind was already on the
  canvas. (`PupaApp` `0.0.126`)

## [0.0.33] — 2026-06-23

### Added

- **Delete a component** from a MyApp home: long-press a component tile and
  pick "Delete" (with a confirm). The last component can't be removed — a
  MyApp always keeps at least one. (`PupaApp` `0.0.125`)

## [0.0.32] — 2026-06-23

### Added

- **iCloud sync across your devices.** MyApps, memories, and settings now
  follow your Apple ID — create a tracker on iPhone, see it on Mac. Data
  lives in the app's iCloud container when available and falls back to local
  storage when iCloud is off (no change in behaviour there). Chat history was
  already shared by the backend; device tokens stay on-device in the Keychain.
  Edits on one device appear live on the others. (`PupaApp` `0.0.124`)
- Storage moved from monolithic `UserDefaults` blobs to **per-file** state
  (one file per MyApp; memories already per-file), so only what changed syncs
  — minimal traffic, and a foundation for per-app snapshots. Clean break:
  existing local data is not migrated. Enabling iCloud requires the
  CloudDocuments capability (see `PupaHost/Config.xcconfig`). (`PupaApp`
  `0.0.124`)

## [0.0.31] — 2026-06-23

### Changed

- **Restructured navigation.** The sidebar now lists MyApps as compact,
  non-expanding rows (tap → home); the **Orchestrator** moved into the sidebar
  footer next to **Screen share** and **Settings**. Each MyApp's home is leaner
  — **Outline** (the agent-written summaries), a **Components** grid (tap a tile
  to open it, "Add" picks a kind and creates one, right-click a tile to rename /
  change its icon), and **Agents** — with Memories and History moved onto a new
  **persistent bottom bar** per MyApp: Home · Memories · History · Pupa (chat) ·
  ⋯ (jump to any component). The chat launcher now lives in that bar on MyApp
  pages; on other pages (orchestrator, agents, screen share) it stays a floating
  pupa circle so chat is always reachable. (`PupaApp` `0.0.122`)
- **Orchestrator uses the MyApp home layout + bottom bar.** Opening the
  Orchestrator now shows the same page style as a myapp — an **Outline**
  describing what it coordinates plus the myapps it can drive, an empty
  **Components** panel, and its **Agent** — and the same persistent bottom bar
  (Home · Memories · Pupa chat · ⋯ jump-to-myapp; History is myapp-only). The
  Memories browser is the same view, reused for both scopes. Replaces the
  bespoke orchestrator page. (`PupaApp` `0.0.123`)

## [0.0.30] — 2026-06-22

### Added

- **Chat status badges on the pupa circle + thread lists.** The collapsed
  chat circle and the thread dropdown / Agents dashboard now badge a
  conversation that needs attention: an **amber** exclamation when a run is
  blocked on you (approve a bash command / answer a question), **red** when
  it errored, and a **blue** exclamation when it finished answering but you
  haven't viewed it yet. A live run still shows a spinner. The badge clears
  for whichever thread is on screen. Highest-priority state wins:
  action-required > error > unviewed > running. (`PupaApp` `0.0.121`)

## [0.0.29] — 2026-06-21

### Fixed

- **Opening a MyApp lands on its home page.** Importing a `.pupaapp`
  (in-app, externally-opened, or via the export sheet) and restoring an
  example now route to the MyApp home overview instead of dropping
  straight onto a component canvas — matching the sidebar menu, which
  already opened home. (`PupaApp` `0.0.120`)

### Added

- **"Working…" spinner while the model is generating.** The chat
  transcript shows a small spinner whenever the model is running and no
  tool-round spinner is up; the tool-round spinner replaces it once a tool
  batch starts. Gives a clear signal the agent is active before the first
  token or between tool rounds. (`PupaApp` `0.0.120`)

## [0.0.28] — 2026-06-21

### Added

- **Skills + the per-MyApp `pupa/` config folder.** Each MyApp's driving
  config now lives in a visible `pupa/` folder in its memory tree:
  `pupa/AGENTS.md` (main agent), `pupa/agents/<sub>/AGENTS.md` (subagents),
  and `pupa/skills/<name>/SKILL.md`. A **skill** is a
  Claude-Code-style markdown playbook auto-discovered for every agent in the
  MyApp: palette-visible skills become `/<name>` chat commands (the bubble
  shows `/<name> args`, the agent receives the rendered body), and
  model-visible skills are listed in context by name + `when_to_use` so the
  agent can load one on demand via the new `app_skill_view` tool (progressive
  disclosure). Memory writes now accept `.json` alongside `.md`; other
  extensions stay rejected (import threat surface). **Breaking:** config moved
  to `pupa/` with no migration — reset an existing workspace's memories to
  clear pre-`pupa/` files. Skills + subagent prompts ride the `.pupaapp`
  bundle and survive a
  memories-off export. Closes #8 (skills parity, markdown-first) and #58
  (symmetric frontend `app_skill_view`). See [docs/skills.md](docs/skills.md).
  (`PupaApp` `0.0.119`)

## [0.0.27] — 2026-06-20

### Fixed

- **Shell-approval / question interrupts no longer get silently orphaned.**
  While the agent is parked on a `request_shell_approval` (or
  `ask_user_questions`) card, the turn is still in flight, so `isStreaming`
  stayed true — which made the composer's primary button a **Stop** button.
  Tapping it routed into `cancel()`, which tore down the session task before
  the resume POST could fire: the backend interrupt was left parked forever
  and the next message landed as a fresh run that silently dropped the
  approved command (the "agent stopped silently" report). Now the composer
  suppresses its Stop affordance while an interrupt is pending (new
  `isAwaitingHumanInput`); resolution flows only through the card's
  Approve / Deny / Submit. And `cancel()` while parked resolves the interrupt
  (deny / empty answers) and keeps the turn alive so the live loop delivers
  the resume, instead of orphaning it. Regression test drives the real
  `ChatViewModel` loop against a mock backend. (`PupaApp` `0.0.118`)

## [0.0.26] — 2026-06-20

### Changed

- **Model picker reads the live backend catalog.** Agent model pickers
  (orchestrator, MyApp main agents, Slack sub-agents) now list whatever the
  backend has registered, fetched from `GET /models` into a new
  `ModelCatalogStore` on launch and whenever the active backend changes.
  The static `KnownLLMModelCatalog` is now only the offline fallback
  (backend unreachable, old backend, not paired). (`PupaApp` `0.0.117`)

## [0.0.25] — 2026-06-19

### Added

- **Settings → Agents.** A new app-wide overview organised as nested
  dropdowns: each MyApp expands to its agents (main agent + Slack
  personas), each agent expands to its own lifetime stats (delegations
  made, invocations received, conversations, last active). The
  orchestrator is a top-level agent dropdown. A second section lists
  conversation threads grouped by agent (tap to make current, swipe to
  delete). Stats are backed by a new
  schema-free `AgentStatsStore` (a flat `[agentKey: counters]` bag keyed by
  `AgentInvocationKey.statKey`), bumped at the single `AgentInvocationGate`
  chokepoint every nested agent run funnels through — so it stays correct
  as agent types grow. (`PupaApp` `0.0.116`)

## [0.0.24] — 2026-06-19

### Changed

- **Bottom dock memories cleaned up.** The dock no longer scatters one icon
  per top-level note (each opening a flat file like AGENTS.md). Instead Home
  and a single **Memories** button (the `brain` glyph) now sit together behind
  the hairline, after the component icons. Memories opens a new browse page
  (`MyAppMemoriesView`) showing the app's full note tree — folders drill in,
  files open in place. The dock also reserves trailing space for the floating
  chat launcher so its right-most icon is no longer hidden behind it.
  (`PupaApp` `0.0.115`)

## [0.0.23] — 2026-06-19

### Fixed

- **Tap a `.pupaapp` to open it in Pupa — from Files, and from chat apps.**
  Tapping a bundle in Files used to show a generic preview, and one received
  over WhatsApp opened as raw JSON; both forced a Save-to-Files /
  Share-to-Pupa detour. The file type now declares
  `LSSupportsOpeningDocumentsInPlace=YES` (so Files routes a tap straight to
  Pupa's import sheet) and drops its `application/json` MIME tag (so chat apps
  stop previewing the JSON and instead surface "Open in Pupa"). No import-logic
  change. (`PupaApp` `0.0.114`)

## [0.0.22] — 2026-06-18

### Added

- **Memory notes are linkable, and reachable from the dock.** The agent can
  drop a tappable link to any note in chat — written as
  `[title](pupa://memory/<path>)` — and tapping it opens the note in the
  detail pane (Back returns you to the chat). Links are scope-relative: the
  agent uses the same note path it already reads and writes, and the app
  binds it to the current app or the orchestrator. A myApp's top-level notes
  now also appear as shortcuts in the bottom dock, beside Home and the
  component icons. (`PupaApp` `0.0.113`)
- **Rename and re-icon a component without losing its data.** Components keep
  a permanent `id` but their name, icon, and LLM-facing description are now
  editable in place — via a new `setComponentMeta` agent tool and a sidebar
  **Rename / icon…** menu (name field, SF Symbol field with a live preview,
  and a quick-pick glyph grid). The agent no longer deletes and re-adds a
  component to relabel it. No bundle-format change — existing `.pupaapp`
  apps are unaffected. (`PupaApp` `0.0.113`)

## [0.0.21] — 2026-06-18

### Added

- **Share an exported app, and open `.pupaapp` files to import.** Export is now
  a **Share…** action — send a MyApp over AirDrop, Messages, WhatsApp, Mail, or
  Save to Files. `.pupaapp` is a registered, Pupa-owned file type, so opening a
  shared bundle on another device (Files, Mail, a chat app) launches Pupa and
  offers to import it after a confirm step that names the app and lists the
  agent prompts it carries. Import & Export is split into two focused
  screens — **Share an app** and **Import an app** — instead of one mixed
  page. (`PupaApp` `0.0.112`)

## [0.0.20] — 2026-06-17

### Changed

- **Chat panel polish.** Message bubbles are now selectable on every platform
  (was iOS-only) and gain a right-click / long-press **Copy** for the whole
  bubble. The composer is a floating, translucent rounded pill over the message
  list — the chat uses the full height and messages fade as they scroll behind
  it. Fullscreen now fills the pane edge-to-edge (no inset gap, flush corners).
  Header `+`, expand, close, paperclip, and send controls are ~15% larger.
  (`PupaApp` `0.0.110`)

### Fixed

- **The iOS bottom app dock no longer blocks page scrolling.** While the dock
  was revealed it laid a full-pane invisible scrim that caught every touch, so
  the page behind could only be tapped (to dismiss the dock), never scrolled.
  The scrim is gone — the page stays fully interactive. Scrolling now dismisses
  the dock, and the 5s inactivity fade still applies. When an app has more
  component icons than fit the width, the dock row scrolls horizontally instead
  of overflowing the screen edges. (`PupaApp` `0.0.110`)
- **iOS attach menu no longer shoves the chat card up.** The paperclip used a
  `Menu` anchored at the card's bottom edge, so the system lifted the whole
  bottom-anchored card to fit the popup. It's now a bottom action sheet
  (`confirmationDialog`) that slides over without moving the card.

## [0.0.19] — 2026-06-16

### Fixed

- **macOS demo (`make mac-demo`) no longer launches with an empty sidebar.**
  `NavigationSplitView`'s sidebar does not render in the unbundled `swift run`
  PupaDemo binary — the column came up blank. `AppView` now hosts the macOS
  layout as a fixed-width `HStack` split (sidebar · `Divider` · detail); the
  macOS sidebar uses a single merged `List` (MyApps + Orchestrator). iOS is
  unaffected — it uses its own slide-in drawer. (`PupaApp` `0.0.109`)
- **macOS detail panes no longer look dimmed.** `Color.canvasBackground` used
  `underPageBackgroundColor` (a dark ~50% grey meant to sit behind pages); it
  now resolves to a soft adaptive grey just below the card surface, mirroring
  iOS `secondarySystemBackground`. macOS only.

## [0.0.18] — 2026-06-15

### Fixed

- **Settings ▸ Tools no longer hangs on "Loading backend tools…"**: the tool
  list is fetched into state owned by the Tools screen itself instead of the
  parent Settings sheet. Pushed via `navigationDestination`, the detail screen
  did not reliably re-observe the parent's `@State`, so a completed fetch left
  the spinner up. The screen now loads on appear and on backend switch.
  (`PupaApp` `0.0.108`)

## [0.0.17] — 2026-06-15

### Changed

- **Tool-gate tools renamed `get_skill_*` → `get_tools_*`**. The gates that
  unlock a component kind's tools (plus `get_tools_memories` /
  `get_tools_notifications`) were misnamed "skills" — they gate tools, not
  skills. Internal `SkillState` → `ToolGateState`, `registerSkillGateTools` →
  `registerToolGates`, and the "Skill Gates" tool group label → "Tool Gates".
  No persistence migration: gate state is per-session, reset on New session.

## [0.0.16] — 2026-06-13

### Added

- **Two grounded templates**: **Research Tracker** (competitive-intel
  watchlist + weekly findings log + signal-trend chart + deltas calculator +
  Scout/Analyst/Digest room) and **Daily Briefing** (MCP-named sources +
  today's briefing + feed-volume chart + 7am push). Both seeded in
  `ExampleRegistry`, exportable as `.pupaapp`, with a self-maintaining agent
  loop in their `AGENTS.md`.
- **Template realism bar** ([docs/templates.md](docs/templates.md)): the
  rubric for building a `.pupaapp` that reads like a real app, a grounded
  reference index, and the "keep yourself updated" memory/skills convention.

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
