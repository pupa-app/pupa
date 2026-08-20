import SwiftUI
import UniformTypeIdentifiers

/// Settings ▸ Import & Export hub. Splits the two flows onto their own focused
/// screens — **Share an app** (export a `.pupa` bundle) and **Import an
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
                           caption: "Send one MyApp, or all of them, as a .\(MyAppBundle.fileExtension) bundle")
                }
                NavigationLink {
                    ImportAppScreen(store: store, memory: memory, onImported: onImported)
                } label: {
                    hubRow(icon: "square.and.arrow.down",
                           title: "Import an app",
                           caption: "Load a .\(MyAppBundle.fileExtension) someone shared, or browse the marketplace")
                }
            } footer: {
                Text("Apps travel as json .\(MyAppBundle.fileExtension) bundles. Sharing publishes whatever you include. Review the agent prompts on the Share screen before sending.")
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

/// Export a MyApp to a `.pupa` and hand it to the system share sheet:
/// component selection + records/memories toggles + a review of the agent
/// prompts being shared. Two entry points share this one screen (`source`):
/// **live** (Settings ▸ Share an app — the app picker also offers **All apps**,
/// every MyApp as one library) and **snapshot** (a pin's Export from History /
/// Settings ▸ Pinned snapshots — fixed to the resolved pinned state, no picker,
/// with a "Pinned version" banner so it reads as pinned, not latest).
struct ExportShareScreen: View {
    /// Where the exported app comes from.
    enum Source {
        /// Settings: pick any live app, or **All apps** as one library.
        case live
        /// A pin's Export: the resolved snapshot `app` + its `meta` (label,
        /// timestamp). Picker and All-apps are hidden; a banner names the pin.
        case snapshot(app: MyApp, meta: SnapshotMeta)
    }

    @Bindable var store: MyAppStore
    var memory: MemoryStore
    var source: Source = .live

    /// Sentinel picker tag selecting "every app as one library bundle".
    private static let allAppsTag = UUID()

    @State private var selectedAppId: UUID?
    @State private var selectedComponentIds: Set<String> = []
    @State private var includeRecords = false
    @State private var includeMemories = false

    /// Temp `.pupa` file backing the share sheet (iOS). Rebuilt whenever the
    /// selection or toggles change so a share always reflects the current
    /// choices; `nil` (control disabled) until at least one component is picked.
    @State private var shareURL: URL?
    /// The same bytes as a document, for the Mac save panel — no temp file.
    @State private var shareDoc: MyAppDocument?
    /// File name (no extension) the save panel opens with.
    @State private var shareBaseName = ""
    @State private var presentingExporter = false
    @State private var notice: SharingNotice?

    private let relFmt: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    private var isSnapshot: Bool {
        if case .snapshot = source { return true }
        return false
    }
    private var snapshotApp: MyApp? {
        if case .snapshot(let app, _) = source { return app }
        return nil
    }
    private var snapshotMeta: SnapshotMeta? {
        if case .snapshot(_, let meta) = source { return meta }
        return nil
    }

    private var isAllApps: Bool { !isSnapshot && selectedAppId == Self.allAppsTag }

    /// Snapshot mode exports its fixed resolved pin; live mode the picked app.
    private var app: MyApp? {
        if let snapshotApp { return snapshotApp }
        return store.myApps.first { $0.id == selectedAppId } ?? store.myApps.first
    }

    var body: some View {
        Form {
            content
        }
        .navigationTitle(isSnapshot ? "Export snapshot" : "Share an app")
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
        .fileExporter(
            isPresented: $presentingExporter,
            document: shareDoc,
            contentType: .pupaAppBundle,
            defaultFilename: shareBaseName
        ) { result in
            if case .failure(let error) = result {
                notice = SharingNotice(title: "Export failed", message: error.localizedDescription)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let app {
            if let meta = snapshotMeta {
                Section {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(meta.label?.isEmpty == false ? meta.label! : "Saved snapshot")
                                .fontWeight(.semibold)
                            Text("Pinned version · \(relFmt.localizedString(for: meta.timestamp, relativeTo: Date()))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "pin.fill").foregroundStyle(.tint)
                    }
                } footer: {
                    Text("Exporting the state you pinned — not the app's latest state.")
                }
            } else {
                Section("App") {
                    Picker("App", selection: Binding(
                        get: { isAllApps ? Self.allAppsTag : app.id },
                        set: { selectedAppId = $0 }
                    )) {
                        Text("All apps").tag(Self.allAppsTag)
                        ForEach(store.myApps) { Text($0.name).tag($0.id) }
                    }
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
                if DeviceInfo.isMac {
                    // Mac routes through the save panel, not the system share
                    // sheet: its "Save to Files" service crashes the app —
                    // ShareKit hands NSSavePanel a nil name (FB13819800).
                    Button {
                        presentingExporter = true
                    } label: {
                        Label("Save…", systemImage: "square.and.arrow.down")
                    }
                    .disabled(shareDoc == nil)
                } else if let shareURL {
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
                if DeviceInfo.isMac {
                    Text(isAllApps
                         ? "Saves a .\(MyAppBundle.fileExtension) file with every app. Opening it on another device imports them all into Pupa."
                         : "Saves a .\(MyAppBundle.fileExtension) file. Opening it on another device imports the app into Pupa.")
                } else {
                    Text(isAllApps
                         ? "Shares a .\(MyAppBundle.fileExtension) file with every app — AirDrop, Messages, WhatsApp, Mail, or Save to Files. Opening it on another device imports them all into Pupa."
                         : "Shares a .\(MyAppBundle.fileExtension) file — AirDrop, Messages, WhatsApp, Mail, or Save to Files. Opening it on another device imports the app into Pupa.")
                }
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

    /// Slack workspace agents that would ship in the current selection — the
    /// privacy review surface. Agent slugs referenced by the rooms; their
    /// persona text ships as `pupa/agents/<slug>/AGENTS.md` memory files.
    /// (Omitted in all-apps mode to keep it minimal.)
    private var sharedPromptPreview: [String] {
        guard !isAllApps, let app else { return [] }
        var slugs: Set<String> = []
        for comp in app.components where selectedComponentIds.contains(comp.id) {
            if case .slack(let s) = comp.body {
                slugs.formUnion(s.channels.flatMap { $0.memberAgentIds })
            }
        }
        return slugs.sorted()
    }

    private func toggle(_ id: String) {
        if selectedComponentIds.contains(id) { selectedComponentIds.remove(id) }
        else { selectedComponentIds.insert(id) }
    }

    private func syncSelection() {
        if isSnapshot {
            guard let app else { return }
            selectedComponentIds = Set(app.components.map(\.id))
            regenerateShareFile()
            return
        }
        if isAllApps { regenerateShareFile(); return }
        guard let app else { return }
        selectedAppId = app.id
        selectedComponentIds = Set(app.components.map(\.id))
        regenerateShareFile()
    }

    /// Encode the current selection — a single-app bundle, or (all-apps mode) a
    /// library of every app. Clears the export when nothing is selectable.
    /// Cheap enough to re-run on every toggle.
    private func regenerateShareFile() {
        if isAllApps {
            guard !store.myApps.isEmpty else { clearShareFile(); return }
            let library = MyAppExporter.makeLibraryBundle(
                apps: store.myApps,
                includeRecords: includeRecords,
                includeMemories: includeMemories,
                memory: memory)
            writeShareFile(named: "Pupa Apps") { try library.encoded() }
            return
        }
        guard let app, !selectedComponentIds.isEmpty else { clearShareFile(); return }
        let bundle = MyAppExporter.makeBundle(
            app: app,
            options: .init(
                selectedComponentIds: selectedComponentIds,
                includeRecords: includeRecords,
                includeMemories: includeMemories),
            memory: memory)
        writeShareFile(named: MyAppExporter.exportBaseName(forAppName: app.name)) {
            try bundle.encoded()
        }
    }

    private func clearShareFile() {
        shareURL = nil
        shareDoc = nil
    }

    /// Stage `encode()`'s bytes for export under `<base>.pupa` (or surface an
    /// error). Mac keeps them in memory for the save panel; iOS also writes a
    /// temp file, since the share sheet hands off a URL. Each iOS regeneration
    /// gets a fresh unique folder: `ShareLink` keys off the item URL's
    /// identity, so rewriting one fixed path could hand off a bundle built
    /// before the latest toggle change (e.g. memories missing despite the
    /// toggle ON).
    private func writeShareFile(named base: String, encode: () throws -> Data) {
        let previous = shareURL
        do {
            let data = try encode()
            shareBaseName = base
            shareDoc = MyAppDocument(data: data)
            if !DeviceInfo.isMac {
                let dir = FileManager.default.temporaryDirectory
                    .appendingPathComponent("share-\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let url = dir.appendingPathComponent(base)
                    .appendingPathExtension(MyAppBundle.fileExtension)
                try data.write(to: url, options: .atomic)
                shareURL = url
            }
        } catch {
            clearShareFile()
            notice = SharingNotice(title: "Export failed", message: error.localizedDescription)
        }
        removeShareFolder(of: previous)
    }

    /// Best-effort cleanup of a superseded regeneration's unique temp folder.
    private func removeShareFolder(of url: URL?) {
        guard let url, url.deletingLastPathComponent()
            .lastPathComponent.hasPrefix("share-") else { return }
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }
}

// MARK: - Import

/// Load a `.pupa` bundle from the Files picker. (Opening one from Mail /
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
                    Label("Choose a .\(MyAppBundle.fileExtension) file…", systemImage: "folder")
                }
            } footer: {
                Text("Pick a .\(MyAppBundle.fileExtension) bundle from Files. You can also open one straight from Mail, Messages, or AirDrop.")
            }
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
            } footer: {
                Text("Opens pupa-app.com in your browser.")
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
