import SwiftUI

/// Settings → Agents. App-wide roster, organised as nested dropdowns:
/// each MyApp expands to its agents (main agent + Slack personas), and
/// each agent expands to its own lifetime stats. The orchestrator is a
/// top-level agent dropdown (it belongs to no MyApp). A second list of
/// conversation threads is grouped by agent, one collapsible group each.
///
/// Reads agents through the existing descriptor pipeline (`AgentRegistry`)
/// and activity through `AgentStatsStore`, so it imposes no new
/// requirement on agent/data structure. Nesting is derived from
/// `AgentDescriptor.kind`/`myAppId` today; a future generic `parentId`
/// would slot in by changing only how agents group under a parent.
public struct AgentsOverviewView: View {
    let store: MyAppStore
    let settings: SettingsStore
    let memory: MemoryStore
    let stats: AgentStatsStore

    public init(
        store: MyAppStore,
        settings: SettingsStore,
        memory: MemoryStore,
        stats: AgentStatsStore
    ) {
        self.store = store
        self.settings = settings
        self.memory = memory
        self.stats = stats
    }

    private var sortedApps: [MyApp] {
        store.myApps.sorted { $0.createdAt < $1.createdAt }
    }

    public var body: some View {
        List {
            Section("Agents") {
                agentDisclosure(
                    AgentRegistry.buildOrchestratorAgent(
                        store: store, settings: settings, memory: memory
                    ),
                    scope: .memory
                )
                ForEach(sortedApps) { app in
                    appDisclosure(app)
                }
            }

            Section("Threads") {
                ForEach(threadGroups, id: \.scope) { group in
                    threadDisclosure(group)
                }
            }
        }
        .navigationTitle("Agents")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    // MARK: - Agents

    /// One MyApp dropdown → its agents (main agent first, then Slack
    /// personas), each its own stats dropdown.
    private func appDisclosure(_ app: MyApp) -> some View {
        let agents = AgentRegistry.enumerateAgents(myApp: app, store: store, settings: settings)
        return DisclosureGroup {
            ForEach(agents) { descriptor in
                agentDisclosure(
                    descriptor,
                    scope: descriptor.kind == .slack ? nil : .myApp(app.id)
                )
            }
        } label: {
            Label {
                HStack(spacing: 6) {
                    Text(app.name).font(.callout).fontWeight(.medium)
                    Text("\(agents.count)")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "square.stack.3d.up")
            }
        }
    }

    /// One agent dropdown → its lifetime stats.
    private func agentDisclosure(_ descriptor: AgentDescriptor, scope: ChatScope?) -> some View {
        let stat = stats.stat(for: statKey(for: descriptor))
        let conversations = scope.map { store.threads(for: $0).count }
        return DisclosureGroup {
            statRow("Delegations made", "\(stat.count(AgentStatsStore.delegationsMade))")
            statRow("Invocations received", "\(stat.count(AgentStatsStore.invocationsReceived))")
            if let conversations {
                statRow("Conversations", "\(conversations)")
            }
            if let last = stat.lastActiveAt {
                statRow("Last active", last.formatted(date: .abbreviated, time: .shortened))
            } else {
                statRow("Last active", "—")
            }
            if let subtitle = descriptor.subtitle, !subtitle.isEmpty {
                statRow("Role", subtitle)
            }
        } label: {
            Label {
                HStack(spacing: 6) {
                    Text(descriptor.name).font(.callout)
                    Text(descriptor.kind.displayName)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.secondary.opacity(0.12))
                        )
                }
            } icon: {
                Image(systemName: descriptor.iconSystemName)
            }
        }
    }

    private func statRow(_ label: String, _ value: String) -> some View {
        LabeledContent(label) {
            Text(value).foregroundStyle(.secondary)
        }
        .font(.callout)
    }

    /// Resolve the `AgentStatsStore` key for a descriptor, matching
    /// `AgentInvocationKey.statKey` on the write side. Main-agent
    /// descriptors share a constant id, so key them off `myAppId`; Slack
    /// descriptor ids are `"slack:<componentId>:<bareId>"` while the gate
    /// keys on `"slack:<bareId>"` — take the segment after the last `:`.
    private func statKey(for descriptor: AgentDescriptor) -> String {
        switch descriptor.kind {
        case .orchestrator:
            return "orchestrator"
        case .myApp:
            return descriptor.myAppId?.uuidString ?? descriptor.id
        case .slack:
            let bare = descriptor.id.split(separator: ":").last.map(String.init) ?? descriptor.id
            return "slack:\(bare)"
        }
    }

    // MARK: - Threads

    private struct ThreadGroup { let title: String; let scope: ChatScope }

    private var threadGroups: [ThreadGroup] {
        var groups = [ThreadGroup(title: "Orchestrator", scope: .memory)]
        for app in sortedApps {
            groups.append(ThreadGroup(title: app.name, scope: .myApp(app.id)))
        }
        return groups
    }

    private func threadDisclosure(_ group: ThreadGroup) -> some View {
        let threads = store.threads(for: group.scope).sorted { $0.createdAt > $1.createdAt }
        return DisclosureGroup {
            if threads.isEmpty {
                Text("No threads.").foregroundStyle(.secondary)
            } else {
                ForEach(threads) { threadRow($0, scope: group.scope) }
            }
        } label: {
            HStack(spacing: 6) {
                Text(group.title).font(.callout).fontWeight(.medium)
                Text("\(threads.count)")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    /// Read-only thread entry — informational, with swipe-to-delete for
    /// cleanup. No "current thread" selection: picking an active
    /// conversation isn't meaningful from a Settings overview.
    private func threadRow(_ thread: ChatThread, scope: ChatScope) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(thread.title.isEmpty ? "New conversation" : thread.title)
                .font(.callout)
                .foregroundStyle(thread.title.isEmpty ? .secondary : .primary)
            Text(thread.createdAt.formatted(date: .abbreviated, time: .shortened))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                store.removeThread(thread.id, for: scope)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }
}
