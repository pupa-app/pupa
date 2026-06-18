import SwiftUI
import UniformTypeIdentifiers

/// Settings ▸ Import & Export screen — the marketplace foundation's UI.
/// Export a MyApp as a portable `.pupaapp` bundle (component selection +
/// records/memories toggles + a review of the agent prompts being shared),
/// and import a bundle back. No MyApp-sidebar changes.
struct SharingSettingsView: View {
    @Bindable var store: MyAppStore
    var memory: MemoryStore
    /// Called after a successful import with the new app's id.
    var onImported: (UUID) -> Void

    @State private var selectedAppId: UUID?
    @State private var selectedComponentIds: Set<String> = []
    @State private var includeRecords = false
    @State private var includeMemories = false

    /// Temp `.pupaapp` file backing the share sheet. Rebuilt whenever the
    /// selection or toggles change so a share always reflects the current
    /// choices; `nil` (control disabled) until at least one component is picked.
    @State private var shareURL: URL?
    @State private var presentingImporter = false
    @State private var notice: Notice?

    private struct Notice: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    private var app: MyApp? {
        store.myApps.first { $0.id == selectedAppId } ?? store.myApps.first
    }

    var body: some View {
        Form {
            exportSection
            importSection
        }
        .navigationTitle("Import & Export")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .onAppear(perform: syncSelection)
        .onChange(of: selectedAppId) { _, _ in syncSelection() }
        .onChange(of: selectedComponentIds) { _, _ in regenerateShareFile() }
        .onChange(of: includeRecords) { _, _ in regenerateShareFile() }
        .onChange(of: includeMemories) { _, _ in regenerateShareFile() }
        .fileImporter(
            isPresented: $presentingImporter,
            allowedContentTypes: [.pupaAppBundle, .json]
        ) { result in
            handleImport(result)
        }
        .alert(item: $notice) { n in
            Alert(title: Text(n.title), message: Text(n.message), dismissButton: .default(Text("OK")))
        }
    }

    // MARK: Export

    @ViewBuilder
    private var exportSection: some View {
        if let app {
            Section("App") {
                Picker("App", selection: Binding(
                    get: { app.id },
                    set: { selectedAppId = $0 }
                )) {
                    ForEach(store.myApps) { Text($0.name).tag($0.id) }
                }
            }

            Section {
                ForEach(app.components) { comp in
                    componentRow(comp)
                }
            } header: {
                Text("Components")
            } footer: {
                Text("Select at least one component to export.")
            }

            Section {
                Toggle("Include records", isOn: $includeRecords)
                Toggle("Include memories", isOn: $includeMemories)
            } footer: {
                Text("Records are user-entered rows/events/messages. Memories include agent notes; agent prompt files (AGENTS.md) are always shared so the agents work on import.")
            }

            if !sharedPromptPreview.isEmpty {
                Section {
                    ForEach(sharedPromptPreview, id: \.self) { line in
                        Text(line).font(.caption).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Agent prompts shared")
                } footer: {
                    Text("Personas and prompt files travel with the bundle. Review them before sharing — they may contain personal context.")
                }
            }

            Section {
                if let shareURL {
                    // An explicit preview stops the share sheet probing the
                    // bundle for a thumbnail it can't make (benign but noisy
                    // "error fetching item … (null)" logs) and gives a clean card.
                    ShareLink(
                        item: shareURL,
                        preview: SharePreview(
                            app.name,
                            image: Image(systemName: app.iconSystemName))
                    ) {
                        Label("Share…", systemImage: "square.and.arrow.up")
                    }
                } else {
                    Label("Share…", systemImage: "square.and.arrow.up")
                        .foregroundStyle(.secondary)
                }
            } footer: {
                Text("Shares a .pupaapp file — AirDrop, Messages, WhatsApp, Mail, or Save to Files. Opening it on another device imports the app into Pupa.")
            }
        } else {
            Section { Text("No apps to export.").foregroundStyle(.secondary) }
        }
    }

    private func componentRow(_ comp: Component) -> some View {
        let warning = ComponentExportRegistry.shared.policy(forKind: comp.kindString)?.exportDataWarning
        return Button {
            toggle(comp.id)
        } label: {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: selectedComponentIds.contains(comp.id) ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selectedComponentIds.contains(comp.id) ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                VStack(alignment: .leading, spacing: 2) {
                    Text(comp.name)
                    if let warning {
                        Text(warning).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .buttonStyle(.plain)
    }

    /// Slack agent personas that would ship in the current selection — the
    /// privacy review surface.
    private var sharedPromptPreview: [String] {
        guard let app else { return [] }
        var out: [String] = []
        for comp in app.components where selectedComponentIds.contains(comp.id) {
            if case .slack(let s) = comp.body {
                for agent in s.agents {
                    let role = agent.role.isEmpty ? "" : " — \(agent.role)"
                    out.append("\(agent.name)\(role)")
                }
            }
        }
        return out
    }

    private func toggle(_ id: String) {
        if selectedComponentIds.contains(id) { selectedComponentIds.remove(id) }
        else { selectedComponentIds.insert(id) }
    }

    private func syncSelection() {
        guard let app else { return }
        selectedAppId = app.id
        selectedComponentIds = Set(app.components.map(\.id))
        regenerateShareFile()
    }

    /// Encode the current selection to a temp `<App>.pupaapp` file the share
    /// sheet hands off. `nil`s `shareURL` (disabling the control) when nothing
    /// is selected. Cheap enough to re-run on every toggle.
    private func regenerateShareFile() {
        guard let app, !selectedComponentIds.isEmpty else {
            shareURL = nil
            return
        }
        let bundle = MyAppExporter.makeBundle(
            app: app,
            options: .init(
                selectedComponentIds: selectedComponentIds,
                includeRecords: includeRecords,
                includeMemories: includeMemories),
            memory: memory)
        do {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent(MemoryStore.myAppFolder(myAppName: app.name))
                .appendingPathExtension(MyAppBundle.fileExtension)
            try bundle.encoded().write(to: url, options: .atomic)
            shareURL = url
        } catch {
            shareURL = nil
            notice = Notice(title: "Export failed", message: error.localizedDescription)
        }
    }

    // MARK: Import

    private var importSection: some View {
        Section("Import") {
            Button("Import bundle…") { presentingImporter = true }
        }
    }

    private func handleImport(_ result: Result<URL, Error>) {
        switch result {
        case .failure(let error):
            notice = Notice(title: "Import failed", message: error.localizedDescription)
        case .success(let url):
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url)
                let imported = try MyAppImporter.importBundle(data, into: store, memory: memory)
                if imported.warnings.isEmpty {
                    onImported(imported.myAppId)
                } else {
                    notice = Notice(
                        title: "Imported with notes",
                        message: imported.warnings.joined(separator: "\n"))
                    onImported(imported.myAppId)
                }
            } catch {
                notice = Notice(title: "Import failed", message: error.localizedDescription)
            }
        }
    }
}
