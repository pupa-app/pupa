import Foundation

/// Seeded "Job Search & Apply" MyApp — the published marketplace app, shipped
/// in-app.
///
/// Unlike the hand-written examples, this one *is* the `job-search-apply`
/// bundle from the marketplace (pupa-app.com/marketplace), embedded verbatim
/// as a `.pupa` resource so the seed can't drift from the download. The
/// canvas ships empty on purpose — the app is a pipeline you fill by running
/// `/setup` then `/job-search`, not a data demo:
///
/// - **`tracker-3` — Job Search.** One row per opening; fit sub-scores,
///   `status` Lead → To Apply → Applied, kanban by status.
/// - **`tracker-1` — Relevant Events.** Conferences / meetups ranked by
///   relevance, populated by `/find-events`.
/// - **`calendar-1` — Deadlines.** Closing dates + follow-ups, linked to rows.
/// - **`checklist-1` — Application Steps.** Per-application step lists.
///
/// The value is the memory layer `seedAgentsMd` writes: four subagents
/// (job-scout, doc-writer, contact-scout, event-scout), the `/setup`,
/// `/job-search`, `/apply-job`, `/find-contacts`, `/find-events` skills, the
/// search / voice / CV profile files, and one `item.moved` automation that
/// starts an application when a row lands in "To Apply".
///
/// Seeded — not imported — so it keeps the normal MyApp defaults (remote
/// images allowed); `MyAppImporter`'s untrusted-bundle hardening applies to
/// what a user downloads, not to what we ship.
enum JobSearchExample: ExampleMyApp {
    /// Display name used both as the seed's `MyApp.name` and as the
    /// idempotency key for `restoreExampleMyApp()` (a MyApp with this
    /// exact name is treated as the example workspace).
    static let name = "Job Search & Apply"
    static let iconSystemName = "briefcase"
    static let tagline = "Scout openings, score by rubric, tailor and apply"

    /// Resource basename of the embedded bundle, under `Resources/`.
    static let resourceName = "job-search-apply"

    /// Build a fresh `MyApp` from the bundle: its components verbatim, a fresh
    /// id, thread and `createdAt` so a restored copy never collides with a
    /// hand-edited one.
    static func make() -> MyApp {
        let app = bundle.app
        let thread = ChatThread()
        return MyApp(
            name: name,
            iconSystemName: app.iconSystemName,
            typeId: app.typeId,
            components: app.components,
            activeComponentId: app.activeComponentId,
            threads: [thread],
            currentThreadId: thread.id
        )
    }

    // MARK: - Memory seeding

    /// Write the bundle's memory files — app + agent `AGENTS.md`, skills,
    /// profile notes, automations — into `appRoot`. Idempotent: each file is
    /// only written if absent, so user edits survive every launch and every
    /// Settings → "Restore example MyApp" tap.
    ///
    /// `@MainActor` because `MemoryStore` is main-actor-isolated; every call
    /// site is already on the main actor.
    @MainActor
    static func seedAgentsMd(globalMemory: MemoryStore?, appRoot: URL) {
        let appMemory = MemoryStore(rootOverride: appRoot)
        var wroteAny = false
        for file in seededMemories where !appMemory.fileExists(at: file.path) {
            _ = try? appMemory.writeFile(path: file.path, content: file.content)
            wroteAny = true
        }
        // The global store caches its tree at init; rescan so the sidebar
        // picks up the new files on next render.
        if wroteAny { globalMemory?.rescan() }
    }

    /// Bundle memories minus the guide plugin: `GuideSkills` re-seeds those
    /// into every scope on launch, version-gated, so a bundled copy would only
    /// ever be a stale duplicate.
    static var seededMemories: [MemoryFile] {
        bundle.memories.filter { !$0.path.hasPrefix("\(MemoryStore.pupaPluginsDir)/") }
    }

    // MARK: - Bundle

    /// Location of the embedded bundle in the module's resource bundle.
    /// Non-nil in any correctly-built app; exposed so tests can hash the file.
    static var resourceURL: URL? {
        Bundle.module.url(forResource: resourceName, withExtension: MyAppBundle.fileExtension)
    }

    /// The embedded `.pupa`, decoded once. A missing or malformed resource is
    /// a broken build, not a runtime condition — `JobSearchExampleTests` pins
    /// both.
    static let bundle: MyAppBundle = {
        guard let url = resourceURL,
              let data = try? Data(contentsOf: url),
              let decoded = try? MyAppBundle.makeDecoder().decode(MyAppBundle.self, from: data)
        else {
            preconditionFailure("Missing or malformed \(resourceName).\(MyAppBundle.fileExtension) resource")
        }
        return decoded
    }()
}
