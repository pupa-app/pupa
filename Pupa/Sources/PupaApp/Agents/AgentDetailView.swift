import SwiftUI

/// Per-agent details page. Renders the `AgentDescriptor.properties`
/// array as a vertical stack of typed rows — adding a new attribute is
/// one extra `AgentProperty` in `AgentRegistry`, no view changes here
/// unless the new value needs a new render shape.
public struct AgentDetailView: View {
    let store: MyAppStore
    let memory: MemoryStore
    let settings: SettingsStore
    let modelCatalog: ModelCatalogStore
    /// `nil` for the orchestrator (which has no MyApp parent); set for every
    /// MyApp + Slack sub-agent.
    let myAppId: UUID?
    let agentId: String
    var onNavigate: (SidebarSelection) -> Void

    public init(
        store: MyAppStore,
        memory: MemoryStore,
        settings: SettingsStore,
        modelCatalog: ModelCatalogStore,
        myAppId: UUID?,
        agentId: String,
        onNavigate: @escaping (SidebarSelection) -> Void
    ) {
        self.store = store
        self.memory = memory
        self.settings = settings
        self.modelCatalog = modelCatalog
        self.myAppId = myAppId
        self.agentId = agentId
        self.onNavigate = onNavigate
    }

    private var myApp: MyApp? {
        guard let myAppId else { return nil }
        return store.myApps.first(where: { $0.id == myAppId })
    }

    private var appColor: Color {
        guard let myAppId else { return .accentColor }
        return Color.color(atIndex: store.colorIndex(for: myAppId))
    }

    private var descriptor: AgentDescriptor? {
        // Orchestrator path — unscoped, built from settings + global memory.
        if agentId == AgentRegistry.orchestratorAgentId {
            return AgentRegistry.buildOrchestratorAgent(store: store, settings: settings, memory: memory, catalog: modelCatalog)
        }
        guard let app = myApp else { return nil }
        return AgentRegistry.enumerateAgents(myApp: app, store: store, settings: settings, catalog: modelCatalog)
            .first(where: { $0.id == agentId })
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let descriptor {
                    header(descriptor)
                    Divider()
                    propertiesPanel(descriptor)
                } else {
                    Text("Agent not found.")
                        .foregroundStyle(.secondary)
                }
            }
            .padding(24)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .background(Color.canvasBackground)
    }

    private func header(_ descriptor: AgentDescriptor) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: descriptor.iconSystemName)
                .font(.title2)
                .foregroundStyle(appColor)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(descriptor.name)
                        .font(.title)
                        .fontWeight(.semibold)
                    Text(descriptor.kind.displayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.secondary.opacity(0.12))
                        )
                }
                if let subtitle = descriptor.subtitle {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
    }

    private func propertiesPanel(_ descriptor: AgentDescriptor) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(descriptor.properties) { property in
                AgentPropertyRow(
                    property: property,
                    onNavigate: onNavigate,
                    onSelectModel: { newId in selectModel(newId, for: descriptor) },
                    onSelectThinking: { level in selectThinking(level, for: descriptor) },
                    onToggleTool: { name, enabled in toggleTool(name, enabled: enabled, for: descriptor) },
                    onReloadModels: { Task { await modelCatalog.refresh(settings: settings) } },
                    modelsRefreshing: modelCatalog.isRefreshing,
                    modelsLoadFailed: modelCatalog.lastRefreshFailed
                )
                Divider()
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.secondary.opacity(0.06))
        )
    }

    /// Persist a new model selection for whichever agent this view is showing.
    /// The Slack-vs-main routing is keyed off `descriptor.kind` — main agents
    /// store in `MyApp.settings`; Slack sub-agents store on the SlackAgent
    /// struct itself (the parent component is recovered by parsing the agent
    /// id, which is built by `AgentRegistry.slackAgentId`).
    private func selectModel(_ newId: String, for descriptor: AgentDescriptor) {
        let provider: String?
        let modelId: String?
        if newId == KnownLLMModelCatalog.backendDefaultId {
            provider = nil
            modelId = nil
        } else if let model = modelCatalog.model(forId: newId) {
            provider = model.provider
            modelId = model.modelId
        } else {
            return
        }

        switch descriptor.kind {
        case .myApp:
            guard let myAppId = descriptor.myAppId else { return }
            store.setMyAppLLM(provider: provider, model: modelId, for: myAppId)
        case .subagent:
            guard let (myAppId, slug) = subagentTarget(descriptor) else { return }
            let appMemory = MemoryStore(rootOverride: MemoryStore.appRoot(
                myAppName: store.myApps.first(where: { $0.id == myAppId })?.name ?? ""))
            _ = try? AgentStore(memory: appMemory).setModel(slug: slug, provider: provider, model: modelId)
        case .orchestrator:
            settings.setOrchestratorLLM(provider: provider, model: modelId)
        }
    }

    /// Persist a new extended-thinking level for whichever agent this view
    /// shows. `thinkingDefaultId` clears the override. Only the main MyApp agent
    /// and the orchestrator surface a thinking picker (see `AgentRegistry`), so
    /// subagents are a no-op here.
    private func selectThinking(_ newLevel: String, for descriptor: AgentDescriptor) {
        let level: String? = newLevel == KnownLLMModelCatalog.thinkingDefaultId ? nil : newLevel
        switch descriptor.kind {
        case .myApp:
            guard let myAppId = descriptor.myAppId else { return }
            store.setMyAppThinking(level, for: myAppId)
        case .orchestrator:
            settings.setOrchestratorThinking(level)
        case .subagent:
            break
        }
    }

    /// Unwind a subagent descriptor id (`subagent:<myAppId>:<slug>`) built by
    /// `AgentRegistry.subagentId`.
    private func subagentTarget(_ descriptor: AgentDescriptor) -> (myAppId: UUID, slug: String)? {
        let parts = descriptor.id.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "subagent",
              let myAppId = UUID(uuidString: String(parts[1])) else { return nil }
        return (myAppId, String(parts[2]))
    }

    /// Enable/disable one tool for whichever agent this view shows. Routes by
    /// `descriptor.kind` exactly like `selectModel`: main → `MyApp.settings`,
    /// Slack → the SlackAgent struct (id unwound via `AgentRegistry.slackAgentId`),
    /// orchestrator → global settings. The current disabled set is recovered
    /// from the rendered `.toolToggles` property so we mutate the live value.
    private func toggleTool(_ name: String, enabled: Bool, for descriptor: AgentDescriptor) {
        var disabled = currentDisabledTools(in: descriptor)
        if enabled { disabled.remove(name) } else { disabled.insert(name) }

        switch descriptor.kind {
        case .myApp:
            guard let myAppId = descriptor.myAppId else { return }
            store.setMyAppDisabledTools(disabled, for: myAppId)
        case .subagent:
            guard let (myAppId, slug) = subagentTarget(descriptor) else { return }
            let appMemory = MemoryStore(rootOverride: MemoryStore.appRoot(
                myAppName: store.myApps.first(where: { $0.id == myAppId })?.name ?? ""))
            _ = try? AgentStore(memory: appMemory).setDisabledTools(slug: slug, disabled)
        case .orchestrator:
            settings.setOrchestratorDisabledTools(disabled)
        }
    }

    /// Pull the agent's current disabled set out of its `.toolToggles` property.
    private func currentDisabledTools(in descriptor: AgentDescriptor) -> Set<String> {
        for property in descriptor.properties {
            if case .toolToggles(_, _, let disabled) = property.value { return disabled }
        }
        return []
    }
}

/// One row on the agent details page. Single switch on
/// `AgentPropertyValue` keeps every property rendering consistent and
/// limits the change surface when new value shapes are introduced.
private struct AgentPropertyRow: View {
    let property: AgentProperty
    var onNavigate: (SidebarSelection) -> Void
    /// Called when the user picks a new model from a `.modelPicker` row.
    /// The closure receives the chosen `KnownLLMModel.id` (or
    /// `KnownLLMModelCatalog.backendDefaultId` to clear the override).
    /// Ignored for non-picker rows.
    var onSelectModel: (String) -> Void
    /// Called when the user picks a level from a `.thinkingPicker` row. Receives
    /// the level string (or `KnownLLMModelCatalog.thinkingDefaultId` to clear).
    /// Ignored for non-picker rows.
    var onSelectThinking: (String) -> Void
    /// Called when the user flips a tool toggle in a `.toolToggles` row.
    /// Receives the tool name and its new enabled state. Ignored for other rows.
    var onToggleTool: (String, Bool) -> Void
    /// Re-fetch the backend model catalog. Wired to the picker's "Reload
    /// models" item so a stale/failed list is recoverable in-place. Ignored
    /// for non-picker rows.
    var onReloadModels: () -> Void
    /// Whether a catalog refresh is currently in flight / last one failed —
    /// drives the picker's spinner and stale indicator.
    var modelsRefreshing: Bool
    var modelsLoadFailed: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(property.label)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            switch property.value {
            case .text(let s):
                Text(s)
                    .font(.callout)
                    .textSelection(.enabled)
            case .badge(let primary, let secondary):
                HStack(spacing: 6) {
                    Text(primary)
                        .font(.callout)
                        .fontWeight(.medium)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color.accentColor.opacity(0.12))
                        )
                    if let secondary {
                        Text(secondary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            case .list(let items):
                if items.isEmpty {
                    Text("(none)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(items, id: \.self) { item in
                            HStack(alignment: .top, spacing: 6) {
                                Text("•").foregroundStyle(.secondary)
                                Text(item).font(.callout)
                            }
                        }
                    }
                }
            case .link(let label, let destination):
                Button {
                    onNavigate(destination)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "doc.text")
                            .foregroundStyle(.secondary)
                        Text(label)
                            .font(.callout)
                            .underline()
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            case .sections(let summary, let groups):
                SectionsDisclosure(summary: summary, groups: groups)
            case .toolToggles(let summary, let groups, let disabled):
                ToolTogglesDisclosure(
                    summary: summary,
                    groups: groups,
                    disabled: disabled,
                    onToggle: onToggleTool
                )
            case .modelPicker(let selectedId, let options):
                ModelPickerRow(
                    selectedId: selectedId,
                    options: options,
                    onSelect: onSelectModel,
                    onReload: onReloadModels,
                    isRefreshing: modelsRefreshing,
                    loadFailed: modelsLoadFailed
                )
            case .thinkingPicker(let selectedLevel, let options):
                ThinkingPickerRow(
                    selectedLevel: selectedLevel,
                    options: options,
                    onSelect: onSelectThinking
                )
            }

            if let note = property.note {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

/// DisclosureGroup wrapping a `.sections` value. Closed by default — the
/// grouped tool list is long enough that showing it inline would dwarf
/// every other property row.
private struct SectionsDisclosure: View {
    let summary: String
    let groups: [AgentPropertySection]
    @State private var expanded: Bool = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(groups, id: \.label) { group in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(group.label)
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)
                        ForEach(group.items, id: \.self) { name in
                            HStack(alignment: .top, spacing: 6) {
                                Text("•").foregroundStyle(.secondary)
                                Text(name)
                                    .font(.callout.monospaced())
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }
            }
            .padding(.top, 6)
        } label: {
            Text(summary)
                .font(.callout)
        }
    }
}

/// Editable variant of `SectionsDisclosure`: each tool row carries a `Toggle`
/// bound to its enabled state (off ⇒ in the agent's disabled set). Flipping
/// one calls `onToggle(name, enabled)`. Closed by default like its read-only
/// sibling — the grouped list is long.
private struct ToolTogglesDisclosure: View {
    let summary: String
    let groups: [AgentPropertySection]
    let disabled: Set<String>
    var onToggle: (String, Bool) -> Void
    @State private var expanded: Bool = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(groups, id: \.label) { group in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(group.label)
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)
                        ForEach(group.items, id: \.self) { name in
                            Toggle(isOn: Binding(
                                get: { !disabled.contains(name) },
                                set: { onToggle(name, $0) }
                            )) {
                                Text(name)
                                    .font(.callout.monospaced())
                            }
                            .toggleStyle(.switch)
                            .controlSize(.mini)
                        }
                    }
                }
            }
            .padding(.top, 6)
        } label: {
            Text(summary)
                .font(.callout)
        }
    }
}
