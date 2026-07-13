# Architecture

Snapshot of how the iOS / macOS client is wired right now. Read this
before changing canvas shapes, tools, state, or persistence.

## Two packages

```
AGUIKit/   ← AG-UI client library. No dependency on Pupa.
Pupa/      ← the app. Depends on ../AGUIKit (local SPM path).
PupaHost/  ← Xcode app project hosting PupaApp for iOS / macOS + TestFlight.
```

`AGUIKit` is the transport + protocol layer: it speaks AG-UI to the
backend, owns a tool registry, and runs the multi-round agent loop.
`Pupa` (the `PupaApp` library target) is everything app-specific:
SwiftUI views, `@Observable` state stores, and the registered tool
handlers.

## AGUIKit — the AG-UI client

[`AGUIKit/Sources/AGUIKit/`](../AGUIKit/Sources/AGUIKit/):

- **[`AgentClient.swift`](../AGUIKit/Sources/AGUIKit/AgentClient.swift)**
  — POSTs `RunAgentInput` to the backend and returns an SSE byte stream.
  Carries `extraHeaders` (used for the `Authorization: Bearer <token>`
  pair-once header).
- **[`AgentSession.swift`](../AGUIKit/Sources/AGUIKit/AgentSession.swift)**
  — the multi-round loop. `send(_:forwardedProps:toolFilter:)` runs a
  turn: stream events, dispatch tool calls to the `ToolRegistry`, append
  results, and re-POST until the model stops. `forwardedProps` (e.g. the
  per-turn `llm = {provider, model}` selection) is captured at send time
  and re-applied on every round, including resume rounds after a frontend
  interrupt. A computed frontend-tool dispatch **always** gets its resume
  POST — even when the runaway round cap (`maxRounds`, from
  `SettingsStore.effectiveMaxToolRounds`: `maxToolRounds` default 24, range
  4–64, or `nil` when the "No limit" toggle is on; every tool round-trip
  consumes one) is hit mid-interrupt — so the backend session is never left
  parked. `nil` removes the breaker: the turn runs until the backend settles. The loop settles with
  `.completed(CompletionOutcome)`: `.produced` when the turn emitted
  assistant text, else `.silent(reason)` (`emptyTurn` / `maxRounds` /
  `droppedStream` / `droppedInterrupt` / `backend`) so the UI can flag a turn
  that ended with no reply instead of silently dropping the spinner.
  `ChatViewModel` renders a `.system` notice bubble for `.silent`.
  **Dropped-interrupt self-heal:** if a round settles with a registered
  frontend tool observed but no `on_interrupt` to drive it (the upstream
  `ag-ui-langgraph` `tasks[0]` emit bug — an interrupt parked on a non-first
  task is dropped in-run), the loop re-POSTs a resume-less continuation to
  trigger the backend's recovery path (which re-emits the parked interrupt),
  bounded to 2 retries before settling `.droppedInterrupt`.
- **[`ToolRegistry.swift`](../AGUIKit/Sources/AGUIKit/ToolRegistry.swift)**
  / **[`Tool.swift`](../AGUIKit/Sources/AGUIKit/Tool.swift)** — host
  registers `@Sendable async` handlers keyed by tool name; their
  JSON-Schema definitions are forwarded to the model on each request.
  **Frontend tools** (in the registry) are executed locally; **backend
  tools** (not in the registry, e.g. `tavily_search`) run server-side and
  the session must NOT fabricate a `ToolMessage` for them (doing so
  caused a duplicate-tool-call spiral fixed in AGUIKit `0.0.9`; see the
  `AgentSessionTests` regression tests if it reappears).
- **[`Events.swift`](../AGUIKit/Sources/AGUIKit/Events.swift)** /
  **[`SSEDecoder.swift`](../AGUIKit/Sources/AGUIKit/SSEDecoder.swift)** /
  **[`Messages.swift`](../AGUIKit/Sources/AGUIKit/Messages.swift)** —
  typed AG-UI event + message model and the SSE line decoder.

## App shape (PupaApp)

[`Pupa/Sources/PupaApp/`](../Pupa/Sources/PupaApp/), grouped by area:

| Area | What it owns |
|---|---|
| [`App/`](../Pupa/Sources/PupaApp/App/) | `RootView` (launch coordinator), `SplashView`, first-install onboarding (`OnboardingFlowView` + slides), `AppView` (root split view), `PupaApp` scene, app icon. |
| [`MyApps/`](../Pupa/Sources/PupaApp/MyApps/) | `MyApp` model + `MyAppStore` (the single mutation surface), `MyAppType` (kind registry), example apps, `ItemEventLog` (change feed captioning History). |
| [`Canvas/`](../Pupa/Sources/PupaApp/Canvas/) | `CanvasState` + the per-shape SwiftUI views (`TrackerView`, `CalendarView`, `ChecklistView`, `KanbanView`, `SlackView`) and the cross-component link picker. |
| [`Chat/`](../Pupa/Sources/PupaApp/Chat/) | `ChatViewModel`, `ChatSessionCoordinator` (drives `AgentSession`), `ChatPanel` + thread-selector dropdown (`ConversationPager`), slash commands, transcript mapping. The composer attaches up to `ChatViewModel.maxImagesPerMessage` images — from the photo library (multi-select), the camera (`CameraPicker`, iOS), or drag-and-drop — each funnelled through `ImagePreparer` into a `PickedImage` and sent as its own AG-UI image part. |
| [`Tools/`](../Pupa/Sources/PupaApp/Tools/) | `AppTools.swift` — registers every frontend tool against the `ToolRegistry`. |
| [`Memory/`](../Pupa/Sources/PupaApp/Memory/) | `MemoryStore` — sandboxed markdown filesystem. |
| [`Agents/`](../Pupa/Sources/PupaApp/Agents/) | Per-agent policies, the agent overview/detail pages, `ModelCatalogStore` (live per-harness model list + tool/permission schema from `GET /harnesses`; no offline fallback). |
| [`Slack/`](../Pupa/Sources/PupaApp/Slack/) | `SlackInvoker` — multi-agent room invocation policy. |
| [`ScreenShare/`](../Pupa/Sources/PupaApp/ScreenShare/) | WebRTC viewer + signalling client for the backend's `/screenshare/ws` broker. |
| [`Settings/`](../Pupa/Sources/PupaApp/Settings/) | `SettingsStore` (backend URL, API key, disabled tools), backend-tools client. |

`AppView` lays this out as a fixed-width `HStack` split (sidebar `Divider`
detail) on macOS and a custom slide-in drawer on iOS. (macOS deliberately
avoids `NavigationSplitView`: its sidebar fails to render in the unbundled
`swift run` PupaDemo binary, leaving an empty column.) The sidebar lists the
**visible** (non-archived) MyApps as compact, **non-expanding** rows (tap a row
→ its home; components, memories, and history are reached from the MyApp home +
its bottom bar, not the sidebar); a footer menu holds the global
**Orchestrator**, the **Screen share** viewer, and **Settings**. A row's
long-press menu offers Rename · **Archive** · Delete.

**Archiving** hides an app: `MyApp.isArchived` (per-app flag, round-tripped
through `persist()`/`load()`) drops it from `MyAppStore.visibleMyApps` — the
sidebar, the Orchestrator's "can orchestrate" list, and the agent-facing
`listMyApps` tool all read that filtered list, so an archived app is
sidebar-hidden **and** agent-off. Archiving also locks all its components
(read-only) via `setAllComponentsLocked`; unarchiving un-hides it but leaves
the lock on. Archived apps are browsed/restored/deleted from **Settings →
Archive** (`ArchivedAppsView`). Memories are keyed on the app slug and untouched
— they ride along, hidden with the app and back on restore. The Orchestrator opens the same home layout as a
MyApp (`MyAppHomeView` with `subject: .orchestrator`) — an Outline explaining
what it coordinates plus the myapps it can drive, and an empty Components panel
— plus the same bottom bar (Home · Agents · Memories · Pupa · ⋯), rather than a
bespoke page. Both homes leave agents to the **Agents** bottom-bar page; the
home itself only shows the Outline + Components. The drawer fills most of a compact
(iPhone-portrait) screen but stays a slim fixed width on a regular width class
(iPad, large iPhone landscape). Drawer + scrim are **always mounted** (like the
keep-alive detail panes): open/close slides by `.offset` under a single scoped
`.snappy(0.25)` animation — cold-constructing the sidebar `List` inside the tap
transaction measured ~90–135ms tap→frame warm (and ~1.1s on first open) and made
the hamburger feel slow next to the animation-free page switches.

The chat lives in a user-resizable `ChatOverlay` card anchored bottom-trailing
of the detail pane. Its launcher lives in the per-MyApp bottom bar (below); on
pages without that bar (screen share, settings) `ChatOverlay` shows
its own fallback pupa circle so chat stays reachable everywhere. On iOS the card
does its own keyboard avoidance (it tracks the keyboard height and lifts/shrinks
the card) so the composer stays visible above the keyboard in any orientation.
The bottom bar's `.safeAreaInset` is applied to the ZStack enclosing **both** the
detail `NavigationStack` and `ChatOverlay`, so it reserves space for the page
content and lifts the floating card above the bar for free — collapsed, resized,
and full-screen — instead of letting the card cover it. A full-screen
expand/restore button (⤢) in the card header fills the detail pane edge-to-edge
(no inset, flush corners; still above the bar); the resize grip is hidden while
full-screen is active.

The composer is a floating, translucent rounded pill overlaid on the bottom of
the message `ScrollView` (not a layout row), so the message list uses the full
card height; the ScrollView carries a bottom alpha-gradient `mask` so messages
fade into the card material as they scroll behind the pill. Message bubbles are
selectable on every platform and expose a **Copy** context-menu action
(`ChatClipboard`, right-click on macOS / long-press on iOS) that copies the
whole bubble.

**Queued messages while busy.** The composer stays typable while a turn is in
flight. Submitting mid-stream doesn't wait or drop — `ChatViewModel.send`
appends the text to `queuedMessages` (FIFO) instead of starting a run. Queued
items render as clock-marked pills above the composer; each can be cancelled
(✕) or tapped to pull back into the composer for editing. When the current turn
settles cleanly (`consume` → `drainQueue`), the *whole* queue is coalesced
(`coalesceQueue`) into one fresh run — texts joined in FIFO order, every
attached image carried in order (capped at `maxImagesPerMessage`) — so a burst
of messages costs one turn, not one turn each, and it stays a single AG-UI user
message. Draining is skipped after an
error (the failure stays on screen; the user decides whether to retry) and on
an explicit **Stop** (`cancel` Case B) / `newThread`, which discard the queue.
While a turn is parked on a human-in-the-loop interrupt the composer is gated,
so nothing queues until the interrupt resolves and the turn fully settles. The
send button is **Stop** only when streaming with an empty composer; with text
typed mid-stream it's an arrow-up that queues.

On a myApp's home / component / memories / agents / history pages — and the
orchestrator's home / memories / agent pages — the detail pane hosts a persistent
**bottom bar** (`MyApps/MyAppBottomBar.swift`) — the per-subject "tab bar",
mounted via `.safeAreaInset(edge: .bottom)` so the page content insets above it
instead of hiding under a floating overlay. It's keyed by `MyAppHomeView.Subject`
(`.myApp(id)` / `.orchestrator`). Left to right: **Home** (`house`), **Agents**
(`person.2`, opens `AgentsListView` / `AgentDetailView`), **Memories**
(`brain`, opens `MyAppMemoriesView` — a browse page of the subject's note tree;
folders drill in, files push `.myAppMemoryFile` / `.memoryFile`. Direct editing
without the agent: the header `+` menu adds a Note / Folder at the scope root; a
folder row's long-press menu adds inside it; any row can be renamed / moved or
deleted. Rows funnel these through `MemoryRowActions` into the shared
`MemorySheet` shells (`New*MemorySheet` / `RenameMemorySheet`) and a delete
confirmation over `MemoryStore`), **History**
(`clock`, pushes `ChangeHistoryView` via `.myAppHistory` — **myApp only**; the
orchestrator has no canvas change-log so it omits this), the **Pupa** chat launcher (toggles
`AppView.chatOpen`, carrying the scope's `StatusBadge`), and a **⋯** menu that
jumps to any component (myApp) or any myapp (orchestrator). Glyphs are tinted the
subject's color (a myApp's creation-order index via
`MyAppStore.colorIndex(for:)`; `orchestratorColor` for the orchestrator), the
current page highlighted; the pupa keeps its own look. Every page these reach
shares a `MyAppPageHeader` (`MyApps/MyAppPageHeader.swift`): a tinted page-name
eyebrow (Home / Agents / Memories / History) above the subject's icon + name, so
the active page is always self-labelling. `AppView` gates the bar
via `barSubject` + `barPage`; taps call `setRoot`, the single entry point for
top-level navigation: it swaps `rootPage` (the `NavigationStack` root) in place
with animations disabled, clears drill-in pushes from `detailPath`, and runs
`dispatchSelection`. The subject's tab pages (home / agents / memories / the
active component canvas) stay mounted in a `ZStack` and switch by opacity
(`DetailPane`, `Equatable` so hidden panes skip body re-evaluation) — measured
~3× faster click→frame than rebuilding the page tree per tap. `selection` is
only the sidebar's row highlight + tap signal (iOS clears it to nil after each
tap so re-taps re-fire); navigation state lives in `rootPage` + `detailPath`.
Because the bar owns the
chat launcher on these pages, `ChatOverlay` hides its fallback circle there
(`launcherVisible`). `MyAppMemoriesView` + `MemoryLandingRow` are
subject-generalized (a path→selection closure), so one browse view + row serve
both scopes. `MyAppMemoriesView` reloads the store from disk on appear
(`.task(id: subject)` → `MemoryStore.reloadFromDisk`), so folders written after
the launch scan (bootstrap `pupa/`, template seeding, an iCloud pull) show
without waiting for a mutation or the cloud watcher; `AppView` also does one
converge+reload at launch for the same reason.

**In-app links (`pupa://`).** The agent can embed tappable navigation links in
chat markdown (and note bodies); `Chat/ChatLink.swift` maps a `pupa://` URL to a
`SidebarSelection` and `AppView.chatLinkAction` (an `OpenURLAction` installed on
the detail `NavigationStack`, `ChatOverlay`, and `CanvasView` — the last so
`pupa://memory/…` values in tracker `.link` fields route in-app) pushes it onto
`detailPath` — real `http(s)` URLs fall through to the browser. The agent writes
**scope-relative** paths — `pupa://memory/<path>` is the same note path it
reads/writes, bound to the current chat scope (a myApp → `.myAppMemoryFile`, the
orchestrator → `.memoryFile`). But `SidebarSelection` memory paths are
**global-root-relative** — the space the shared `memory` store, browse, and
agent-prompt links all use — so `chatLinkAction` calls
`SidebarSelection.globalizedMemoryPath` to prefix the scope folder (the myApp
slug, or `orchestrator/`) before routing; otherwise the target note can't be
read. `pupa://component/<id>` targets the current myApp; the explicit
`pupa://myapp/<uuid>/memory/<path>` form is for cross-scope links. Distinct from
Slack's `pupa-mention://` and the `.pupa` file type.

The card header is split across two rows. The **agent selector** (`AgentDropdown`)
sits in the card's top bar — alongside the resize / expand / close controls — so
the active agent's name and colour read as the card title; switching agents calls
`onSwitchAgent`. The **conversation dropdown** (`ChatPanel.threadDropdown`) plus
its `+` (new thread) stay one row below, inside `ChatPanel`. The thread dropdown
lists threads newest-first. When 2+ threads exist each entry is a submenu with
"Open" and "Delete" so any thread can be deleted without switching to it first.

**Status badges.** `ChatActivityStatus` (`Chat/ChatActivityStatus.swift`) is a
per-thread state derived live from each `ChatViewModel`: `actionRequired`
(parked on a shell-approval / question interrupt) > `error` (`lastError`) >
`unviewedAnswer` (a turn settled while the thread was off-screen) > `running` >
`idle`. The VM tracks `hasUnviewedCompletion` (set when a real turn settles in
`setStreaming`, cleared by `markViewed()` whenever a `ChatPanel` for that thread
is on screen). `ChatSessionCoordinator.status(for:threadId:)` exposes one
thread's status and `aggregateStatus(for:)` folds a scope's threads to the
highest. The shared `StatusBadge` view renders an amber / red / blue
exclamation (or a spinner while `running`) on the bottom bar's **Pupa** button
(and `ChatOverlay`'s fallback circle on pages without the bar) — scope
aggregate, upgraded to `running` when `busyMyApps` covers the scope — plus the
thread dropdown rows + label and the Agents dashboard thread rows.

## Launch sequence

`RootView` is the scene root (`PupaApp`, demo, host all mount it). It owns
the shared `SettingsStore` and drives a strict two-phase launch: `SplashView`
plays on every cold launch and fully fades out *before* the next surface fades
in — so splash and onboarding never blend. On first install (`OnboardingKeys`
absent) `OnboardingFlowView` runs a value carousel + a backend-pairing step
that reuses the production `BackendEditSheet` against the same `SettingsStore`
the app reads; existing users skip straight to `AppView`. Skipping pairing
sets a flag that surfaces a dismissible "connect your backend" banner in
`AppView`; finishing while paired parks a suggested first message
(`OnboardingHandoff`) that the first `ChatPanel` consumes.

### Guided tour

Once onboarding finishes, an **interactive guided tour** runs once
(`App/GuidedTour.swift` + `App/GuidedTourOverlay.swift`). A floating *coach
card* explains each step while the tour programmatically navigates the **real**
app to that surface — fifteen steps: welcome (opens the sidebar menu), Settings
overview (the category list), Settings · Backend (deep-linked), then the MyApp
bottom bar walked left to right — Home, Agents, Memories, History — followed by
chat, agents & threads, the Orchestrator introduced from its sidebar-menu button
then opened (prefilled "create a new myapp"), slash commands, screen share (rings
its sidebar button), Share a MyApp (rings the Settings button — Import & Export
lives inside), and a closing "add an example" card that deep-links to
Settings · Examples (`settingsPage: .examples`) and rings the example list
(`highlight: .settingsExamples`), so the user taps **Restore** on whichever
example they like to drop a workspace in to explore. It is
**route-driven, not pixel-anchored**, so it survives UI redesigns: a shared
`@Observable GuidedTourStore.shared` (mirroring `OnboardingHandoff.shared`)
holds the step list (`TourContent`, pure data) + current index. Each `TourStep`
carries **composable, independent intents** (a step may navigate *and* open the
chat with a prefill) — `selection`, `opensSidebar`, `settingsPage`, `opensChat`,
`chatPrefill`, `highlight` — that target the stable routing layer, never
geometry.
`AppView.applyTourStep()` reconciles them: it routes the step's selection
through `setRoot` (so the chat scope follows), opens the sidebar, and
writes the store's intent flags (`wantSettingsOpen` / `wantSettingsPage` /
`wantChatOpen` / `chatPrefill` / `wantHighlight`). Host views then mirror those
declaratively:
`MyAppSidebarView` drives the Settings sheet, `SettingsSheet` deep-links its
`NavigationStack` path, `ChatOverlay` expands/collapses to match `wantChatOpen`,
and `ChatPanel` adopts `chatPrefill` (including "/" to surface the
`SlashCommandPalette`). A tour chat prefill is **typed in** — `ChatPanel`
streams it character by character after a short lead-in (instant under Reduce
Motion or for single-char "/"). `wantHighlight` names a control
(`TourHighlight`: a bottom-bar tab, the chat header, or a sidebar-footer action);
`TourHighlight.swift` provides a `.tourAnchor` preference those views publish
(several views may share a role — the chat header rings the agent + thread
pickers as one union) and a `TourHighlightOverlay` glow ring drawn by the
`tourHighlightLayer` modifier `AppView` applies once per platform body, above the
sidebar + canvas and under the coach card. This is the tour's one use of view
geometry, but it's resolved through preferences at render time (not pixel-pinned)
and sits behind `.allowsHitTesting(false)`, so it tracks layout changes and never
blocks the control it points at. The card is gated on
`tour.isActive` and rendered above
the sidebar + chat; because an iOS `.sheet` covers that ZStack, `SettingsSheet`
re-renders the same card as its own overlay during the Settings steps. (That
sheet is hosted by the sidebar — always mounted, but `applyTourStep` still
opens the drawer whenever a step opens Settings to keep tour semantics.) Each step starts the card
at its `placement` anchor, but a grab handle lets the user drag it anywhere; the
position snaps back to the anchor on the next step. The tour
auto-starts when `completed && !tourCompleted`, persists `pupa.tour.completed`
on finish/skip so it never replays, and is re-launchable from Settings →
"Getting started tour". `RootView`'s migration back-fills `tourCompleted = true`
for pre-existing users so an update never replays it.

## Canvas mutations

All canvas / item mutation goes through **`MyAppStore`**
([MyApps/MyAppStore.swift](../Pupa/Sources/PupaApp/MyApps/MyAppStore.swift))
— either via `mutate(_:kind:_:)` (kind-routed) or
`mutate(myAppId:byComponentId:_:)` (explicit component). Views never
mutate state directly; they read it and call store methods or registered
tools. Each mutation appends a lightweight `ItemEvent` to `ItemEventLog`
that captions the History timeline (verb + component-kind noun); the log
no longer drives undo.

### Deterministic write targeting

Agent-driven writes never route by the **active/view** component. Every
write-bearing tool (tracker / calendar / checklist / chart / slack)
resolves its target through `MyAppStore.resolveWriteTarget(kind:…)` (item
/ body edits) or `resolveRenderTarget(kind:…)` (full renders, which may
also land on a lone empty seed). Rules: an explicit `componentId` is
honoured exactly or **fails loudly** (unknown id / wrong kind); an omitted
id resolves only when the myApp holds **exactly one** component of that
kind — otherwise the resolver returns a `.failure` that the tool layer
echoes back to the agent, listing the candidate ids. This stops two
writes in a turn (e.g. a render then an item add) from silently landing
on different same-kind components. Every write tool takes an optional
`componentId` param and echoes the resolved id in its result.

The **active/view component is not agent-facing.** It's dropped from the
per-turn "Live canvas state" summary (so browsing between turns never
busts the prompt cache) and no tool — read or write — falls back to it.
Read/discovery resolvers use the same "explicit-id or unambiguous-single"
rule as writes. When the agent genuinely needs "the component the user is
looking at" it fetches it on demand via the `getActiveComponent` tool and
passes the resolved id explicitly. `setActiveComponent` still exists but
only drives the on-screen view.

### History = snapshots (not per-command undo)

State is versioned by **`SnapshotStore`**
([Sync/SnapshotStore.swift](../Pupa/Sources/PupaApp/Sync/SnapshotStore.swift)):
git-style, per-MyApp snapshots at `state/snapshots/<appId>/<snapshotId>.json`,
riding the same `CloudDocument`/`PupaStorage` seam so history syncs across
devices. Each snapshot stores either a full `base` state or a `JSONPatch`
delta from its parent (`AGUIKit/JSONDiff`), diff-chained with a full base at
the root and every ~20 links, so history keeps only what changed. Consecutive
identical edits dedup by content hash; `prune` bounds each app (cap + TTL,
mirroring `ItemEventLog.prune`) and re-bases the oldest *non-base* survivor so
eviction never breaks a chain.

**Pinned snapshots (permanent).** A user can **Take snapshot** from the
History page to capture a labelled `.pinned` restore point — a "keep this
state forever" milestone. Pins are always stored as a full `base`
(self-contained) and are **exempt from `prune`**: never aged out, never
counted toward the cap. Each pinned row carries an **Export** button that
resolves the snapshot to its `MyApp` and hands it to `MyAppExporter` as a
`.pupa` bundle (`MyAppStore.snapshotBundleData`), reusing the marketplace
export path. Pinning is unlimited (no gate).

**Pins survive deletion.** Deleting a MyApp keeps its pins:
`persist()` calls `SnapshotStore.deleteNonPinned` (drops only automatic
snapshots; removes the dir only when no pins remain). **Settings ▸ Pinned
snapshots** (`PinnedSnapshotsView`, shown when any pin exists) lists every
pin grouped per MyApp — including deleted apps, flagged "deleted", with
name/icon resolved from the pin's own state. Each row **Export**s or
**Restore**s: a live app restores append-only; a deleted app is *revived*
(`MyAppStore.restorePinnedSnapshot` re-inserts it under its original id, so
its surviving pins stay attached).

Snapshots are captured at three hook points in `MyAppStore`: a **debounced
edit** capture in `persist()`, a **pre-reload checkpoint** before a remote
iCloud reload overwrites dirty local state, and **conflict capture** — on
`reloadFromDisk` any unresolved `NSFileVersion` conflict has every side
snapshotted before the live file is resolved newest-wins, so no offline edit
is ever silently lost.

`ChangeHistoryView` (per-MyApp bottom bar **History**) lists the snapshots
newest-first, grouped by day, with a **Restore** button per older entry.
Restore is **append-only** (git-`revert`, not `git reset`): the current state
is checkpointed first, then the chosen state is applied and recorded as a new
head — so the pre-restore state stays recoverable and the restore is the newest
entry. A toolbar **Take snapshot** action pins the current state (labelled,
permanent); pinned entries show a `pin.fill` glyph and an **Export** action.

### Component lock

Each `Component` carries an `isLocked` flag. A locked component refuses every
non-read operation. Enforcement is layered:

- **Backstop (authoritative):** both `mutate` choke points — plus the direct
  `removeComponent` / `linkItems` / `unlinkItems` paths — bail when the target
  component is locked and set `MyAppStore.lastWriteBlockedByLock`. No write
  (UI, agent, or future caller) can slip through.
- **Agent message:** every frontend tool declares its intent via
  `ClientTool.readOnly`. After all tools are registered, `registerMyAppTools`
  wraps each *mutating* tool (`ToolRegistry.transformAll`): it resets the lock
  flag, runs the handler, and if a write was blocked returns
  `{ok:false, locked:true, error:…}` so the model asks the user to unlock.
  Read-only tools are exempt.
- **UI:** `CanvasView` shows a lock icon on top of the component and applies
  `.disabled` to the locked body (controls inert, scrolling intact). The lock
  toggle itself (and `setComponentLocked`, the agent's lock/unlock tool) edit
  the flag directly, so unlocking is never gated. The MyApp **home** page adds
  a lock-all toggle (`setAllComponentsLocked`) that locks/unlocks every
  component at once.

### Memory lock

`MyApp.isMemoryLocked` (per-app flag, round-tripped like `isArchived`) locks
the app's whole memory subtree read-only — the memory counterpart of the
component lock. Enforcement is a single `MemoryStore.writeGuard` closure
consulted (with the target path) before every mutating op; it throws
`MemoryError.locked` when the path is locked, leaving reads open:

- **Agent:** the per-session scoped store wired in `ChatSessionCoordinator`
  returns its MyApp's `isMemoryLocked`, so a locked app's memory-write tools
  echo `{ok:false, error:…}`.
- **UI:** the global (sidebar) store's guard maps a path's leading slug to a
  MyApp via `MyAppStore.isMemoryLocked(forRootPath:)`, so `MyAppMemoriesView`
  and `MemoryFileView` refuse edits too. The **Memories** page carries the
  lock toggle (`setMemoryLocked`) and hides its add/edit/rename/delete
  affordances while locked.

## Shapes

A "shape" (canvas component kind) is a SwiftUI view backed by a typed
data model, plus render + mutator frontend tools, registered on
`MyAppType.supportedComponentKinds`. Built-ins: `tracker`, `calendar`,
`checklist`, `kanban`, `slack`, `calculator`, `chart`. The agent's `addComponent`
tool derives its JSON-Schema `kind` enum from `supportedComponentKinds` at
registration time — a new kind not added there is silently rejected. The
resolved system-prompt fragment also carries a `kindCatalogLine` menu
(one `kind — blurb` per supported kind, from each kind's dedicated
`ComponentKindSpec.catalogBlurb`) so the agent knows what each kind is *for*
before any component of that kind exists — the full per-kind `promptFragment`
only rides context once the kind is present. The always-on
`baseSystemPromptFragment` also states the two-gate build sequence upfront
(`addComponent` → `get_tools_<kind>` → the kind's render tool populates it),
so the model doesn't have to reconstruct it from individual tool descriptions.
Each kind is declared once as a
`ComponentKindSpec` in `MyAppType.kinds` (tools + prompt fragment + catalog
blurb); `supportedComponentKinds`, `toolNamesByKind`, and
`promptFragmentsByKind` all derive from it. Full recipe in
[docs/adding-a-component.md](adding-a-component.md).

### Component modules — one folder, one self-registering module (#162)

The per-kind wiring for a shape used to be smeared across ~10 shared files
(`CanvasView`, `CanvasSummary`, `CanvasState`, `AppTools`, `MyAppType`, plus the
item/export/migration registries). Tier 1 of #162 collapses that into a single
`ComponentModule` protocol + `ComponentRegistry`
([`Canvas/Components/ComponentModule.swift`](../Pupa/Sources/PupaApp/Canvas/Components/ComponentModule.swift)),
mirroring `ItemPolicyRegistry` / `ComponentExportRegistry`: a `@MainActor`
singleton keyed by the lowercase kind string, populated at bootstrap in
`MyAppTypeRegistry.registerBuiltins()`. A module vends everything for its kind —
`kindSpec`, `defaultIcon`, `makeEmptyBody`, `itemCount`, `emptyHint`, `makeView`,
`itemPolicy`, `exportPolicy`, `registerTools` — each doing its own single-case
unwrap on `CanvasApp` instead of the central exhaustive switch.

The central sites **look up the module** instead of switching on the enum:
`CanvasView.componentContent` → `makeView`, `EmptyComponentHint` copy →
`emptyHint`, `CanvasSummary` size → `itemCount`, `addComponent` icon →
`defaultIcon`, and `ComponentItemPickerSheet`'s linkable filter / section header
/ empty hint / item enumeration → `isLinkable` / `linkableItems` /
`linkPickerEmptyHint`. `MyAppType.kinds` is **assembled** from each module's
`nonisolated static let kindSpec` (no literal), and `ComponentRegistry.assertComplete`
traps at bootstrap if a supported kind lacks a module. The `CanvasApp` enum stays
the **Codable persistence discriminator** (its `case` arms, `Kind`,
`init(from:)`/`encode(to:)`, `mapLinkedItems`, `componentReferences`, and
`emptyBody` — kept as a nonisolated switch on the core `addComponent` path).

**All six built-in kinds are migrated** — each owns a
`Canvas/Components/<Kind>/` folder (view files, data model, `<Kind>Module`, tools
`AppTools+<Kind>`, item/export policies) with tests under
`Tests/PupaAppTests/Components/<Kind>/`; tracker was the reference. Per-kind
export policies live in their folders (`Marketplace/ComponentExportPolicies.swift`
is gone). A `nil` module lookup means only `.empty` (or a future kind before its
module lands — `assertComplete` catches that at bootstrap). Still shared in
`MyAppStore`: the per-kind mutators, deliberately kept on the store's single
guarded-mutation path rather than split into folders.

A `Component`'s `id` is permanent (the key every cross-component ref, active
selection, and tool dispatch resolves by), but its `name`, `iconSystemName`,
and LLM-facing `summary` are mutable. `MyAppStore.updateComponentMeta` edits
them in place, exposed to the agent as the `setComponentMeta` tool and to the
user via the MyApp home Components grid's per-tile **Rename / icon…** context
menu — so relabelling never means delete-and-re-add (which would lose the
component's data).

The **calculator** shape is a live numeric model: tunable variable rows,
tracker-aggregate rows (sum/avg/min/max/count with a category filter),
`linkedField` rows (one field off a single linked tracker item — swap the
item to re-run the model), and formula rows over other rows' stable keys.
Results recompute every render via three pure engines (expression evaluator,
tracker reducer, resolver) — see
[docs/components/calculator.md](components/calculator.md).

The **chart** shape plots pie/bar/line with one or more overlaid `series`
(each a `ChartSeriesSource`: a tracker field grouped + reduced via
`TrackerAggregator.series`, a list of calculator rows, a calculator `.list`
array, or inline points), resolved live by `ChartResolver` to `[ChartSeries]`
with a distinct colour per series. The view (`ChartView(series:kind:)`) is
store-free so it embeds inside a calculator (`CalculatorData.inlineChart`, plus
`extraCharts` for further charts stacked below), or stands alone — see
[docs/components/chart.md](components/chart.md). It also
embeds **inline in chat**: `embedComponent` (hostKind "chat") resolves a chart
to `[ChartSeries]` *now* and posts a frozen `ChatChartSnapshot` as its own
assistant bubble. The snapshot rides in the tool result, so it both renders
live (`ChatViewModel`) and rebuilds on transcript reload (`TranscriptMapper`)
with no extra persistence — reproducible, never re-resolved against a mutated
canvas.

## Frontend tools — the agent's mutation channel

[`Tools/AppTools.swift`](../Pupa/Sources/PupaApp/Tools/AppTools.swift)
registers every tool the agent can call: canvas mutators
(`addTrackerItem`, `addCalendarEvent`, `linkItem`, `addComponent`…),
memory ops (`writeMemoryFile`, `readMemoryFile`, `lsMemories`…), and
human-in-the-loop (`ask_user_questions` via the `HumanInTheLoopBridge`
that `ChatViewModel` conforms to). The backend forwards their schemas to
the model and the client executes the calls — the backend owns no
canvas logic.

**Agent harnesses.** Each backend can serve several agent loops ("harnesses" —
LangGraph, Claude Code, …) at once, mounted at `POST /harnesses/{id}`.
`BackendEntry.harnessID` selects which one this connection talks to (chosen in
the backend edit sheet); `SettingsStore.agentRunURL` derives the run endpoint
(`{url}/harnesses/{id}`, or the bare `url` for the backend default). Switching
harness rebuilds the `AgentSession` (the URL changes), same as a URL edit.

The model picker catalog + per-harness tool/permission schema are fetched live
from `GET /harnesses` by `BackendHarnessesClient` into a `ModelCatalogStore`
([Agents/ModelCatalogStore.swift](../Pupa/Sources/PupaApp/Agents/ModelCatalogStore.swift)),
owned by `AppView` and refreshed on launch and whenever the active backend (or
its harness) changes. **There is no offline fallback**: when the backend is
unreachable the model list is empty and the picker shows an explicit
"backend unreachable" state rather than a stale hardcoded catalog. The selected
`{provider, model}` is forwarded per turn in `RunAgentInput.forwardedProps["llm"]`.

**Harness-scoped permissions.** Settings → Tools renders controls from the
active harness's advertised schema (`HarnessPermissionControl`): a `toolset`
(backend-tool mutes → `state["disabled_tools"]`), `bool`
(`shell_approval_disabled`), or `choice` (`claude_loop_native`). Values echo
into `RunAgentInput.state` under each control's `key`; harness-specific ones
live in `SettingsStore.backendHarnessControls` keyed by harness id.

**Per-agent overrides.** Model and tool gating are configured per agent on the
Agents page. `AgentRegistry` builds an `AgentDescriptor` per agent carrying a
glanceable `modelSummary` + `toolSummary` (shown on `AgentsListView` rows) and,
in `AgentDetailView`, an editable model picker plus a toggleable tool surface.
The picker lists only the catalog's concrete models (grouped by provider) plus
a "Reload models" action — there is no "Backend default" entry to pick. An agent
with no override rests on the catalog's first model (the registry's primary, i.e.
the effective backend default), so the row always names a concrete model rather
than an abstract sentinel; the "inherits the backend's model" note still flags
that it isn't an explicit override.
Storage parallels the existing per-agent LLM storage: the main agent uses
`MyApp.settings` (`llm.*`, `tools.disabled` as a `SettingValue.stringArray`),
subagents keep their overrides in `pupa/agents/<slug>/AGENTS.md` frontmatter
(`model`/`provider`/`tools`/`disabled_tools`; edited via `AgentStore.setModel` /
`setDisabledTools`), and the orchestrator uses global `SettingsStore` fields.
Each agent's disabled set is **unioned** with the global Settings → Tools set
(`disabledBackendTools`) and sent every turn as `state.disabled_tools`, which
the backend `ToolGatingMiddleware` drops from the model's tool list. The send
paths — the main-agent chat turn (`ChatViewModel`), orchestrator→MyApp sub-runs
and generic/Slack subagent sub-runs (`ChatSessionCoordinator`, via
`llmForwardedProps`) — all forward the resolved per-agent model and disabled
union, so a subagent runs on its own configured model rather than the backend
default.

**Per-thread model.** Each conversation thread can pin its own model,
overriding the agent default. A compact `ModelPickerRow(compact:)` chip sits
beside the thread-name dropdown in the chat header
([Chat/ChatPanel.swift](../Pupa/Sources/PupaApp/Chat/ChatPanel.swift),
wired via [Chat/ConversationPager.swift](../Pupa/Sources/PupaApp/Chat/ConversationPager.swift)).
The pin lives on `ChatThread.llmProvider/llmModel`
(`MyAppStore.setThreadLLM/threadLLM`), so it persists with the thread and is
independent of the agent default — changing the default later doesn't move a
pinned thread. Resolution precedence at send time
(`ChatViewModel.forwardedPropsJSON`): **thread pin → agent default → backend
env default**. An untouched thread rests on the agent default and follows it;
picking a model pins the thread, and picking the backend-default sentinel
clears the pin (re-inherits). No backend change — the resolved `{provider,
model}` still rides `forwardedProps["llm"]`.

## Skills & the `pupa/` config folder

Each MyApp keeps its driving config in a visible `pupa/` subfolder of its
memory root (`memories/<slug>/pupa/`): `AGENTS.md` (main agent),
`agents/<sub>/AGENTS.md` (subagents), and `skills/<name>/SKILL.md` (a
playbook can be a skill — e.g. the Content Studio `setup` skill provides
`/setup`).
The orchestrator has its own `orchestrator/pupa/`. Visible (non-dot) so it
rides the sidebar, per-turn snapshot, and the `.pupa` bundle; writes are
limited to `.md` / `.json`.

`AGENTS.md` *layers over* the resolved type fragment, it does not replace it
(`MyAppPolicy.buildSystemPrompt`): the dynamic base + `kindCatalogLine` +
per-kind prose is always prepended, then AGENTS.md rides on top as the user's
customization. Seeding therefore no longer bakes the fragment into AGENTS.md —
otherwise per-kind guidance froze at creation and was lost as the canvas
changed (#164).

A **skill** is a markdown playbook (`SKILL.md` + optional frontmatter), the
directory name being its `/command`. `SkillStore`
([Pupa/Sources/PupaApp/Skills/](../Pupa/Sources/PupaApp/Skills/)) discovers
them per scope and:

- feeds palette-visible skills into `SlashCommandRegistry` as `/<name>`
  commands (`SkillStore.slashCommands()` → the registry's live `skillProvider`;
  built-ins win on name collision);
- lists model-visible skills (name + `when_to_use`) into the agent's context
  via `ChatViewModel.skillsContextEntry` — present in all three context paths
  (main chat, sub-run, Slack);
- the agent loads a body on demand with `app_skill_view`, always advertised
  through `MyAppType.skillToolNames`.

Skills are seeded three ways: per-example (each example's `seedAgentsMd`);
universally via `DefaultSkills`, seeded **once at app birth**
(`MyAppStore.seedBirthFiles` — `addMyApp` / example restore / fresh-install
default), file-exists-guarded so user/agent edits *and deletions* survive
later launches — every app ships `/to-memory` (records durable learnings into
`pupa/MEMORIES.md`); and via `GuideSkills`, the managed user-facing guide
plugin (`/pupa` + `/pupa-components` / `/pupa-sharing` / `/pupa-memory` /
`/pupa-agents` / `/pupa-system`) living under
`pupa/plugins/pupa-guide/skills/` — `SkillStore` discovers both that plugin
root and the user's `pupa/skills/` (user skill wins a name collision).
Re-seeded **every launch** into the orchestrator and every app
(`AppView.init`), version-gated on frontmatter `version:` so app updates
refresh the bodies. `GuideSkills` replaced the retired `/pupa-internals`
default skill and removes a pristine seeded copy of it on reseed. See
[skills.md](skills.md).

These are **app skills** (on-device `pupa/skills/`, `app_skill_view`), distinct
from any **backend** skills library (`~/.pupa-backend/skills/`, the backend's
own `skill_view` tool) the client never touches — see [skills.md](skills.md).

## Subagents

A **subagent** is a Claude-Code-style delegate: a `pupa/agents/<slug>/AGENTS.md`
file with frontmatter (`name`, `description`, `when_to_use`, `tools`,
`disabled_tools`, `model`, `provider`) and a persona body. Drop the file and the
subagent exists — `AgentStore`
([Pupa/Sources/PupaApp/Agents/AgentStore.swift](../Pupa/Sources/PupaApp/Agents/AgentStore.swift))
discovers them per scope by walking `pupa/agents/*/AGENTS.md`, exactly mirroring
`SkillStore`. `AgentStore.createAgent` is the canonical writer (used by the Slack
create-agent UI and any future `create_agent` tool); an agent can also author one
by hand-writing the file with the memory tools.

The main agent — and, by default, any subagent (A2A) — invokes one with the
`invoke_agent(name, prompt)` frontend tool (`AppTools.registerSubagentTools`,
advertised via `MyAppType.subagentToolNames`). The handler calls
`ChatSessionCoordinator.runSubagent`, which spins a transient `AgentSession`
scoped to the parent MyApp: memory + canvas surface inherited, tool set narrowed
by `SubagentPolicy.narrowedTools` (the frontmatter `tools` allowlist minus
`disabled_tools`, minus main-chat-only admin tools, always plus `invoke_agent`),
persona pinned as a context entry, and the frontmatter model/provider forwarded.
Progressive disclosure mirrors skills: `ChatViewModel.agentsContextEntry` lists
each subagent's `{name, description, when_to_use}`; the persona loads only when
the subagent runs.

Every subagent run is gated by the shared `AgentInvocationGate` under a
`.subagent(myAppId:slug:)` key, so reentrancy, chain-depth, and per-pair turn
budgets bound A2A chains exactly as they bound orchestrator→MyApp delegation.

**Slack is a UI over subagents.** A Slack component holds only channels +
messages (`SlackData`); its workspace roster is *all* subagents discovered under
the MyApp. Channels reference agents by slug; @-mentioning one (or posting in a
DM) calls `invokeSlackAgent`, a thin Slack wrapper over the same subagent runner
that adds channel-history context, live `SlackInvoker` bubbles, and auto-posting
of the reply.

Full reference: [skills.md](skills.md).

## Persistence

**The local tree is always the store of record.** `PupaStorage.activeRoot` is
always local `~/Library/Application Support/pupa`; the stores read and write it
directly and never block on iCloud. iCloud is a **mirror**, not the canonical
root — so turning it off in iOS Settings (which relaunches the app) can't hide
MyApps ("app looks lost") or strand offline edits, the way the old
switch-roots-per-launch design did (pupa#110). All synced file IO goes through
`CloudDocument`, which writes the local tree with **plain atomic** writes (no
`NSFileCoordinator`: the local store is single-process with no file presenter,
so coordination only bought a main-thread XPC stall — pupa#120) and schedules a
debounced `StorageMirror` pass after every write. iCloud-side coordination lives
only in `StorageMirror`.

`StorageMirror` converges the local tree with the iCloud container
(`cloudMirrorRoot`) in the background, off the main thread. Merge is
**baseline-aware (3-way)**: a persisted `.mirror-baseline.json` records each
file's hash as of the last sync, so an ordinary sequential edit (one side moved
off the baseline) just propagates, while a genuine conflict (both sides moved)
resolves newest-wins with the losing side preserved under `conflicts/` — data
is never dropped. Deletes propagate; a delete racing an edit keeps the edit.
The `conflicts/` tree is **local-only (never mirrored)** and **bounded**:
losing sides are deduped by content, capped to the newest few per path, and
aged out, so a repeatedly-conflicting file can't balloon storage.
It's triggered at launch (`warm()`), after any local write, and by the
`CloudWatcher` (`NSMetadataQuery`) when a remote change lands — all debounced
into one pass. The watcher's reload runs each store's `reloadFromDisk` off the
main actor, republishing only the result on main, so a burst of remote writes
can't stampede the UI thread.

Debounced background writers are **quiescable**: `StorageMirror.drain()`
cancels the armed debounce and awaits an in-flight pass, and
`MyAppStore.clearStorage()` (async) bumps a storage epoch that expires armed
snapshot debounces, drains the mirror, and removes the merge baseline. Tests
run serially (`--no-parallel`, see Makefile) and rely on these so no
background disk task crosses a suite boundary.

There is no migration from the pre-iCloud single-blob storage — a new build
seeds fresh. iCloud needs the CloudDocuments entitlement
(`PupaHost.entitlements`, container `iCloud.com.pupa-app.client` =
`PupaStorage.containerID`).

- **Canvas + MyApps state** → **per-file** under `state/`: one
  `apps/<uuid>.json` per MyApp plus `index.json` (active id, order,
  orchestrator threads, audit log, and the UI-only component-folder layout).
  One mutation rewrites only the touched file (dirty-hashed in `MyAppStore`),
  so iCloud syncs minimal traffic and per-app snapshots stay cheap. On load,
  `sweepOrphanAppFiles` deletes `apps/` files the index doesn't reference and
  that haven't been touched for a week — `persist()` only deletes files it saw
  during its own session, so leaked files would otherwise accumulate forever;
  the age gate protects an iCloud merge that lands an app file before its
  index.
- **Component folders (UI-only)** → the home-page grid
  (`MyAppHomeView.componentsPanel`) lets you drag component tiles into folders,
  iOS-home-screen style. The layout (`ComponentFolderLayout`: folders +
  componentId→folderId assignments) is **presentational**, kept off-model in
  `index.json` (`MyAppStore.componentFolders`, keyed by MyApp `id.uuidString`).
  It is deliberately *not* on `Component`/`MyApp`, so the agent
  (`getCanvasState`) and marketplace exports never see it. It syncs across
  devices but is not part of per-app History snapshots.
- **Settings** → JSON file `state/settings.json` (backend list,
  disabled backend tools, A2A guardrails). Device tokens are **excluded** —
  they stay in the Keychain, unsynced. The Settings
  sheet groups these into drill-down categories: **Account** (the read-only
  `ProfileSettingsView` — iCloud sync status, this device via `DeviceInfo`,
  data overview, version; no auth/login of its own), Backend, Tools (shell
  approval + backend tool toggles), Agent-to-agent (the `AgentInvocationGate`
  conversation-rounds + chain-depth limits), **Agents** (the
  `AgentsOverviewView` — see below), Notifications (lists/cancels
  pending scheduled notifications), and Examples.
- **Agent activity stats** → `UserDefaults` blob `pupa.agentstats.v1`,
  owned by `AgentStatsStore`. Device-local, **not** iCloud-synced (advisory
  counters only). Deliberately schema-free: a flat
  `[agentKey: AgentStat]` bag whose `counters` are an open `[String: Int]`,
  keyed by `AgentInvocationKey.statKey` (opaque string, never a struct
  shape) so it survives as agent kinds grow. Counters are bumped at the one
  `AgentInvocationGate.onNestedEnter` chokepoint every MyApp sub-run and
  Slack sub-agent funnels through — `delegationsMade` on the caller,
  `invocationsReceived` on the target. Stats are advisory/lossy-tolerant
  (missing key → zero; orphans ignored). **Settings → Agents**
  (`AgentsOverviewView`) reads the roster through the existing
  `AgentRegistry` descriptor pipeline and renders it as nested dropdowns
  (each MyApp expands to its agents — main agent + Slack personas, derived
  from `AgentDescriptor.kind`/`myAppId`; each agent expands to its stats;
  the orchestrator is a top-level agent dropdown) showing these counters +
  per-agent conversation counts (derived live from `MyAppStore.threads`),
  plus a threads collection grouped by agent.
- **Memories** → markdown files under `<storage root>/memories/`
  (per-agent namespaces under `agents/<agentId>/`). Survive "New session".
  Each file syncs individually via iCloud. The per-app folder is keyed on
  the app name's slug, so `MyAppStore.renameMyApp` migrates the subtree to
  the new slug (via `MemoryStore.migrateAppFolder`; on a slug collision the
  trees merge and existing destination files win). App-scoped stores from
  `appScopedStore` propagate their writes to the parent store's tree, so
  the sidebar / Memories tab refresh without a relaunch.
- **Chat history** → owned by the *backend* checkpointer, keyed by
  `threadId`. The client reloads old conversations from
  `GET /db/threads/{threadId}/messages` after relaunch. Unset DB config
  on the backend → history dies with the backend process.
- **Paired-device token** → iOS Keychain (service
  `com.pupa.backend-token`).
- **Onboarding flags** → `UserDefaults` booleans `pupa.onboarding.completed`
  (gates the first-install flow; back-filled `true` for pre-existing users so
  an update doesn't replay it) and `pupa.onboarding.backendSkipped` (drives the
  connect-backend reminder banner).

## Export / Import (marketplace)

A MyApp can be exported as a portable, **inert** `.pupa` bundle (versioned
header + the `Codable` `MyApp` tree + memory files) and rebuilt on another
install — **no code from the bundle is executed**. UI lives in Settings ▸
Import & Export: export is a **Share…** action (`ShareLink` → AirDrop /
Messages / WhatsApp / Files). `.pupa` is a registered, app-owned file type
(`UTType.pupaAppBundle`), so opening a shared bundle routes to Pupa via
`AppView.onOpenURL`, which read-only-decodes it for a confirm sheet before
running the same importer. Each Share regeneration writes a fresh unique
temp file so the `ShareLink` never hands off a bundle built before the
latest toggle change. Cross-component references are enumerated/pruned by a single
unified model on `CanvasApp` (`componentReferences` / `remapReferences`) shared
with the delete cascade; each kind registers a `ComponentExportPolicy`. Import
treats the bundle as untrusted (settings allow-list, size/count caps,
slug-safe rename, traversal-safe memory writes). Full design + threat model:
[marketplace.md](marketplace.md).

## Backend

The backend is a separate repo —
[pupa-app/pupa-backend](https://github.com/pupa-app/pupa-backend). The
client only needs its URL (Settings → Backend; default
`http://localhost:8004/`) and a paired-device token. The wire protocol
is plain AG-UI, so any AG-UI-compatible agent backend is a drop-in URL
swap.

## Signing & build configuration

The Xcode project (`PupaHost`) carries **no signing identity** — no
`DEVELOPMENT_TEAM` lives in `project.pbxproj` (keeps personal Apple
account info out of the repo). Signing is supplied per-developer via an
xcconfig override:

- [`PupaHost/Config.xcconfig`](../PupaHost/Config.xcconfig) — committed,
  set as the project's base configuration (Debug + Release, inherited by
  all targets). It only does `#include? "Local.xcconfig"`. The `?` makes
  the include optional, so clones / CI without the file still build (just
  unsigned).
- `PupaHost/Local.xcconfig` — **git-ignored**, created by each developer.
  Holds the one line `DEVELOPMENT_TEAM = <your team id>`.

**First-time setup on a fresh clone:** create `PupaHost/Local.xcconfig`
with your Apple Developer team ID:

```
DEVELOPMENT_TEAM = XXXXXXXXXX
```

Then build/run in Xcode as normal (automatic signing). Do **not** set the
team via Xcode's *Signing & Capabilities* dropdown — that writes
`DEVELOPMENT_TEAM` back into `project.pbxproj` and re-leaks it.

The app's bundle ID is `com.pupa-app.client` (reverse-DNS of the owned
domain `pupa-app.com`; platform-neutral so one Universal Purchase record
covers iOS + macOS). Tests/UITests use the `.tests` / `.uitests` suffixes.
The bundle ID is permanent once an app record exists in App Store Connect,
so settle on the final value before creating that record.
