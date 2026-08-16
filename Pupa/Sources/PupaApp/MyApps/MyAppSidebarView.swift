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
    var onArchiveMyApp: (UUID) -> Void

    @State private var newSheetPresented = false
    @State private var settingsSheetPresented = false
    /// Shared guided-tour store. The Settings tour step raises
    /// `wantSettingsOpen`; we mirror it onto `settingsSheetPresented` so the
    /// sheet opens (and closes) in lock-step with the tour.
    @State private var tour = GuidedTourStore.shared
    /// The myApp whose combined edit sheet (name + icon + color) is open.
    @State private var editingMyAppId: UUID?

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
        onDeleteMyApp: @escaping (UUID) -> Void,
        onArchiveMyApp: @escaping (UUID) -> Void
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
        self.onArchiveMyApp = onArchiveMyApp
    }

    public var body: some View {
        VStack(spacing: 0) {
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
        // Covers launch with the flag already true (the sidebar mounts once,
        // at app start), where `onChange` never fires. Reconcile on appear so
        // the sheet still opens.
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
            get: { editingMyAppId.flatMap { id in store.myApps.first(where: { $0.id == id }) } },
            set: { if $0 == nil { editingMyAppId = nil } }
        )) { myApp in
            EditMyAppSheet(
                initialName: myApp.name,
                initialIcon: myApp.iconSystemName,
                initialColorIndex: store.colorIndex(for: myApp.id)
            ) { newName, newIcon, newColorIndex in
                store.renameMyApp(myApp.id, to: newName)
                store.setIconSystemName(newIcon, for: myApp.id)
                store.setColorIndex(newColorIndex, for: myApp.id)
                editingMyAppId = nil
            } onCancel: {
                editingMyAppId = nil
            }
        }
        // Base app chrome reads neutral grey, not system blue. MyApp rows keep
        // their per-app icon color (set explicitly in `myAppRow`).
        .tint(.appBase)
    }

    /// Footer actions: the global Orchestrator, the screen-share viewer, and
    /// Settings. The Orchestrator moved here from a sidebar section — it's a
    /// global agent, not one of "your projects".
    private var bottomMenu: some View {
        HStack(spacing: 8) {
            Spacer()

            Button {
                selection = .orchestrator
                onSelectionChange(.orchestrator)
            } label: {
                Label("Orchestrator", systemImage: "square.stack.3d.up.fill")
                    .font(.system(size: 18))
                    .frame(height: 30)
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .accessibilityLabel("Open Orchestrator")
            .tourAnchor(.sidebarOrchestrator)

            Spacer()

            Button {
                selection = .screenShare
                onSelectionChange(.screenShare)
            } label: {
                Label("Screen share", systemImage: "rectangle.on.rectangle")
                    .font(.system(size: 18))
                    .frame(height: 30)
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .accessibilityLabel("Open Screen share")
            .tourAnchor(.sidebarScreenShare)

            Spacer()

            Button {
                settingsSheetPresented = true
            } label: {
                Label("Settings", systemImage: "gearshape")
                    .font(.system(size: 18))
                    .frame(height: 30)
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .accessibilityLabel("Open Settings")
            .tourAnchor(.sidebarSettings)

            Spacer()
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
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
                example.seedAgentsMd(
                    globalMemory: memory, appRoot: MemoryStore.appRoot(myAppId: id))
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

    private var myAppsSection: some View {
        Section {
            ForEach(store.visibleMyApps) { myApp in
                myAppRow(myApp)
            }
        } header: {
            HStack(spacing: 6) {
                Text("MyApps")
                InfoBadge(
                    title: "MyApps",
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

    /// Palette slot for a myApp's dot — the app's own stable stored slot, so
    /// deleting another app never slides this dot's color onto a neighbour.
    private func colorIndex(for myApp: MyApp) -> Int {
        store.colorIndex(for: myApp.id)
    }

    private func myAppRow(_ myApp: MyApp) -> some View {
        let tag = SidebarSelection.myAppHome(myApp.id)
        return HStack(spacing: 8) {
            Label {
                Text(myApp.name).lineLimit(1)
                    .foregroundStyle(.primary)
            } icon: {
                Image(systemName: myApp.iconSystemName)
                    .foregroundStyle(Color.color(atIndex: colorIndex(for: myApp)))
            }
            Spacer(minLength: 0)
            if busyMyApps.contains(myApp.id) {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Streaming")
            }
        }
        .tag(tag)
        // iOS `List(selection:)` only tap-selects rows in edit mode, so plain
        // taps landed on the binding unreliably — routing to the wrong (stale)
        // MyApp. Drive selection explicitly from a full-row tap; macOS keeps
        // using `List(selection:)` via the `.tag` above for its row highlight.
        #if os(iOS)
        .contentShape(Rectangle())
        .onTapGesture { selection = tag }
        #endif
        .contextMenu {
            Button {
                editingMyAppId = myApp.id
            } label: {
                Label("Edit", systemImage: "pencil")
            }
            Button {
                onArchiveMyApp(myApp.id)
            } label: {
                Label("Archive", systemImage: "archivebox")
            }
            .disabled(store.visibleMyApps.count <= 1)
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

/// Combined edit sheet for a myApp's identity: name, icon, and accent color,
/// all in one place. Opened from the sidebar row context menu ("Edit"). The
/// orchestrator can drive the same three mutators via tools, but this is the
/// user's direct, hold-down-and-edit path.
private struct EditMyAppSheet: View {
    let initialName: String
    let initialIcon: String
    let initialColorIndex: Int
    /// (name, iconSystemName, colorIndex)
    var onCommit: (String, String, Int) -> Void
    var onCancel: () -> Void

    @State private var name: String = ""
    @State private var icon: String = ""
    @State private var colorIndex: Int = 0
    @FocusState private var nameFocused: Bool

    /// Themed quick-pick palette so the common case needs no typing. Any
    /// valid SF Symbol name still works via the text field. All symbols
    /// here predate the app's min OS, so they render on every device that
    /// can run Pupa — including a phone importing a shared myApp.
    private let suggestions = [
        // Productivity
        "list.bullet.rectangle", "checklist", "calendar", "clock", "note.text",
        "folder", "tray", "doc.text", "paperclip", "pencil",
        // Work & money
        "briefcase", "chart.pie", "chart.bar", "chart.line.uptrend.xyaxis",
        "dollarsign.circle", "creditcard", "cart", "bag",
        // Health & fitness
        "heart", "dumbbell", "figure.walk", "cross.case", "bed.double", "flame", "drop",
        // Home & food
        "house", "fork.knife", "cup.and.saucer", "leaf", "pawprint", "gift",
        // Communication
        "bubble.left.and.bubble.right", "envelope", "phone", "bell", "person.2", "person.crop.circle",
        // Travel & places
        "airplane", "car", "map", "location", "globe", "bicycle",
        // Learning & media
        "book", "graduationcap", "music.note", "camera", "photo", "film",
        // Markers
        "star", "flag", "tag", "bookmark", "pin", "bolt", "sparkles", "target",
        // Tools
        "function", "hammer", "wrench.and.screwdriver", "gearshape",
    ]

    private let iconColumns = [GridItem(.adaptive(minimum: 44), spacing: 8)]
    private let colorColumns = [GridItem(.adaptive(minimum: 40), spacing: 10)]

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isDirty: Bool {
        trimmedName != initialName
            || icon.trimmingCharacters(in: .whitespacesAndNewlines) != initialIcon
            || colorIndex != initialColorIndex
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Myapp name", text: $name)
                        .focused($nameFocused)
                        .onSubmit(commit)
                }
                Section("Icon") {
                    HStack(spacing: 10) {
                        Image(systemName: icon.isEmpty ? "square.dashed" : icon)
                            .font(.system(size: 22))
                            .foregroundStyle(Color.color(atIndex: colorIndex))
                            .frame(width: 32, height: 32)
                        TextField("SF Symbol name", text: $icon)
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            #endif
                    }
                    LazyVGrid(columns: iconColumns, spacing: 8) {
                        ForEach(suggestions, id: \.self) { symbol in
                            Button { icon = symbol } label: {
                                Image(systemName: symbol)
                                    .font(.system(size: 18))
                                    .frame(width: 40, height: 40)
                                    .background {
                                        if icon == symbol {
                                            RoundedRectangle(cornerRadius: 8)
                                                .fill(Color.accentColor.opacity(0.2))
                                        }
                                    }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 2)
                }
                Section("Color") {
                    LazyVGrid(columns: colorColumns, spacing: 10) {
                        ForEach(Array(Color.myAppColorPalette.enumerated()), id: \.offset) { index, swatch in
                            Button { colorIndex = index } label: {
                                Circle()
                                    .fill(swatch)
                                    .frame(width: 30, height: 30)
                                    .overlay {
                                        Circle()
                                            .strokeBorder(Color.primary, lineWidth: colorIndex == index ? 2 : 0)
                                    }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Color \(index + 1)")
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
            .navigationTitle("Edit myapp")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: commit)
                        .disabled(!isDirty || trimmedName.isEmpty)
                }
            }
            #if os(macOS)
            .frame(minWidth: 340, idealWidth: 400, minHeight: 360, idealHeight: 440)
            #endif
        }
        .onAppear {
            name = initialName
            icon = initialIcon
            colorIndex = initialColorIndex
            nameFocused = true
        }
    }

    private func commit() {
        guard !trimmedName.isEmpty else { return }
        onCommit(trimmedName, icon.trimmingCharacters(in: .whitespacesAndNewlines), colorIndex)
    }
}
