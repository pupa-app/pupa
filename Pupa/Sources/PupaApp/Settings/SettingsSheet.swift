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
///   - **Tools** — all tool permissions in one place: the global
///     shell-command approval toggle and per-tool backend toggles fetched
///     live from `GET /backend-tools`.
///   - **Agent-to-agent** — A2A guardrails (`AgentInvocationGate`):
///     conversation rounds per agent pair + max chain depth.
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
    @State private var presentingAddBackend: Bool = false
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
        onImported: ((UUID) -> Void)? = nil
    ) {
        self.settings = settings
        self.onRestoreExample = onRestoreExample
        self.onStartTour = onStartTour
        self.onClose = onClose
        self.store = store
        self.memory = memory
        self.onImported = onImported
    }

    /// Top-level Settings categories. Each pushes a screen with that
    /// category's real controls (the existing section builders, re-hosted in
    /// their own `Form`).
    private enum SettingsCategory: Hashable {
        case backend, tools, agents, notifications, examples, sharing
    }

    /// True when the Import & Export screen can be shown (stores wired in).
    private var canShare: Bool { store != nil && memory != nil && onImported != nil }

    public var body: some View {
        NavigationStack(path: $path) {
            List {
                NavigationLink(value: SettingsCategory.backend) {
                    categoryRow(icon: "network", title: "Backend",
                                caption: "Server URL, API key, pairing")
                }
                NavigationLink(value: SettingsCategory.tools) {
                    categoryRow(icon: "wrench.and.screwdriver", title: "Tools",
                                caption: "Shell approval & tool permissions")
                }
                NavigationLink(value: SettingsCategory.agents) {
                    categoryRow(icon: "point.3.connected.trianglepath.dotted", title: "Agent-to-agent",
                                caption: "Conversation rounds & chain depth")
                }
                NavigationLink(value: SettingsCategory.notifications) {
                    categoryRow(icon: "bell.badge", title: "Notifications",
                                caption: "Pending scheduled notifications")
                }
                if onRestoreExample != nil {
                    NavigationLink(value: SettingsCategory.examples) {
                        categoryRow(icon: "sparkles", title: "Examples",
                                    caption: "Add a sample workspace")
                    }
                }
                if canShare {
                    NavigationLink(value: SettingsCategory.sharing) {
                        categoryRow(icon: "square.and.arrow.up.on.square", title: "Import & Export",
                                    caption: "Share or load a MyApp bundle")
                    }
                }
                if let onStartTour {
                    Section {
                        Button {
                            onStartTour()
                        } label: {
                            categoryRow(icon: "figure.walk.motion", title: "Getting started tour",
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
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    InfoBadge(
                        title: "Settings",
                        message: "Configure Pupa. The Backend section points the app at a remote server; the Tools section controls shell-command approval and which tools the agent is allowed to call this session."
                    )
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: onClose)
                }
            }
            #if os(macOS)
            .frame(minWidth: 320, idealWidth: 380, minHeight: 360, idealHeight: 480)
            #endif
        }
        // Guided tour deep-links: land directly on the requested page (its
        // Settings step opens Backend) when the sheet appears and if the tour
        // moves between settings pages while open.
        .onAppear { applyTourPage(tour.wantSettingsPage) }
        .onChange(of: tour.wantSettingsPage) { _, page in applyTourPage(page) }
        // The Settings tour step's coach card lives in AppView, but on iOS this
        // `.sheet` renders above that ZStack and would hide it — so re-render
        // the same card here for that one step. Both sites read the one store.
        .overlay {
            if tour.isActive, tour.wantSettingsOpen {
                GuidedTourView(tour: tour)
            }
        }
        .sheet(item: $editingBackend) { entry in
            BackendEditSheet(
                title: "Edit backend",
                initialEntry: entry,
                onSave: { updated in
                    settings.updateBackend(
                        entry.id,
                        label: updated.label,
                        url: updated.url
                    )
                    editingBackend = nil
                },
                onDelete: settings.backends.count > 1 ? {
                    settings.removeBackend(entry.id)
                    editingBackend = nil
                } : nil,
                onCancel: { editingBackend = nil },
                settings: settings
            )
        }
        .sheet(isPresented: $presentingAddBackend) {
            BackendEditSheet(
                title: "Add backend",
                initialEntry: BackendEntry(label: "", url: SettingsStore.defaultBackendURL),
                onSave: { newEntry in
                    let id = settings.addBackend(label: newEntry.label, url: newEntry.url)
                    settings.setActiveBackend(id)
                    presentingAddBackend = false
                },
                onDelete: nil,
                onCancel: { presentingAddBackend = false }
            )
        }
        .task(id: probeKey) { await probeAllBackends() }
    }

    /// One row in the top-level category list: icon + title + one-line caption.
    private func categoryRow(icon: String, title: String, caption: String) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: icon)
        }
    }

    /// Pushed detail screen for a category — re-hosts the matching section
    /// builder in its own `Form` so the existing controls/logic are unchanged.
    @ViewBuilder
    private func categoryDetail(_ category: SettingsCategory) -> some View {
        Group {
            switch category {
            case .backend:
                Form { backendSection }.navigationTitle("Backend")
            case .tools:
                // Self-contained screen that owns its own `toolsLoad` state.
                // Pushed via `navigationDestination`, so it must load + render
                // from its own `@State` — a parent `@State` mutated here is not
                // reliably re-observed by the destination closure.
                ToolsSettingsView(settings: settings)
            case .agents:
                Form { agentsSection }.navigationTitle("Agent-to-agent")
            case .notifications:
                PendingNotificationsList().navigationTitle("Notifications")
            case .examples:
                Form { examplesSection }.navigationTitle("Examples")
            case .sharing:
                if let store, let memory, let onImported {
                    SharingSettingsView(store: store, memory: memory, onImported: onImported)
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
                presentingAddBackend = true
            } label: {
                Label("Add backend", systemImage: "plus")
            }
        } header: {
            Text("Backend")
        } footer: {
            Text("Tap a backend to activate it; tap the active one again (or use the context menu) to edit. Each backend keeps its own URL + optional API key. Stored in UserDefaults — fine for personal testing, not for shared secrets.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var agentsSection: some View {
        Section {
            Stepper(
                value: Binding(
                    get: { settings.a2aMaxTurnsPerPair },
                    set: { settings.setA2AMaxTurnsPerPair($0) }
                ),
                in: SettingsStore.a2aMaxTurnsPerPairRange
            ) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Conversation rounds: \(settings.a2aMaxTurnsPerPair)")
                    Text("How many back-and-forth turns one agent may have with another before the gate cuts it off.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Stepper(
                value: Binding(
                    get: { settings.a2aMaxChainDepth },
                    set: { settings.setA2AMaxChainDepth($0) }
                ),
                in: SettingsStore.a2aMaxChainDepthRange
            ) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Max chain depth: \(settings.a2aMaxChainDepth)")
                    Text("How deep a chain of agents-calling-agents can go before further nested calls are blocked.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } header: {
            Text("Agent-to-agent limits")
        } footer: {
            Text("Guardrails for when one agent delegates to another — the orchestrator fanning out to myApp agents, or a Slack room. Changes take effect on the next agent call.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var examplesSection: some View {
        Section {
            ForEach(ExampleRegistry.all.indices, id: \.self) { i in
                exampleRow(ExampleRegistry.all[i])
            }
        } header: {
            Text("Examples")
        } footer: {
            Text("Adds an example workspace to the sidebar. Idempotent — if it's already present, this just makes it the active workspace.")
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
                        .accessibilityLabel("Requires login — run `make pair` and complete pairing in Edit")
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
                        return (entry.id, .unreachable(String(describing: error)))
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
        case nil: break
        }
    }

}

/// Settings ▸ Tools detail. Self-contained: owns the shell-approval toggle and
/// the backend-tool list, loading the list into its **own** `@State` on appear
/// and on backend switch. Lives as its own `View` (not an inline section on
/// `SettingsSheet`) because it's pushed via `navigationDestination`, where a
/// parent's `@State` mutated from the destination is not reliably re-observed.
private struct ToolsSettingsView: View {
    @Bindable var settings: SettingsStore

    @State private var toolsLoad: ToolsLoadState = .loading

    private enum ToolsLoadState: Equatable {
        case loading
        case loaded([BackendToolDescriptor])
        case failed(message: String, fallback: [BackendToolDescriptor])
    }

    /// Hard-coded fallback so the section renders something useful when the
    /// backend is unreachable. Kept in sync manually with `backend_tools.py`;
    /// drift only matters offline — the online path always wins.
    private static let fallbackTools: [BackendToolDescriptor] = [
        BackendToolDescriptor(
            name: "tavily_search",
            description: "Web search via Tavily — real-world lookups mid-turn.",
            enabledByEnv: true
        ),
    ]

    var body: some View {
        Form {
            securitySection
            developerSection
        }
        .navigationTitle("Tools")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task(id: settings.activeBackendID) { await loadTools() }
    }

    @ViewBuilder
    private var securitySection: some View {
        Section {
            Toggle(isOn: Binding(
                get: { !settings.shellApprovalDisabled },
                set: { settings.setShellApprovalDisabled(!$0) }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Require shell approval")
                    Text("Show an Approve / Deny card before every shell command. When off, commands run unattended.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } header: {
            Text("Shell commands")
        } footer: {
            Text("Only applies when the backend has the shell tool enabled. The setting is per-device and persisted; flipping it takes effect on your next message.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var developerSection: some View {
        Section {
            switch toolsLoad {
            case .loading:
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading backend tools…")
                        .foregroundStyle(.secondary)
                }
            case .loaded(let tools), .failed(_, let tools):
                if tools.isEmpty {
                    Text("No backend tools registered on the server.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(tools) { tool in
                        toolRow(tool)
                    }
                }
            }
        } header: {
            Text("Backend tools")
        } footer: {
            footerView
        }
    }

    @ViewBuilder
    private func toolRow(_ tool: BackendToolDescriptor) -> some View {
        Toggle(isOn: Binding(
            get: { settings.isEnabled(tool.name) },
            set: { settings.setEnabled(tool.name, to: $0) }
        )) {
            VStack(alignment: .leading, spacing: 2) {
                Text(tool.name).font(.body.monospaced())
                Text(tool.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !tool.enabledByEnv {
                    Text("Unavailable — server is missing the required API key.")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
        }
        .disabled(!tool.enabledByEnv)
    }

    @ViewBuilder
    private var footerView: some View {
        if case .failed(let message, _) = toolsLoad {
            Text("Couldn't reach the backend (\(message)). Showing a fallback list — toggles still persist locally.")
                .font(.caption)
                .foregroundStyle(.orange)
        } else {
            Text("Disabling a tool removes it from the model's tool list per turn. Re-enabling restores it on the next message — no restart needed.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func loadTools() async {
        let client = BackendToolsClient(
            backendURL: settings.backendURL,
            extraHeaders: settings.authHeaders,
            session: settings.backendSession
        )
        do {
            toolsLoad = .loaded(try await client.list())
        } catch {
            toolsLoad = .failed(
                message: String(describing: error),
                fallback: Self.fallbackTools
            )
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
                Text("Scheduled notifications that haven't fired yet — from the agent or created by you. Swipe (or use the context menu) to cancel one.")
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
                Text(date, format: .dateTime.weekday().month().day().hour().minute())
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
            errorMessage = error.localizedDescription
            isScheduling = false
        }
    }
}
