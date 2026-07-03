import SwiftUI
import UniformTypeIdentifiers

/// Settings ▸ Import & Export hub. Splits the two flows onto their own focused
/// screens — **Share an app** (export a `.pupaapp` bundle) and **Import an
/// app** (load one back) — so neither page mixes unrelated controls.
struct SharingSettingsView: View {
    @Bindable var store: MyAppStore
    var memory: MemoryStore
    /// Called after a successful import with the new app's id.
    var onImported: (UUID) -> Void

    var body: some View {
        Form {
            Section {
                NavigationLink {
                    ExportShareScreen(store: store, memory: memory)
                } label: {
                    hubRow(icon: "square.and.arrow.up",
                           title: "Share an app",
                           caption: "Send one MyApp — or all of them — as a .pupaapp bundle")
                }
                NavigationLink {
                    ImportAppScreen(store: store, memory: memory, onImported: onImported)
                } label: {
                    hubRow(icon: "square.and.arrow.down",
                           title: "Import an app",
                           caption: "Load a .pupaapp someone shared")
                }
            } footer: {
                Text("Apps travel as inert .pupaapp bundles. Sharing publishes whatever you include — review the agent prompts on the Share screen before sending.")
            }
        }
        .navigationTitle("Import & Export")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private func hubRow(icon: String, title: String, caption: String) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(caption).font(.caption).foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: icon)
        }
    }
}

/// One-off alert payload shared by both screens.
private struct SharingNotice: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

// MARK: - Share

/// Export a MyApp to a `.pupaapp` and hand it to the system share sheet:
/// component selection + records/memories toggles + a review of the agent
/// prompts being shared. The app picker also offers **All apps** — every MyApp
/// bundled into one `.pupaapp` library (no component picker; each app whole).
private struct ExportShareScreen: View {
    @Bindable var store: MyAppStore
    var memory: MemoryStore

    /// Sentinel picker tag selecting "every app as one library bundle".
    private static let allAppsTag = UUID()

    @State private var selectedAppId: UUID?
    @State private var selectedComponentIds: Set<String> = []
    @State private var includeRecords = false
    @State private var includeMemories = false

    /// Temp `.pupaapp` file backing the share sheet. Rebuilt whenever the
    /// selection or toggles change so a share always reflects the current
    /// choices; `nil` (control disabled) until at least one component is picked.
    @State private var shareURL: URL?
    @State private var notice: SharingNotice?

    private var isAllApps: Bool { selectedAppId == Self.allAppsTag }

    private var app: MyApp? {
        store.myApps.first { $0.id == selectedAppId } ?? store.myApps.first
    }

    var body: some View {
        Form {
            content
        }
        .navigationTitle("Share an app")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .onAppear(perform: syncSelection)
        .onChange(of: selectedAppId) { _, _ in syncSelection() }
        .onChange(of: selectedComponentIds) { _, _ in regenerateShareFile() }
        .onChange(of: includeRecords) { _, _ in regenerateShareFile() }
        .onChange(of: includeMemories) { _, _ in regenerateShareFile() }
        .alert(item: $notice) { n in
            Alert(title: Text(n.title), message: Text(n.message), dismissButton: .default(Text("OK")))
        }
    }

    @ViewBuilder
    private var content: some View {
        if let app {
            Section("App") {
                Picker("App", selection: Binding(
                    get: { isAllApps ? Self.allAppsTag : app.id },
                    set: { selectedAppId = $0 }
                )) {
                    Text("All apps").tag(Self.allAppsTag)
                    ForEach(store.myApps) { Text($0.name).tag($0.id) }
                }
            }

            if !isAllApps {
                Section {
                    ForEach(app.components) { comp in
                        componentRow(comp)
                    }
                } header: {
                    Text("Components")
                } footer: {
                    Text("Select at least one component to share.")
                }
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
                        preview: isAllApps
                            ? SharePreview("Pupa Apps", image: Image(systemName: "square.stack.3d.up"))
                            : SharePreview(app.name, image: Image(systemName: app.iconSystemName))
                    ) {
                        Label("Share…", systemImage: "square.and.arrow.up")
                    }
                } else {
                    Label("Share…", systemImage: "square.and.arrow.up")
                        .foregroundStyle(.secondary)
                }
            } footer: {
                Text(isAllApps
                     ? "Shares a .pupaapp file with every app — AirDrop, Messages, WhatsApp, Mail, or Save to Files. Opening it on another device imports them all into Pupa."
                     : "Shares a .pupaapp file — AirDrop, Messages, WhatsApp, Mail, or Save to Files. Opening it on another device imports the app into Pupa.")
            }
        } else {
            Section { Text("No apps to share.").foregroundStyle(.secondary) }
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
    /// privacy review surface. (Omitted in all-apps mode to keep it minimal.)
    private var sharedPromptPreview: [String] {
        guard !isAllApps, let app else { return [] }
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
        if isAllApps { regenerateShareFile(); return }
        guard let app else { return }
        selectedAppId = app.id
        selectedComponentIds = Set(app.components.map(\.id))
        regenerateShareFile()
    }

    /// Encode the current selection to a temp `.pupaapp` file the share sheet
    /// hands off — a single-app bundle, or (all-apps mode) a library of every
    /// app. `nil`s `shareURL` when nothing is selectable. Cheap enough to re-run
    /// on every toggle.
    private func regenerateShareFile() {
        if isAllApps {
            guard !store.myApps.isEmpty else { shareURL = nil; return }
            let library = MyAppExporter.makeLibraryBundle(
                apps: store.myApps,
                includeRecords: includeRecords,
                includeMemories: includeMemories,
                memory: memory)
            writeShareFile(named: "Pupa Apps") { try library.encoded() }
            return
        }
        guard let app, !selectedComponentIds.isEmpty else { shareURL = nil; return }
        let bundle = MyAppExporter.makeBundle(
            app: app,
            options: .init(
                selectedComponentIds: selectedComponentIds,
                includeRecords: includeRecords,
                includeMemories: includeMemories),
            memory: memory)
        writeShareFile(named: MemoryStore.myAppFolder(myAppName: app.name)) { try bundle.encoded() }
    }

    /// Write `encode()`'s bytes to a temp `<base>.pupaapp` and point the share
    /// sheet at it (or surface an error).
    private func writeShareFile(named base: String, encode: () throws -> Data) {
        do {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent(base)
                .appendingPathExtension(MyAppBundle.fileExtension)
            try encode().write(to: url, options: .atomic)
            shareURL = url
        } catch {
            shareURL = nil
            notice = SharingNotice(title: "Export failed", message: error.localizedDescription)
        }
    }
}

// MARK: - Import

/// Load a `.pupaapp` bundle from the Files picker. (Opening one from Mail /
/// Messages / AirDrop routes through `AppView.onOpenURL` with its own confirm
/// step — this is the manual in-app path.)
private struct ImportAppScreen: View {
    @Bindable var store: MyAppStore
    var memory: MemoryStore
    var onImported: (UUID) -> Void

    @State private var presentingImporter = false
    @State private var notice: SharingNotice?

    var body: some View {
        Form {
            Section {
                Button {
                    presentingImporter = true
                } label: {
                    Label("Choose a .pupaapp file…", systemImage: "folder")
                }
            } footer: {
                Text("Pick a .pupaapp bundle from Files. You can also open one straight from Mail, Messages, or AirDrop — Pupa imports it after a confirm step. Imported apps are sandboxed: untrusted bundles can't change your settings.")
            }
        }
        .navigationTitle("Import an app")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
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

    private func handleImport(_ result: Result<URL, Error>) {
        switch result {
        case .failure(let error):
            notice = SharingNotice(title: "Import failed", message: error.localizedDescription)
        case .success(let url):
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url)
                if MyAppImporter.probeFormat(data) == .library {
                    let imported = try MyAppImporter.importLibrary(data, into: store, memory: memory)
                    guard let first = imported.myAppIds.first else {
                        notice = SharingNotice(title: "Import failed", message: "The bundle had no apps to import.")
                        return
                    }
                    let n = imported.myAppIds.count
                    var lines = ["Imported \(n) app\(n == 1 ? "" : "s")."]
                    lines.append(contentsOf: imported.warnings)
                    notice = SharingNotice(title: "Imported", message: lines.joined(separator: "\n"))
                    onImported(first)
                } else {
                    let imported = try MyAppImporter.importBundle(data, into: store, memory: memory)
                    if !imported.warnings.isEmpty {
                        notice = SharingNotice(
                            title: "Imported with notes",
                            message: imported.warnings.joined(separator: "\n"))
                    }
                    onImported(imported.myAppId)
                }
            } catch {
                notice = SharingNotice(title: "Import failed", message: error.localizedDescription)
            }
        }
    }
}
