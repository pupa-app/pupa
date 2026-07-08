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
    static let version = "4"

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

    /// Seed a single app by name (constructs its own scope-rooted store).
    @MainActor @discardableResult
    static func seed(appName: String) -> Bool {
        seed(into: MemoryStore(rootOverride: MemoryStore.appRoot(myAppName: appName)))
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
    - **Memories** — each myapp (and the orchestrator) keeps its own markdown
      notes, edited by you and the agent alike. They persist across sessions
      and are separate from canvas data — durable context, not records.

    Items can link across components *within one myapp*. Myapps don't share
    data — an app moves between devices or people as a `.pupa` file.

    **Go deeper** (users: type the `/command`; agents: `app_skill_view`)
    - /pupa-components — the shapes a canvas can hold and how they combine
    - /pupa-sharing — export and install myapps as `.pupa` files
    - /pupa-memory — memories, sessions, change history, archive
    - /pupa-agents — skills, subagents and slack rooms
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
    records and memories ride along, then Share (AirDrop, Messages, Files…).

    **Install.** Open a `.pupa` file (or import from Settings). A confirmation
    sheet shows what's inside before anything is added. Imported agent
    instructions run with your tools once installed — only install bundles
    you trust.
    """

    private static let memoryBody = """
    \(frontMatter(
        description: "How Pupa remembers: memories, sessions, change history, archive",
        whenToUse: "when asked what persists, how to undo changes, or how to hide an app"
    ))
    - **Memories** — per-app markdown notes both you and the agent read and
      write. They persist across sessions; edit them any time from the
      Memories tab.
    - **Sessions** — "New session" starts a fresh conversation. The canvas
      and memories stay.
    - **History** — every canvas change is recorded per myapp. Browse the
      History tab and restore any earlier state in one tap.
    - **Archive** — hide a myapp without deleting it (its data and memories
      are kept). Browse, restore or delete from Settings ▸ Archive.
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
    per-app markdown filesystem for durable notes — not canvas data. Two
    different stores; don't cross them.

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
