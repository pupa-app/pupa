import SwiftUI

/// Modal Settings sheet. Reuses the `NavigationStack { Form { Section } }`
/// pattern from the New MyApp / Rename MyApp sheets so iOS / macOS gets a
/// system-shaped layout for free.
///
/// Sections:
///   - **Backend** — base URL + optional shared API key (sent as
///     `Authorization: Bearer <key>` to match the backend's
///     `PUPA_API_KEY` env var). Both are persisted via `SettingsStore`
///     and take effect on the next message — no app restart needed (see
///     `ChatViewModel.rebuildSessionIfSettingsChanged`).
///   - **Developer — Backend tools** — per-tool toggles fetched live from
///     `GET /backend-tools`.
public struct SettingsSheet: View {
    @Bindable var settings: SettingsStore
    /// When set, enables the per-MyApp override section in Security.
    @Bindable var store: MyAppStore
    var activeMyAppId: UUID?
    var onRestoreExample: ((any ExampleMyApp.Type) -> Void)?
    var onClose: () -> Void

    @State private var selectedExampleName: String = ExampleRegistry.all.first?.name ?? ""
    @State private var toolsLoad: ToolsLoadState = .loading
    @State private var loadErrorMessage: String?
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

    private enum ToolsLoadState: Equatable {
        case loading
        case loaded([BackendToolDescriptor])
        case failed(message: String, fallback: [BackendToolDescriptor])

        var descriptors: [BackendToolDescriptor] {
            switch self {
            case .loading: return []
            case .loaded(let tools): return tools
            case .failed(_, let fallback): return fallback
            }
        }
    }

    /// Hard-coded fallback so the Developer section renders something useful
    /// even when the backend is unreachable (e.g. the user opened Settings
    /// before `make backend` finished booting). Kept in sync manually with
    /// the canonical list in `backend/backend_tools.py`; drift only matters
    /// for the offline-render path, the online path always wins.
    ///
    /// `enabledByEnv: true` here so the toggle remains tappable offline —
    /// the user can pre-set their preference and it takes effect on the
    /// next message once the backend comes online.
    private static let fallbackTools: [BackendToolDescriptor] = [
        BackendToolDescriptor(
            name: "tavily_search",
            description: "Web search via Tavily — real-world lookups mid-turn.",
            enabledByEnv: true
        ),
    ]

    public init(
        settings: SettingsStore,
        store: MyAppStore,
        activeMyAppId: UUID? = nil,
        onRestoreExample: ((any ExampleMyApp.Type) -> Void)? = nil,
        onClose: @escaping () -> Void
    ) {
        self.settings = settings
        self.store = store
        self.activeMyAppId = activeMyAppId
        self.onRestoreExample = onRestoreExample
        self.onClose = onClose
    }

    public var body: some View {
        NavigationStack {
            Form {
                backendSection
                securitySection
                if onRestoreExample != nil {
                    examplesSection
                }
                developerSection
            }
            .navigationTitle("Settings")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    InfoBadge(
                        title: "Settings",
                        message: "Configure Pupa. The Backend section points the app at a remote server; the Developer section controls which backend tools the agent is allowed to call this session."
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
                    Task { await loadTools() }
                },
                onDelete: settings.backends.count > 1 ? {
                    settings.removeBackend(entry.id)
                    editingBackend = nil
                    Task { await loadTools() }
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
                    Task { await loadTools() }
                },
                onDelete: nil,
                onCancel: { presentingAddBackend = false }
            )
        }
        .task { await loadTools() }
        .task(id: probeKey) { await probeAllBackends() }
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
                        Task { await loadTools() }
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
                            Task { await loadTools() }
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
                            Task { await loadTools() }
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
            // Per-myApp override — only shown when a myApp is active
            if let myAppId = activeMyAppId,
               let myApp = store.myApp(withId: myAppId) {
                let overrideValue = myApp.settings[ShellApprovalDisabledKey.name]
                let hasOverride = overrideValue != nil
                let effectivelyDisabled: Bool = {
                    if case .bool(let v) = overrideValue { return v }
                    return settings.shellApprovalDisabled
                }()
                Toggle(isOn: Binding(
                    get: { !effectivelyDisabled },
                    set: { newVal in
                        store.setMyAppSetting(
                            ShellApprovalDisabledKey.self,
                            value: !newVal,
                            for: myAppId
                        )
                    }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text("Require shell approval (this MyApp)")
                            if hasOverride {
                                Text("OVERRIDE")
                                    .font(.caption2)
                                    .padding(.horizontal, 4)
                                    .background(Color.accentColor.opacity(0.15), in: Capsule())
                                    .foregroundColor(Color.accentColor)
                            }
                        }
                        Text("Overrides the global toggle for \"\(myApp.name)\" only. Tap to set; long-press to clear override.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .contextMenu {
                    if hasOverride {
                        Button(role: .destructive) {
                            store.setMyAppSetting(
                                ShellApprovalDisabledKey.self,
                                value: nil,
                                for: myAppId
                            )
                        } label: {
                            Label("Clear override (use global)", systemImage: "arrow.uturn.left")
                        }
                    }
                }
            }
        } header: {
            Text("Security")
        } footer: {
            Text("Only applies when the backend has the shell tool enabled. The setting is per-device and persisted; flipping it takes effect on your next message.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var examplesSection: some View {
        Section {
            Picker("Example", selection: $selectedExampleName) {
                ForEach(ExampleRegistry.all.indices, id: \.self) { i in
                    let example = ExampleRegistry.all[i]
                    VStack(alignment: .leading, spacing: 1) {
                        Text(example.name)
                        Text(example.tagline)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .tag(example.name)
                }
            }
            #if os(iOS)
            .pickerStyle(.navigationLink)
            #else
            .pickerStyle(.menu)
            #endif
            Button("Restore selected example") {
                if let example = ExampleRegistry.example(named: selectedExampleName) {
                    onRestoreExample?(example)
                }
            }
            .buttonStyle(.borderless)
        } header: {
            Text("Examples")
        } footer: {
            Text("Adds the selected example workspace to the sidebar. Idempotent — if it's already present, this just makes it the active workspace.")
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
            Text("Developer — Backend tools")
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

    private func loadTools() async {
        let client = BackendToolsClient(
            backendURL: settings.backendURL,
            extraHeaders: settings.authHeaders
        )
        do {
            let tools = try await client.list()
            toolsLoad = .loaded(tools)
        } catch {
            toolsLoad = .failed(
                message: String(describing: error),
                fallback: Self.fallbackTools
            )
        }
    }
}
