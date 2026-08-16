import Foundation

/// Skills every MyApp ships with, independent of which example (if any) it was
/// created from. Universal: written into `pupa/skills/` so the capability rides
/// the `.pupa` export bundle.
///
/// Seeded **once, at app birth** — `addMyApp`, `restoreExample`, and the
/// fresh-install default app. Never on subsequent launches, so the file is the
/// user's from then on: edits *and deletions* stick (a launch-time reseed would
/// resurrect anything the user removed). The `fileExists` guard only avoids
/// clobbering an app that was already seeded.
enum DefaultSkills {
    /// `(path, body)` pairs written into a MyApp's memory root when missing.
    static let files: [(path: String, body: String)] = [
        ("pupa/skills/to-memory/SKILL.md", toMemorySkillMd),
    ]

    /// Write any missing default-skill file into `appMemory`. Returns whether
    /// anything was written.
    @MainActor @discardableResult
    static func seed(into appMemory: MemoryStore) -> Bool {
        var wrote = false
        for (path, body) in files where !appMemory.fileExists(at: path) {
            _ = try? appMemory.writeFile(path: path, content: body)
            wrote = true
        }
        return wrote
    }

    /// Seed a single app (constructs its own scope-rooted store).
    /// Call once when the app is created — not on every launch.
    @MainActor @discardableResult
    static func seed(appId: UUID) -> Bool {
        seed(into: MemoryStore(rootOverride: MemoryStore.appRoot(myAppId: appId)))
    }

    // MARK: - Skill bodies

    /// `/to-memory` — distil durable, app-level guidance from the conversation
    /// into `pupa/MEMORIES.md` so the next session starts already aligned.
    private static let toMemorySkillMd = """
    ---
    description: Record durable, app-level learnings from this conversation to pupa/MEMORIES.md
    when_to_use: when the user runs /to-memory or asks to capture what was learned this session
    ---
    Capture what would help next time someone works on *this* app — especially
    points where the user redirected you or an initial approach needed realignment.

    1. Re-read this conversation. Extract *general, durable* guidance: conventions
       clarified, preferences stated, gotchas, and anything that needed
       realignment mid-task. Skip one-off task specifics.
    2. Read the existing `pupa/MEMORIES.md` (if present) so you merge, not duplicate.
    3. Write to `pupa/MEMORIES.md` or your AGENTS.md file with the merged result — short bullets under clear
       headings, the new insight integrated in place. Choose AGENTS.md for info you should always be aware of in every conversation, 
       while choose MEMORIES.md for info that is not always needed.
    4. Tell the user in one line what you added.
    """

    /// Retired `/pupa-internals` body, replaced by the `GuideSkills` plugin.
    /// Kept verbatim only so `GuideSkills.seed` can recognise (and remove) a
    /// pristine seeded copy on existing installs — never seeded anymore.
    static let retiredPupaInternalsSkillMd = """
    ---
    description: How Pupa fits together — the app(on-device)/backend split, the two skill systems, and where standing behaviour lives
    when_to_use: when unsure whether something belongs in the app or the backend, which skill system you're touching, or how to change your standing behaviour
    ---
    This is the map, not the manual: each tool's own description carries the
    mechanics (which tool, what args, whether to create a component first). What
    follows is only what those descriptions don't tell you.

    **App vs backend — the boundary.** Everything the user sees — canvas
    components and their items, memory, skills, `AGENTS.md` — is app state,
    created and edited **on the user's device** through your frontend tools. The
    backend only runs you plus a few server-side tools (web search, shell, …) and
    stores **no app data**. Never write app content to a backend path or via a
    shell unless explicitly told to; if unsure where something belongs, ask.

    **The object model.** A myapp's canvas holds *components*; data items live
    **inside** a component. Memory is a *separate* per-app markdown filesystem for
    durable notes — not canvas data. Two different stores; don't cross them.

    **Two skill systems — don't confuse them.** *App* skills are the on-device
    `pupa/skills/<name>/SKILL.md` files (this file is one). A backend may
    separately expose its own read-only `skill_view` library. App skills are always the `pupa/skills/` files.

    **Changing standing behaviour.** Persistent instructions for main agent live at
    `pupa/AGENTS.md` (subagents: `pupa/agents/<name>/AGENTS.md`). Edit those to
    change how you or other agents behave permanently — not memory, not a skill.
    """
}
