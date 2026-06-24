import Foundation

/// Coarse classification used to badge a row on the agents list.
public enum AgentKind: String, Sendable {
    case myApp
    case slack
    /// The cross-MyApp meta-agent. Has no `myAppId` — it routes against
    /// every MyApp via `invokeMyAppAgent` and lives in the `.memory` scope.
    case orchestrator

    public var displayName: String {
        switch self {
        case .myApp: return "MyApp"
        case .slack: return "Slack"
        case .orchestrator: return "Orchestrator"
        }
    }
}

/// View-model snapshot of one agent, surfaced on the per-MyApp Agents
/// list and details pages. The struct intentionally exposes its
/// attributes as an ordered `[AgentProperty]` so adding a new field
/// later is one `append(...)` in `AgentRegistry.enumerateAgents` plus,
/// if a new render mode is required, one case in `AgentPropertyValue`.
public struct AgentDescriptor: Identifiable, Sendable, Hashable {
    public let id: String
    public let name: String
    public let kind: AgentKind
    public let iconSystemName: String
    /// The owning MyApp. `nil` for the orchestrator, which is scope-wide
    /// and not parented to any MyApp.
    public let myAppId: UUID?
    /// Optional one-liner shown under the name in the list (e.g. a
    /// Slack agent's role).
    public let subtitle: String?
    /// Glanceable model label for the list row (e.g. "Sonnet 4.6" or
    /// "Backend default"). Derived in `AgentRegistry` so the list view never
    /// reaches into `properties`.
    public let modelSummary: String
    /// Glanceable tool-count caption for the list row (e.g. "12 tools" or
    /// "12 tools · 2 off").
    public let toolSummary: String
    public let properties: [AgentProperty]

    public init(
        id: String,
        name: String,
        kind: AgentKind,
        iconSystemName: String,
        myAppId: UUID?,
        subtitle: String? = nil,
        modelSummary: String,
        toolSummary: String,
        properties: [AgentProperty]
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.iconSystemName = iconSystemName
        self.myAppId = myAppId
        self.subtitle = subtitle
        self.modelSummary = modelSummary
        self.toolSummary = toolSummary
        self.properties = properties
    }
}

/// One row on the agent details page.
public struct AgentProperty: Identifiable, Sendable, Hashable {
    public let id: String
    public let label: String
    public let value: AgentPropertyValue
    /// Optional secondary line under the value — used today for TODO
    /// markers ("not modifiable yet", "resolved at global scope") so the
    /// view conveys what's flexible vs. read-only without duplicating
    /// renderers.
    public let note: String?

    public init(id: String, label: String, value: AgentPropertyValue, note: String? = nil) {
        self.id = id
        self.label = label
        self.value = value
        self.note = note
    }
}

/// Discriminated union the details view switches on. Each case is a
/// presentation shape, not a domain type — when a future attribute needs
/// a different rendering (e.g. a chart, a toggle), add a new case here
/// and a matching branch in `AgentPropertyRow`.
public enum AgentPropertyValue: Sendable, Hashable {
    case text(String)
    case badge(primary: String, secondary: String?)
    case list([String])
    /// Tappable row that pushes `destination` onto the detail-pane stack.
    /// Used for AGENTS.md prompt links (`.myAppMemoryFile`).
    case link(label: String, destination: SidebarSelection)
    /// Long, multi-section content (e.g. the agent's full tool surface
    /// grouped by component). Rendered as a collapsed DisclosureGroup —
    /// the row header shows a summary, expanding reveals the sections.
    case sections(summary: String, groups: [AgentPropertySection])
    /// Editable tool surface — same grouping as `.sections`, but each tool
    /// gets an on/off toggle. `disabled` is the agent's current per-agent
    /// disabled set; a tool in it renders off. Flipping a toggle routes a
    /// `(toolName, enabled)` callback (passed separately to `AgentPropertyRow`
    /// so this case stays Hashable). Off = added to the agent's disabled set,
    /// unioned with the global Settings → Tools set at send time.
    case toolToggles(summary: String, groups: [AgentPropertySection], disabled: Set<String>)
    /// Editable model selector. `selectedId` is the currently-chosen
    /// `KnownLLMModel.id`, or `KnownLLMModelCatalog.backendDefaultId` when
    /// no per-agent override is set. `options` is the catalog entries to
    /// offer (grouped by provider in the rendered Menu). The mutation
    /// callback is passed separately to `AgentPropertyRow` so this case
    /// stays Hashable — the row resolves it from the parent view.
    case modelPicker(selectedId: String, options: [KnownLLMModel])
}

/// One labelled bucket inside a `.sections` value (e.g. "Canvas", "Memory",
/// "Tracker"). Item ordering is preserved by the renderer.
public struct AgentPropertySection: Sendable, Hashable {
    public let label: String
    public let items: [String]

    public init(label: String, items: [String]) {
        self.label = label
        self.items = items
    }
}
