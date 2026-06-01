import SwiftUI

/// Horizontal paged container that hosts one `ChatPanel` per conversation thread.
///
/// Swiping left/right (or using the `‹ ›` arrow buttons on macOS) moves between
/// threads for the currently-selected scope. The store's `currentThreadId` drives
/// the initial scroll position; swiping updates it bidirectionally via
/// `.scrollPosition(id:)`.
///
/// Each page lazily creates its `ChatViewModel` via `coordinator.session(for:threadId:)`
/// and calls `loadHistoryIfNeeded()` when it becomes the visible page — this
/// fetches the backend transcript for old threads and seeds the session for
/// continuation, without blocking the UI.
struct ConversationPager: View {
    let scope: ChatScope
    let coordinator: ChatSessionCoordinator
    let store: MyAppStore
    let agents: [AgentPickerEntry]
    let onSwitchAgent: (ChatScope) -> Void

    /// Mirrors `store.currentThreadId(for: scope)`, two-way bound to the scroll view.
    @State private var currentId: String?

    var body: some View {
        let threads = store.threads(for: scope)
        ScrollView(.horizontal) {
            LazyHStack(spacing: 0) {
                ForEach(threads) { thread in
                    let vm = coordinator.session(for: scope, threadId: thread.id)
                    ChatPanel(
                        viewModel: vm,
                        currentThreadTitle: thread.title.isEmpty ? nil : thread.title,
                        agents: agents,
                        onSwitchAgent: onSwitchAgent,
                        onAddThread: { store.addThread(for: scope) },
                        onDeleteThread: threads.count > 1 ? {
                            coordinator.discardSession(for: scope, threadId: thread.id)
                            store.removeThread(thread.id, for: scope)
                        } : nil
                    )
                    .containerRelativeFrame(.horizontal)
                    .id(thread.id)
                    .task(id: thread.id) {
                        if currentId == thread.id {
                            await MainActor.run { vm.loadHistoryIfNeeded() }
                        }
                    }
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: $currentId)
        .scrollIndicators(.hidden)
        #if os(macOS)
        // macOS trackpad swiping works with the scroll view above, but also
        // expose explicit arrow buttons so keyboard / click navigation works.
        .overlay(alignment: .bottom) {
            macArrows(threads: threads)
        }
        #endif
        .onAppear {
            currentId = store.currentThreadId(for: scope)
        }
        .onChange(of: store.currentThreadId(for: scope)) { _, newId in
            // Store changed externally (e.g. addThread from newThread()) — sync scroll.
            guard newId != currentId else { return }
            withAnimation(.easeInOut(duration: 0.25)) { currentId = newId }
        }
        .onChange(of: currentId) { _, newId in
            // User swiped — push change back to store.
            guard let newId, newId != store.currentThreadId(for: scope) else { return }
            store.setCurrentThread(newId, for: scope)
            // Trigger history load when the newly-visible page has no bubbles.
            let vm = coordinator.session(for: scope, threadId: newId)
            vm.loadHistoryIfNeeded()
        }
    }

    #if os(macOS)
    private func macArrows(threads: [ChatThread]) -> some View {
        let current = store.currentThreadId(for: scope)
        let idx = threads.firstIndex(where: { $0.id == current }) ?? 0
        return HStack(spacing: 12) {
            Button {
                guard idx > 0 else { return }
                let prev = threads[idx - 1].id
                store.setCurrentThread(prev, for: scope)
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 12, weight: .semibold))
            }
            .disabled(idx == 0)
            .buttonStyle(.plain)
            .help("Previous conversation")

            Button {
                guard idx < threads.count - 1 else { return }
                let next = threads[idx + 1].id
                store.setCurrentThread(next, for: scope)
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
            }
            .disabled(idx == threads.count - 1)
            .buttonStyle(.plain)
            .help("Next conversation")
        }
        .padding(.bottom, 8)
        .foregroundStyle(.secondary)
    }
    #endif
}
