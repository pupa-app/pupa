import Foundation

/// Skills every MyApp ships with, independent of which example (if any) it was
/// created from. Universal: written into `pupa/skills/` so the capability rides
/// the `.pupaapp` export bundle.
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

    /// Seed a single app by name (constructs its own scope-rooted store).
    /// Call once when the app is created — not on every launch.
    @MainActor @discardableResult
    static func seed(appName: String) -> Bool {
        seed(into: MemoryStore(rootOverride: MemoryStore.appRoot(myAppName: appName)))
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
}
