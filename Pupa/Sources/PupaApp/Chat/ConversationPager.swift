import SwiftUI

/// Hosts the `ChatPanel` for the scope's currently-selected conversation
/// thread.
///
/// Thread switching used to be a horizontal swipe-pager; it's now a dropdown
/// in the panel header (`ChatPanel.threadDropdown`). This view simply renders
/// the panel for `store.currentThreadId(for: scope)` and re-renders when the
/// store's selection changes. Each thread lazily creates its `ChatViewModel`
/// via `coordinator.session(for:threadId:)`; `loadHistoryIfNeeded()` runs
/// whenever the visible thread changes (`.task(id:)`) — fetching the backend
/// transcript for old threads and seeding the session for continuation,
/// without blocking the UI.
struct ConversationPager: View {
    let scope: ChatScope
    let coordinator: ChatSessionCoordinator
    let store: MyAppStore
    let agents: [AgentPickerEntry]
    let onSwitchAgent: (ChatScope) -> Void

    var body: some View {
        let threads = store.threads(for: scope)
        let currentId = store.currentThreadId(for: scope)
        let vm = coordinator.session(for: scope, threadId: currentId)
        ChatPanel(
            viewModel: vm,
            threads: threads,
            currentThreadId: currentId,
            agents: agents,
            onSwitchAgent: onSwitchAgent,
            onSelectThread: { id in
                guard id != store.currentThreadId(for: scope) else { return }
                store.setCurrentThread(id, for: scope)
                coordinator.session(for: scope, threadId: id).loadHistoryIfNeeded()
            },
            onAddThread: { store.addThread(for: scope) },
            onDeleteThread: threads.count > 1 ? { id in
                coordinator.discardSession(for: scope, threadId: id)
                store.removeThread(id, for: scope)
            } : nil,
            status: { id in coordinator.status(for: scope, threadId: id) }
        )
        // Load history when the visible thread changes (and on first appear).
        .task(id: currentId) { await MainActor.run { vm.loadHistoryIfNeeded() } }
    }
}
