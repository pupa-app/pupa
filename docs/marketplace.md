# Export / Import (marketplace foundation)

How a MyApp is turned into a portable artifact and rebuilt elsewhere. Code:
[Pupa/Sources/PupaApp/Marketplace/](../Pupa/Sources/PupaApp/Marketplace/).
Building the seeded templates that ship as bundles: [templates.md](templates.md).

## What a bundle is

A `.pupa` file is **inert JSON** — `MyAppBundle` (`MyAppBundle.swift`):

```
header   (read & validated first)   app (Codable MyApp tree)   memories[]
```

- `header`: `format` magic, `formatVersion` (hard-reject when newer),
  `appVersion` (soft-warn when newer), `exportedAt`, `includedRecords`,
  `includedMemories`.
- `app`: the whole `MyApp` — the single source of truth. No parallel schema.
  A component's editable `name` / `iconSystemName` / `summary` already live
  here, so renaming or re-iconing a component (via `setComponentMeta`) needs
  **no format change** — `formatVersion` stays put and old bundles load as-is.
- `memories`: `{path, content}`, paths relative to the app's memory root. The
  `pupa/` config subtree (agent + subagent prompts, skills, **automation
  rules** at `pupa/automations.json`) is app capability, not user data: it
  rides the bundle and **survives a memories-off export**. On import,
  `MemoryStore.writeFile` accepts only `.md` / `.json`, so a hostile bundle
  can't drop an executable into the sandbox. `pupa/automations.json` is a
  memories-subtree file like a skill, so it needs **no `formatVersion`
  bump**; it carries prompt text (the `startThread` template), the same
  prompt-injection surface as `AGENTS.md`, and rides the same defense.

The bundle carries **no executable content**. All rebuild logic lives in the
app and is dispatched by component `kind`.

## Unified reference model

Every cross-component reference is enumerated and pruned in **one** place —
`CanvasApp.componentReferences()` / `remapReferences(keepComponent:keepItem:)`
([CanvasState.swift](../Pupa/Sources/PupaApp/Canvas/CanvasState.swift)) — shared
by the delete cascade (`MyAppStore.cascadeRemoveRefs`) and the exporter. The
switch is exhaustive (no `default`), so a new `CanvasApp` arm fails the build
until its refs are declared. It covers: item `linkedItems`; calculator
`aggregate` / `linkedField` / `list` source refs; chart series source
componentIds — **including charts embedded in a calculator** (`inlineChart` /
`extraCharts`). Scalar component sources degrade to broken-but-tolerated rather
than cascading row deletion.

## Per-kind export policy

`ComponentExportPolicy` (`ComponentExportPolicy.swift`) owns only what's
export-specific: `strippingUserData(_ body:)` (drop user records, keep reusable
structure) and an `exportDataWarning`. One per kind, registered in
`MyAppTypeRegistry.registerBuiltins()`. Completeness is enforced by
`ComponentExportRegistry.assertComplete` (a `preconditionFailure` at bootstrap)
**and** a CI test — a supported kind without a policy can't ship.

## Export + share (Settings ▸ Import & Export)

Export is platform-split. On iPhone / iPad it's a **Share…** action
(`ShareLink`): the selection is encoded to a temp `<App>.pupa` and handed to the
system share sheet — AirDrop, Messages, WhatsApp, Mail, or Save to Files. The
temp file is rebuilt whenever the component selection or the records/memories
toggles change.

On Mac (`DeviceInfo.isMac` — the shipping Mac app is the iOS binary, so
`#if os(macOS)` is false there) it's a **Save…** action: the same bytes go
straight to `.fileExporter` / `MyAppDocument`, no temp file. The share sheet is
not offered because its "Save to Files" service crashes the app — ShareKit
passes `nil` to `-[NSSavePanel setNameFieldStringValue:]` (Apple bug,
FB13819800). The file base name comes from `MyAppExporter.exportBaseName`,
which falls back to `pupa-app` for names that slugify to empty.

`MyAppExporter.makeBundle`: keep selected components → strip records per policy
(when records off) → prune dangling refs → carry agents (structural) → scope
memories (drop a deselected kind's subtree; memories-off keeps only `AGENTS.md`)
→ reset volatile state (threads) → assemble header.

A pin's **Export** (History / Settings ▸ Pinned snapshots) reuses this *same*
screen (`ExportShareScreen`), fed the resolved snapshot
(`MyAppStore.restoredApp(forSnapshot:appId:)`) instead of the live app and
flagged with a "Pinned version" banner. Records/memories default off, same as a
live share.

## Import — three entry points, one authority

A bundle reaches the importer three ways: the in-app **Import bundle…** picker,
**tap-to-open** — a `.pupa` opened from Files / Mail / a chat app — and a
**marketplace install link** on iOS/iPadOS. The OS routes tap-to-open via the
registered file type (see *File type*) and the link via the registered
`pupa-install` scheme; SwiftUI delivers both to `AppView.onOpenURL`. Because
those sources are untrusted, an external open is **read-only decoded for a
confirm sheet** (app name + agent prompts) before anything runs — only on
confirm does it call the same `MyAppImporter.importBundle`. All three paths
share that one validation authority.

### Install links (`pupa-install://`)

`pupa-install://import?url=<https .pupa>&sha256=<hex>`. Safari can't hand a
website's `.pupa` to Pupa — it lands in Downloads and needs a manual "Open in" —
so the marketplace page sends a link and Pupa fetches the bytes itself. The
website already holds the catalog entry, so the link carries what Pupa needs and
the app learns nothing about catalogs. The Import screen's "Browse the
marketplace" row is the outbound half of the same round trip — one hard-coded
page URL (`browseURL`), no catalog fetch in the client. Universal Links can't serve this: iOS
suppresses them when link and page share a domain.

`MarketplaceInstallLink` owns the untrusted edge. It allow-lists the bundle URL
**by URL component** (`https`, host `raw.githubusercontent.com`, path under
`/pupa-app/marketplace/main/apps/`, extension `.pupa`, no `..`) — a string
prefix would accept `https://raw.githubusercontent.com@evil.example/…`, and a
repo-wide prefix would accept unmerged fork-PR heads, which raw.githubusercontent
serves under the base repo's path. `fetchBundle` then caps the transfer at
`MyAppImporter.maxBundleBytes` (declared `Content-Length` first, running cap
while reading) and verifies the bytes against the link's digest before anything
is staged. One target builds both platforms, so macOS registers the scheme too.

Only `pupa-install` is registered. The in-app `pupa` (ChatLink) and `pupa-pair`
(QR) schemes stay unregistered — both feed paths written for locally produced
text, not for anything a web page can emit.

`MyAppImporter.importBundle` treats the bundle as **hostile** and validates
fully before any store/disk mutation:

1. size cap (pre-decode) → decode → header magic + version.
2. `typeId` resolves; every component `kind` is supported + has a policy.
3. caps (components / items / messages / memory files) + uniqueness
   (component / item / agent / channel ids).
4. **settings allow-list** — only an `llm.*` pair survives; keys like
   `shell_approval_disabled` are dropped. Immediately after, the importer
   stamps `media.remoteImages: false` — *after* the allow-list, so a bundle
   asking for it has already had the key dropped.
5. fresh `id`, slug-collision-safe rename, fresh thread + `createdAt`.
6. prune dangling refs. (The `llm.*` pair is kept when both fields are
   non-empty strings — the model catalog is backend-provided now, so it can't
   be validated here; an unknown pair is rejected at request time.)
7. insert; then write memories via `MemoryStore.writeFile` (its `resolve`
   blocks `..`, absolute paths, and any extension outside `.md` / `.json`).
   `pupa/automations.json` is rewritten on the way through to force
   `confirm: true` on every rule.

## Library bundle (many apps in one file)

`MyAppLibraryBundle` (`MyAppLibraryBundle.swift`) is a thin container —
`header` + `apps: [MyAppBundle]` — that ships **every** MyApp in one file. Same
`.pupa` extension; the two are told apart by `header.format`
(`pupa.library.bundle` vs `pupa.myapp.bundle`), probed by
`MyAppImporter.probeFormat` so the UI routes single vs library (Files picker,
tap-to-open confirm sheet). No new UTType.

- **Export**: the Share screen's app picker has an **All apps** option →
  `MyAppExporter.makeLibraryBundle` calls `makeBundle` once per app (all
  components, shared records/memories toggles). No separate screen.
- **Import**: `MyAppImporter.importLibrary` decodes, checks the library
  magic/version + an app-count cap, then loops `importDecoded` — the same
  per-app authority the single path uses. **Best-effort**: one malformed app is
  skipped with a warning, the rest land. Because each app is inserted before the
  next imports, the slug-unique rename deduplicates apps that collide with each
  other.

No new security surface: every per-app guard runs per app; the container adds
only a larger pre-decode byte cap and the app-count cap.

## Threat model

The bundle is inert (no code execution). Remaining vectors → mitigations:

| Vector | Mitigation |
|---|---|
| Settings injection (`shell_approval_disabled` …) | allow-list to validated `llm.*` |
| Prompt injection via `AGENTS.md` / Slack personas (runs with victim's tools) | export review pane + "imported" provenance + a confirm sheet (names app + agent prompts) on externally-opened files; **real fix = signing + moderation in the backend follow-on** |
| Bundled automation rules (`pupa/automations.json`) that auto-invoke the model on a canvas move | **closed for direct bundle authorship**: the importer rewrites the file to force `confirm: true`, matching the path through `MemoryStore.canonicalise` so a differently-spelled path (`/pupa/…`, `pupa//…`, `pupa/Automations.JSON`) can't land on the file while dodging the rewrite. Rules the user writes locally are untouched. **Still reachable via the row above**: the file is an ordinary writable `.json`, so an injected prompt can ask the agent's memory tools to set `confirm:false` after import |
| Bundle content that calls out on render (image URLs in cards or notes) — a zero-click beacon, and a LAN probe since ATS permits local networking | imported apps are stamped `media.remoteImages: false`; card and markdown images render a placeholder until the user turns it on. The bundle can't grant itself the setting — the allow-list drops it and the importer stamps `false` afterwards |
| Link fields reaching the OS by scheme (`file:`, `tel:`, Pupa's own `pupa-install://`) | `TrackerLinkURL.parse` accepts `http`/`https` only |
| Memory path traversal | `MemoryStore.resolve()` prefix/`..`/extension guards (`.md`, `.json`) |
| Cross-app memory clobber via slug collision | slug-unique rename on import |
| DoS (huge/nested bundle) | pre-decode byte cap + post-decode count caps |
| Hostile `pupa-install://` link from any web page | component-wise source allow-list (pinned to `main/apps/`, so unmerged fork-PR heads don't qualify) + `Content-Length`/streaming cap + digest check; a link naming a *real* app the user didn't ask for is left to the confirm sheet |
| Integrity (duplicate ids, dangling `activeComponentId`, unknown kind) | stage-0 validation |
| Cross-app ref escape | refs resolve only within the imported app; `id` reassigned |

Privacy: sharing = publishing. `AGENTS.md` and Slack personas travel as
structure; the export screen surfaces personas for review.

## Follow-on (not yet built)

Remote marketplace service (store/serve bundles + in-app browser). Add a
**signature** to `MyAppBundle` and server-side moderation then — the primary
defense against prompt injection, which the importer can only surface. (A
checksum exists for install links, but it binds bytes to a link, not a bundle to
a publisher.)

## File type

`.pupa` is an **exported UTType** — `com.pupa-app.app-bundle`, conforming to
`public.data` **only** (not `public.json`/`public.text`: a text conformance
makes Files/QuickLook preview the JSON on tap instead of opening Pupa),
declared in `PupaHost/Info.plist` (`UTExportedTypeDeclarations`) and owned by
the app via `CFBundleDocumentTypes` (`LSHandlerRank = Owner`). That ownership +
opacity is what lets the OS open a received `.pupa` in Pupa (tap-to-import).
The type carries **no `public.mime-type` tag** (a prior `application/json` tag
made chat apps preview the JSON instead of offering "Open in Pupa"), and
`LSSupportsOpeningDocumentsInPlace=YES` so Files routes a tap straight to the
import sheet — Pupa reads the original URL under a security-scoped resource and
copies the bytes itself.
In Swift it's `UTType.pupaAppBundle` (`PupaUTType.swift`): the share/export side
writes it, the importer accepts it **and** legacy `.json` exports. A bundle is
still JSON, so the importer validates via the header `format` magic, not the
extension. The Info.plist holds only the array keys — `GENERATE_INFOPLIST_FILE`
stays on and merges the generated keys over it. `CFBundleURLTypes` in the same
file registers `pupa-install` (see *Install links*).
