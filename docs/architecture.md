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
  interrupt.
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
| [`MyApps/`](../Pupa/Sources/PupaApp/MyApps/) | `MyApp` model + `MyAppStore` (the single mutation surface), `MyAppType` (kind registry), example apps, `ItemEventLog` (reversible change log). |
| [`Canvas/`](../Pupa/Sources/PupaApp/Canvas/) | `CanvasState` + the per-shape SwiftUI views (`TrackerView`, `CalendarView`, `ChecklistView`, `KanbanView`, `SlackView`) and the cross-component link picker. |
| [`Chat/`](../Pupa/Sources/PupaApp/Chat/) | `ChatViewModel`, `ChatSessionCoordinator` (drives `AgentSession`), `ChatPanel` + thread-selector dropdown (`ConversationPager`), slash commands, transcript mapping. The composer attaches one image — from the photo library, the camera (`CameraPicker`, iOS), or drag-and-drop — all funnelled through `ImagePreparer` into a `PickedImage`. |
| [`Tools/`](../Pupa/Sources/PupaApp/Tools/) | `AppTools.swift` — registers every frontend tool against the `ToolRegistry`. |
| [`Memory/`](../Pupa/Sources/PupaApp/Memory/) | `MemoryStore` — sandboxed markdown filesystem; orchestrator home. |
| [`Agents/`](../Pupa/Sources/PupaApp/Agents/) | Per-agent policies, the agent overview/detail pages, `KnownLLMModelCatalog`. |
| [`Slack/`](../Pupa/Sources/PupaApp/Slack/) | `SlackInvoker` — multi-agent room invocation policy. |
| [`ScreenShare/`](../Pupa/Sources/PupaApp/ScreenShare/) | WebRTC viewer + signalling client for the backend's `/screenshare/ws` broker. |
| [`Settings/`](../Pupa/Sources/PupaApp/Settings/) | `SettingsStore` (backend URL, API key, disabled tools), backend-tools client. |

`AppView` lays this out as a fixed-width `HStack` split (sidebar `Divider`
detail) on macOS and a custom slide-in drawer on iOS. (macOS deliberately
avoids `NavigationSplitView`: its sidebar fails to render in the unbundled
`swift run` PupaDemo binary, leaving an empty column. The macOS sidebar also
uses one merged `List` — MyApps + Orchestrator — since the iOS dual-`List`
layout doesn't apply without the split view.) The drawer fills most of a
compact (iPhone-portrait)
screen but stays a slim fixed width on a regular width class (iPad, large
iPhone landscape). The chat lives in a floating, user-resizable `ChatOverlay`
card anchored bottom-trailing of the detail pane; on iOS it does its own
keyboard avoidance (it tracks the keyboard height and lifts/shrinks the card)
so the composer stays visible above the keyboard in any orientation. A
full-screen expand/restore button (⤢) in the card header fills the detail pane
edge-to-edge (no inset, flush corners); the resize grip is hidden while
full-screen is active.

The composer is a floating, translucent rounded pill overlaid on the bottom of
the message `ScrollView` (not a layout row), so the message list uses the full
card height; the ScrollView carries a bottom alpha-gradient `mask` so messages
fade into the card material as they scroll behind the pill. Message bubbles are
selectable on every platform and expose a **Copy** context-menu action
(`ChatClipboard`, right-click on macOS / long-press on iOS) that copies the
whole bubble.

On a myApp's home/component pages the detail pane also hosts a **bottom dock**
(`MyApps/MyAppDock.swift`): an icon-only quick-switcher — Home plus one icon
per component, tinted the app's color (creation-order index via
`MyAppStore.colorIndex(for:)`), current page highlighted. It reveals on
*approach* — macOS slides it up while the pointer is near the bottom edge; iOS
peeks a handle you tap to expand. On iOS the dock never covers the page (no
scrim), so the page stays scrollable; scrolling dismisses the dock (`AppView`
bumps a `dockDismissSignal` via a non-blocking `simultaneousGesture` on the
content `NavigationStack`), and a 5s inactivity timer fades it otherwise. When
the icons exceed the width the row scrolls horizontally (`ViewThatFits`).
`AppView` hosts it once below `ChatOverlay`, gated to `.myAppHome`/`.myApp`/
`.myAppComponent`; taps flat-switch the root selection (reset `detailPath`, set
`selection`, run `dispatchSelection`).

The conversation dropdown (`ChatPanel.threadDropdown`) lists threads newest-first.
When 2+ threads exist each entry is a submenu with "Open" and "Delete" so any
thread can be deleted without switching to it first.

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
app to that surface — ten steps: welcome (opens the sidebar menu), Settings
overview (the category list), Settings · Backend (deep-linked), a MyApp, chat,
agents & threads, the orchestrator (prefilled "create a new myapp"), agent
settings, slash commands, and Share a MyApp (deep-links Settings · Import &
Export). It is
**route-driven, not pixel-anchored**, so it survives UI redesigns: a shared
`@Observable GuidedTourStore.shared` (mirroring `OnboardingHandoff.shared`)
holds the step list (`TourContent`, pure data) + current index. Each `TourStep`
carries **composable, independent intents** (a step may navigate *and* open the
chat with a prefill) — `selection`, `opensSidebar`, `settingsPage`, `opensChat`,
`chatPrefill` — that target the stable routing layer, never geometry.
`AppView.applyTourStep()` reconciles them: it routes `selection`/`detailPath`
(via `dispatchSelection`, so the chat scope follows), opens the sidebar, and
writes the store's intent flags (`wantSettingsOpen` / `wantSettingsPage` /
`wantChatOpen` / `chatPrefill`). Host views then mirror those declaratively:
`MyAppSidebarView` drives the Settings sheet, `SettingsSheet` deep-links its
`NavigationStack` path, `ChatOverlay` expands/collapses to match `wantChatOpen`,
and `ChatPanel` adopts `chatPrefill` (including "/" to surface the
`SlashCommandPalette`). The card is gated on `tour.isActive` and rendered above
the sidebar + chat; because an iOS `.sheet` covers that ZStack, `SettingsSheet`
re-renders the same card as its own overlay during the Settings steps. (That
sheet is hosted by the conditionally-mounted sidebar, so `applyTourStep` keeps
the sidebar mounted whenever a step opens Settings.) Each step starts the card
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
tools. Every mutation records a typed inverse in `ItemEventLog` so
`undo(eventId:)` can reverse it. This log is surfaced both via the
sidebar's per-MyApp **History** sheet and a **History** panel on the
MyApp landing page (`MyAppHomeView`, below Memories) — recent events
inline, "View all" opening the same sheet.

## Shapes

A "shape" (canvas component kind) is a SwiftUI view backed by a typed
data model, plus render + mutator frontend tools, registered on
`MyAppType.supportedComponentKinds`. Built-ins: `tracker`, `calendar`,
`checklist`, `kanban`, `slack`, `calculator`, `chart`. The agent's `addComponent`
tool derives its JSON-Schema `kind` enum from `supportedComponentKinds` at
registration time — a new kind not added there is silently rejected.
Full recipe in
[docs/adding-a-component.md](adding-a-component.md).

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

The model picker catalog
([Agents/KnownLLMModel.swift](../Pupa/Sources/PupaApp/Agents/KnownLLMModel.swift))
is a static list that must stay in sync with the backend's
`MODEL_REGISTRY`; the selected `{provider, model}` is forwarded per turn
in `RunAgentInput.forwardedProps["llm"]`.

## Persistence

- **Canvas + MyApps state** → `UserDefaults` blob `pupa.myapps.v1`.
- **Settings** → `UserDefaults` blob `pupa.settings.v1` (backend URL,
  optional API key, disabled backend tools, A2A guardrails). The Settings
  sheet groups these into drill-down categories: Backend, Tools (shell
  approval + backend tool toggles), Agent-to-agent (the `AgentInvocationGate`
  conversation-rounds + chain-depth limits), Notifications (lists/cancels
  pending scheduled notifications), and Examples.
- **Memories** → markdown files under
  `~/Library/Application Support/pupa/memories/` (per-agent namespaces
  under `agents/<agentId>/`). Survive "New session".
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

A MyApp can be exported as a portable, **inert** `.pupaapp` bundle (versioned
header + the `Codable` `MyApp` tree + memory files) and rebuilt on another
install — **no code from the bundle is executed**. UI lives in Settings ▸
Import & Export. Cross-component references are enumerated/pruned by a single
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

The app's bundle ID is `app.pupa.ios` (a generic placeholder). The bundle
ID is permanent once an app record exists in App Store Connect, so settle
on the final value before creating that record.
