import Foundation

/// Common interface every seeded example MyApp must satisfy.
///
/// Each conforming type is responsible for building its `MyApp` value and
/// writing the optional AGENTS.md memory files that give the example its
/// agent personas. Both operations are idempotent — `make()` always
/// allocates fresh UUIDs so restoring never duplicates an existing copy,
/// and `seedAgentsMd` is file-exists-guarded so user edits survive every
/// subsequent restore / app launch.
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

    /// Write AGENTS.md persona files into the memory tree. No-op for
    /// examples that don't need them. Always `@MainActor` because
    /// `MemoryStore` is main-actor-isolated.
    @MainActor
    static func seedAgentsMd(globalMemory: MemoryStore, appRootOverride: URL?)
}

/// Centralised registry of all seeded examples. Add a new conformance here
/// to make it appear in the Settings picker and in the first-launch seed.
public enum ExampleRegistry {
    // Wellbeing Coach is first so it's both the default first-launch seed and
    // the Settings picker's default selection.
    public nonisolated(unsafe) static let all: [any ExampleMyApp.Type] = [
        WellbeingCoachExample.self,
        JobSearchExample.self,
        ContentStudioExample.self,
        DevWorkspaceExample.self,
        FashionCompanionExample.self,
        HomeBuyingExample.self,
        ResearchTrackerExample.self,
        DailyBriefingExample.self,
    ]

    /// Write every example's AGENTS.md files. Called once at app launch so
    /// personas are available regardless of which example the user opens.
    @MainActor
    public static func seedAll(globalMemory: MemoryStore) {
        for example in all {
            example.seedAgentsMd(globalMemory: globalMemory, appRootOverride: nil)
        }
    }

    /// Look up an example type by its `name`. Returns `nil` when not found.
    public static func example(named name: String) -> (any ExampleMyApp.Type)? {
        all.first(where: { $0.name == name })
    }
}
