import SwiftUI
import AGUIKit

/// Root view. Wires up the myApps store + memory store, hosts the chat
/// session coordinator, and lays out a sidebar (myApps + memory files) +
/// canvas with a floating chat overlay.
///
/// Layout:
///   - Sidebar column hosts `MyAppSidebarView` with two sections: MyApps and
///     Memories (markdown filesystem). Selecting a myApp switches the visible
///     chat to that myApp's session (without cancelling other streams);
///     selecting a memory file shows the rendered markdown in the detail
///     pane and routes chat to the shared memory session.
///   - Detail column is a `ZStack` of the active content (canvas or memory
///     file viewer) under a floating `ChatOverlay` anchored bottom-trailing.
///     The overlay rebinds to whichever `ChatViewModel` matches the current
///     selection — backgrounded sessions keep streaming until they finish.
public struct AppView: View {
    @State private var store: MyAppStore
    @State private var memory: MemoryStore
    @State private var settings: SettingsStore
    @State private var coordinator: ChatSessionCoordinator
    @State private var screenShare: ScreenShareViewModel
    @State private var selection: SidebarSelection?
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    #if os(iOS)
    @State private var showSidebar = false
    #endif
    /// Which chat session is shown in the overlay. Decoupled from `selection`
    /// so the agent dropdown can switch chat context without moving the canvas.
    @State private var chatScope: ChatScope
    /// Navigation stack pushed on top of the root detail view. The sidebar
    /// `selection` is the stack root; tapping a component card or memory file
    /// inside `MyAppHomeView` pushes onto this path so Back returns to the
    /// landing page instead of clearing the whole detail pane.
    @State private var detailPath: [SidebarSelection] = []

    public init() {
        MyAppTypeRegistry.shared.registerBuiltins()
        // Install the UNUserNotificationCenter delegate before any agent
        // turn can call `sendNotification`. Idempotent.
        NotificationCenterCoordinator.shared.bootstrap()
        let store = MyAppStore()
        let memory = MemoryStore()
        // Idempotent: writes each example's AGENTS.md persona files on
        // launches where any are missing. User edits survive every launch.
        ExampleRegistry.seedAll(globalMemory: memory)
        let settings = SettingsStore()
        self._store = State(initialValue: store)
        self._memory = State(initialValue: memory)
        self._settings = State(initialValue: settings)
        self._coordinator = State(initialValue: ChatSessionCoordinator(
            store: store,
            memory: memory,
            settings: settings
        ))
        self._screenShare = State(initialValue: ScreenShareViewModel(settings: settings))
        self._selection = State(initialValue: .myAppHome(store.activeMyAppId))
        self._chatScope = State(initialValue: .myApp(store.activeMyAppId))
    }

    public var body: some View {
        #if os(iOS)
        iOSBody
            .onChange(of: store.myApps) { _, apps in
                for app in apps { coordinator.ensureMyAppMemory(app) }
            }
        #else
        NavigationSplitView(columnVisibility: $columnVisibility) {
            MyAppSidebarView(
                store: store,
                memory: memory,
                settings: settings,
                selection: $selection,
                busyMyApps: coordinator.busyMyApps,
                onSelectionChange: dispatchSelection,
                onDeleteMyApp: deleteMyApp
            )
            .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 360)
        } detail: {
            detail
        }
        .frame(minWidth: 560, idealWidth: 1300, minHeight: 600, idealHeight: 720)
        .onChange(of: store.myApps) { _, apps in
            for app in apps { coordinator.ensureMyAppMemory(app) }
        }
        #endif
    }

    #if os(iOS)
    private var iOSBody: some View {
        ZStack(alignment: .leading) {
            ZStack {
                NavigationStack(path: $detailPath) {
                    content
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .toolbar {
                            ToolbarItem(placement: .topBarLeading) {
                                Button {
                                    withAnimation(.spring(duration: 0.3)) { showSidebar.toggle() }
                                } label: {
                                    Image(systemName: "sidebar.leading")
                                }
                            }
                        }
                        .navigationDestination(for: SidebarSelection.self) { dest in
                            detailView(for: dest)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .toolbar {
                                    ToolbarItem(placement: .topBarLeading) {
                                        Button {
                                            withAnimation(.spring(duration: 0.3)) { showSidebar.toggle() }
                                        } label: {
                                            Image(systemName: "sidebar.leading")
                                        }
                                    }
                                }
                        }
                }
                ChatOverlay(
                    scope: chatScope,
                    coordinator: coordinator,
                    store: store,
                    agents: agentPickerEntries,
                    onSwitchAgent: switchAgent
                )
            }

            if showSidebar {
                Color.black.opacity(0.4)
                    .ignoresSafeArea()
                    .onTapGesture {
                        withAnimation(.spring(duration: 0.3)) { showSidebar = false }
                    }
                    .transition(.opacity)

                MyAppSidebarView(
                    store: store,
                    memory: memory,
                    settings: settings,
                    selection: $selection,
                    busyMyApps: coordinator.busyMyApps,
                    onSelectionChange: dispatchSelection,
                    onDeleteMyApp: deleteMyApp
                )
                .frame(width: UIScreen.main.bounds.width - 56)
                .background(Color(uiColor: .systemBackground))
                .shadow(radius: 10)
                .ignoresSafeArea()
                .transition(.move(edge: .leading))
            }
        }
        .animation(.spring(duration: 0.3), value: showSidebar)
        .onChange(of: selection) { _, _ in
            detailPath = []
            withAnimation(.spring(duration: 0.3)) { showSidebar = false }
        }
    }
    #endif

    private var detail: some View {
        ZStack {
            NavigationStack(path: $detailPath) {
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .navigationDestination(for: SidebarSelection.self) { dest in
                        detailView(for: dest)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
            }
            ChatOverlay(
                scope: chatScope,
                coordinator: coordinator,
                store: store,
                agents: agentPickerEntries,
                onSwitchAgent: switchAgent
            )
        }
        // Sidebar tap replaces the stack root, so any drilled-in landing-page
        // pushes are stale — reset the path so we don't leave a phantom Back
        // arrow pointing at a view the user didn't navigate from.
        .onChange(of: selection) { _, _ in
            detailPath = []
        }
    }

    private var agentPickerEntries: [AgentPickerEntry] {
        var entries: [AgentPickerEntry] = [
            AgentPickerEntry(
                scope: .memory,
                name: "Orchestrator",
                icon: "square.stack.3d.up.fill",
                color: .orchestratorColor
            )
        ]
        let sorted = store.myApps.sorted { $0.createdAt < $1.createdAt }
        for (index, app) in sorted.enumerated() {
            entries.append(AgentPickerEntry(
                scope: .myApp(app.id),
                name: app.name,
                icon: app.iconSystemName,
                color: .color(atIndex: index)
            ))
        }
        return entries
    }

    /// Switch only the chat agent — canvas/space stays where it is.
    private func switchAgent(_ scope: ChatScope) {
        if case .memory = scope {
            coordinator.session(for: .memory).memoryFocusedPath = ""
        }
        chatScope = scope
    }

    @ViewBuilder
    private var content: some View {
        if let sel = selection {
            detailView(for: sel)
        } else {
            // Transient state on iOS compact between Back-tap and next row
            // tap; macOS only sees this if something programmatically clears
            // selection. Show the active MyApp's canvas so the detail pane
            // never goes blank.
            CanvasView(
                store: store,
                selection: .myApp(store.activeMyAppId),
                coordinator: coordinator
            )
        }
    }

    /// Renders the detail view for a given selection. Used for both the
    /// `NavigationStack` root (driven by sidebar `selection`) and pushed
    /// destinations (driven by `detailPath`). Keeping a single source of
    /// truth means a landing-page push of `.myAppComponent` shows the same
    /// `CanvasView` as a direct sidebar tap on that component.
    @ViewBuilder
    private func detailView(for sel: SidebarSelection) -> some View {
        switch sel {
        case .myAppHome(let id):
            MyAppHomeView(
                store: store,
                memory: memory,
                settings: settings,
                myAppId: id,
                onNavigate: { nav in
                    // Push onto the navigation stack instead of replacing
                    // selection — Back from the destination returns to the
                    // landing page. dispatchSelection still runs so the
                    // active component and chat scope follow the user.
                    dispatchSelection(nav)
                    detailPath.append(nav)
                }
            )
        case .myApp, .myAppComponent:
            CanvasView(store: store, selection: sel, coordinator: coordinator)
        case .myAppAgents(let id):
            AgentsListView(
                store: store,
                memory: memory,
                settings: settings,
                myAppId: id,
                onNavigate: { nav in
                    dispatchSelection(nav)
                    detailPath.append(nav)
                }
            )
        case .myAppAgentDetail(let id, let agentId):
            AgentDetailView(
                store: store,
                memory: memory,
                settings: settings,
                myAppId: id,
                agentId: agentId,
                onNavigate: { nav in
                    dispatchSelection(nav)
                    detailPath.append(nav)
                }
            )
        case .myAppMemoryFile(let id, let path):
            MemoryFileView(store: memory, path: path) {
                if !detailPath.isEmpty {
                    detailPath.removeLast()
                } else {
                    selection = .myApp(id)
                }
            }
        case .memoryFile(let path):
            MemoryFileView(store: memory, path: path) {
                if !detailPath.isEmpty {
                    detailPath.removeLast()
                } else {
                    selection = .myApp(store.activeMyAppId)
                }
            }
        case .orchestrator:
            OrchestratorHomeView(
                store: store,
                onNavigate: { nav in
                    dispatchSelection(nav)
                    detailPath.append(nav)
                }
            )
        case .orchestratorAgentDetail:
            AgentDetailView(
                store: store,
                memory: memory,
                settings: settings,
                myAppId: nil,
                agentId: AgentRegistry.orchestratorAgentId,
                onNavigate: { nav in
                    dispatchSelection(nav)
                    detailPath.append(nav)
                }
            )
        case .screenShare:
            ScreenShareView(viewModel: screenShare)
        }
    }

    private func dispatchSelection(_ sel: SidebarSelection) {
        switch sel {
        case .myAppHome(let id):
            store.setActive(id)
            chatScope = .myApp(id)
        case .myApp(let id):
            // Pure rebind — other sessions keep streaming. Updating
            // activeMyAppId is what makes CanvasView show the right myApp.
            store.setActive(id)
            chatScope = .myApp(id)
        case .myAppComponent(let id, let componentId):
            store.setActive(id)
            // Sidebar tap drives the active-component selection so the
            // canvas + kind-targeted mutators agree on what's focused.
            _ = store.setActiveComponent(componentId: componentId, myAppId: id)
            chatScope = .myApp(id)
        case .myAppMemoryFile(let id, _):
            store.setActive(id)
            chatScope = .myApp(id)
        case .myAppAgents(let id), .myAppAgentDetail(let id, _):
            // Agents pages don't change the chat scope — they stay on
            // the owning MyApp so the user can keep chatting while
            // inspecting agent metadata.
            store.setActive(id)
            chatScope = .myApp(id)
        case .memoryFile(let path):
            coordinator.session(for: .memory).memoryFocusedPath = path
            chatScope = .memory
        case .orchestrator, .orchestratorAgentDetail:
            coordinator.session(for: .memory).memoryFocusedPath = ""
            chatScope = .memory
        case .screenShare:
            // Screen share doesn't change the chat scope — the overlay just
            // floats over the panel and keeps using the memory session.
            break
        }
    }

    /// Cancel + drop the per-myApp session before the myApp leaves the
    /// store, so an in-flight stream tears down cleanly and any straggling
    /// tool calls no-op against the missing-myApp guard in `MyAppStore`.
    private func deleteMyApp(_ id: UUID) {
        coordinator.discardSession(for: .myApp(id))
        store.removeMyApp(id)
        if selection?.myAppId == id {
            selection = .myApp(store.activeMyAppId)
        }
        if case .myApp(let chatId) = chatScope, chatId == id {
            chatScope = .myApp(store.activeMyAppId)
        }
    }
}
