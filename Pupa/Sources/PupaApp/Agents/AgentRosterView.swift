import SwiftUI

/// Settings ▸ Agents ▸ Roster. App-wide roster as nested dropdowns: each MyApp
/// expands to its agents (main agent + Slack personas), and each agent expands
/// to its own lifetime stats. The orchestrator is a top-level agent dropdown
/// (it belongs to no MyApp).
///
/// Reads agents through the existing descriptor pipeline (`AgentRegistry`) and
/// activity through `AgentStatsStore`, so it imposes no new requirement on
/// agent/data structure. Nesting is derived from `AgentDescriptor.kind` /
/// `myAppId` today; a future generic `parentId` would slot in by changing only
/// how agents group under a parent.
struct AgentRosterView: View {
    let store: MyAppStore
    let settings: SettingsStore
    let memory: MemoryStore
    let stats: AgentStatsStore
    let modelCatalog: ModelCatalogStore

    /// Per-thread token + cost, fetched on appear from `POST /db/threads/usage`.
    /// Owned per screen so the fetch only fires for the page you opened.
    @State private var usage = ThreadUsageStore()

    private var sortedApps: [MyApp] {
        store.myApps.sorted { $0.createdAt < $1.createdAt }
    }

    var body: some View {
        List {
            agentDisclosure(
                AgentRegistry.buildOrchestratorAgent(
                    store: store, settings: settings, memory: memory, catalog: modelCatalog
                ),
                scope: .memory
            )
            ForEach(sortedApps) { app in
                appDisclosure(app)
            }
        }
        .navigationTitle("Roster")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task { await refreshUsage() }
    }

    /// Batch every scope's threads into one usage request.
    private func refreshUsage() async {
        var ids = store.threads(for: .memory).map(\.id)
        for app in sortedApps {
            ids.append(contentsOf: store.threads(for: .myApp(app.id)).map(\.id))
        }
        await usage.refresh(threadIds: ids, client: usageClient())
    }

    /// On-demand cache-breakdown fetch for one agent's threads (runs on expand).
    private func refreshCache(_ ids: [String]) async {
        await usage.refreshCache(threadIds: ids, client: usageClient())
    }

    private func usageClient() -> BackendUsageClient {
        BackendUsageClient(
            backendURL: settings.backendURL,
            extraHeaders: settings.authHeaders,
            session: settings.backendSession
        )
    }

    // MARK: - Agents

    /// One MyApp dropdown → its agents (main agent first, then Slack
    /// personas), each its own stats dropdown.
    private func appDisclosure(_ app: MyApp) -> some View {
        let agents = AgentRegistry.enumerateAgents(myApp: app, store: store, settings: settings, catalog: modelCatalog)
        return DisclosureGroup {
            ForEach(agents) { descriptor in
                agentDisclosure(
                    descriptor,
                    scope: descriptor.kind == .subagent ? nil : .myApp(app.id)
                )
            }
        } label: {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(app.name).font(.callout).fontWeight(.medium)
                        Text("\(agents.count)")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    // MyApp-wide total, summed across every thread in the app.
                    if let caption = usage.caption(threadIds: store.threads(for: .myApp(app.id)).map(\.id)) {
                        Text(caption).font(.caption2).foregroundStyle(.secondary)
                    }
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
            if let scope, let roll = usage.rollup(threadIds: store.threads(for: scope).map(\.id)) {
                if let tokens = roll.totalTokens {
                    statRow("Tokens used", ThreadUsageStore.formatTokens(tokens))
                }
                if let cost = roll.costUSD {
                    statRow("Est. cost", ThreadUsageStore.formatCost(cost))
                }
            }
            // Prompt-cache % — fetched on demand when this agent is expanded.
            if let scope {
                let ids = store.threads(for: scope).map(\.id)
                if !ids.isEmpty {
                    statRow(
                        "Cache read",
                        usage.cacheReadPct(threadIds: ids).map { String(format: "%.0f%%", $0) } ?? "—"
                    )
                    .task(id: ids) { await refreshCache(ids) }
                }
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
    /// descriptors share a constant id, so key them off `myAppId`.
    private func statKey(for descriptor: AgentDescriptor) -> String {
        switch descriptor.kind {
        case .orchestrator:
            return "orchestrator"
        case .myApp:
            return descriptor.myAppId?.uuidString ?? descriptor.id
        case .subagent:
            // Descriptor id is `subagent:<myAppId>:<slug>` — identical to
            // `AgentInvocationKey.subagent.statKey`.
            return descriptor.id
        }
    }
}
