import SwiftUI

public struct MyAppSidebarView: View {
    @Bindable var store: MyAppStore
    @Bindable var memory: MemoryStore
    @Bindable var settings: SettingsStore
    /// Lifetime per-agent activity counters, forwarded to the Settings →
    /// Agents overview.
    let stats: AgentStatsStore
    /// Live LLM model registry, forwarded to the Settings → Agents overview's
    /// model pickers.
    let modelCatalog: ModelCatalogStore
    /// Live session owner, forwarded to the Settings → Agents overview for
    /// per-thread status dots.
    let coordinator: ChatSessionCoordinator
    @Binding var selection: SidebarSelection?
    let busyMyApps: Set<UUID>
    var onSelectionChange: (SidebarSelection) -> Void
    var onDeleteMyApp: (UUID) -> Void

    @State private var newSheetPresented = false
    @State private var settingsSheetPresented = false
    /// Shared guided-tour store. The Settings tour step raises
    /// `wantSettingsOpen`; we mirror it onto `settingsSheetPresented` so the
    /// sheet opens (and closes) in lock-step with the tour.
    @State private var tour = GuidedTourStore.shared
    @State private var renamingMyAppId: UUID?

    public init(
        store: MyAppStore,
        memory: MemoryStore,
        settings: SettingsStore,
        stats: AgentStatsStore,
        modelCatalog: ModelCatalogStore,
        coordinator: ChatSessionCoordinator,
        selection: Binding<SidebarSelection?>,
        busyMyApps: Set<UUID>,
        onSelectionChange: @escaping (SidebarSelection) -> Void,
        onDeleteMyApp: @escaping (UUID) -> Void
    ) {
        self.store = store
        self.memory = memory
        self.settings = settings
        self.stats = stats
        self.modelCatalog = modelCatalog
        self.coordinator = coordinator
        self._selection = selection
        self.busyMyApps = busyMyApps
        self.onSelectionChange = onSelectionChange
        self.onDeleteMyApp = onDeleteMyApp
    }

    public var body: some View {
        VStack(spacing: 0) {
            brandHeader
            Divider()
            // Compact, non-expanding MyApp rows. Tapping a row lands on its
            // home; components, memories, and history are reached from the
            // MyApp home + its bottom bar (not the sidebar). `selection` is
            // optional so iOS compact can clear it on Back — a non-optional
            // binding silently swallowed SwiftUI's `nil` write.
            #if os(macOS)
            List(selection: $selection) {
                myAppsSection
            }
            .listStyle(.sidebar)
            .frame(maxHeight: .infinity)
            #else
            List(selection: $selection) {
                myAppsSection
            }
            .frame(maxHeight: .infinity)
            #endif

            Divider()
            bottomMenu
        }
        // Fires for selection changes from the list (shared binding).
        .onChange(of: selection) { _, new in
            if let new { onSelectionChange(new) }
        }
        // Guided tour drives the Settings sheet through its intent flag so the
        // step's coach card and the sheet stay in sync.
        .onChange(of: tour.wantSettingsOpen) { _, want in
            settingsSheetPresented = want
        }
        // On iOS the sidebar is conditionally mounted; a tour step that opens
        // Settings remounts it with the flag already true, so `onChange` never
        // fires. Reconcile on appear so the sheet still opens.
        .onAppear {
            if tour.wantSettingsOpen { settingsSheetPresented = true }
        }
        .sheet(isPresented: $newSheetPresented) {
            NewMyAppSheet(store: store) { newSheetPresented = false }
        }
        .sheet(isPresented: $settingsSheetPresented) {
            settingsSheet
        }
        .sheet(item: Binding(
            get: { renamingMyAppId.flatMap { id in store.myApps.first(where: { $0.id == id }) } },
            set: { if $0 == nil { renamingMyAppId = nil } }
        )) { myApp in
            RenameMyAppSheet(initial: myApp.name) { newName in
                store.renameMyApp(myApp.id, to: newName)
                renamingMyAppId = nil
            } onCancel: {
                renamingMyAppId = nil
            }
        }
    }

    /// Footer actions: the global Orchestrator, the screen-share viewer, and
    /// Settings. The Orchestrator moved here from a sidebar section — it's a
    /// global agent, not one of "your projects".
    private var bottomMenu: some View {
        HStack(spacing: 8) {
            Button {
                selection = .orchestrator
                onSelectionChange(.orchestrator)
            } label: {
                Label("Orchestrator", systemImage: "square.stack.3d.up.fill")
                    .foregroundStyle(Color.orchestratorColor)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Open Orchestrator")

            Button {
                selection = .screenShare
                onSelectionChange(.screenShare)
            } label: {
                Label("Screen share", systemImage: "rectangle.on.rectangle")
                    .imageScale(.large)
                    .font(.title3)
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .accessibilityLabel("Open Screen share")

            Button {
                settingsSheetPresented = true
            } label: {
                Label("Settings", systemImage: "gearshape")
                    .imageScale(.large)
                    .font(.title3)
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .accessibilityLabel("Open Settings")
        }
        .padding(12)
    }

    @ViewBuilder
    private var settingsSheet: some View {
        SettingsSheet(
            settings: settings,
            onRestoreExample: { example in
                let id = store.restoreExample(example)
                // Refresh the example's AGENTS.md files so the
                // user-triggered restore writes any that are
                // missing (idempotent — user edits stick).
                example.seedAgentsMd(globalMemory: memory, appRootOverride: nil)
                selection = .myAppHome(id)
                onSelectionChange(.myAppHome(id))
                settingsSheetPresented = false
            },
            onStartTour: {
                // Dismiss the sheet, then restart the tour from the top.
                // Uses the live active myApp + pairing state so route
                // targets resolve and the chat copy adapts.
                settingsSheetPresented = false
                tour.start(
                    activeMyAppId: store.activeMyAppId,
                    isPaired: settings.isPaired(settings.activeBackend.id)
                )
            },
            onClose: {
                settingsSheetPresented = false
            },
            store: store,
            memory: memory,
            stats: stats,
            modelCatalog: modelCatalog,
            coordinator: coordinator,
            onImported: { id in
                selection = .myAppHome(id)
                onSelectionChange(.myAppHome(id))
                settingsSheetPresented = false
            }
        )
    }

    private var brandHeader: some View {
        HStack(spacing: 10) {
            if let icon = AppIcon.swiftUIImage {
                icon
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 28, height: 28)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            Text("Pupa")
                .font(.headline)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var myAppsSection: some View {
        Section {
            ForEach(store.myApps) { myApp in
                myAppRow(myApp)
            }
        } header: {
            HStack(spacing: 6) {
                Text("Your projects")
                InfoBadge(
                    title: "Your projects",
                    message: "Each myapp is a separate canvas with its own chat, thread, and tool surface. Open one to browse its components, memories, and history from its home page and bottom bar."
                )
                Spacer()
                Button {
                    newSheetPresented = true
                } label: {
                    Image(systemName: "plus")
                        .accessibilityLabel("New myapp")
                }
                .buttonStyle(.borderless)
            }
        }
    }

    /// Color index for a myApp based on its creation order — guarantees no
    /// two apps share a color within a palette-sized group.
    private func colorIndex(for myApp: MyApp) -> Int {
        let sorted = store.myApps.sorted { $0.createdAt < $1.createdAt }
        return sorted.firstIndex(where: { $0.id == myApp.id }) ?? 0
    }

    private func myAppRow(_ myApp: MyApp) -> some View {
        HStack(spacing: 8) {
            Label {
                Text(myApp.name).lineLimit(1)
            } icon: {
                Image(systemName: myApp.iconSystemName)
            }
            .foregroundStyle(Color.color(atIndex: colorIndex(for: myApp)))
            Spacer(minLength: 0)
            if busyMyApps.contains(myApp.id) {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Streaming")
            }
            Image(systemName: "chevron.right")
                .font(.footnote)
                .foregroundStyle(.tertiary)
        }
        .tag(SidebarSelection.myAppHome(myApp.id))
        .contextMenu {
            Button {
                renamingMyAppId = myApp.id
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            Button(role: .destructive) {
                onDeleteMyApp(myApp.id)
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .disabled(store.myApps.count <= 1)
        }
    }
}

private struct NewMyAppSheet: View {
    @Bindable var store: MyAppStore
    var onClose: () -> Void
    @State private var name: String = ""
    @State private var selectedKinds: Set<String> = ["tracker"]
    @FocusState private var nameFocused: Bool

    /// The MyAppType backing every new MyApp. Today only the tracker
    /// container is registered; if more types appear, this falls back
    /// to whatever the registry exposes first.
    private var appType: MyAppType {
        MyAppTypeRegistry.shared.allTypes.first ?? .tracker
    }

    /// Component kinds the user can seed, in a stable display order.
    /// Filtered against `appType.supportedComponentKinds` so a future
    /// type that drops a kind never offers it here.
    private var availableKinds: [String] {
        ["tracker", "calendar", "checklist", "slack", "calculator", "chart"]
            .filter { appType.supportedComponentKinds.contains($0) }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("e.g. Books, Wardrobe, Workouts", text: $name)
                        .focused($nameFocused)
                        .onSubmit(commit)
                }
                Section("Components") {
                    ForEach(availableKinds, id: \.self) { kind in
                        Toggle(isOn: binding(for: kind)) {
                            Label(displayLabel(for: kind), systemImage: icon(for: kind))
                        }
                    }
                }
            }
            .navigationTitle("New myapp")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onClose)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create", action: commit)
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            #if os(macOS)
            .frame(minWidth: 360, idealWidth: 420, minHeight: 320, idealHeight: 380)
            #endif
        }
        .onAppear { nameFocused = true }
    }

    private func binding(for kind: String) -> Binding<Bool> {
        Binding(
            get: { selectedKinds.contains(kind) },
            set: { isOn in
                if isOn { selectedKinds.insert(kind) } else { selectedKinds.remove(kind) }
            }
        )
    }

    private func displayLabel(for kind: String) -> String {
        kind.prefix(1).uppercased() + kind.dropFirst()
    }

    private func icon(for kind: String) -> String {
        switch kind {
        case "tracker": return "list.bullet.rectangle"
        case "calendar": return "calendar"
        case "checklist": return "checklist"
        case "slack": return "bubble.left.and.bubble.right"
        case "calculator": return "function"
        case "chart": return "chart.pie"
        default: return "square.dashed"
        }
    }

    private func commit() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let myAppId = store.addMyApp(
            typeId: appType.id,
            name: trimmed,
            iconSystemName: appType.iconSystemName
        )
        // Seed each ticked component. `addComponent` collapses the
        // `.empty` placeholder MyApp.init drops in, so the first call
        // replaces it and the rest append cleanly. Zero ticks leaves
        // the MyApp on its placeholder — the user can add via the +
        // button later.
        for kind in availableKinds where selectedKinds.contains(kind) {
            store.addComponent(
                kind: kind,
                name: displayLabel(for: kind),
                iconSystemName: icon(for: kind),
                myAppId: myAppId
            )
        }
        onClose()
    }
}

private struct RenameMyAppSheet: View {
    let initial: String
    var onCommit: (String) -> Void
    var onCancel: () -> Void
    @State private var draft: String = ""
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Myapp name", text: $draft)
                        .focused($focused)
                        .onSubmit { onCommit(draft) }
                }
            }
            .navigationTitle("Rename myapp")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { onCommit(draft) }
                        .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty || draft == initial)
                }
            }
            #if os(macOS)
            .frame(minWidth: 320, idealWidth: 380, minHeight: 160, idealHeight: 200)
            #endif
        }
        .onAppear {
            draft = initial
            focused = true
        }
    }
}
