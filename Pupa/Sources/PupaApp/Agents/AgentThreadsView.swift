import SwiftUI

/// Settings ▸ Agents ▸ Threads. Every conversation thread grouped by agent,
/// one collapsible group each, with token + cost usage per thread.
struct AgentThreadsView: View {
    let store: MyAppStore
    let settings: SettingsStore
    /// Live session owner, for per-thread status dots. Optional so previews /
    /// callers without a coordinator render no badges.
    let coordinator: ChatSessionCoordinator?

    /// Per-thread token + cost, fetched on appear from `POST /db/threads/usage`.
    /// Owned per screen so the fetch only fires for the page you opened.
    @State private var usage = ThreadUsageStore()

    private var sortedApps: [MyApp] {
        store.myApps.sorted { $0.createdAt < $1.createdAt }
    }

    var body: some View {
        List {
            ForEach(threadGroups, id: \.scope) { group in
                threadDisclosure(group)
            }
        }
        .navigationTitle("Threads")
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
            HStack(spacing: 6) {
                Text(thread.title.isEmpty ? "New conversation" : thread.title)
                    .font(.callout)
                    .foregroundStyle(thread.title.isEmpty ? .secondary : .primary)
                let s = coordinator?.status(for: scope, threadId: thread.id) ?? .idle
                if s != .idle {
                    StatusBadge(status: s, size: 12)
                }
            }
            Text(thread.createdAt.formatted(date: .abbreviated, time: .shortened))
                .font(.caption2)
                .foregroundStyle(.secondary)
            if let line = usage.line(for: thread.id) {
                Text(line)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            // Backend threadId — surfaced for debugging. Selectable,
            // and long-press / right-click copies it.
            Text(thread.id)
                .font(.caption2.monospaced())
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
                .contextMenu {
                    Button {
                        ChatClipboard.copy(thread.id)
                    } label: {
                        Label("Copy thread ID", systemImage: "doc.on.doc")
                    }
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
