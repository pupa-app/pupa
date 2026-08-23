import Foundation

/// Common interface every seeded example MyApp must satisfy.
///
/// Each conforming type is responsible for building its `MyApp` value and
/// writing the optional AGENTS.md memory files that give the example its
/// agent personas. Both operations are idempotent — `make()` always
/// allocates fresh UUIDs so restoring never duplicates an existing copy,
/// and `seedAgentsMd` runs only at app birth (fresh-install + restore), so a
/// user's edits — and deletions — to the persona files are never resurrected.
public protocol ExampleMyApp {
    /// Display name. Also the idempotency key used by `MyAppStore` to
    /// detect whether the example is already present in the sidebar.
    static var name: String { get }
    /// SF Symbol name shown next to the example in the Settings picker.
    static var iconSystemName: String { get }
    /// One-line description rendered as picker subtitle in Settings.
    static var tagline: String { get }

    /// Build a fully-populated `MyApp` ready to append to the store.
    static func make() -> MyApp

    /// Write AGENTS.md persona files into `appRoot` (the app's memory root,
    /// keyed on its immutable id). No-op for examples that don't need them.
    /// Always `@MainActor` because `MemoryStore` is main-actor-isolated.
    /// `globalMemory` is rescanned when non-nil; pass nil from app-birth call
    /// sites that have no sidebar store (the chat coordinator rescans on the
    /// next app-scoped write).
    @MainActor
    static func seedAgentsMd(globalMemory: MemoryStore?, appRoot: URL)
}

/// Centralised registry of all seeded examples. Add a new conformance here
/// to make it appear in the Settings picker and in the first-launch seed.
public enum ExampleRegistry {
    // Daily Briefing is first so it's both the default first-launch seed and
    // the Settings picker's default selection.
    public nonisolated(unsafe) static let all: [any ExampleMyApp.Type] = [
        DailyBriefingExample.self,
        WellbeingCoachExample.self,
        JobSearchExample.self,
        ContentStudioExample.self,
        DevWorkspaceExample.self,
        FashionCompanionExample.self,
        ResearchTrackerExample.self,
    ]

    /// Seed one example's persona AGENTS.md at app birth (restore / fresh
    /// install). The example is identified by display name; its memories are
    /// rooted on `id`. No-op when the name isn't an example. `globalMemory` is
    /// rescanned when provided.
    @MainActor
    public static func seedAgentsMd(
        forAppNamed name: String, id: UUID, globalMemory: MemoryStore? = nil
    ) {
        example(named: name)?.seedAgentsMd(
            globalMemory: globalMemory, appRoot: MemoryStore.appRoot(myAppId: id))
    }

    /// Look up an example type by its `name`. Returns `nil` when not found.
    public static func example(named name: String) -> (any ExampleMyApp.Type)? {
        all.first(where: { $0.name == name })
    }
}
