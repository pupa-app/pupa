# Pupa (iOS / macOS)

The native client package. Two products:

- **`PupaApp`** — a Swift Package library with all the SwiftUI views, the
  `@Observable` state stores (`MyAppStore`, `MemoryStore`,
  `SettingsStore`, …), and the frontend tool registrations. Drop into an
  iOS App target in Xcode, `import PupaApp`, and mount `AppView`.
- **`PupaDemo`** — a runnable macOS executable using the same library.
  Fast iteration without Xcode: `swift run PupaDemo` against a backend on
  `:8004`.

Depends on the local `../AGUIKit` package for the AG-UI protocol +
transport. The backend lives in a separate repo —
[pupa-app/pupa-backend](https://github.com/pupa-app/pupa-backend).

## Run on macOS (no Xcode needed)

```sh
# 1. Start a backend on :8004 (see the pupa-backend repo).
# 2. From the repo root:
make mac-demo            # = swift run --package-path Pupa PupaDemo
```

The window pops up with the canvas on the left and chat on the right.
The client speaks AG-UI directly to the FastAPI backend on `:8004`.

## Run on iOS (Xcode)

Open `../PupaHost/PupaHost.xcodeproj` — the host app already wires in
`PupaApp` via SPM. Or, in a fresh project:

1. File → New → Project → iOS App (SwiftUI).
2. File → Add Package Dependencies → Add Local → point at this `Pupa`
   folder.
3. In your `App.swift`:

   ```swift
   import SwiftUI
   import PupaApp

   @main
   struct PupaAppEntry: App {
       var body: some Scene {
           WindowGroup {
               AppView(backendURL: URL(string: "http://YOUR_BACKEND_HOST:8004/")!)
           }
       }
   }
   ```

4. For a non-localhost backend, use HTTPS or add an
   `NSAppTransportSecurity` exception.

## Backend URL

Defaults to `http://localhost:8004/`. Override by passing `backendURL:`
to `AppView`, or in-app via Settings → Backend. Point at a hosted
instance with pair-once auth in front — see the backend repo.

## Layout

```
Sources/PupaApp/
├── App/        # AppView (split canvas + chat), PupaApp scene, app icon
├── MyApps/     # MyApp model + MyAppStore (the single mutation surface)
├── Canvas/     # CanvasState + per-shape views (Tracker/Calendar/Checklist/Kanban/Slack)
├── Chat/       # ChatViewModel, ChatSessionCoordinator (drives AGUIKit)
├── Tools/      # AppTools.swift — registers all frontend tools
├── Memory/     # MemoryStore — sandboxed markdown filesystem
├── Agents/     # per-agent policies, agent pages, KnownLLMModelCatalog
├── Slack/      # SlackInvoker — multi-agent room policy
├── ScreenShare/# WebRTC viewer + signalling for /screenshare/ws
└── Settings/   # SettingsStore (backend URL, API key, disabled tools)

Sources/PupaDemo/
└── App.swift   # @main shell wrapping AppView
```

See [../docs/architecture.md](../docs/architecture.md) for the full
reference and [../docs/adding-a-component.md](../docs/adding-a-component.md)
for the recipe to add a new canvas shape.

## Build & test

```sh
swift build --package-path .     # or: make build-pupa  (from repo root)
swift test  --package-path .     # or: make test-pupa
swift run PupaDemo               # macOS only
```
