import SwiftUI

/// Modal Settings sheet. Reuses the `NavigationStack { Form { Section } }`
/// pattern from the New MyApp / Rename MyApp sheets so iOS / macOS gets a
/// system-shaped layout for free.
///
/// Categories (each pushes its own screen):
///   - **Backend** — base URL + optional shared API key (sent as
///     `Authorization: Bearer <key>` to match the backend's
///     `PUPA_API_KEY` env var). Both are persisted via `SettingsStore`
///     and take effect on the next message — no app restart needed (see
///     `ChatViewModel.rebuildSessionIfSettingsChanged`).
///   - **Agents** — hub for everything agent-governing: the roster, the
///     tools agents may call (shell approval + per-tool backend toggles),
///     the A2A / turn limits, and the conversation threads.
///   - **Notifications** — lists pending scheduled notifications and lets
///     the user cancel them (`NotificationCenterCoordinator`).
///   - **Examples** — add a sample workspace to the sidebar.
public struct SettingsSheet: View {
    @Bindable var settings: SettingsStore
    var onRestoreExample: ((any ExampleMyApp.Type) -> Void)?
    /// Replay entry point for the interactive guided tour. Provided by the
    /// caller (which has the active myApp + pairing state); tapping the
    /// "Getting started tour" row dismisses the sheet and (re)starts the tour.
    /// `nil` hides the row (e.g. previews).
    var onStartTour: (() -> Void)?
    var onClose: () -> Void
    /// MyApp + memory stores backing the Import & Export screen. When any of
    /// these three is nil the Sharing row is hidden (e.g. previews).
    var store: MyAppStore?
    var memory: MemoryStore?
    /// Lifetime per-agent activity counters backing the Agents roster.
    /// When nil (e.g. previews) the hub's Roster row is hidden; Tools and
    /// Limits still render.
    var stats: AgentStatsStore?
    /// Live LLM model registry backing the Agents roster. Same nil rule.
    var modelCatalog: ModelCatalogStore?
    /// Live session owner, for the Agents threads screen's status dots.
    var coordinator: ChatSessionCoordinator?
    /// Called after a successful import with the new app's id (select + dismiss).
    var onImported: ((UUID) -> Void)?
    /// Shared guided-tour store. On iOS a `.sheet` renders above the AppView
    /// ZStack, so the coach card hosted there is hidden during the Settings
    /// step — we re-render `GuidedTourView` as this sheet's own overlay for
    /// that one step. Both render sites read this one shared store.
    @State private var tour = GuidedTourStore.shared

    /// Navigation path for the category list. Bound so the guided tour can
    /// deep-link straight to a page (its Settings step lands on Backend).
    @State private var path: [SettingsCategory] = []
    @State private var editingBackend: BackendEntry?
    /// The id of a backend just created by "Add backend" and being edited for the
    /// first time — discarded if the user cancels the sheet (see onCancel).
    @State private var pendingNewBackendID: UUID?
    @State private var backendProbes: [UUID: BackendProbe] = [:]

    /// Result of the per-backend `/auth/config` probe shown in the Settings
    /// list. Drives the 🔓 / 🔒 / 🔑 / ⚠️ / ⏳ status badge in each row.
    private enum BackendProbe: Equatable {
        case probing
        case reachable(BackendConfig)
        case unreachable(String)
    }

    public init(
        settings: SettingsStore,
        onRestoreExample: ((any ExampleMyApp.Type) -> Void)? = nil,
        onStartTour: (() -> Void)? = nil,
        onClose: @escaping () -> Void,
        store: MyAppStore? = nil,
        memory: MemoryStore? = nil,
        stats: AgentStatsStore? = nil,
        modelCatalog: ModelCatalogStore? = nil,
        coordinator: ChatSessionCoordinator? = nil,
        onImported: ((UUID) -> Void)? = nil
    ) {
        self.settings = settings
        self.onRestoreExample = onRestoreExample
        self.onStartTour = onStartTour
        self.onClose = onClose
        self.store = store
        self.memory = memory
        self.stats = stats
        self.modelCatalog = modelCatalog
        self.coordinator = coordinator
        self.onImported = onImported
    }

    /// Top-level Settings categories. Each pushes a screen with that
    /// category's real controls (the existing section builders, re-hosted in
    /// their own `Form`).
    private enum SettingsCategory: Hashable {
        case profile, backend, agents, notifications, examples, sharing, pinned, archive, recentlyDeleted
    }

    /// Whether to offer the Recently deleted row. Loaded on appear, never in
    /// `body`: it reads the filesystem.
    @State private var hasDeletedApps = false

    /// Whether to offer the Pinned snapshots row. Same rule, same reason: the
    /// gate walks every app's snapshot directory. Reading it inline made
    /// presenting Settings wait on the whole snapshot corpus.
    @State private var hasPinnedSnapshots = false

    /// Off-main tombstone scan feeding `hasDeletedApps`. `hasTombstones()`, not
    /// `deletedMyApps()` — the row needs only "any?", and the full listing's
    /// per-entry resolve belongs on the screen itself, not on a gate re-run on
    /// every settings navigation.
    private func refreshHasDeletedApps() async {
        hasDeletedApps = await Task.detached(priority: .userInitiated) {
            MyAppStore.hasTombstones()
        }.value
    }

    /// True when the Import & Export screen can be shown (stores wired in).
    private var canShare: Bool { store != nil && memory != nil && onImported != nil }

    public var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    NavigationLink(value: SettingsCategory.profile) {
                        SettingsHubRow(icon: "person.crop.circle", title: "Account",
                                    caption: "iCloud sync & device")
                    }
                }
                NavigationLink(value: SettingsCategory.backend) {
                    SettingsHubRow(icon: "network", title: "Backend",
                                caption: "Server URL, API key, pairing")
                }
                NavigationLink(value: SettingsCategory.agents) {
                    SettingsHubRow(icon: "person.3.sequence", title: "Agents",
                                caption: "Roster, tools, limits & threads")
                }
                NavigationLink(value: SettingsCategory.notifications) {
                    SettingsHubRow(icon: "bell.badge", title: "Notifications",
                                caption: "Pending scheduled notifications")
                }
                if onRestoreExample != nil {
                    NavigationLink(value: SettingsCategory.examples) {
                        SettingsHubRow(icon: "sparkles", title: "Examples",
                                    caption: "Add a sample workspace")
                    }
                }
                if canShare {
                    NavigationLink(value: SettingsCategory.sharing) {
                        SettingsHubRow(icon: "square.and.arrow.up.on.square", title: "Import & Export",
                                    caption: "Share or load a MyApp bundle")
                    }
                }
                if store != nil, hasPinnedSnapshots {
                    NavigationLink(value: SettingsCategory.pinned) {
                        SettingsHubRow(icon: "pin", title: "Pinned snapshots",
                                    caption: "Saved states per app")
                    }
                }
                if let store, !store.archivedMyApps.isEmpty {
                    NavigationLink(value: SettingsCategory.archive) {
                        SettingsHubRow(icon: "archivebox", title: "Archive",
                                    caption: "Hidden apps")
                    }
                }
                if store != nil, hasDeletedApps {
                    NavigationLink(value: SettingsCategory.recentlyDeleted) {
                        // `arrow.up.trash`, not `trash.arrow.circlepath` — the
                        // latter isn't an SF Symbol and rendered as a blank gap.
                        SettingsHubRow(icon: "arrow.up.trash", title: "Recently deleted",
                                    caption: "Restore a deleted app")
                    }
                }
                if let onStartTour {
                    Section {
                        Button {
                            onStartTour()
                        } label: {
                            SettingsHubRow(icon: "figure.walk.motion", title: "Getting started tour",
                                        caption: "Replay the interactive walkthrough")
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .navigationTitle("Settings")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .navigationDestination(for: SettingsCategory.self) { category in
                categoryDetail(category)
            }
            .task { await refreshHasDeletedApps() }
            // Keyed on `historyRevision` so pinning or unpinning re-runs the
            // gate — the observation dependency the removed synchronous
            // accessor used to establish with a bare `_ = historyRevision`.
            .task(id: store?.historyRevision) {
                hasPinnedSnapshots = await SnapshotStore.hasAnyPins()
            }
            // Re-check on the pop, so restoring the last deleted app drops the
            // row. A push can't have changed what's on disk.
            .onChange(of: path) { _, new in
                guard new.isEmpty else { return }
                Task { await refreshHasDeletedApps() }
            }
            .toolbar {
                // Dismiss control sits leading (left) on both platforms, so
                // going back is one left-side tap — matching the back chevron
                // every pushed page already shows. `.cancellationAction` is the
                // modal-dismiss placement and lands top-left on iOS.
                ToolbarItem(placement: .cancellationAction) {
                    Button(action: onClose) {
                        #if os(iOS)
                        Image(systemName: "chevron.backward")
                        #else
                        Text("Done")
                        #endif
                    }
                    .accessibilityLabel("Back")
                }
            }
        }
        #if os(macOS)
        // macOS `Form` defaults to `.columns` — tight margins, and short
        // multi-section pages stretch their sections top-to-bottom to fill the
        // frame. Force the iOS-like inset-grouped style (inherited by every
        // pushed detail's Form via the environment) so pages top-align, keep
        // sensible side margins, and scroll when taller than the sheet.
        .formStyle(.grouped)
        // Size the whole stack — not just the root list — so pushed detail
        // pages (Account, Backend) fill the sheet and top-align. A modest min
        // height keeps short pages (Agent-to-agent) from being a mostly-empty
        // card while tall ones scroll.
        .frame(minWidth: 480, idealWidth: 600, minHeight: 440, idealHeight: 600)
        #endif
        // Guided tour deep-links: land directly on the requested page (its
        // Settings step opens Backend) when the sheet appears and if the tour
        // moves between settings pages while open.
        .onAppear { applyTourPage(tour.wantSettingsPage) }
        .onChange(of: tour.wantSettingsPage) { _, page in applyTourPage(page) }
        // The Settings tour step's coach card + highlight ring live in AppView,
        // but on iOS this `.sheet` renders above that ZStack and would hide them
        // — so re-render the ring and card here for the Settings steps. Both
        // sites read the one store; the ring only resolves when the active step
        // tags a control inside this sheet (e.g. the Examples list).
        .tourHighlightLayer(tour)
        .overlay {
            if tour.isActive, tour.wantSettingsOpen {
                GuidedTourView(tour: tour)
            }
        }
        .sheet(item: $editingBackend) { entry in
            BackendEditSheet(
                title: pendingNewBackendID == entry.id ? "Add backend" : "Edit backend",
                initialEntry: entry,
                onSave: { updated in
                    // Persist every field the sheet can edit — label (random if
                    // left blank so pairing never blocks on a name), URL, cert
                    // fingerprint, and the selected harness.
                    let label = updated.label.isEmpty ? SettingsStore.randomBackendLabel() : updated.label
                    settings.updateBackend(
                        entry.id,
                        label: label,
                        url: updated.url,
                        certFingerprint: .some(updated.certFingerprint),
                        harnessID: .some(updated.harnessID)
                    )
                    pendingNewBackendID = nil
                    editingBackend = nil
                },
                onDelete: settings.backends.count > 1 ? {
                    settings.removeBackend(entry.id)
                    pendingNewBackendID = nil
                    editingBackend = nil
                } : nil,
                onCancel: {
                    // A freshly-added, never-saved backend is discarded on cancel
                    // so an abandoned "Add" leaves no orphan row.
                    if pendingNewBackendID == entry.id {
                        settings.removeBackend(entry.id)
                        pendingNewBackendID = nil
                    }
                    editingBackend = nil
                },
                settings: settings
            )
        }
        .task(id: probeKey) { await probeAllBackends() }
    }

    /// Pushed detail screen for a category — re-hosts the matching section
    /// builder in its own `Form` so the existing controls/logic are unchanged.
    @ViewBuilder
    private func categoryDetail(_ category: SettingsCategory) -> some View {
        Group {
            switch category {
            case .profile:
                ProfileSettingsView(settings: settings, store: store, memory: memory)
            case .backend:
                Form { backendSection }.navigationTitle("Backend")
            case .agents:
                // Hub. Its sub-screens own their own state and are pushed with
                // closure links, so they stay out of `SettingsCategory` — the
                // tour's deep-link map only needs the top-level pages.
                AgentsSettingsView(
                    settings: settings, store: store, memory: memory,
                    stats: stats, modelCatalog: modelCatalog, coordinator: coordinator
                )
            case .notifications:
                PendingNotificationsList().navigationTitle("Notifications")
            case .examples:
                Form { examplesSection }.navigationTitle("Examples")
            case .sharing:
                if let store, let memory, let onImported {
                    SharingSettingsView(store: store, memory: memory, onImported: onImported)
                }
            case .pinned:
                if let store {
                    PinnedSnapshotsView(store: store, onRestored: onImported)
                }
            case .archive:
                if let store {
                    ArchivedAppsView(store: store)
                }
            case .recentlyDeleted:
                if let store {
                    RecentlyDeletedAppsView(store: store)
                }
            }
        }
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    /// Cache key for the per-backend probe task. Re-run whenever the list,
    /// the active selection, or any backend's URL changes — any of those can
    /// affect the 🔓 / 🔒 / 🔗 status shown in the rows.
    private var probeKey: String {
        let parts = settings.backends.map { "\($0.id.uuidString)|\($0.url.absoluteString)" }
        return parts.joined(separator: "#") + "@" + settings.activeBackendID.uuidString
    }

    @ViewBuilder
    private var backendSection: some View {
        Section {
            ForEach(settings.backends) { entry in
                Button {
                    if entry.id != settings.activeBackendID {
                        settings.setActiveBackend(entry.id)
                    } else {
                        editingBackend = entry
                    }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: entry.id == settings.activeBackendID
                              ? "largecircle.fill.circle"
                              : "circle")
                            .foregroundStyle(entry.id == settings.activeBackendID ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.label.isEmpty ? entry.url.host ?? entry.url.absoluteString : entry.label)
                                .foregroundStyle(.primary)
                            Text(entry.url.absoluteString)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            if let harnessID = entry.harnessID, !harnessID.isEmpty {
                                Text(harnessID)
                                    .font(.caption2.monospaced())
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 1)
                                    .background(
                                        Capsule().fill(Color.accentColor.opacity(0.12))
                                    )
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        probeBadge(for: entry)
                        Image(systemName: "pencil")
                            .foregroundStyle(.secondary)
                            .opacity(entry.id == settings.activeBackendID ? 1 : 0)
                    }
                }
                .buttonStyle(.plain)
                #if os(iOS)
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    if settings.backends.count > 1 {
                        Button(role: .destructive) {
                            settings.removeBackend(entry.id)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                    Button {
                        editingBackend = entry
                    } label: {
                        Label("Edit", systemImage: "pencil")
                    }
                    .tint(.blue)
                }
                #endif
                .contextMenu {
                    Button {
                        editingBackend = entry
                    } label: { Label("Edit", systemImage: "pencil") }
                    if settings.backends.count > 1 {
                        Button(role: .destructive) {
                            settings.removeBackend(entry.id)
                        } label: { Label("Delete", systemImage: "trash") }
                    }
                }
            }

            Button {
                // Create the entry up front and open the full edit sheet on it,
                // so scan/pair is available immediately (no name-then-reopen
                // step). Cancelling the sheet discards it (pendingNewBackendID).
                let entry = BackendEntry(label: "", url: SettingsStore.defaultBackendURL)
                settings.addBackend(entry)
                settings.setActiveBackend(entry.id)
                pendingNewBackendID = entry.id
                editingBackend = entry
            } label: {
                Label("Add backend", systemImage: "plus")
            }
        } header: {
            Text("Backend")
        } footer: {
            Text("Tap a backend to activate it; tap the active one again (or use the context menu) to edit. Each backend keeps its own URL; the paired-device token is stored in the Keychain.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var examplesSection: some View {
        Section {
            Link(destination: MarketplaceInstallLink.browseURL) {
                HStack {
                    Label("Browse the marketplace", systemImage: "bag")
                    Spacer()
                    Image(systemName: "arrow.up.right")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(ExampleRegistry.all.indices, id: \.self) { i in
                exampleRow(ExampleRegistry.all[i])
            }
            .tourAnchor(.settingsExamples)
        } header: {
            Text("Examples")
        } footer: {
            Text("Adds an example MyApp. Browse the marketplace for more.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func exampleRow(_ example: any ExampleMyApp.Type) -> some View {
        HStack(spacing: 12) {
            Image(systemName: example.iconSystemName)
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(example.name)
                Text(example.tagline)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            Button("Restore") { onRestoreExample?(example) }
                .buttonStyle(.borderless)
        }
    }

    @ViewBuilder
    private func probeBadge(for entry: BackendEntry) -> some View {
        if settings.isPaired(entry.id) {
            Label("Paired", systemImage: "link.circle.fill")
                .labelStyle(.iconOnly)
                .foregroundStyle(.green)
                .accessibilityLabel("Paired — device token in Keychain")
        } else {
            switch backendProbes[entry.id] ?? .probing {
            case .probing:
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Checking backend")
            case .reachable(let config):
                if !config.authRequired {
                    Label("Open", systemImage: "lock.open.fill")
                        .labelStyle(.iconOnly)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Open — no authentication required")
                } else {
                    Label("Needs pairing", systemImage: "lock.fill")
                        .labelStyle(.iconOnly)
                        .foregroundStyle(.orange)
                        .accessibilityLabel("Requires login — run `pupa-backend pair` and complete pairing in Edit")
                }
            case .unreachable:
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .accessibilityLabel("Unreachable")
            }
        }
    }

    private func probeAllBackends() async {
        // Mark every backend as probing up-front so the badge is consistent
        // when the user adds a new entry mid-probe.
        for entry in settings.backends where backendProbes[entry.id] == nil {
            backendProbes[entry.id] = .probing
        }
        // Probe each backend independently — one slow / unreachable backend
        // shouldn't block the others' badges from updating.
        await withTaskGroup(of: (UUID, BackendProbe).self) { group in
            for entry in settings.backends {
                group.addTask {
                    // `/auth/config` is on the backend's always-public path
                    // (see middleware._is_public), so the probe doesn't need
                    // an Authorization header.
                    let client = BackendConfigClient(backendURL: entry.url)
                    do {
                        let config = try await client.fetch()
                        return (entry.id, .reachable(config))
                    } catch {
                        return (entry.id, .unreachable(FriendlyBackendError.message(for: error)))
                    }
                }
            }
            for await (id, probe) in group {
                backendProbes[id] = probe
            }
        }
        // Drop probes for backends the user removed mid-task.
        let liveIDs = Set(settings.backends.map(\.id))
        backendProbes = backendProbes.filter { liveIDs.contains($0.key) }
    }

    /// Push the navigation path to the tour's requested page. `nil` leaves the
    /// user's own navigation untouched (e.g. when Settings was opened by hand).
    private func applyTourPage(_ page: TourSettingsPage?) {
        switch page {
        case .root: path = []
        case .backend: path = [.backend]
        case .sharing: path = [.sharing]
        case .examples: path = [.examples]
        case .account: path = [.profile]
        case nil: break
        }
    }

}

/// Settings → Archive screen: the apps hidden from the sidebar. Each row
/// restores (`Unarchive`) or permanently deletes the app. Reached only when at
/// least one app is archived (the row is otherwise hidden).
private struct ArchivedAppsView: View {
    @Bindable var store: MyAppStore
    /// App awaiting delete confirmation.
    @State private var pendingDelete: MyApp?

    var body: some View {
        List {
            Section {
                if store.archivedMyApps.isEmpty {
                    Text("No archived apps.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(store.archivedMyApps) { app in
                        row(app)
                    }
                }
            } footer: {
                Text("Archived apps are hidden from the sidebar and every agent, and their components are locked. Unarchive to bring one back.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Archive")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .confirmationDialog(
            pendingDelete.map { "Delete “\($0.name)”?" } ?? "",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingDelete
        ) { app in
            Button("Delete", role: .destructive) {
                store.removeMyApp(app.id)
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: { _ in
            Text("This app and its canvas are permanently deleted.")
        }
    }

    private func row(_ app: MyApp) -> some View {
        HStack(spacing: 10) {
            Image(systemName: app.iconSystemName)
                .foregroundStyle(Color.color(atIndex: store.colorIndex(for: app.id)))
            Text(app.name)
                .foregroundStyle(.primary)
            Spacer()
            Button("Unarchive") { store.setMyAppArchived(app.id, false) }
                .buttonStyle(.borderless)
        }
        #if os(iOS)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) { pendingDelete = app } label: {
                Label("Delete", systemImage: "trash")
            }
            Button { store.setMyAppArchived(app.id, false) } label: {
                Label("Unarchive", systemImage: "tray.and.arrow.up")
            }
            .tint(.blue)
        }
        #endif
        .contextMenu {
            Button { store.setMyAppArchived(app.id, false) } label: {
                Label("Unarchive", systemImage: "tray.and.arrow.up")
            }
            Button(role: .destructive) { pendingDelete = app } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }
}

/// Settings → Notifications screen: lists pending scheduled notifications
/// (agent-scheduled and user-created), soonest-first, with their delivery
/// time. Tap the `+` to compose a new one; swipe / context-menu to cancel.
/// Reads the app-wide `NotificationCenterCoordinator.shared` singleton directly.
private struct PendingNotificationsList: View {
    @State private var items: [NotificationCenterCoordinator.PendingNotification] = []
    @State private var loaded = false
    @State private var showComposer = false

    var body: some View {
        List {
            Section {
                if !loaded {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Loading…").foregroundStyle(.secondary)
                    }
                } else if items.isEmpty {
                    Text("No scheduled notifications.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(items) { item in
                        row(item)
                    }
                }
            } footer: {
                Text("Scheduled notifications that haven't fired yet. Swipe (or use the context menu) to cancel one.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .task { await reload() }
        #if os(iOS)
        .refreshable { await reload() }
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showComposer = true } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showComposer) {
            NotificationComposerSheet(
                onScheduled: {
                    showComposer = false
                    Task { await reload() }
                },
                onCancel: { showComposer = false }
            )
        }
    }

    private func row(_ item: NotificationCenterCoordinator.PendingNotification) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(item.title.isEmpty ? "(no title)" : item.title)
            if !item.body.isEmpty {
                Text(item.body)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            if let date = item.deliveryAt {
                HStack(spacing: 4) {
                    if item.repeats {
                        Image(systemName: "repeat")
                    }
                    Text(date, format: .dateTime.weekday().month().day().hour().minute())
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }
            if item.myAppId != nil {
                let label = item.componentId.map { "→ \($0)" } ?? "→ app"
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.tint)
            }
        }
        #if os(iOS)
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) { cancel(item) } label: {
                Label("Cancel", systemImage: "trash")
            }
        }
        #endif
        .contextMenu {
            Button(role: .destructive) { cancel(item) } label: {
                Label("Cancel notification", systemImage: "trash")
            }
        }
    }

    private func cancel(_ item: NotificationCenterCoordinator.PendingNotification) {
        Task {
            _ = await NotificationCenterCoordinator.shared.cancel(id: item.id)
            await reload()
        }
    }

    private func reload() async {
        items = await NotificationCenterCoordinator.shared.pendingNotifications()
        loaded = true
    }
}

/// Sheet for composing a user-initiated notification. Reuses `NotificationRequest`
/// and `NotificationCenterCoordinator.schedule(_:)` — the same path the agent takes.
private struct NotificationComposerSheet: View {
    var onScheduled: () -> Void
    var onCancel: () -> Void

    enum TriggerKind: String, CaseIterable, Identifiable {
        case now = "Now"
        case after = "In..."
        case atDate = "At..."
        var id: String { rawValue }
    }

    @State private var title = ""
    @State private var message = ""
    @State private var triggerKind: TriggerKind = .now
    @State private var delayMinutes = 5
    @State private var atDate = Date().addingTimeInterval(3_600)
    @State private var isScheduling = false
    @State private var errorMessage: String?

    private var titleTrimmed: String { title.trimmingCharacters(in: .whitespaces) }
    private var bodyTrimmed: String { message.trimmingCharacters(in: .whitespaces) }
    private var canSchedule: Bool {
        !titleTrimmed.isEmpty
        && titleTrimmed.count <= NotificationRequest.titleMaxLength
        && bodyTrimmed.count <= NotificationRequest.bodyMaxLength
        && !isScheduling
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Content") {
                    TextField("Title", text: $title)
                    TextField("Body (optional)", text: $message, axis: .vertical)
                        .lineLimit(3...)
                    if titleTrimmed.count > NotificationRequest.titleMaxLength {
                        Text("Title too long (\(titleTrimmed.count)/\(NotificationRequest.titleMaxLength))")
                            .font(.caption).foregroundStyle(.red)
                    }
                    if bodyTrimmed.count > NotificationRequest.bodyMaxLength {
                        Text("Body too long (\(bodyTrimmed.count)/\(NotificationRequest.bodyMaxLength))")
                            .font(.caption).foregroundStyle(.red)
                    }
                }

                Section("When") {
                    Picker("Trigger", selection: $triggerKind) {
                        ForEach(TriggerKind.allCases) { k in Text(k.rawValue).tag(k) }
                    }
                    .pickerStyle(.segmented)

                    switch triggerKind {
                    case .now:
                        EmptyView()
                    case .after:
                        Stepper(
                            "In \(delayMinutes) \(delayMinutes == 1 ? "minute" : "minutes")",
                            value: $delayMinutes, in: 1...60
                        )
                    case .atDate:
                        DatePicker(
                            "Date & time",
                            selection: $atDate,
                            in: Date()...,
                            displayedComponents: [.date, .hourAndMinute]
                        )
                    }
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("New Reminder")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isScheduling {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Schedule") { Task { await schedule() } }
                            .disabled(!canSchedule)
                    }
                }
            }
        }
    }

    private func schedule() async {
        isScheduling = true
        errorMessage = nil
        let trigger: NotificationRequest.Trigger
        switch triggerKind {
        case .now:   trigger = .now
        case .after: trigger = .after(seconds: delayMinutes * 60)
        case .atDate: trigger = .atDate(atDate)
        }
        let request = NotificationRequest(
            title: titleTrimmed,
            body: bodyTrimmed,
            trigger: trigger
        )
        do {
            _ = try await NotificationCenterCoordinator.shared.schedule(request)
            onScheduled()
        } catch NotificationCenterCoordinator.ScheduleError.notAuthorised {
            errorMessage = "Notification permission denied. Enable it in Settings → Pupa."
            isScheduling = false
        } catch {
            errorMessage = FriendlyBackendError.message(for: error)
            isScheduling = false
        }
    }
}
