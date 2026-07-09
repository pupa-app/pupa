import SwiftUI

/// Per-MyApp overview of every agent that runs on its behalf — the
/// MyApp's main agent plus any Slack personas living inside Slack
/// components. Reached by tapping the "Agents" panel on the MyApp
/// landing page; the row tap pushes the per-agent details page.
public struct AgentsListView: View {
    let store: MyAppStore
    let memory: MemoryStore
    let settings: SettingsStore
    let modelCatalog: ModelCatalogStore
    let myAppId: UUID
    var onNavigate: (SidebarSelection) -> Void

    public init(
        store: MyAppStore,
        memory: MemoryStore,
        settings: SettingsStore,
        modelCatalog: ModelCatalogStore,
        myAppId: UUID,
        onNavigate: @escaping (SidebarSelection) -> Void
    ) {
        self.store = store
        self.memory = memory
        self.settings = settings
        self.modelCatalog = modelCatalog
        self.myAppId = myAppId
        self.onNavigate = onNavigate
    }

    private var myApp: MyApp? {
        store.myApps.first(where: { $0.id == myAppId })
    }

    private var appColor: Color {
        Color.color(atIndex: store.colorIndex(for: myAppId))
    }

    private var descriptors: [AgentDescriptor] {
        guard let app = myApp else { return [] }
        return AgentRegistry.enumerateAgents(myApp: app, store: store, settings: settings, catalog: modelCatalog)
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let app = myApp {
                    header(app)
                    Divider()
                    agentsPanel
                } else {
                    Text("App not found.")
                        .foregroundStyle(.secondary)
                }
            }
            .padding(24)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .background(Color.canvasBackground)
    }

    private func header(_ app: MyApp) -> some View {
        MyAppPageHeader(page: "Agents", name: app.name, icon: "person.2.fill", color: appColor)
    }

    private var agentsPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Agents")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Spacer()
                Text("\(descriptors.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if descriptors.isEmpty {
                Text("No agents yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(descriptors) { descriptor in
                        agentRow(descriptor)
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.secondary.opacity(0.06))
        )
    }

    private func agentRow(_ descriptor: AgentDescriptor) -> some View {
        Button {
            onNavigate(.myAppAgentDetail(myAppId, agentId: descriptor.id))
        } label: {
            HStack(spacing: 10) {
                Image(systemName: descriptor.iconSystemName)
                    .frame(width: 22)
                    .foregroundStyle(appColor)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(descriptor.name)
                            .font(.callout)
                            .fontWeight(.medium)
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
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    HStack(spacing: 6) {
                        Text(descriptor.modelSummary)
                            .font(.caption2)
                            .fontWeight(.medium)
                            .foregroundStyle(appColor)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(appColor.opacity(0.12))
                            )
                        Text(descriptor.toolSummary)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
