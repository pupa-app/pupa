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
    let settings: SettingsStore
    let modelCatalog: ModelCatalogStore

    var body: some View {
        let threads = store.threads(for: scope)
        let currentId = store.currentThreadId(for: scope)
        let vm = coordinator.session(for: scope, threadId: currentId)
        ChatPanel(
            viewModel: vm,
            threads: threads,
            currentThreadId: currentId,
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
            status: { id in coordinator.status(for: scope, threadId: id) },
            modelOptions: modelCatalog.models,
            selectedModelId: selectedModelId(threadId: currentId),
            onSelectModel: { id in selectModel(id, threadId: currentId) }
        )
        // Load history when the visible thread changes (and on first appear).
        .task(id: currentId) { await MainActor.run { vm.loadHistoryIfNeeded() } }
    }

    /// The catalog id the header chip rests on: the thread override if pinned,
    /// else the scope default, resolved against the live catalog. Falls back to
    /// the backend-default sentinel when the effective model isn't in the
    /// catalog (or nothing is set). Mirrors `AgentRegistry.modelProperty`.
    private func selectedModelId(threadId: String) -> String {
        let effective = store.threadLLM(threadId: threadId, for: scope) ?? scopeDefault
        if let (provider, model) = effective,
           let known = modelCatalog.model(provider: provider, modelId: model) {
            return known.id
        }
        return KnownLLMModelCatalog.backendDefaultId
    }

    /// Write the picked model as the thread's override — the backend-default
    /// sentinel clears it so the thread re-inherits the scope default.
    private func selectModel(_ id: String, threadId: String) {
        if id == KnownLLMModelCatalog.backendDefaultId {
            store.setThreadLLM(provider: nil, model: nil, threadId: threadId, for: scope)
        } else if let model = modelCatalog.model(forId: id) {
            store.setThreadLLM(provider: model.provider, model: model.modelId, threadId: threadId, for: scope)
        }
    }

    /// The scope's per-agent default model, inherited by threads with no pin.
    private var scopeDefault: (provider: String, model: String)? {
        switch scope {
        case .myApp(let id): return store.myAppLLM(for: id)
        case .memory:        return settings.orchestratorLLM()
        }
    }
}
