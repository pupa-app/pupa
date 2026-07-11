# Adding a new component / canvas shape

End-to-end recipe for landing a new canvas-component kind on iOS / macOS. Written off the back of the Slack component PR (umbrella issue [#125](https://github.com/*/issues/125)) — every step here is a concrete drill into a file you'll touch.

> **First question**: do you actually need a new component, or just a new **view mode** for an existing one? An alternate calendar layout over `CalendarData` should be a `CalendarViewMode` case, not a new union arm. See `TrackerViewMode` in [CanvasState.swift](../Pupa/Sources/PupaApp/Canvas/CanvasState.swift) for the pattern. New shape = new data model.

This guide assumes a new shape called `widget` with a body type `WidgetData`. Substitute your kind name everywhere.

> **Migration in flight (issue #162).** The per-kind wiring below is being
> consolidated into one self-registering `ComponentModule` per kind, each owning
> a `Canvas/Components/<Kind>/` folder — see the *Component modules* section in
> [architecture.md](architecture.md) and **[`Canvas/Components/Tracker/`](../Pupa/Sources/PupaApp/Canvas/Components/Tracker/)** as the reference. As kinds migrate, the central switches in steps 2/4/5/… become
> `ComponentRegistry` lookups (with the legacy switch as fallback until every
> kind ships a module). New shapes should follow the tracker layout: put the
> view, data model, `<Kind>Module`, tools extension, and policies in the folder,
> register the module in `MyAppTypeRegistry.registerBuiltins()`, and still make
> the ~4 `CanvasApp` enum edits below (the enum stays the persistence
> discriminator).

## Worked example

The Slack component is the most recent end-to-end example and the only one whose docs follow the recommended per-shape layout. Open the three files side-by-side while you read this guide:

- [docs/components/slack.md](components/slack.md) — the per-shape doc you should mirror for your own component.
- [`Canvas/SlackView.swift`](../Pupa/Sources/PupaApp/Canvas/SlackView.swift) — view + composer pattern.
- [`Slack/SlackInvoker.swift`](../Pupa/Sources/PupaApp/Slack/SlackInvoker.swift) — only relevant if your shape is multi-agent.

## 1. Data model (the discriminated union arm)

[Pupa/Sources/PupaApp/Canvas/CanvasState.swift](../Pupa/Sources/PupaApp/Canvas/CanvasState.swift)

- Define `WidgetData: Codable, Hashable, Sendable` (and any nested item types). Include the same backward-compat decoder pattern the other bodies use — every field `decodeIfPresent` with a sensible default — so a pre-shape persisted blob still decodes after upgrade.
- Add `.widget(WidgetData)` to the `CanvasApp` enum. Update:
  - `Kind` raw-value enum (`case widget`)
  - `kindString` switch
  - `init(from:)` and `encode(to:)` switches
  - `emptyBody(forKind:)` so `addComponent(kind: "widget", ...)` seeds a usable empty body

## 2. Sweep switch-exhaustiveness regressions

Adding a `CanvasApp` case turns any non-default-having switch elsewhere in the codebase into a compile error. Build once and let the compiler walk you through them. Typical call sites you'll need to extend (from the Slack PR):

- [Canvas/CanvasView.swift](../Pupa/Sources/PupaApp/Canvas/CanvasView.swift) — the body dispatcher
- [Canvas/CanvasSummary.swift](../Pupa/Sources/PupaApp/Canvas/CanvasSummary.swift) — `itemCount(of:)`
- [Canvas/ComponentItemPickerSheet.swift](../Pupa/Sources/PupaApp/Canvas/ComponentItemPickerSheet.swift) — four switches for the cross-component link picker
- [Canvas/CanvasState.swift](../Pupa/Sources/PupaApp/Canvas/CanvasState.swift) — the **unified reference model**: `mapLinkedItems`, `componentReferences()`, and `remapReferences(keepComponent:keepItem:)`. If your shape holds cross-component refs (item `linkedItems` or spec componentIds), declare them in `componentReferences()` and prune them in `remapReferences` — this one place feeds **both** the delete cascade and marketplace export.
- [MyApps/MyAppStore.swift](../Pupa/Sources/PupaApp/MyApps/MyAppStore.swift) — switches in `linkItems`, `unlinkItems`, `itemExists`, `displayNameForRefTarget` (`cascadeRemoveRefs` now routes through `CanvasApp.remapReferences`, so it needs no per-kind edit)

For a non-linkable shape (Slack messages aren't link targets), fold the new case in with `.empty`: `case .widget, .empty: return false`. For a linkable shape, mirror the tracker / calendar / checklist branches that handle `linkedItems`.

## 3. Store mutators

Add a `// MARK: - Widget mutators` section to [MyAppStore.swift](../Pupa/Sources/PupaApp/MyApps/MyAppStore.swift) and write the per-shape mutators (e.g. `addWidgetItem`, `setWidget`, …). Use the existing `mutate(_:kind:_:)` for kind-routed calls and `mutate(myAppId:byComponentId:_:)` when the call site explicitly targets one component (multi-component MyApps).

Every mutator must:
- Take an optional `myAppId: UUID? = nil` (defaults to `activeMyAppId`)
- Take an optional `componentId: String? = nil` for multi-component MyApps
- Return either `Void`, a `@discardableResult` Bool changed-flag, or an id for "create" mutators
- Call `persist()` only when state actually changed (the `mutate` helper handles this for you)

Also add `widgetComponentId(myAppId:)` mirroring `trackerComponentId` / `calendarComponentId` / `checklistComponentId`, so the (forthcoming) tools have a resolver when no explicit `componentId` is passed.

## 4. SwiftUI view + canvas dispatcher

- New file: `Pupa/Sources/PupaApp/Canvas/WidgetView.swift` next to [ChecklistView.swift](../Pupa/Sources/PupaApp/Canvas/ChecklistView.swift). Takes `(store: MyAppStore, data: WidgetData, myAppId: UUID, componentId: String)`.
- Dispatch from [CanvasView.swift](../Pupa/Sources/PupaApp/Canvas/CanvasView.swift)'s switch:

```swift
case .widget(let data):
    WidgetView(store: store, data: data, myAppId: resolvedMyAppId, componentId: component.id)
```

## 5. Per-kind tool / prompt gating

[Pupa/Sources/PupaApp/MyApps/MyAppType.swift](../Pupa/Sources/PupaApp/MyApps/MyAppType.swift)

In `MyAppType.tracker` (the default `MyAppType` every MyApp currently uses), add **one** `ComponentKindSpec` entry to the `kinds` dictionary, keyed `"widget"`. That single entry is the whole per-kind surface — `supportedComponentKinds`, `toolNamesByKind`, and `promptFragmentsByKind` all derive from it, so there are no parallel maps to keep in sync. Its three fields:

- `tools:` — every Widget tool name. Advertised only on rounds where at least one `.widget` component exists. (Being absent from this set is also what makes `addComponent` reject the kind — the tool's JSON Schema `enum` derives from `kinds.keys`.)
- `promptFragment:` — a paragraph on the mental model: when to choose this shape, what its `summary` slot is for, how state surfaces. Rides context only while a `.widget` component is present. Don't enumerate tool names; they're forwarded as proper tool definitions.
- `catalogBlurb:` — a single phrase (no leading kind label) for the always-on `addComponent` catalog menu, e.g. `"a small live status widget"`. This is the *only* per-kind prose the agent sees **before** a widget exists, so it's what lets the model decide to create one. Keep it distinct from `promptFragment` — the menu must read as one clean line.

## 5b. Marketplace export policy

Register a `ComponentExportPolicy` for `"widget"` in `MyAppTypeRegistry.registerBuiltins()`, beside the item-policy registrations ([ComponentExportPolicies.swift](../Pupa/Sources/PupaApp/Marketplace/ComponentExportPolicies.swift)). `strippingUserData` drops user records but keeps reusable structure; set `exportDataWarning` if records can't be fully stripped. **`ComponentExportRegistry.assertComplete` traps at bootstrap (and CI fails) if a supported kind has no policy**, so this isn't optional. See [marketplace.md](marketplace.md).

## 6. Frontend tools

Register in [AppTools.swift](../Pupa/Sources/PupaApp/Tools/AppTools.swift). Either inline in `registerMyAppTools` or extracted into a private `registerWidgetTools(on:store:myAppId:)` called from `registerMyAppTools` near the end.

Tool patterns to follow:
- **`renderWidget(title, ..., summary)`** — destructive full render OR `summary`-only update. Echoes `{ok, fields?, totalItems?, summarySet?}`.
- **Bulk mutators**: `addWidgetItems(items: [...])`, `patchWidgetItems(patches: [...])`, `removeWidgetItems(ids: [...])` — one tool that accepts a list of size 1+. Don't ship a singular + plural pair (see memory note `feedback_few_clear_tools`).
- **Discovery**: `listWidgetItems(limit?, offset?)`, `searchWidgetItems(query, ...)`, `getWidgetItem(id)` — keeps the per-turn canvas-state context entry thin while letting the agent paginate.

Tool result echoes must describe the state change so the agent can reason mid-turn (`{added, totalItems, ...}`). The injected canvas-state context entry only refreshes between user messages; mid-turn the agent's only state signal is the tool result.

## 7. Tests

Mirror the patterns in [ChecklistTests.swift](../Pupa/Tests/PupaAppTests/ChecklistTests.swift):

- **Codec round-trip**: encode/decode `WidgetData`; legacy `CanvasApp` JSON without the new case still decodes.
- **Mutators**: every mutator's happy path + at least one edge (empty input, unknown id).
- **Tool gating** (in [ToolGatingTests.swift](../Pupa/Tests/PupaAppTests/ToolGatingTests.swift)): a fresh MyApp with no Widget component does NOT advertise Widget tools; adding the component advertises them. Watch out for the `addComponent` schema-enum drift test there — it pins the contract you're modifying in step 5.

Write tests first when feasible (failing test → impl). For UI-only changes pure to `WidgetView.swift`, manual smoke via `make mac-demo` is fine.

## 8. Docs + versioning

End of PR:

- **Write a per-shape doc at `docs/components/<your-shape>.md`** covering the shape's mental model, data model, mutator surface, tool surface, UX details, and any quirks specific to the shape (multi-agent runtime, custom view modes, etc.). [docs/components/slack.md](components/slack.md) is the canonical example — mirror its outline.
- **Cross-link from [docs/architecture.md](architecture.md)** with a *short* (1-2 paragraph) entry that summarises the shape and links into the per-shape doc. Don't dump the full design into architecture.md; that file is the high-level navigator. The existing [Slack section](architecture.md#slack--multi-agent-rooms-ios--macos) shows the right shape.
- Add a one-line entry to [README.md → What pupa is](../README.md) if the shape is user-visible (it almost certainly is).
- Bump patch versions where you touched code:
  - Project: root version badge + [CHANGELOG.md](../CHANGELOG.md) entry
  - Backend: [backend/pyproject.toml](../backend/pyproject.toml) + [backend/CHANGELOG.md](../backend/CHANGELOG.md) — only if you changed backend
  - Pupa iOS: [Version.swift](../Pupa/Sources/PupaApp/Version.swift) + [Pupa/CHANGELOG.md](../Pupa/CHANGELOG.md)
  - AGUIKit: only if you changed the protocol package

Patch-only bumps unless the user asks otherwise (`0.0.X` → `0.0.X+1`).

## Common pitfalls

These tripped me on the Slack PR; flag them on your own.

- **`addComponent` schema drift** ([AppTools.swift:1041-1080](../Pupa/Sources/PupaApp/Tools/AppTools.swift)). The tool's `kind` enum + description are derived from `MyAppType.supportedComponentKinds` at registration time. If you ship a new kind but forget to add it to `supportedComponentKinds`, the JSON Schema enum will reject the model's call silently. The regression test `addComponent schema enum + description derive from supportedComponentKinds (no hardcoded drift)` in [ToolGatingTests.swift](../Pupa/Tests/PupaAppTests/ToolGatingTests.swift) catches this.
- **Backward-compat decoding**. Every Codable struct should use `decodeIfPresent` with defaults so on-disk blobs from earlier project versions decode cleanly. The legacy-JSON test in [SlackDataCodecTests.swift](../Pupa/Tests/PupaAppTests/SlackDataCodecTests.swift) (and the matching one in [ChecklistTests.swift](../Pupa/Tests/PupaAppTests/ChecklistTests.swift)) is the contract you're upholding.
- **MainActor + `@Sendable` closures**. `ToolRegistry` handlers are `@Sendable async`. Any MainActor-isolated state inside the handler needs `await MainActor.run { ... }`. Pure helpers (regex parsing, transforms) should be `nonisolated static` so they're callable from anywhere — see `SlackView.parseMentions` in [SlackView.swift](../Pupa/Sources/PupaApp/Canvas/SlackView.swift).
- **Switch exhaustiveness via `_ = `**. Resist adding `default: break` to switches over `CanvasApp.body` — that defeats the compiler's "did you handle the new case" guarantee. Explicitly list every case (group with comma for shared no-op behaviour: `case .widget, .empty: return false`).
- **Don't enumerate tools in the system prompt**. Tool names + JSON Schema + short descriptions are forwarded as proper tool definitions. Duplicating them in `promptFragmentsByKind` causes drift the moment you rename or split a tool.
- **Mutator + tool result echoes**. Mutator tools must return a description of what changed (`{added/removed/patched, totalItems, ...}`) so the model can reason mid-turn before the next round refreshes the canvas-state context.

## Multi-agent shapes (Slack-style)

If the new shape hosts multiple agents (a Slack-like room, a multi-agent panel), you'll also need:

- A small invocation-policy actor (see [SlackInvoker.swift](../Pupa/Sources/PupaApp/Slack/SlackInvoker.swift)) — per-agent lock, invocation-stack reentrancy guard, max-chain-depth cap, and live per-invocation state for UI rendering.
- An invocation method on [ChatSessionCoordinator](../Pupa/Sources/PupaApp/Chat/ChatSessionCoordinator.swift) that builds a transient `AgentSession`, maps the channel history to a user prompt, injects persona via a context entry, and consumes `SessionEvent.toolCallStarted/.toolCallFinished` to feed the live state.
- A per-invocation memory namespace via `MemoryStore.agentRoot(agentId:)` so two agents don't collide on file paths.
- A tool-context value object (see `AppTools.SlackToolContext`) carrying `currentAgentId`, an `invoke` closure for fan-out, and a `markMessagePosted` callback for auto-post suppression. Admin tools refuse when `currentAgentId != nil`; posting tools require it to be non-nil.

The full Slack architecture lives in [docs/components/slack.md](components/slack.md) — read its sections on the invocation lifecycle, `slackPostMessage` fan-out, and reentrancy guard before designing your own multi-agent shape.
