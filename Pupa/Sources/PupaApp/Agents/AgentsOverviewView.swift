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
    let modelCatalog: ModelCatalogStore

    /// Per-thread token + cost, fetched on appear from `POST /db/threads/usage`.
    /// Local to this view — usage is shown nowhere else.
    @State private var usage = ThreadUsageStore()

    public init(
        store: MyAppStore,
        settings: SettingsStore,
        memory: MemoryStore,
        stats: AgentStatsStore,
        modelCatalog: ModelCatalogStore
    ) {
        self.store = store
        self.settings = settings
        self.memory = memory
        self.stats = stats
        self.modelCatalog = modelCatalog
    }

    private var sortedApps: [MyApp] {
        store.myApps.sorted { $0.createdAt < $1.createdAt }
    }

    public var body: some View {
        List {
            Section("Agents") {
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
        .task { await refreshUsage() }
    }

    /// Batch every visible thread id into one usage request.
    private func refreshUsage() async {
        let ids = threadGroups.flatMap { store.threads(for: $0.scope).map(\.id) }
        let client = BackendUsageClient(
            backendURL: settings.backendURL,
            extraHeaders: settings.authHeaders,
            session: settings.backendSession
        )
        await usage.refresh(threadIds: ids, client: client)
    }

    /// On-demand cache-breakdown fetch for one agent's threads (runs on expand).
    private func refreshCache(_ ids: [String]) async {
        let client = BackendUsageClient(
            backendURL: settings.backendURL,
            extraHeaders: settings.authHeaders,
            session: settings.backendSession
        )
        await usage.refreshCache(threadIds: ids, client: client)
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
                    scope: descriptor.kind == .slack ? nil : .myApp(app.id)
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
                    if let caption = scopeUsageCaption(.myApp(app.id)) {
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
                    statRow("Tokens used", formatTokens(tokens))
                }
                if let cost = roll.costUSD {
                    statRow("Est. cost", formatCost(cost))
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

    // MARK: - Usage formatting

    /// One-line `"12.3k tok · $0.04"` for a thread, or `nil` when no usage
    /// is known (Langfuse off, or no trace ingested yet).
    private func usageLine(for threadId: String) -> String? {
        guard let u = usage.usage(for: threadId) else { return nil }
        var parts: [String] = []
        if let tokens = u.totalTokens { parts.append("\(formatTokens(tokens)) tok") }
        if let cost = u.costUSD { parts.append(formatCost(cost)) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Compact `"7.2k tok · $0.03"` total across every thread in `scope`,
    /// or `nil` when no thread has known usage. Used for the MyApp-wide and
    /// per-agent aggregate captions.
    private func scopeUsageCaption(_ scope: ChatScope) -> String? {
        guard let roll = usage.rollup(threadIds: store.threads(for: scope).map(\.id)) else { return nil }
        var parts: [String] = []
        if let tokens = roll.totalTokens { parts.append("\(formatTokens(tokens)) tok") }
        if let cost = roll.costUSD { parts.append(formatCost(cost)) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func formatTokens(_ tokens: Int) -> String {
        if tokens < 1000 { return "\(tokens)" }
        return String(format: "%.1fk", Double(tokens) / 1000.0)
    }

    private func formatCost(_ cost: Double) -> String {
        // Sub-dollar costs need more precision than two decimals.
        cost < 1 ? String(format: "$%.4f", cost) : String(format: "$%.2f", cost)
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
            if let line = usageLine(for: thread.id) {
                Text(line)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
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
