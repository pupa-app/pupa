import SwiftUI
import AGUIKit
#if canImport(UIKit)
import UIKit
#endif

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
    /// Drives the resumable-SSE lifecycle hooks (background hold / foreground
    /// re-attach). See `handleScenePhase`.
    @Environment(\.scenePhase) private var scenePhase
    @State private var store: MyAppStore
    @State private var memory: MemoryStore
    @State private var settings: SettingsStore
    @State private var modelCatalog = ModelCatalogStore()
    @State private var coordinator: ChatSessionCoordinator
    @State private var screenShare: ScreenShareViewModel
    /// Watches the iCloud container for remote edits; reloads the synced
    /// stores so changes from another device appear live. Nil until started.
    @State private var cloudWatcher: CloudWatcher?
    /// The sidebar list's row highlight + tap signal. Navigation itself lives
    /// in `rootPage`; the sidebar's `onChange` routes taps through `setRoot`.
    /// iOS clears this back to nil after each tap so re-taps re-fire.
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
    /// The detail pane's `NavigationStack` root — the current top-level page
    /// (bottom-bar tab, sidebar pick, orchestrator, screen share). Replaced in
    /// place (never pushed) with animations disabled; combined with the
    /// keep-alive panes in `content`, a page switch is an opacity flip instead
    /// of the 100–200ms click→frame teardown/rebuild it used to be. All
    /// writers go through `setRoot`.
    @State private var rootPage: SidebarSelection
    /// Navigation stack pushed on top of `rootPage` — true drill-ins only
    /// (component card from the landing page, memory file, agent detail,
    /// history), so Back returns to the page the user came from.
    @State private var detailPath: [SidebarSelection] = []
    /// Whether the chat card is open. Owned here so the per-MyApp bottom bar's
    /// pupa button and the guided tour can both drive it, and `ChatOverlay`
    /// renders the card vs. its fallback launcher accordingly.
    @State private var chatOpen = false
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
    /// A `.pupa` opened from outside the app (`onOpenURL`), staged for an
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
        // Kick a background iCloud mirror pass (covers demo/preview entry that
        // bypasses `PupaApp`). The stores below load from the local canonical
        // tree regardless; the mirror converges with iCloud off the main thread.
        PupaStorage.warm()
        let store = MyAppStore()
        // Guide skills are managed content, re-seeded (version-gated) into
        // the orchestrator and every app on each launch so installs pick up
        // new guide bodies on app update — the one exception to the
        // seed-once rule below. Runs before `MemoryStore()` so the global
        // sidebar store's init rescan already sees the files.
        GuideSkills.seedOrchestrator()
        for app in store.myApps { GuideSkills.seed(appName: app.name) }
        let memory = MemoryStore()
        // Rename must move the app's slug-keyed memory folder through the
        // live store so the sidebar tree refreshes in place.
        store.globalMemory = memory
        // Sidebar/Memories edits go through this global store; refuse writes to
        // any app whose memories are locked, matching the agent's scoped guard.
        memory.writeGuard = { [weak store] path in store?.isMemoryLocked(forRootPath: path) ?? false }
        // Persona AGENTS.md and default skills (the `/to-memory` skill) are
        // seeded once at app birth (addMyApp / restoreExample / fresh-install)
        // — never on launch — so user edits *and deletions* aren't
        // resurrected. Guide skills (above) are the deliberate exception.
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
        self._rootPage = State(initialValue: .myAppHome(store.activeMyAppId))
        self._chatScope = State(initialValue: .myApp(store.activeMyAppId))
    }

    /// Single entry point for top-level navigation: swaps the detail root in
    /// place with animations disabled (instant page switch, no push
    /// transition), clears any drill-in pushes, keeps the macOS sidebar
    /// highlight in sync, and routes the chat scope. Re-entrant safe — the
    /// sidebar's selection `onChange` calls back into here.
    private func setRoot(_ sel: SidebarSelection) {
        if rootPage != sel || !detailPath.isEmpty {
            var tx = Transaction()
            tx.disablesAnimations = true
            withTransaction(tx) {
                rootPage = sel
                detailPath = []
            }
        }
        #if os(macOS)
        // iOS deliberately skips this: `selection` is cleared to nil after
        // every drawer tap so a re-tap of the same row re-fires — writing it
        // back here would defeat that.
        if selection != sel { selection = sel }
        #endif
        dispatchSelection(sel)
    }

    /// Drain a pending notification tap: navigate to its deep-link target
    /// first, then perform its tap action. `populateChat` reuses the tour's
    /// prefill bridge; `runAgent` parks the prompt for `ChatPanel` to send on
    /// the now-active scope. Consume-once — clears the buffer so a live tap
    /// (`.onReceive`) and the cold-launch drain (`.task`) never double-fire.
    private func handleNotificationTap() {
        guard let tap = NotificationCenterCoordinator.shared.pendingTap else { return }
        NotificationCenterCoordinator.shared.pendingTap = nil
        if let sel = tap["selection"] as? SidebarSelection { setRoot(sel) }
        guard let action = tap["tapAction"] as? String else { return }
        let prompt = tap["tapPrompt"] as? String ?? ""
        guard !prompt.isEmpty else { return }
        switch action {
        case "populateChat":
            tour.chatPrefill = prompt
            tour.wantChatOpen = true
        case "runAgent":
            tour.chatAutoSend = prompt
            tour.wantChatOpen = true
        default:
            break
        }
    }

    public var body: some View {
        platformBody
            .safeAreaInset(edge: .top) {
                if showBackendReminder { backendReminderBanner }
            }
            .sheet(isPresented: $showBackendSheet) { backendPairingSheet }
            .onReceive(NotificationCenter.default.publisher(for: .pupaNotificationTap)) { _ in
                handleNotificationTap()
            }
            // Cold launch: a tap that launches the app can fire `didReceive`
            // before the `.onReceive` above subscribes, so also drain the
            // coordinator's one-slot buffer here. Consume-once (the drain clears
            // it) so a live tap isn't also replayed.
            .task { handleNotificationTap() }
            // Tap-to-import: a `.pupa` opened from Files / Mail / a chat app
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
            // Fetch the model catalog from the active backend on launch and on
            // every change to the active backend. Keying on `activeBackend`
            // (not just `activeBackendID`) re-fetches when the URL is edited in
            // place or a pairing completes — both mutate the entry without
            // changing its id, which previously left the picker stuck on the
            // stale/fallback list until a cold relaunch.
            .task(id: settings.activeBackend) {
                await modelCatalog.refresh(settings: settings)
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
            // Live iCloud sync: reload the stores when another device's edits
            // land in the container. No-op when iCloud is inactive.
            .task { startCloudWatcher() }
            // First-launch converge: `warm()` kicks a background iCloud pull but
            // never reloads the stores, so a fresh device would show a stale
            // (empty) memory tree until the next mutation. Await one reconcile
            // and republish from local if it wrote anything. No-op iCloud off.
            .task {
                let changed = await StorageMirror.shared.reconcile()
                guard changed else { return }
                await store.reloadFromDisk()
                await memory.reloadFromDisk()
                await settings.reloadFromDisk()
            }
            // Resumable SSE lifecycle (pupa#103): ride out short backgrounds
            // with a UIKit background task so in-flight streams survive, and
            // on return to foreground re-attach any stream the OS killed —
            // the backend's replay log serves back what was missed.
            .onChange(of: scenePhase) { _, phase in
                handleScenePhase(phase)
            }
    }

    /// Keeps the process (and its SSE sockets) alive for the ~30s grace
    /// window iOS grants after backgrounding, but only while a turn is
    /// actually streaming. `.invalid` whenever no hold is active.
    #if os(iOS)
    @State private var streamKeepAlive: UIBackgroundTaskIdentifier = .invalid
    #endif

    private func handleScenePhase(_ phase: ScenePhase) {
        #if os(iOS)
        switch phase {
        case .background:
            guard coordinator.anyStreaming, streamKeepAlive == .invalid else { return }
            streamKeepAlive = UIApplication.shared.beginBackgroundTask(withName: "pupa.sse.stream") {
                // Expiry: end the hold; the socket dies and the backend's
                // replay buffer takes over until the next foreground.
                endStreamKeepAlive()
            }
        case .active:
            endStreamKeepAlive()
            coordinator.reattachAllAfterForeground()
        default:
            break
        }
        #else
        if phase == .active { coordinator.reattachAllAfterForeground() }
        #endif
    }

    #if os(iOS)
    private func endStreamKeepAlive() {
        guard streamKeepAlive != .invalid else { return }
        UIApplication.shared.endBackgroundTask(streamKeepAlive)
        streamKeepAlive = .invalid
    }
    #endif

    /// Start watching the iCloud container for remote changes, reloading each
    /// synced store so the UI reflects edits made on another device. Idempotent.
    private func startCloudWatcher() {
        guard cloudWatcher == nil else { return }
        let watcher = CloudWatcher {
            // Pull the remote change into the local canonical tree first, then
            // republish the stores from local. No-op reconcile when iCloud off.
            let changed = await StorageMirror.shared.reconcile()
            guard changed else { return }
            await store.reloadFromDisk()
            await memory.reloadFromDisk()
            await settings.reloadFromDisk()
        }
        watcher.start()
        cloudWatcher = watcher
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
        // The Settings sheet is hosted by the sidebar, so open the drawer
        // whenever a step opens Settings — even though the sheet then covers
        // it. (The drawer is always mounted now, so the sheet could present
        // from a closed drawer; keeping it open preserves tour semantics.)
        // Animated by the scoped `.animation(value: showSidebar)` drivers.
        showSidebar = step.opensSidebar || step.settingsPage != nil
        #endif
        tour.wantSettingsPage = step.settingsPage
        tour.wantSettingsOpen = step.settingsPage != nil
        tour.wantChatOpen = step.opensChat
        tour.chatPrefill = step.chatPrefill
        tour.wantHighlight = step.highlight
        if let sel = step.selection {
            setRoot(sel)
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
                stats: coordinator.agentStats,
                modelCatalog: modelCatalog,
                coordinator: coordinator,
                selection: $selection,
                busyMyApps: coordinator.busyMyApps,
                onSelectionChange: setRoot,
                onDeleteMyApp: deleteMyApp,
                onArchiveMyApp: archiveMyApp
            )
            .frame(width: 260)
            Divider()
            detail
        }
        .frame(minWidth: 560, idealWidth: 1300, minHeight: 600, idealHeight: 720)
        // Ring the active step's target across the whole window (sidebar footer,
        // bottom-bar tab, or chat header), under the coach card, non-blocking.
        .tourHighlightLayer(tour)
        .overlay {
            if tour.isActive {
                GuidedTourView(tour: tour)
            }
        }
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
                                    showSidebar.toggle()
                                } label: {
                                    Image(systemName: "line.3.horizontal")
                                }
                            }
                        }
                        .navigationDestination(for: SidebarSelection.self) { dest in
                            detailView(for: dest)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .toolbar {
                                    ToolbarItem(placement: .topBarLeading) {
                                        Button {
                                            showSidebar.toggle()
                                        } label: {
                                            Image(systemName: "line.3.horizontal")
                                        }
                                    }
                                }
                        }
                }
                ChatOverlay(
                    scope: chatScope,
                    coordinator: coordinator,
                    store: store,
                    settings: settings,
                    modelCatalog: modelCatalog,
                    agents: agentPickerEntries,
                    onSwitchAgent: switchAgent,
                    isOpen: $chatOpen,
                    launcherVisible: !bottomBarVisible
                )
            }
            // Inset on the ZStack (not the NavigationStack) so the bar reserves
            // space for the content AND lifts the floating `ChatOverlay` above
            // it — collapsed, resized, and fullscreen.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                myAppBottomBar
            }

            // Drawer + scrim are ALWAYS mounted (keep-alive, like `DetailPane`):
            // opening slides by offset instead of cold-constructing the sidebar
            // List inside the tap transaction — the conditional mount measured
            // ~90-135ms tap→frame warm and ~1.1s on first open (Debug, sim).
            // Scrim: opacity-driven, never hit-testable while closed.
            Color.black.opacity(showSidebar ? 0.4 : 0)
                .ignoresSafeArea()
                .onTapGesture { showSidebar = false }
                .allowsHitTesting(showSidebar)
                .animation(.snappy(duration: 0.25), value: showSidebar)

            // Drawer: slides by offset. Gradient trailing edge replaces
            // `.shadow(radius: 10)` — a per-frame shadow on a huge moving
            // layer forced offscreen rasterization during the slide.
            HStack(spacing: 0) {
                MyAppSidebarView(
                    store: store,
                    memory: memory,
                    settings: settings,
                    stats: coordinator.agentStats,
                    modelCatalog: modelCatalog,
                    coordinator: coordinator,
                    selection: $selection,
                    busyMyApps: coordinator.busyMyApps,
                    onSelectionChange: setRoot,
                    onDeleteMyApp: deleteMyApp,
                    onArchiveMyApp: archiveMyApp
                )
                .frame(width: sidebarWidth)
                // Bleed only the background behind the status bar / home
                // indicator; the content keeps its safe-area insets so the
                // brand header sits below the clock instead of under it.
                .background(Color(uiColor: .systemBackground).ignoresSafeArea())

                LinearGradient(
                    colors: [.black.opacity(0.25), .clear],
                    startPoint: .leading, endPoint: .trailing
                )
                .frame(width: 16)
                .ignoresSafeArea()
                .allowsHitTesting(false)
            }
            .offset(x: showSidebar ? 0 : -(sidebarWidth + 16))
            .allowsHitTesting(showSidebar)
            .accessibilityHidden(!showSidebar)
            .animation(.snappy(duration: 0.25), value: showSidebar)
        }
        // Ring the control the active step describes (sidebar footer, bottom-bar
        // tab, or chat header) — over the drawer + canvas, under the coach card,
        // never blocking input.
        .tourHighlightLayer(tour)
        // Coach card sits on top of everything (incl. the ring) so the welcome
        // step keeps it visible while the menu is open.
        .overlay {
            if tour.isActive {
                GuidedTourView(tour: tour)
            }
        }
        .onChange(of: selection) { _, new in
            // Ignore our own clear-to-nil (below). Navigation itself happens in
            // `setRoot`, invoked by the sidebar's `onSelectionChange` — this
            // handler only closes the drawer and re-arms the row highlight.
            guard new != nil else { return }
            showSidebar = false
            // List(selection:) won't re-fire onChange for an identical value, so a
            // re-tap of the same row is dropped. Reset the highlight after the tap
            // is dispatched; `rootPage` keeps the detail pane in place while nil.
            DispatchQueue.main.async { selection = nil }
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
            ChatOverlay(
                scope: chatScope,
                coordinator: coordinator,
                store: store,
                settings: settings,
                modelCatalog: modelCatalog,
                agents: agentPickerEntries,
                onSwitchAgent: switchAgent,
                isOpen: $chatOpen,
                launcherVisible: !bottomBarVisible
            )
            // Intercept `pupa://` links the agent embeds in chat markdown —
            // route them in-app instead of to the browser. Scoped to the
            // overlay subtree so it doesn't hijack the canvas's own openURL
            // handlers (e.g. Slack mentions). Real http(s) URLs fall through.
            .environment(\.openURL, chatLinkAction)
        }
        // Inset on the ZStack (not the NavigationStack) so the bar reserves
        // space for the content AND lifts the floating `ChatOverlay` above it —
        // collapsed, resized, and fullscreen.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            myAppBottomBar
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
        // Only non-archived apps (archived ones are hidden from every
        // agent-facing list). Color comes from each app's own stable slot, not
        // its position here, so deleting one app never slides another's color.
        let sorted = store.visibleMyApps.sorted { $0.createdAt < $1.createdAt }
        for app in sorted {
            entries.append(AgentPickerEntry(
                scope: .myApp(app.id),
                name: app.name,
                icon: app.iconSystemName,
                color: .color(atIndex: store.colorIndex(for: app.id))
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

    /// The `NavigationStack` root. The current subject's bar tabs (home /
    /// agents / memories) stay mounted in a `ZStack` and switch by opacity —
    /// rebuilding a page tree on every tab click measured 100–145ms
    /// click→frame even in release; an opacity flip is near-free. Pages
    /// outside that set (component canvas, history, screen share, memory
    /// files, agent details) build on demand as before.
    @ViewBuilder
    private var content: some View {
        let keepAlive = keepAlivePages(for: rootPage)
        ZStack {
            ForEach(keepAlive, id: \.self) { page in
                DetailPane(
                    page: page,
                    isActive: page == rootPage,
                    content: AnyView(detailView(for: page))
                )
            }
            if !keepAlive.contains(rootPage) {
                detailView(for: rootPage)
            }
        }
    }

    /// Keep-alive pane. `Equatable` on `(page, isActive)` so a mounted page's
    /// body is NOT re-evaluated when unrelated `AppView` state changes — the
    /// pages read `@Observable` stores directly, so real data changes still
    /// invalidate them from within. Without this, every click re-ran all
    /// mounted page bodies (AgentsListView's does synchronous disk scans).
    private struct DetailPane: View, Equatable {
        nonisolated static func == (a: DetailPane, b: DetailPane) -> Bool {
            a.page == b.page && a.isActive == b.isActive
        }
        let page: SidebarSelection
        let isActive: Bool
        let content: AnyView
        var body: some View {
            content
                .opacity(isActive ? 1 : 0)
                .allowsHitTesting(isActive)
                .accessibilityHidden(!isActive)
        }
    }

    /// The always-mounted tab pages for the subject `root` belongs to: the
    /// bar's fixed tabs plus the app's active component canvas (the page users
    /// bounce to most). Other component canvases can be numerous and heavy, so
    /// they stay build-on-demand; switching the active component swaps the
    /// pane's identity and rebuilds once.
    private func keepAlivePages(for root: SidebarSelection) -> [SidebarSelection] {
        switch barSubject(for: root) {
        case .myApp(let id):
            var pages: [SidebarSelection] = [.myAppHome(id), .myAppAgents(id), .myAppMemories(id)]
            if let comp = store.myApps.first(where: { $0.id == id })?.activeComponentId {
                pages.append(.myAppComponent(id, comp))
            }
            return pages
        case .orchestrator:
            return [.orchestrator, .orchestratorAgentDetail, .orchestratorMemories]
        case nil:
            return []
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
                modelCatalog: modelCatalog,
                subject: .myApp(id),
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
                // Route `pupa://` links the agent drops in `.link` fields (e.g. a
                // tracker "Doc" pointing at a note) in-app. `chatLinkAction`
                // falls through (`.systemAction`) for http(s), and `SlackView`'s
                // own nested `openURL` still wins for `pupa-mention://`.
                .environment(\.openURL, chatLinkAction)
        case .myAppAgents(let id):
            AgentsListView(
                store: store,
                memory: memory,
                settings: settings,
                modelCatalog: modelCatalog,
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
                modelCatalog: modelCatalog,
                myAppId: id,
                agentId: agentId,
                onNavigate: { nav in
                    dispatchSelection(nav)
                    detailPath.append(nav)
                }
            )
        case .myAppMemories(let id):
            MyAppMemoriesView(
                store: store,
                memory: memory,
                subject: .myApp(id),
                onNavigate: { nav in
                    dispatchSelection(nav)
                    detailPath.append(nav)
                }
            )
        case .myAppHistory(let id):
            ChangeHistoryView(store: store, myAppId: id)
        case .orchestratorMemories:
            MyAppMemoriesView(
                store: store,
                memory: memory,
                subject: .orchestrator,
                onNavigate: { nav in
                    dispatchSelection(nav)
                    detailPath.append(nav)
                }
            )
        case .myAppMemoryFile(let id, let path):
            MemoryFileView(store: memory, path: path, readOnly: store.isMemoryLocked(myAppId: id)) {
                if !detailPath.isEmpty {
                    detailPath.removeLast()
                } else {
                    setRoot(.myApp(id))
                }
            }
        case .memoryFile(let path):
            MemoryFileView(store: memory, path: path) {
                if !detailPath.isEmpty {
                    detailPath.removeLast()
                } else {
                    setRoot(.myApp(store.activeMyAppId))
                }
            }
        case .orchestrator:
            MyAppHomeView(
                store: store,
                memory: memory,
                settings: settings,
                modelCatalog: modelCatalog,
                subject: .orchestrator,
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
                modelCatalog: modelCatalog,
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

    /// The selection driving the detail pane right now: the top of the pushed
    /// stack if any, else the root page.
    private var effectiveSelection: SidebarSelection {
        detailPath.last ?? rootPage
    }

    /// Whether the bottom bar is showing — also gates whether `ChatOverlay`
    /// renders its own fallback launcher.
    private var bottomBarVisible: Bool {
        barSubject(for: effectiveSelection) != nil && barPage(for: effectiveSelection) != nil
    }

    /// Folded chat status for the current scope — mirrors `ChatOverlay.status`
    /// so the bar's pupa button shows the same badge the floating circle would.
    private var chatStatus: ChatActivityStatus {
        let base = coordinator.aggregateStatus(for: chatScope)
        if base == .idle, case .myApp(let id) = chatScope,
           coordinator.busyMyApps.contains(id) {
            return .running
        }
        return base
    }

    /// Persistent per-MyApp bottom bar, shown on a myApp's home / component /
    /// memories pages. The effective page is `detailPath.last ?? rootPage` so
    /// a home→component push still marks the component active. Taps swap the
    /// root via `setRoot`, which also routes the chat scope.
    @ViewBuilder
    private var myAppBottomBar: some View {
        let effective = effectiveSelection
        if let subject = barSubject(for: effective), let page = barPage(for: effective) {
            MyAppBottomBar(
                store: store,
                subject: subject,
                currentPage: page,
                appColor: barColor(for: subject),
                chatStatus: chatStatus,
                chatOpen: chatOpen,
                // Root swap handles both a tab switch and a re-tap (which just
                // pops any drill-in pushes back to the tab's own page).
                onSelect: setRoot,
                onShowHistory: { id in detailPath.append(.myAppHistory(id)) },
                onToggleChat: {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                        chatOpen.toggle()
                    }
                }
            )
        }
    }

    /// The bar's subject for a selection, or `nil` for pages that shouldn't
    /// show the bar (agents, agent detail, screen share, settings).
    private func barSubject(for sel: SidebarSelection) -> MyAppHomeView.Subject? {
        switch sel {
        case .myAppHome(let id), .myApp(let id), .myAppComponent(let id, _),
             .myAppMemories(let id), .myAppMemoryFile(let id, _),
             .myAppHistory(let id),
             .myAppAgents(let id), .myAppAgentDetail(let id, _):
            return .myApp(id)
        case .orchestrator, .orchestratorMemories, .memoryFile,
             .orchestratorAgentDetail:
            return .orchestrator
        default:
            return nil
        }
    }

    private func barColor(for subject: MyAppHomeView.Subject) -> Color {
        switch subject {
        case .myApp(let id): return .color(atIndex: store.colorIndex(for: id))
        case .orchestrator: return .orchestratorColor
        }
    }

    /// Maps a selection to the bar's active page, or `nil` for pages that
    /// shouldn't show the bar. Memory browse pages + files highlight Memories.
    private func barPage(for sel: SidebarSelection) -> MyAppBottomBar.Page? {
        switch sel {
        case .myAppHome, .myApp, .orchestrator: return .home
        case .myAppComponent(_, let componentId): return .component(componentId)
        case .myAppMemories, .myAppMemoryFile, .orchestratorMemories, .memoryFile:
            return .memories
        case .myAppAgents, .myAppAgentDetail, .orchestratorAgentDetail:
            return .agents
        case .myAppHistory: return .history
        default: return nil
        }
    }

    /// Same-value writes to an `@Observable`-adjacent `@State` still invalidate
    /// the chat overlay subtree; every page click routes through here, so skip
    /// the no-op rebinds.
    private func setChatScope(_ scope: ChatScope) {
        if chatScope != scope { chatScope = scope }
    }

    private func dispatchSelection(_ sel: SidebarSelection) {
        switch sel {
        case .myAppHome(let id):
            store.setActive(id)
            setChatScope(.myApp(id))
        case .myApp(let id):
            // Pure rebind — other sessions keep streaming. Updating
            // activeMyAppId is what makes CanvasView show the right myApp.
            store.setActive(id)
            setChatScope(.myApp(id))
        case .myAppComponent(let id, let componentId):
            store.setActive(id)
            // Sidebar tap drives the active-component selection so the
            // canvas + kind-targeted mutators agree on what's focused.
            _ = store.setActiveComponent(componentId: componentId, myAppId: id)
            setChatScope(.myApp(id))
        case .myAppMemoryFile(let id, _), .myAppMemories(let id), .myAppHistory(let id):
            store.setActive(id)
            setChatScope(.myApp(id))
        case .myAppAgents(let id), .myAppAgentDetail(let id, _):
            // Agents pages don't change the chat scope — they stay on
            // the owning MyApp so the user can keep chatting while
            // inspecting agent metadata.
            store.setActive(id)
            setChatScope(.myApp(id))
        case .memoryFile(let path):
            // `path` is global-root-relative (`orchestrator/x.md`); the
            // orchestrator agent's `focusedFile` context is scope-relative —
            // strip the scope folder so it points at the note the agent knows.
            let prefix = MemoryStore.orchestratorFolder() + "/"
            let scoped = path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
            coordinator.session(for: .memory).memoryFocusedPath = scoped
            setChatScope(.memory)
        case .orchestrator, .orchestratorAgentDetail, .orchestratorMemories:
            coordinator.session(for: .memory).memoryFocusedPath = ""
            setChatScope(.memory)
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
            // ChatLink emits scope-relative memory paths; the shared `memory`
            // store reads global-root-relative ones — globalize before routing.
            let global = sel.globalizedMemoryPath { id in
                store.myApps.first { $0.id == id }?.name
            }
            openFromChat(global)
            return .handled
        }
    }

    /// Cancel + drop the per-myApp session before the myApp leaves the
    /// store, so an in-flight stream tears down cleanly and any straggling
    /// tool calls no-op against the missing-myApp guard in `MyAppStore`.
    private func deleteMyApp(_ id: UUID) {
        coordinator.discardSession(for: .myApp(id))
        store.removeMyApp(id)
        if rootPage.myAppId == id || selection?.myAppId == id {
            setRoot(.myApp(store.activeMyAppId))
        }
        if case .myApp(let chatId) = chatScope, chatId == id {
            chatScope = .myApp(store.activeMyAppId)
        }
    }

    /// Archive (hide) a myApp: tear down its session — it's now agent-off and
    /// read-only — then flip the flag and repoint any selection / chat scope
    /// that pointed at it to the (new) active myApp. Restorable from Settings →
    /// Archive.
    private func archiveMyApp(_ id: UUID) {
        coordinator.discardSession(for: .myApp(id))
        store.setMyAppArchived(id, true)
        if rootPage.myAppId == id || selection?.myAppId == id {
            setRoot(.myApp(store.activeMyAppId))
        }
        if case .myApp(let chatId) = chatScope, chatId == id {
            chatScope = .myApp(store.activeMyAppId)
        }
    }

    // MARK: Tap-to-import

    /// Read + read-only-decode an opened `.pupa` for the confirm preview.
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
        switch MyAppImporter.probeFormat(data) {
        case .single:
            guard let bundle = try? MyAppBundle.makeDecoder().decode(MyAppBundle.self, from: data) else {
                importNotice = ImportNotice(message: "This file isn't a valid Pupa app bundle.")
                return
            }
            pendingImport = PendingImport(
                data: data,
                isLibrary: false,
                appNames: [bundle.app.name],
                agentPrompts: agentPrompts(in: bundle.app))
        case .library:
            guard let library = try? MyAppBundle.makeDecoder().decode(MyAppLibraryBundle.self, from: data) else {
                importNotice = ImportNotice(message: "This file isn't a valid Pupa app bundle.")
                return
            }
            pendingImport = PendingImport(
                data: data,
                isLibrary: true,
                appNames: library.apps.map { $0.app.name },
                agentPrompts: library.apps.flatMap { agentPrompts(in: $0.app) })
        case .unknown:
            importNotice = ImportNotice(message: "This file isn't a valid Pupa app bundle.")
        }
    }

    /// Slack workspace agents in a bundle — the privacy review surface. Agent
    /// slugs referenced by the rooms; their persona text ships as
    /// `pupa/agents/<slug>/AGENTS.md` memory files (shown in the memory review).
    private func agentPrompts(in app: MyApp) -> [String] {
        var slugs: Set<String> = []
        for comp in app.components {
            if case .slack(let s) = comp.body {
                slugs.formUnion(s.channels.flatMap { $0.memberAgentIds })
            }
        }
        return slugs.sorted()
    }

    /// Run the real import after the user confirms, then navigate to the new
    /// app exactly like the in-app Import button.
    private func confirmImport(_ pending: PendingImport) {
        pendingImport = nil
        do {
            if pending.isLibrary {
                let result = try MyAppImporter.importLibrary(pending.data, into: store, memory: memory)
                guard let first = result.myAppIds.first else {
                    importNotice = ImportNotice(message: "The bundle had no apps to import.")
                    return
                }
                setRoot(.myAppHome(first))
                let n = result.myAppIds.count
                var lines = ["Imported \(n) app\(n == 1 ? "" : "s")."]
                lines.append(contentsOf: result.warnings)
                importNotice = ImportNotice(message: lines.joined(separator: "\n"))
            } else {
                let result = try MyAppImporter.importBundle(pending.data, into: store, memory: memory)
                setRoot(.myAppHome(result.myAppId))
                if !result.warnings.isEmpty {
                    importNotice = ImportNotice(message: result.warnings.joined(separator: "\n"))
                }
            }
        } catch {
            importNotice = ImportNotice(message: error.localizedDescription)
        }
    }
}

/// A `.pupa` opened from outside the app, staged for confirmation. Holds one
/// app (single bundle) or many (library bundle).
private struct PendingImport: Identifiable {
    let id = UUID()
    let data: Data
    let isLibrary: Bool
    /// Names of the app(s) that would be imported.
    let appNames: [String]
    /// Agent personas across the bundle, surfaced for review before import.
    let agentPrompts: [String]
}

private struct ImportNotice: Identifiable {
    let id = UUID()
    let message: String
}

/// Confirm step for an externally-opened `.pupa`: names the app and lists
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
                    if pending.isLibrary {
                        ForEach(pending.appNames, id: \.self) { Text($0) }
                    } else {
                        Text(pending.appNames.first ?? "").font(.headline)
                    }
                } header: {
                    Text(pending.isLibrary
                         ? "Import \(pending.appNames.count) app\(pending.appNames.count == 1 ? "" : "s")"
                         : "Import app")
                } footer: {
                    Text(pending.isLibrary
                         ? "These apps were shared with you. Imported agents run with your tools and data — review before importing."
                         : "This app was shared with you. Imported agents run with your tools and data — review before importing.")
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
