import SwiftUI

/// Settings ▸ Tools detail. Self-contained: owns the shell-approval toggle and
/// the backend-tool list, loading the list into its **own** `@State` on appear
/// and on backend switch. Lives as its own `View` (not an inline section on
/// `SettingsSheet`) because it's pushed via `navigationDestination`, where a
/// parent's `@State` mutated from the destination is not reliably re-observed.
/// Settings → Tools. The controls shown depend on the **active backend
/// harness**: they're rendered from the harness's permission schema advertised
/// by `GET /harnesses`, so Deep Agents shows its shell-approval toggle + backend
/// tool mutes while Claude Code shows its host-tool scope + auto-approve. No
/// hardcoded fallback: an unreachable backend shows an explicit error row.
struct ToolsSettingsView: View {
    @Bindable var settings: SettingsStore

    @State private var load: LoadState = .loading

    private enum LoadState: Equatable {
        case loading
        case loaded(HarnessDescriptor)
        case failed(String)
    }

    var body: some View {
        Form {
            switch load {
            case .loading:
                Section {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Loading harness controls…").foregroundStyle(.secondary)
                    }
                }
            case .failed(let message):
                Section {
                    Label("Backend unreachable", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
            case .loaded(let harness):
                controls(for: harness)
            }
        }
        .navigationTitle("Tools")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task(id: settings.activeBackendID) { await loadHarness() }
    }

    @ViewBuilder
    private func controls(for harness: HarnessDescriptor) -> some View {
        if harness.permissions.isEmpty {
            Section {
                Text("This harness exposes no permission controls.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        ForEach(harness.permissions, id: \.key) { control in
            controlSection(control, harness: harness)
        }
    }

    @ViewBuilder
    private func controlSection(_ control: HarnessPermissionControl, harness: HarnessDescriptor) -> some View {
        switch control.type {
        case .toolset:
            toolsetSection(control, tools: harness.tools)
        case .bool:
            boolSection(control, harnessID: harness.id)
        case .choice:
            choiceSection(control, harnessID: harness.id)
        }
    }

    // MARK: toolset (backend tool mute list — Deep Agents `disabled_tools`)

    @ViewBuilder
    private func toolsetSection(_ control: HarnessPermissionControl, tools: [BackendToolDescriptor]) -> some View {
        Section {
            if tools.isEmpty {
                Text("No backend tools registered on the server.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(tools) { tool in toolRow(tool) }
            }
        } header: {
            Text(control.label)
        } footer: {
            Text("Disabling a tool removes it from the model's tool list per turn. Re-enabling restores it on the next message — no restart needed.")
                .font(.caption).foregroundStyle(.secondary)
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
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !tool.enabledByEnv {
                    Text("Unavailable. Server is missing the required API key.")
                        .font(.caption2).foregroundStyle(.orange)
                }
            }
        }
        .disabled(!tool.enabledByEnv)
    }

    // MARK: bool control

    @ViewBuilder
    private func boolSection(_ control: HarnessPermissionControl, harnessID: String) -> some View {
        // `shell_approval_disabled` keeps its dedicated storage + inverted label
        // ("Require approval"); other bools use the generic per-harness store.
        if control.key == "shell_approval_disabled" {
            Section("Shell commands") {
                Toggle(isOn: Binding(
                    get: { !settings.shellApprovalDisabled },
                    set: { settings.setShellApprovalDisabled(!$0) }
                )) {
                    labelStack("Require shell approval",
                               "Show an Approve / Deny card before every shell command. When off, commands run unattended.")
                }
            }
        } else {
            Section {
                Toggle(isOn: Binding(
                    get: { boolValue(control, harnessID: harnessID) },
                    set: { settings.setHarnessControl(harnessID: harnessID, key: control.key, value: .bool($0)) }
                )) {
                    Text(control.label)
                }
            }
        }
    }

    private func boolValue(_ control: HarnessPermissionControl, harnessID: String) -> Bool {
        if case .bool(let v)? = settings.harnessControl(harnessID: harnessID, key: control.key) { return v }
        return control.defaultBool ?? false
    }

    // MARK: choice control (e.g. Claude host-tool scope)

    @ViewBuilder
    private func choiceSection(_ control: HarnessPermissionControl, harnessID: String) -> some View {
        Section(control.label) {
            Picker(control.label, selection: Binding(
                get: { choiceValue(control, harnessID: harnessID) },
                set: { settings.setHarnessControl(harnessID: harnessID, key: control.key, value: .string($0)) }
            )) {
                ForEach(control.options ?? [], id: \.self) { option in
                    Text(option).tag(option)
                }
            }
            .pickerStyle(.menu)
        }
    }

    private func choiceValue(_ control: HarnessPermissionControl, harnessID: String) -> String {
        if case .string(let v)? = settings.harnessControl(harnessID: harnessID, key: control.key) { return v }
        return control.defaultString ?? control.options?.first ?? ""
    }

    @ViewBuilder
    private func labelStack(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            Text(subtitle)
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func loadHarness() async {
        load = .loading
        let client = BackendHarnessesClient(
            backendURL: settings.backendURL,
            extraHeaders: settings.authHeaders,
            session: settings.backendSession
        )
        do {
            let harnesses = try await client.list()
            let active = harnesses.first(where: { $0.id == settings.activeHarnessID })
                ?? harnesses.first(where: { $0.isDefault })
                ?? harnesses.first
            if let active {
                load = .loaded(active)
            } else {
                load = .failed("No harnesses advertised by the backend.")
            }
        } catch {
            load = .failed(FriendlyBackendError.message(for: error, host: settings.backendURL.host))
        }
    }
}
