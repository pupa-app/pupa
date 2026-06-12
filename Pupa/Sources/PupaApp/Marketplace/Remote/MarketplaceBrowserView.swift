import SwiftUI

/// Settings ▸ Marketplace — browse a remote catalog of `.pupaapp` apps and
/// install one. Read-only: publishing stays the manual export flow. The source
/// URL is editable so a user can point at any host (GitHub raw by default).
/// Install routes through `MyAppImporter.importBundle`, the same untrusted-input
/// gate the file importer uses.
struct MarketplaceBrowserView: View {
    @Bindable var settings: SettingsStore
    var store: MyAppStore
    var memory: MemoryStore
    /// Called after a successful install with the new app's id.
    var onImported: (UUID) -> Void

    @State private var marketplace = MarketplaceStore()
    @State private var sourceURLText: String = ""
    @State private var selected: MarketplaceCatalog.Entry?

    private var source: MarketplaceSource { settings.marketplaceSource }

    var body: some View {
        Form {
            sourceSection
            catalogSection
        }
        .navigationTitle("Marketplace")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .onAppear { if sourceURLText.isEmpty { sourceURLText = source.baseURL.absoluteString } }
        .task(id: source) { await marketplace.refresh(source: source) }
        .refreshable { await marketplace.refresh(source: source) }
        .sheet(item: $selected) { entry in
            MarketplaceEntryDetailView(
                entry: entry, source: source, marketplace: marketplace,
                store: store, memory: memory,
                onImported: { id in selected = nil; onImported(id) })
        }
    }

    // MARK: Source

    @ViewBuilder
    private var sourceSection: some View {
        Section {
            TextField("Catalog URL", text: $sourceURLText)
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                #endif
                .autocorrectionDisabled()
                .onSubmit(applySource)
            Button("Use this source", action: applySource)
                .disabled(URL(string: sourceURLText)?.scheme == nil)
        } header: {
            Text("Source")
        } footer: {
            Text("An HTTPS URL serving an index.json catalog. The default points at the Pupa marketplace; change it to read from your own repo.")
        }
    }

    private func applySource() {
        guard var text = Optional(sourceURLText.trimmingCharacters(in: .whitespaces)),
              !text.isEmpty else { return }
        if !text.hasSuffix("/") { text += "/" }  // base must end in `/`
        guard let url = URL(string: text), url.scheme != nil else { return }
        settings.setMarketplaceSourceURL(url)
        sourceURLText = url.absoluteString
    }

    // MARK: Catalog

    @ViewBuilder
    private var catalogSection: some View {
        switch marketplace.state {
        case .idle, .loading:
            Section { HStack { ProgressView(); Text("Loading catalog…").foregroundStyle(.secondary) } }
        case .failed(let message):
            Section {
                Text(message).foregroundStyle(.secondary)
                Button("Retry") { Task { await marketplace.refresh(source: source) } }
            }
        case .loaded:
            if let entries = marketplace.catalog?.entries, !entries.isEmpty {
                Section {
                    ForEach(entries) { entry in entryRow(entry) }
                } header: {
                    HStack {
                        Text("Apps")
                        if marketplace.isStale {
                            Spacer()
                            Label("Offline — cached", systemImage: "wifi.slash")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            } else {
                Section { Text("No apps in this catalog.").foregroundStyle(.secondary) }
            }
        }
    }

    private func entryRow(_ entry: MarketplaceCatalog.Entry) -> some View {
        Button { selected = entry } label: {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: entry.displaySymbol)
                    .foregroundStyle(.tint).frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.name)
                    if let author = entry.author, !author.isEmpty {
                        Text("by \(author)").font(.caption).foregroundStyle(.secondary)
                    }
                    if let summary = entry.summary, !summary.isEmpty {
                        Text(summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    if !entry.isCompatible {
                        Text("Requires a newer version of Pupa")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
        }
        .buttonStyle(.plain)
        .disabled(!entry.isCompatible)
    }
}

/// The install flow for one catalog entry: download → integrity check (in the
/// client) → decode for a persona review → import. The download is decoded once
/// here only to *preview* personas; `importBundle` re-validates from scratch.
private struct MarketplaceEntryDetailView: View {
    let entry: MarketplaceCatalog.Entry
    let source: MarketplaceSource
    let marketplace: MarketplaceStore
    let store: MyAppStore
    let memory: MemoryStore
    var onImported: (UUID) -> Void

    @Environment(\.dismiss) private var dismiss

    private enum Phase: Equatable {
        case idle, working
        case review(personas: [String])
        case failed(String)
    }
    @State private var phase: Phase = .idle
    @State private var downloaded: Data?
    @State private var warnings: [String] = []

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if let author = entry.author, !author.isEmpty {
                        LabeledContent("Author", value: author)
                    }
                    if let summary = entry.summary, !summary.isEmpty { Text(summary) }
                    LabeledContent("Size", value: byteString(entry.sizeBytes))
                    if let tags = entry.tags, !tags.isEmpty {
                        LabeledContent("Tags", value: tags.joined(separator: ", "))
                    }
                } header: { Text(entry.name) }

                phaseSection
            }
            .navigationTitle(entry.name)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private var phaseSection: some View {
        switch phase {
        case .idle:
            Section {
                Button("Download & review", action: downloadAndReview)
                    .disabled(!entry.isCompatible)
            } footer: {
                Text("Downloads the bundle, verifies its checksum, and shows the agent personas it carries before anything is added.")
            }
        case .working:
            Section { HStack { ProgressView(); Text("Working…").foregroundStyle(.secondary) } }
        case .review(let personas):
            if personas.isEmpty {
                Section { Text("No agent personas in this app.").font(.caption).foregroundStyle(.secondary) }
            } else {
                Section {
                    ForEach(personas, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                } header: {
                    Text("Agent prompts you'd import")
                } footer: {
                    Text("Personas and prompt files run with your tools after import. Review them before adding.")
                }
            }
            Section { Button("Add to my apps", action: install) }
        case .failed(let message):
            Section {
                Text(message).foregroundStyle(.secondary)
                Button("Try again") { phase = .idle }
            }
        }
    }

    private func downloadAndReview() {
        phase = .working
        Task {
            do {
                let data = try await marketplace.download(entry, from: source)
                let bundle = try MyAppBundle.makeDecoder().decode(MyAppBundle.self, from: data)
                downloaded = data
                phase = .review(personas: AgentPromptPreview.personaLines(in: bundle.app))
            } catch {
                phase = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
        }
    }

    private func install() {
        guard let data = downloaded else { return }
        phase = .working
        do {
            let result = try MyAppImporter.importBundle(data, into: store, memory: memory)
            onImported(result.myAppId)
        } catch {
            phase = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    private func byteString(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}
