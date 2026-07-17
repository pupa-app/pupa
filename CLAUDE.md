# Pupa iOS / macOS — agent guide

NEVER SIGN YOURSELF IN ANY COMMIT OR PR OR ISSUE. NEVER LEAVE ANY PERSONAL INFORMATION IN THE REPO INCLUDING DEVELOPERS' ACCOUNT NAMES AND PATHS ON THEIR MACHINES.

BE VERY SUCCINT, IN DOCSTRINGS, DOCS and PROMPTS. 

**Prompt vs tool description split:** `promptFragmentsByKind` is for *when to use* a component and cross-kind tips — not operational detail. Operational detail (schemas, parameter shapes, operator lists, error modes) belongs in tool descriptions and JSON schemas. Never repeat tool schema content in the prompt fragment.

USE /caveman SKILL BY DEFAULT

Native iOS / macOS client for the Pupa agent. SwiftUI canvas that moulds
into shapes (`tracker` / `calendar` / `checklist` / `slack`…) + side-panel
chat that drives the canvas via frontend tools. Talks plain AG-UI to the
backend (separate repo) over a single `POST /` SSE stream.

## Read these first

- [docs/architecture.md](docs/architecture.md) — how the app works **right
  now**. Source of truth.
- [docs/adding-a-component.md](docs/adding-a-component.md) — end-to-end
  recipe for landing a new canvas shape.
- [docs/marketplace.md](docs/marketplace.md) — MyApp export/import bundle
  format, the unified reference model, and the import threat model.
- [docs/skills.md](docs/skills.md) — the per-MyApp `pupa/` config folder
  (AGENTS.md, subagent prompts) and how skills become slash commands +
  model-loadable playbooks (`app_skill_view`).
- [docs/templates.md](docs/templates.md) — the realism bar for shipping
  `.pupa` templates: rubric, grounded reference index, and the
  self-maintaining agent loop. Read before adding an `ExampleMyApp`.
- [AGUIKit/](AGUIKit/) — standalone Swift Package: AG-UI client, tool
  registry, multi-round session loop. No dependency on Pupa.
- [Pupa/](Pupa/) — the app: SwiftUI views, `@Observable` stores, tool
  handlers. Depends on `../AGUIKit` (local SPM path).
- [PupaHost/](PupaHost/) — thin Xcode app project hosting `PupaApp`; used
  for TestFlight archives.
- [CHANGELOG.md](CHANGELOG.md) — release history. Patch-only bumps.

## When changing behaviour — update the docs

On any change (new shape, tool, state, persistence rule, layout): update
[docs/architecture.md](docs/architecture.md) to reflect reality. Add an
entry to [CHANGELOG.md](CHANGELOG.md) under the next patch bump for
user-visible changes. If the change alters what the user can see or do,
also update the guide skill bodies in
[GuideSkills.swift](Pupa/Sources/PupaApp/Skills/GuideSkills.swift) **and
bump `GuideSkills.version`** so existing installs re-seed.

## Versioning

Single CHANGELOG, `0.0.X` versions. **Bump patch only** (`0.0.1` →
`0.0.2`) unless the user says otherwise.

Sub-packages keep independent patch-only versions:

| Package | Version file |
|---|---|
| Pupa iOS | `Pupa/Sources/PupaApp/Version.swift` (`PupaAppVersion`) |
| AGUIKit | `AGUIKit/Sources/AGUIKit/Version.swift` (`AGUIKitVersion`) |

Bump a sub-package version when its code changes; bump the root project
version (root CHANGELOG + README badge) when shipping any
release-worthy change. `PupaAppVersion` is the source of truth for the
TestFlight `MARKETING_VERSION` — see the `testflight-release` skill.

## Branching & releases

See [CONTRIBUTING.md](CONTRIBUTING.md). Branch from `dev`, squash-merge
to `dev`, fast-forward `main` from `dev` for releases.

## Conventions

- **Canvas mutations only via `CanvasState`
  ([Pupa/Sources/PupaApp/Canvas/CanvasState.swift](Pupa/Sources/PupaApp/Canvas/CanvasState.swift))
  or registered frontend tools.** No duplicate mutation logic in views.
- **Shapes are SwiftUI views**, not generative-UI primitives. Adding one
  = small self-contained change — follow the recipe at
  [docs/adding-a-component.md](docs/adding-a-component.md).
- **Agent behaviour primarily via frontend tools** in
  [`AppTools.swift`](Pupa/Sources/PupaApp/Tools/AppTools.swift). The
  backend forwards their JSON-Schema definitions to the model; the client
  executes them. Keep the `addComponent` kind enum in sync with
  `MyAppType.supportedComponentKinds`.
- **Memory files are persistent** (long-term markdown filesystem at
  `~/Library/Application Support/pupa/memories/`); canvas state +
  `threadId` reset on "New session".
- **Keep the model catalog in sync.** `KnownLLMModelCatalog`
  ([Pupa/Sources/PupaApp/Agents/KnownLLMModel.swift](Pupa/Sources/PupaApp/Agents/KnownLLMModel.swift))
  must track the backend's `MODEL_REGISTRY`.
- **Write a test early when helpful.** For bugs / features, prefer a
  failing test up front; skip only for pure UI tweaks and docs.
- **Run the suite with `make test`** — not raw `swift test`. It covers
  both packages (AGUIKit + Pupa) and pins Pupa's `--no-parallel`. Narrow
  with `make test FILTER=SomeTests`.

## Run

`make help` for targets. `make mac-demo` runs the native macOS demo
against a backend on `:8004`; `make build` / `make test` compile and
test both Swift packages. Open `PupaHost/PupaHost.xcodeproj` in Xcode
for iOS simulator / device runs.

## CI

GitHub Actions currently **fails from a billing block, not real test
failures** — a blocked job shows 0 steps and "fails" in ~2s. Ignore red
CI; verify locally with `make test` (the source of truth until billing
is restored).
