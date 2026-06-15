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
        let sorted = store.myApps.sorted { $0.createdAt < $1.createdAt }
        let index = sorted.firstIndex(where: { $0.id == myAppId }) ?? 0
        return Color.color(atIndex: index)
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
                    onSelectModel: { newId in selectModel(newId, for: descriptor) }
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
        case .slack:
            guard let myAppId = descriptor.myAppId else { return }
            // Slack agent ids are built as "slack:<componentId>:<slackAgentId>" —
            // unwind to find the targeted SlackAgent. AgentRegistry.slackAgentId
            // is the single source of truth for this format.
            let parts = descriptor.id.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3, parts[0] == "slack" else { return }
            let componentId = String(parts[1])
            let slackAgentId = String(parts[2])
            store.setSlackAgentLLM(
                provider: provider,
                model: modelId,
                componentId: componentId,
                agentId: slackAgentId,
                myAppId: myAppId
            )
        case .orchestrator:
            settings.setOrchestratorLLM(provider: provider, model: modelId)
        }
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
            case .modelPicker(let selectedId, let options):
                ModelPickerRow(
                    selectedId: selectedId,
                    options: options,
                    onSelect: onSelectModel
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

/// Editable model selector rendered as a `Menu` grouped by provider. The
/// options come from `ModelCatalogStore.models` (fetched from the backend)
/// plus a "Backend default" sentinel entry that clears the per-agent override.
private struct ModelPickerRow: View {
    let selectedId: String
    let options: [KnownLLMModel]
    var onSelect: (String) -> Void

    private var currentLabel: String {
        if selectedId == KnownLLMModelCatalog.backendDefaultId {
            return "Backend default"
        }
        return options.first(where: { $0.id == selectedId })?.label
            ?? "Backend default"
    }

    private var currentSecondary: String? {
        if selectedId == KnownLLMModelCatalog.backendDefaultId {
            return nil
        }
        guard let selected = options.first(where: { $0.id == selectedId }) else { return nil }
        return KnownLLMModelCatalog.providerDisplayName(selected.provider)
    }

    private var grouped: [(provider: String, items: [KnownLLMModel])] {
        let order = options.map(\.provider).reduce(into: [String]()) { acc, p in
            if !acc.contains(p) { acc.append(p) }
        }
        return order.map { provider in
            (provider, options.filter { $0.provider == provider })
        }
    }

    var body: some View {
        Menu {
            Button {
                onSelect(KnownLLMModelCatalog.backendDefaultId)
            } label: {
                if selectedId == KnownLLMModelCatalog.backendDefaultId {
                    Label("Backend default", systemImage: "checkmark")
                } else {
                    Text("Backend default")
                }
            }
            ForEach(grouped, id: \.provider) { group in
                Section(KnownLLMModelCatalog.providerDisplayName(group.provider)) {
                    ForEach(group.items) { model in
                        Button {
                            onSelect(model.id)
                        } label: {
                            if model.id == selectedId {
                                Label(model.label, systemImage: "checkmark")
                            } else {
                                Text(model.label)
                            }
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text(currentLabel)
                    .font(.callout)
                    .fontWeight(.medium)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.accentColor.opacity(0.12))
                    )
                if let secondary = currentSecondary {
                    Text(secondary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.down")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
