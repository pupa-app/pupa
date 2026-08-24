import Foundation

/// The user-facing guide plugin every scope ships with: `/pupa` plus its
/// children (`pupa-components`, `pupa-sharing`, `pupa-memory`, `pupa-agents`,
/// `pupa-system`), bundled under `pupa/plugins/pupa-guide/` so the user's
/// `pupa/skills/` space stays theirs. Seeded into the orchestrator and every
/// MyApp; users read them as `/commands`, agents load them via `app_skill_view`.
///
/// Managed content — the opposite lifecycle of `DefaultSkills`: re-seeded on
/// **every launch**, overwritten whenever the shipped `version` is newer than
/// the on-disk frontmatter `version:`. Edits are lost on the next version
/// bump and deletions resurrect; a custom copy needs a different skill name.
///
/// Bodies are user-conceptual only — no implementation internals. The
/// component-kind list is generated from `MyAppType.kinds` so it can't drift.
enum GuideSkills {
    /// Bump when any guide body changes so existing installs re-seed.
    static let version = "22"

    /// The plugin folder holding this guide's skills.
    static let pluginDir = "\(MemoryStore.pupaPluginsDir)/pupa-guide"

    /// `(dir, body)` pairs; `dir` becomes the `/command` and skill name.
    static func files() -> [(dir: String, body: String)] {
        [
            ("pupa", motherBody),
            ("pupa-components", componentsBody()),
            ("pupa-sharing", sharingBody),
            ("pupa-memory", memoryBody),
            ("pupa-agents", agentsBody),
            ("pupa-automations", automationsBody),
            ("pupa-system", systemBody),
        ]
    }

    /// Write any absent or out-of-date guide skill into `memory`, then run
    /// migrations: drop guide copies an earlier build seeded at the root of
    /// `pupa/skills/` (identified by their managed `version:` frontmatter),
    /// and retire a pristine seeded `/pupa-internals` (the skill this plugin
    /// replaced) — a user-modified copy is left alone. Returns whether
    /// anything changed.
    @MainActor @discardableResult
    static func seed(into memory: MemoryStore) -> Bool {
        var wrote = false
        for (dir, body) in files() {
            let path = "\(pluginDir)/skills/\(dir)/SKILL.md"
            let existing = try? memory.readFile(path: path).content
            guard needsWrite(existing: existing) else { continue }
            _ = try? memory.writeFile(path: path, content: body)
            wrote = true
        }
        for (dir, _) in files() {
            let legacyPath = "\(MemoryStore.pupaSkillsDir)/\(dir)/SKILL.md"
            guard let old = try? memory.readFile(path: legacyPath).content,
                  SkillFrontMatter.parse(old).fields["version"] != nil else { continue }
            try? memory.delete(path: "\(MemoryStore.pupaSkillsDir)/\(dir)", recursive: true)
            wrote = true
        }
        let internalsPath = "\(MemoryStore.pupaSkillsDir)/pupa-internals/SKILL.md"
        if let old = try? memory.readFile(path: internalsPath).content,
           old == DefaultSkills.retiredPupaInternalsSkillMd {
            try? memory.delete(path: "\(MemoryStore.pupaSkillsDir)/pupa-internals", recursive: true)
            wrote = true
        }
        return wrote
    }

    /// Seed a single app (constructs its own scope-rooted store).
    @MainActor @discardableResult
    static func seed(appId: UUID) -> Bool {
        seed(into: MemoryStore(rootOverride: MemoryStore.appRoot(myAppId: appId)))
    }

    /// Seed the orchestrator scope.
    @MainActor @discardableResult
    static func seedOrchestrator() -> Bool {
        seed(into: MemoryStore(rootOverride: MemoryStore.orchestratorRoot()))
    }

    /// True when the file is absent or its frontmatter `version:` is missing
    /// or older than the shipped `version`.
    static func needsWrite(existing: String?) -> Bool {
        guard let existing else { return true }
        let (fields, _) = SkillFrontMatter.parse(existing)
        return MyAppImporter.isNewer(version, than: fields["version"] ?? "0")
    }

    private static func frontMatter(description: String, whenToUse: String) -> String {
        """
        ---
        description: \(description)
        when_to_use: \(whenToUse)
        version: \(version)
        ---
        """
    }

    // MARK: - Bodies

    private static let motherBody = """
    \(frontMatter(
        description: "What Pupa is and what it can do — guide entry point",
        whenToUse: "when the user asks what Pupa is, what it can do, or how its pieces fit together"
    ))
    Pupa builds apps around you: describe what you need in chat and the agent
    assembles a **myapp** — a canvas of components it edits live while you talk.

    **Boundaries — who is what**
    - **Orchestrator** — the top-level chat. Creates, renames, archives and
      deletes myapps and delegates work to their agents. Has its own memories
      and skills; no canvas of its own.
    - **Myapp** — one workspace: its own agent, canvas, memories, skills and
      subagents.
    - **Component** — one shape on a myapp's canvas (tracker, calendar, …).
    - **Item** — one record inside a component (row, event, task…).
    - **Memories** — each myapp (and the orchestrator) keeps its own
      filesystem-like tree of markdown notes and folders living *inside* the
      app — not on the device's file system. Edited by you and the agent
      alike; persists across sessions. Durable context, not records.

    Items can link across components *within one myapp*. Myapps don't share
    data — an app moves between devices or people as a `.pupa` file.

    **Go deeper** (users: type the `/command`; agents: `app_skill_view`)
    - /pupa-components — the shapes a canvas can hold and how they combine
    - /pupa-sharing — export and install myapps as `.pupa` files
    - /pupa-memory — memories, sessions, change history, archive
    - /pupa-agents — skills, subagents and slack rooms
    - /pupa-automations — react to canvas events (an item moved) by proposing a chat
    - /pupa-system — where things live: on-device app vs backend, standing instructions
    """

    /// Kind list generated from the builtin type's `kinds` specs so the guide
    /// tracks the real catalog by construction.
    static func componentsBody() -> String {
        let kinds = MyAppType.tracker.kinds
        let kindLines = kinds.keys.sorted()
            .map { "- **\($0)** — \(kinds[$0]?.catalogBlurb ?? $0)" }
            .joined(separator: "\n")
        return """
        \(frontMatter(
            description: "The component shapes a myapp canvas can hold and how they combine",
            whenToUse: "when choosing, combining or linking components, or asked what shapes exist"
        ))
        A myapp's canvas holds components. Available shapes:

        \(kindLines)

        **Combining.** One myapp mixes shapes freely. Items link across
        components — a tracker row to a calendar event, a task to a parent
        record. Calculators and charts read live from other components, and a
        chart can be embedded straight into chat.

        **Views, not shapes.** Kanban is a tracker view mode (table ⇄ cards),
        not a separate component.

        **Finding and scanning.** Both tracker views have a search box above
        the cards — it matches any field, including link URLs, and in kanban it
        narrows the cards without dropping columns. The shrink button next to
        the view toggle collapses every card to its title for a whole-board
        view; it sticks per component. Cards with several links show the first
        few and a "+N" you can tap to see the rest.
        """
    }

    private static let sharingBody = """
    \(frontMatter(
        description: "Share and install myapps as .pupa files",
        whenToUse: "when exporting, sharing, importing or installing an app"
    ))
    A `.pupa` file is an inert snapshot of a myapp: its components, optionally
    your records and memories, plus the app's agent instructions and skills.
    No code runs from the file itself.

    **Export.** Settings ▸ Import & Export: pick components, choose whether
    records and memories ride along, then Share (AirDrop, Messages, Files…) —
    on Mac, Save, which writes the `.pupa` wherever you choose.
    Exporting a pinned snapshot (from History or Settings ▸ Pinned snapshots)
    opens this same screen with a "Pinned version" banner — records and memories
    default off there too.

    **Install.** Open a `.pupa` file (or import from Settings). A confirmation
    sheet shows what's inside before anything is added. Imported agent
    instructions run with your tools once installed — only install bundles
    you trust.

    **Marketplace.** Settings ▸ Import & Export ▸ Import an app links out to
    pupa-app.com/marketplace. Installing from there sends the app back to Pupa
    through the same confirmation sheet.
    """

    private static let memoryBody = """
    \(frontMatter(
        description: "How Pupa remembers: memories, sessions, change history, archive",
        whenToUse: "when asked what persists, how to undo changes, or how to hide an app"
    ))
    - **Memories** — a filesystem-like tree of notes and folders that lives
      *inside* the app, not on the device's file system. Notes are markdown
      (`.md`); config notes can be `.json` and show verbatim as code, so
      indentation survives. Browse and edit it from the Memories tab; the agent
      reads and writes it too. Persists across sessions.
    - **Sessions** — "New session" starts a fresh conversation. The canvas
      and memories stay. Past conversations are kept on-device and re-open with
      their full history when you reopen the app — even after a long time away.
    - **History** — every canvas change is recorded per myapp. Browse the
      History tab and restore any earlier state in one tap. Tap **Take
      snapshot** to pin the current state permanently (kept forever); pinned
      snapshots can be **Export**ed as a `.pupa` file (same share screen as
      Settings, flagged as the pinned version). Pins survive deleting
      the myapp — find them all in **Settings ▸ Pinned snapshots**, where a
      deleted app can be restored (revived) from a pin.
    - **Archive** — hide a myapp without deleting it (its data and memories
      are kept). Browse, restore or delete from Settings ▸ Archive.
    - **Folders** — tidy the sidebar: a myapp's row menu ▸ Move to Folder puts
      it in a folder (or a new one); a folder row collapses, renames or
      ungroups. Cosmetic only — folders never travel in a `.pupa` file, and a
      folder disappears once its last myapp leaves.
    - **Recently deleted** — deleting a myapp is undoable for 180 days.
      Settings ▸ Recently deleted lists them (including ones deleted on another
      device, and ones a sync removed on its own) and restores the last saved
      state — chats, components, and any skills or subagents a sync took with
      it. Dismissing the "Sync removed …"
      banner loses nothing — the app waits here. Each row can also be **deleted
      permanently** — that erases its saved state, pinned snapshots included, on
      every device.
    - **Recovering lost skills** — if a sync takes a skill or subagent from a
      myapp that is still here, a "Sync removed N memory files" banner offers to
      put them back. Recoverable for 30 days.
    """

    private static let agentsBody = """
    \(frontMatter(
        description: "Skills, subagents and multi-agent slack rooms",
        whenToUse: "when creating skills or subagents, using /commands, or working with slack rooms"
    ))
    - **Skills** — reusable playbooks that double as `/commands` in chat.
      Each app has its own set (this guide is one). Ask the agent to create
      one, or write it yourself in the memory tree under `pupa/skills/`.
    - **Subagents** — named delegates with their own persona and
      instructions. The main agent creates them and hands off focused tasks.
    - **Orchestrator** — the top-level agent: creates and manages myapps and
      delegates work to each app's agent.

    **Slack rooms.** A component with channels, group DMs and DMs. The
    workspace roster is simply *all* the myapp's subagents — creating a
    subagent adds it to the roster; nothing lives in the component but rooms
    and their transcripts. @-mention an agent (or post in its DM) to wake it:
    it reads the channel's history for context, works with the app's tools,
    and posts its reply back to the channel. Agents can @-mention each other,
    so one message can start a chain of replies. Exporting the app keeps the
    channels and the agent personas but strips the transcripts.
    """

    /// Bundle automations (issue #209): the authoring contract for
    /// `pupa/automations.json` — trigger catalog, matcher, action templates,
    /// and the guards. User-conceptual up top; the JSON block is the agent's
    /// write recipe (loaded via `app_skill_view`). Keep in sync with
    /// `AutomationConfig` / `RuleEngine`.
    private static let automationsBody = """
    \(frontMatter(
        description: "React to canvas events (an item moved) by proposing a chat — the pupa/automations.json rule format and its guards",
        whenToUse: "when the user wants the app to act automatically on a canvas change, or when authoring or editing automation rules"
    ))
    An **automation** reacts *inside* a myapp to a canvas event by proposing a
    chat. Declarative config, no code — rules ride the `.pupa` bundle and only
    ever start a model turn, always behind a confirm bubble unless a rule
    explicitly opts out.

    **Trigger (v1).** `item.moved` — a user changes any **select** field on a
    tracker item: dragging a kanban lane, editing the field on the card, or
    saving the edit sheet. Independent of the board's group-by — a rule
    watching `Priority` fires while the board is grouped by `Status`, and in
    grid view too. One event per changed select field. Agent moves never
    trigger (so a reaction can't loop on itself).

    **Where.** One file per app: `pupa/automations.json`. Shape mirrors Claude
    Code hook config — an `automations` map keyed by event name, each a list of
    rules — but these are Pupa domain events, not harness hooks.

    ```json
    {"automations":{"item.moved":[
      {"id":"review-on-move",
       "matcher":{"field":"Status","toColumn":"Review"},
       "action":{"startThread":{"prompt":"Review {{item.title}}."}},
       "confirm":true}
    ]}}
    ```

    **Fields.**
    - `id` (required) — unique per rule; also the lock key.
    - `matcher` — field-equality predicates, **all must hold (AND)**; omit or
      `{}` to match every move. Keys are any of the item's own fields plus the
      transition keys `field` / `toColumn` / `fromColumn`. Add `field` whenever
      two select fields share an option name, or the rule fires on both.
    - `action.startThread.prompt` (required) — the chat prompt. Templates:
      `{{item.title}}`, `{{item.<field>}}`, `{{field}}`, `{{toColumn}}`,
      `{{fromColumn}}`, substituted literally (no code).
    - `confirm` — `true` (default) proposes a Start/Dismiss bubble; `false`
      auto-fires with no prompt. `false` only survives in rules the user wrote
      locally: **import rewrites every rule to `confirm: true`**, so shipping
      it in a bundle has no effect.

    **Guards (automatic — you don't configure them).**
    - **Self-mutation** — the reaction's own edits don't re-trigger the rule.
    - **Once-per-transition** — the same move fires once within a short window.
    - **In-flight lock** — while a rule's reaction for an item is running, the
      same item won't re-fire it (a timeout backstop frees a stuck one).

    **Limits.** v1 has one event (`item.moved`), one action (`startThread`),
    equality-only matching, and no chaining. A malformed rule is skipped, not
    fatal — the rest of the file still loads.
    """

    /// Agent-facing successor of the retired `/pupa-internals`: the
    /// app/backend boundary and where standing behaviour lives.
    private static let systemBody = """
    \(frontMatter(
        description: "Where things live: the on-device app vs the backend, and standing instructions",
        whenToUse: "when unsure whether something belongs in the app or the backend, which skill system you're touching, or how to change standing behaviour"
    ))
    **App vs backend.** Everything the user sees — components and their
    items, memories, skills, `AGENTS.md` — is app state, created and edited
    **on the user's device** through the app's own tools. The backend only
    runs the model plus a few server-side tools (web search, shell, …) and
    stores **no app data**. Never write app content to a backend path or via
    a shell unless explicitly told to; if unsure where something belongs, ask.

    **Canvas vs memory.** Components hold data items; memory is a *separate*
    per-app markdown note tree for durable context — not canvas data. Two
    different stores; don't cross them. Memory paths are an in-app structure,
    not host file paths — never reach for it via a shell.

    **Two skill systems.** *App* skills are on-device `SKILL.md` files —
    yours under `pupa/skills/<name>/`, bundled ones under
    `pupa/plugins/<plugin>/skills/<name>/` (this guide is one). A backend may
    separately expose its own read-only skills library. App skills are
    always the on-device files.

    **Standing behaviour.** Persistent instructions for an app's main agent
    live at `pupa/AGENTS.md` (subagents: `pupa/agents/<name>/AGENTS.md`).
    Edit those to change behaviour permanently — not memory, not a skill.
    """
}
