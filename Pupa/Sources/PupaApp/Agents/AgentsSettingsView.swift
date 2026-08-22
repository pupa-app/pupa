import SwiftUI

/// Settings ▸ Agents hub. Everything that governs agents lives under here —
/// the roster, the tools they may call, the limits they run under, and the
/// threads they produced — each on its own screen so no page mixes unrelated
/// controls. Same shape as the Import & Export hub.
///
/// Roster and Threads need the app stores; Tools and Limits need only
/// `SettingsStore`, so they render even when the stores are absent (previews).
/// That matters — Tools used to be a top-level Settings row and must stay
/// reachable regardless.
public struct AgentsSettingsView: View {
    let settings: SettingsStore
    var store: MyAppStore?
    var memory: MemoryStore?
    var stats: AgentStatsStore?
    var modelCatalog: ModelCatalogStore?
    /// Live session owner, for the Threads screen's per-thread status dots.
    var coordinator: ChatSessionCoordinator?

    public init(
        settings: SettingsStore,
        store: MyAppStore? = nil,
        memory: MemoryStore? = nil,
        stats: AgentStatsStore? = nil,
        modelCatalog: ModelCatalogStore? = nil,
        coordinator: ChatSessionCoordinator? = nil
    ) {
        self.settings = settings
        self.store = store
        self.memory = memory
        self.stats = stats
        self.modelCatalog = modelCatalog
        self.coordinator = coordinator
    }

    public var body: some View {
        Form {
            Section {
                if let store, let memory, let stats, let modelCatalog {
                    NavigationLink {
                        AgentRosterView(
                            store: store, settings: settings, memory: memory,
                            stats: stats, modelCatalog: modelCatalog
                        )
                    } label: {
                        SettingsHubRow(icon: "person.3.sequence", title: "Roster",
                                       caption: "Agents per app, and their activity")
                    }
                }
                NavigationLink {
                    ToolsSettingsView(settings: settings)
                } label: {
                    SettingsHubRow(icon: "wrench.and.screwdriver", title: "Tools",
                                   caption: "Shell approval & tool permissions")
                }
                NavigationLink {
                    AgentLimitsView(settings: settings)
                } label: {
                    SettingsHubRow(icon: "gauge.with.dots.needle.33percent", title: "Limits",
                                   caption: "Agent-to-agent & turn limits")
                }
                if let store {
                    NavigationLink {
                        AgentThreadsView(store: store, settings: settings, coordinator: coordinator)
                    } label: {
                        SettingsHubRow(icon: "bubble.left.and.bubble.right", title: "Threads",
                                       caption: "Conversations, tokens & cost")
                    }
                }
            }
        }
        .navigationTitle("Agents")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}
