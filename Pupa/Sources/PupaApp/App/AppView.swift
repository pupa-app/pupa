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
    #if os(iOS)
    /// Whether the slide-in sidebar/menu is open. Persisted so the app opens to
    /// the same state it was left in; defaults to `true` so a fresh install
    /// lands on an open menu. Written through by the toolbar toggle and the
    /// auto-close on selection, so "last state" survives relaunch.
    @AppStorage("pupa.ui.sidebarOpen") private var showSidebar = true
    /// Drives the slide-in menu width: on a regular width class (iPad, or a
    /// large iPhone in landscape) the drawer stays slim instead of swallowing
    /// the whole screen the way it does on compact iPhones.
    @Environment(\.horizontalSizeClass) private var hSizeClass
    #endif
    /// Which chat session is shown in the overlay. Decoupled from `selection`
    /// so the agent dropdown can switch chat context without moving the canvas.
    @State private var chatScope: ChatScope
    /// Navigation stack pushed on top of the root detail view. The sidebar
    /// `selection` is the stack root; tapping a component card or memory file
    /// inside `MyAppHomeView` pushes onto this path so Back returns to the
    /// landing page instead of clearing the whole detail pane.
    @State private var detailPath: [SidebarSelection] = []
    /// iOS: bumped when the page behind the dock is scrolled, telling
    /// `MyAppDock` to tuck away. See the `simultaneousGesture` in `iOSBody`.
    @State private var dockDismissSignal = 0
    /// Set when the user skipped backend pairing during onboarding. Drives the
    /// dismissible reminder banner until a backend is paired.
    @AppStorage(OnboardingKeys.backendSkipped) private var backendSkipped = false
    /// Presents the pairing sheet from the reminder banner.
    @State private var showBackendSheet = false
    /// Onboarding + tour completion flags. Together they gate the one-time
    /// auto-start of the interactive guided tour: it runs after onboarding
    /// finishes (`onboardingCompleted` flips true) and never again once the
    /// tour is completed or skipped.
    @AppStorage(OnboardingKeys.completed) private var onboardingCompleted = false
    @AppStorage(OnboardingKeys.tourCompleted) private var tourCompleted = false
    /// Shared interactive-tour store. Host views reconcile to its intent flags
    /// (`wantSettingsOpen` / `wantChatOpen` / `chatPrefill`) and `applyTourStep`
    /// drives `selection` for `.navigate` steps.
    @State private var tour = GuidedTourStore.shared
    /// A `.pupaapp` opened from outside the app (`onOpenURL`), staged for an
    /// explicit confirm step before it touches the store — the source is
    /// untrusted and the bundle's agent prompts run with the user's tools.
    @State private var pendingImport: PendingImport?
    /// Result/error surfaced after an external import attempt.
    @State private var importNotice: ImportNotice?

    /// `settings` is optional so `RootView` can hand in the shared
    /// `SettingsStore` it also gives to onboarding — pairing done during
    /// onboarding then mutates the very instance this view reads. Callers that
    /// don't care (previews, the macOS demo) pass nothing and get a fresh one.
    public init(settings injectedSettings: SettingsStore? = nil) {
        MyAppTypeRegistry.shared.registerBuiltins()
        // Install the UNUserNotificationCenter delegate before any agent
        // turn can call `sendNotification`. Idempotent.
        NotificationCenterCoordinator.shared.bootstrap()
        let store = MyAppStore()
        let memory = MemoryStore()
        // Idempotent: writes each example's AGENTS.md persona files on
        // launches where any are missing. User edits survive every launch.
        ExampleRegistry.seedAll(globalMemory: memory)
        let settings = injectedSettings ?? SettingsStore()
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
        platformBody
            .safeAreaInset(edge: .top) {
                if showBackendReminder { backendReminderBanner }
            }
            .sheet(isPresented: $showBackendSheet) { backendPairingSheet }
            .onReceive(NotificationCenter.default.publisher(for: .pupaNotificationTap)) { note in
                guard let sel = note.userInfo?["selection"] as? SidebarSelection else { return }
                detailPath = []
                selection = sel
                dispatchSelection(sel)
            }
            // Tap-to-import: a `.pupaapp` opened from Files / Mail / a chat app
            // arrives here. Stage it for a confirm step rather than importing
            // straight into the store (untrusted source).
            .onOpenURL { stagePendingImport($0) }
            .sheet(item: $pendingImport) { pending in
                ImportConfirmSheet(
                    pending: pending,
                    onImport: { confirmImport(pending) },
                    onCancel: { pendingImport = nil }
                )
            }
            .alert(item: $importNotice) { note in
                Alert(title: Text("Import"), message: Text(note.message),
                      dismissButton: .default(Text("OK")))
            }
            // One-time guided tour: evaluate on appear (covers a relaunch where
            // a previous run was abandoned mid-tour) and whenever onboarding
            // completes (the first-install hand-off from `OnboardingFlowView`).
            .task { maybeStartTour() }
            .onChange(of: onboardingCompleted) { _, _ in maybeStartTour() }
            // Reconcile the app to the active step. `isActive` becoming true
            // applies the first step on start; `index` covers Next / Back.
            .onChange(of: tour.isActive) { _, active in
                if active { applyTourStep() }
            }
            .onChange(of: tour.index) { _, _ in applyTourStep() }
    }

    /// Auto-start the interactive tour exactly once: after onboarding finishes
    /// and only while it hasn't already been completed / skipped. Builds the
    /// step list against the live active myApp and the current pairing state so
    /// the route targets resolve and the chat copy adapts.
    private func maybeStartTour() {
        guard onboardingCompleted, !tourCompleted, !tour.isActive else { return }
        tour.start(
            activeMyAppId: store.activeMyAppId,
            isPaired: settings.isPaired(settings.activeBackend.id)
        )
    }

    /// Reconcile the whole app to the active tour step. Each step's composable
    /// intents fully define the intended UI state — every host-facing flag is
    /// written here (set or cleared) so transitions are deterministic
    /// regardless of the previous step: the sidebar menu, the Settings sheet +
    /// page, the chat overlay + prefill, and the sidebar `selection` (routed
    /// via `dispatchSelection` so the chat scope follows).
    private func applyTourStep() {
        guard tour.isActive, let step = tour.currentStep else { return }
        #if os(iOS)
        // The Settings sheet is hosted by the (conditionally-mounted) sidebar,
        // so keep the sidebar mounted whenever a step opens Settings — even
        // though the sheet then covers it — otherwise the sheet can't present.
        withAnimation(.spring(duration: 0.3)) {
            showSidebar = step.opensSidebar || step.settingsPage != nil
        }
        #endif
        tour.wantSettingsPage = step.settingsPage
        tour.wantSettingsOpen = step.settingsPage != nil
        tour.wantChatOpen = step.opensChat
        tour.chatPrefill = step.chatPrefill
        if let sel = step.selection {
            detailPath = []
            selection = sel
            dispatchSelection(sel)
        }
    }

    @ViewBuilder
    private var platformBody: some View {
        #if os(iOS)
        iOSBody
            .onChange(of: store.myApps) { _, apps in
                for app in apps { coordinator.ensureMyAppMemory(app) }
            }
        #else
        HStack(spacing: 0) {
            MyAppSidebarView(
                store: store,
                memory: memory,
                settings: settings,
                selection: $selection,
                busyMyApps: coordinator.busyMyApps,
                onSelectionChange: dispatchSelection,
                onDeleteMyApp: deleteMyApp
            )
            .frame(width: 260)
            Divider()
            detail
        }
        .frame(minWidth: 560, idealWidth: 1300, minHeight: 600, idealHeight: 720)
        .onChange(of: store.myApps) { _, apps in
            for app in apps { coordinator.ensureMyAppMemory(app) }
        }
        #endif
    }

    /// Show the "connect your backend" nudge only when the user explicitly
    /// skipped pairing during onboarding and the active backend is still
    /// unpaired. `isPaired` reads the Keychain live, so the banner clears the
    /// moment pairing completes (from the banner's sheet or from Settings).
    private var showBackendReminder: Bool {
        // Read `activeBackend` first so this view observes `backends` —
        // `isPaired` alone reads the Keychain and registers no dependency, so
        // the banner wouldn't clear when pairing mutates the store otherwise.
        let active = settings.activeBackend
        return backendSkipped && !settings.isPaired(active.id)
    }

    private var backendReminderBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "link.badge.plus")
                .foregroundStyle(.orange)
            Text("Connect your backend to start chatting")
                .font(.subheadline)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            Spacer(minLength: 8)
            Button("Connect") { showBackendSheet = true }
                .font(.subheadline.weight(.semibold))
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
            Button {
                // Acknowledge — stop nagging for this install.
                backendSkipped = false
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial)
        .overlay(alignment: .bottom) { Divider() }
    }

    /// Reuses the production pairing UI, operating on the active backend in the
    /// shared `SettingsStore` — same wiring as the Settings sheet's edit path.
    private var backendPairingSheet: some View {
        let entry = settings.activeBackend
        return BackendEditSheet(
            title: "Connect backend",
            initialEntry: entry,
            onSave: { updated in
                settings.updateBackend(
                    entry.id,
                    label: updated.label,
                    url: updated.url,
                    certFingerprint: .some(updated.certFingerprint)
                )
                showBackendSheet = false
            },
            onDelete: nil,
            onCancel: { showBackendSheet = false },
            settings: settings
        )
    }

    #if os(iOS)
    /// Width of the slide-in menu drawer. Compact (iPhone portrait) keeps the
    /// near-full-width drawer; regular (iPad, large iPhone landscape) caps it at
    /// a slim sidebar width so most of the canvas stays visible behind it.
    private var sidebarWidth: CGFloat {
        if hSizeClass == .regular { return 320 }
        return UIScreen.main.bounds.width - 56
    }

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
                // Scrolling the page dismisses the dock. `simultaneousGesture`
                // recognizes alongside the child ScrollView's pan, so the page
                // still scrolls while the drag bumps the dismiss signal.
                .simultaneousGesture(
                    DragGesture(minimumDistance: 12)
                        .onChanged { _ in dockDismissSignal += 1 }
                )
                myAppDock(for: selection ?? .myApp(store.activeMyAppId))
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
                .frame(width: sidebarWidth)
                // Bleed only the background behind the status bar / home
                // indicator; the content keeps its safe-area insets so the
                // brand header sits below the clock instead of under it.
                .background(Color(uiColor: .systemBackground).ignoresSafeArea())
                .shadow(radius: 10)
                .transition(.move(edge: .leading))
            }

            // Coach card sits above the sidebar drawer + chat so the welcome
            // step (which opens the menu) keeps the card visible on top.
            if tour.isActive {
                GuidedTourView(tour: tour)
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
            // Route `pupa://` links inside pushed memory notes in-app too.
            .environment(\.openURL, chatLinkAction)
            myAppDock(for: selection ?? .myApp(store.activeMyAppId))
            ChatOverlay(
                scope: chatScope,
                coordinator: coordinator,
                store: store,
                agents: agentPickerEntries,
                onSwitchAgent: switchAgent
            )
            // Intercept `pupa://` links the agent embeds in chat markdown —
            // route them in-app instead of to the browser. Scoped to the
            // overlay subtree so it doesn't hijack the canvas's own openURL
            // handlers (e.g. Slack mentions). Real http(s) URLs fall through.
            .environment(\.openURL, chatLinkAction)
            if tour.isActive {
                GuidedTourView(tour: tour)
            }
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

    /// Bottom quick-switch dock, shown only on a myApp's home/component pages.
    /// The effective page is `detailPath.last ?? rootSelection` so a
    /// homepage→component push still marks the component as active. Taps reuse
    /// the same flat-switch as the notification handler: reset the stack, set
    /// the root selection, and run `dispatchSelection` so the chat scope follows.
    @ViewBuilder
    private func myAppDock(for rootSelection: SidebarSelection) -> some View {
        let effective = detailPath.last ?? rootSelection
        if let id = effective.myAppId, let page = dockPage(for: effective) {
            MyAppDock(
                store: store,
                myAppId: id,
                currentPage: page,
                appColor: .color(atIndex: store.colorIndex(for: id)),
                memoryFiles: dockMemoryFiles(myAppId: id),
                dismissSignal: dockDismissSignal,
                onSelect: { nav in
                    detailPath = []
                    selection = nav
                    dispatchSelection(nav)
                }
            )
        }
    }

    /// Maps a selection to the dock's active page, or `nil` for pages that
    /// shouldn't show a dock (agents, orchestrator, …). A myApp memory note
    /// keeps the dock up and highlights the note.
    private func dockPage(for sel: SidebarSelection) -> MyAppDock.Page? {
        switch sel {
        case .myAppHome, .myApp: return .home
        case .myAppComponent(_, let componentId): return .component(componentId)
        case .myAppMemoryFile(_, let path): return .memory(path)
        default: return nil
        }
    }

    /// The active myApp's top-level memory notes, surfaced as dock shortcuts.
    /// Reads the same per-app subtree of the global `memory.tree` the sidebar
    /// shows; files only (folders stay sidebar-only).
    private func dockMemoryFiles(myAppId: UUID) -> [MyAppDock.MemoryItem] {
        guard let app = store.myApps.first(where: { $0.id == myAppId }) else { return [] }
        let slug = MemoryStore.myAppFolder(myAppName: app.name)
        let children = memory.tree.children?
            .first(where: { $0.name == slug })?
            .children ?? []
        return children.compactMap { node in
            guard case .file = node.kind else { return nil }
            return MyAppDock.MemoryItem(path: node.path, name: node.name)
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

    /// Navigate from a tapped in-app `pupa://` link in chat. Pushes the
    /// target onto the detail stack — so Back returns to where the user was
    /// — and routes the chat scope to match (via `dispatchSelection`).
    private func openFromChat(_ sel: SidebarSelection) {
        detailPath.append(sel)
        dispatchSelection(sel)
    }

    /// `OpenURLAction` that routes in-app `pupa://` links (chat + notes) to a
    /// `SidebarSelection` and lets every other URL fall through to the system
    /// browser. Scope-relative links bind to the chat's current myApp.
    private var chatLinkAction: OpenURLAction {
        OpenURLAction { url in
            let current: UUID? = { if case .myApp(let id) = chatScope { return id }; return nil }()
            guard let sel = ChatLink.sidebarSelection(from: url, currentMyAppId: current) else {
                return .systemAction
            }
            openFromChat(sel)
            return .handled
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

    // MARK: Tap-to-import

    /// Read + read-only-decode an opened `.pupaapp` for the confirm preview.
    /// `MyAppImporter` is the validation authority — this only extracts the app
    /// name + agent prompts and never mutates the store.
    private func stagePendingImport(_ url: URL) {
        guard url.isFileURL else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else {
            importNotice = ImportNotice(message: "Couldn't read that file.")
            return
        }
        guard let bundle = try? MyAppBundle.makeDecoder().decode(MyAppBundle.self, from: data),
              bundle.header.format == MyAppBundle.formatMagic else {
            importNotice = ImportNotice(message: "This file isn't a valid Pupa app bundle.")
            return
        }
        pendingImport = PendingImport(
            data: data,
            appName: bundle.app.name,
            agentPrompts: agentPrompts(in: bundle.app))
    }

    /// Slack agent personas in a bundle — the privacy review surface, mirroring
    /// the export screen's `sharedPromptPreview`.
    private func agentPrompts(in app: MyApp) -> [String] {
        var out: [String] = []
        for comp in app.components {
            if case .slack(let s) = comp.body {
                for agent in s.agents {
                    let role = agent.role.isEmpty ? "" : " — \(agent.role)"
                    out.append("\(agent.name)\(role)")
                }
            }
        }
        return out
    }

    /// Run the real import after the user confirms, then navigate to the new
    /// app exactly like the in-app Import button.
    private func confirmImport(_ pending: PendingImport) {
        pendingImport = nil
        do {
            let result = try MyAppImporter.importBundle(pending.data, into: store, memory: memory)
            detailPath = []
            selection = .myApp(result.myAppId)
            dispatchSelection(.myApp(result.myAppId))
            if !result.warnings.isEmpty {
                importNotice = ImportNotice(message: result.warnings.joined(separator: "\n"))
            }
        } catch {
            importNotice = ImportNotice(message: error.localizedDescription)
        }
    }
}

/// A `.pupaapp` opened from outside the app, staged for confirmation.
private struct PendingImport: Identifiable {
    let id = UUID()
    let data: Data
    let appName: String
    /// Agent personas in the bundle, surfaced for review before import.
    let agentPrompts: [String]
}

private struct ImportNotice: Identifiable {
    let id = UUID()
    let message: String
}

/// Confirm step for an externally-opened `.pupaapp`: names the app and lists
/// the agent prompts that would run with the user's tools, so an untrusted
/// bundle can't import silently.
private struct ImportConfirmSheet: View {
    let pending: PendingImport
    let onImport: () -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(pending.appName).font(.headline)
                } header: {
                    Text("Import app")
                } footer: {
                    Text("This app was shared with you. Imported agents run with your tools and data — review before importing.")
                }
                if !pending.agentPrompts.isEmpty {
                    Section("Agent prompts") {
                        ForEach(pending.agentPrompts, id: \.self) { line in
                            Text(line).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Import")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import", action: onImport)
                }
            }
        }
        .presentationDetents([.medium])
    }
}
