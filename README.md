<p align="center">
  <img src="docs/assets/pupa-icon.png" alt="Pupa" width="160" height="160" />
</p>

# Pupa

[![Pupa](https://img.shields.io/badge/Pupa-0.0.172-000000?logo=apple&logoColor=white)](Pupa/Sources/PupaApp/Version.swift)
[![AGUIKit](https://img.shields.io/badge/AGUIKit-0.0.25-f05138?logo=swift&logoColor=white)](AGUIKit/Sources/AGUIKit/Version.swift)

Native iOS / macOS client for the Pupa agent: a SwiftUI canvas that
moulds into the shape you ask for (tracker, calendar, checklist, slack
rooms, calculator, charts…), a side-panel chat that drives it, and a long-lived Memories
filesystem that survives sessions. Talks plain
[AG-UI](https://github.com/copilotkit/copilotkit) to the
[Pupa backend](https://github.com/pupa-app/pupa-backend) over a single
SSE stream.

## Contents

- [Components](#components)
- [Layout](#layout)
- [Run](#run)
- [Architecture](#architecture)
- [Backend](#backend)
- [Adding a new component](#adding-a-new-component)
- [Contributing](#contributing)

## Components

| Component | Version | Where |
|---|---|---|
| **Pupa iOS / macOS app** (SwiftUI) | `0.0.172` | [`Pupa/Sources/PupaApp/Version.swift`](Pupa/Sources/PupaApp/Version.swift) |
| **AGUIKit** (Swift Package — AG-UI client) | `0.0.25` | [`AGUIKit/Sources/AGUIKit/Version.swift`](AGUIKit/Sources/AGUIKit/Version.swift) |

Patch-only bumps (`0.0.X` → `0.0.X+1`). See [CHANGELOG.md](CHANGELOG.md)
for the root project version and [CONTRIBUTING.md](CONTRIBUTING.md) for
the release flow.

## Layout

```
pupa/
├── AGUIKit/      ← standalone Swift Package, the AG-UI client.
│                   Could be published independently — no dependency on Pupa.
├── Pupa/         ← the app proper. Depends on ../AGUIKit (local SPM path),
│                   plus SwiftUI views, @Observable stores, tool handlers.
├── PupaHost/     ← thin Xcode app project (PupaHost.xcodeproj) that hosts
│                   PupaApp on iOS / macOS via SPM. Used for TestFlight builds.
└── docs/         ← architecture + "adding a new component" recipe.
```

`AGUIKit` is meant to be **the AG-UI client library that doesn't exist
in the Swift ecosystem yet** — equivalent to what `@copilotkit/runtime`
+ `@copilotkit/react-core` do for browsers. By keeping it isolated,
anyone building any AG-UI agent client on Apple platforms can reuse it
without taking on Pupa's UI choices.

## Run

### macOS demo (fast iteration outside Xcode)

```bash
# 1. Start a backend on :8004 (see https://github.com/pupa-app/pupa-backend).
# 2. Run the macOS demo:
make mac-demo            # = swift run --package-path Pupa PupaDemo
```

The demo defaults to `http://localhost:8004/`. Override by passing
`backendURL:` to `AppView` in `Pupa/Sources/PupaDemo/App.swift`, or via
Settings → Backend inside the running app.

### iOS / macOS app via Xcode

Open `PupaHost/PupaHost.xcodeproj` in Xcode 16+; the host app pulls in
`PupaApp` via the workspace's pinned SPM dependencies. Select an iOS
simulator or "My Mac (Designed for iPad)" and run.

> **Signing.** `DEVELOPMENT_TEAM` is intentionally blank in the checked-in
> project. Before running on a device or archiving for TestFlight, set
> your own team under the `PupaHost` target → Signing & Capabilities (or
> via `xcodebuild DEVELOPMENT_TEAM=...`). The `testflight-release` skill
> does not set it for you.

### Tests

```bash
make test                # both packages
make test-aguikit        # AGUIKit only (use FILTER=Foo to scope)
make test-pupa           # PupaApp only
```

## Architecture

```
   ┌─────────────────────────────────────┐
   │  Pupa (SwiftUI app)                 │
   │   • Canvas (tracker / calendar /    │   ────── AG-UI ───────▶   Pupa backend
   │     checklist / slack / …)          │      POST / (SSE)          (FastAPI on :8004)
   │   • Chat + slash commands           │
   │   • Frontend tools (canvas + mem)   │
   │   • Memories filesystem             │
   │   • UserDefaults state              │
   │                                     │
   │     uses ─▶  AGUIKit                │
   │                • AgentClient/Session│
   │                • multi-round loop   │
   │                • ToolRegistry       │
   └─────────────────────────────────────┘
```

Key facts:

- **Canvas mutations only via `CanvasState`
  ([Pupa/Sources/PupaApp/Canvas/CanvasState.swift](Pupa/Sources/PupaApp/Canvas/CanvasState.swift))
  or registered frontend tools.** No duplicate mutation logic in views.
- **Shapes are SwiftUI views**, not generative-UI primitives. Adding one
  = small self-contained change — recipe at
  [docs/adding-a-component.md](docs/adding-a-component.md).
- **Agent behaviour primarily via frontend tools** registered in
  [`AppTools.swift`](Pupa/Sources/PupaApp/Tools/AppTools.swift). The
  backend only owns `tavily_search` (optional).
- **Memories are persistent**; canvas + chat state reset on "New
  session" but the markdown filesystem at
  `~/Library/Application Support/pupa/memories/` survives.

Full reference in [docs/architecture.md](docs/architecture.md).

## Backend

The backend lives in a separate repo —
[pupa-app/pupa-backend](https://github.com/pupa-app/pupa-backend).
Install + run + pair-once auth flow are documented there. The client
defaults to `http://localhost:8004/`; point it at a hosted instance via
Settings → Backend.

## Adding a new component

Follow [docs/adding-a-component.md](docs/adding-a-component.md) — full
recipe (SwiftUI view, typed data model, render + mutator tools, kind
registration on `MyAppType`, tests) covered end-to-end.

## TestFlight

The `testflight-release` skill at
[`.claude/skills/testflight-release/`](.claude/skills/testflight-release/)
syncs `MARKETING_VERSION` to `PupaAppVersion`, bumps
`CURRENT_PROJECT_VERSION`, and produces a `.xcarchive` ready for upload
via Xcode Organizer. Invoke through Claude Code's
`/testflight-release`, or run the script directly:

```bash
.claude/skills/testflight-release/archive.sh [--build N] [--no-bump] [--skip-icon-check]
```

## Contributing

[CONTRIBUTING.md](CONTRIBUTING.md) covers the branching workflow (`dev`
integration, fast-forward release to `main`) and the hard rules for AI
assistants. [CLAUDE.md](CLAUDE.md) is the in-repo agent guide.
