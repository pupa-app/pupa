import SwiftUI

public struct MiniAppSidebarView: View, Equatable {
    @Bindable var store: MiniAppStore
    @Binding var selection: SidebarSelection?
    let busyMiniApps: Set<UUID>
    var onSelectionChange: (SidebarSelection) -> Void
    var onDeleteMiniApp: (UUID) -> Void
    var onArchiveMiniApp: (UUID) -> Void
    /// Dismiss, when presented as a sheet. `nil` on macOS, where this is a
    /// permanent column with nothing to dismiss.
    var onClose: (() -> Void)?

    @State private var newSheetPresented = false
    /// The miniApp whose combined edit sheet (name + icon + color) is open.
    @State private var editingMiniAppId: UUID?
    /// Collapsed sidebar folders, comma-joined ids. Per-device chrome, so it
    /// stays out of the mirrored `index.json` — collapsing on the Mac must not
    /// collapse on the iPad. Absent id = expanded, so a new folder opens.
    @AppStorage("sidebar.collapsedMiniAppFolders") private var collapsedFolderIds = ""
    /// The miniApp a pending "New Folder…" will hold, and the name being typed.
    @State private var newFolderSeedApp: UUID?
    /// The folder being renamed.
    @State private var renamingFolderId: String?
    @State private var folderNameDraft = ""

    public init(
        store: MiniAppStore,
        selection: Binding<SidebarSelection?>,
        busyMiniApps: Set<UUID>,
        onSelectionChange: @escaping (SidebarSelection) -> Void,
        onDeleteMiniApp: @escaping (UUID) -> Void,
        onArchiveMiniApp: @escaping (UUID) -> Void,
        onClose: (() -> Void)? = nil
    ) {
        self.store = store
        self._selection = selection
        self.busyMiniApps = busyMiniApps
        self.onSelectionChange = onSelectionChange
        self.onDeleteMiniApp = onDeleteMiniApp
        self.onArchiveMiniApp = onArchiveMiniApp
        self.onClose = onClose
    }

    /// Value inputs and store identity only — the closures are stable action
    /// handlers and can't be compared. The stores are `@Observable`, so a real
    /// data change still invalidates this view from within; what this skips is
    /// the *other* three `AppView` body passes a single drawer tap causes
    /// (write `selection`, `setRoot`, close the drawer, clear `selection`),
    /// each of which rebuilt the whole `List`.
    nonisolated public static func == (a: MiniAppSidebarView, b: MiniAppSidebarView) -> Bool {
        // SwiftUI evaluates view equality on the main actor, but `Equatable`
        // is `nonisolated`, and `@Binding`/`@Bindable` accessors are
        // main-actor-isolated — so reading them here needs the invariant
        // stated rather than eight isolation warnings.
        MainActor.assumeIsolated {
            a.selection == b.selection
                && a.busyMiniApps == b.busyMiniApps
                && a.store === b.store
        }
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Compact, non-expanding MiniApp rows. Tapping a row lands on its
            // home; components, memories, and history are reached from the
            // MiniApp home + its bottom bar (not the sidebar). `selection` is
            // optional so iOS compact can clear it on Back — a non-optional
            // binding silently swallowed SwiftUI's `nil` write.
            #if os(macOS)
            List(selection: $selection) {
                miniAppsSection
            }
            .listStyle(.sidebar)
            .frame(maxHeight: .infinity)
            #else
            List(selection: $selection) {
                miniAppsSection
            }
            .frame(maxHeight: .infinity)
            #endif
        }
        .onAppear {
            let defaults = UserDefaults.standard
            if defaults.object(forKey: "sidebar.collapsedMiniAppFolders") == nil,
               let old = defaults.string(forKey: "sidebar.collapsedMyAppFolders") {
                collapsedFolderIds = old
            }
        }
        // Fires for selection changes from the list (shared binding).
        .onChange(of: selection) { _, new in
            if let new { onSelectionChange(new) }
        }
        .sheet(isPresented: $newSheetPresented) {
            NewMiniAppSheet(store: store) { newSheetPresented = false }
        }
        .alert("New Folder", isPresented: Binding(
            get: { newFolderSeedApp != nil },
            set: { if !$0 { newFolderSeedApp = nil } }
        )) {
            TextField("Name", text: $folderNameDraft)
            Button("Cancel", role: .cancel) { newFolderSeedApp = nil }
            Button("Create") {
                if let seed = newFolderSeedApp {
                    store.createMiniAppFolder(name: folderNameDraft, containing: seed)
                }
                newFolderSeedApp = nil
            }
        }
        .alert("Rename Folder", isPresented: Binding(
            get: { renamingFolderId != nil },
            set: { if !$0 { renamingFolderId = nil } }
        )) {
            TextField("Name", text: $folderNameDraft)
            Button("Cancel", role: .cancel) { renamingFolderId = nil }
            Button("Rename") {
                if let fid = renamingFolderId {
                    store.renameMiniAppFolder(folderId: fid, name: folderNameDraft)
                }
                renamingFolderId = nil
            }
        }
        .sheet(item: Binding(
            get: { editingMiniAppId.flatMap { id in store.miniApps.first(where: { $0.id == id }) } },
            set: { if $0 == nil { editingMiniAppId = nil } }
        )) { miniApp in
            EditMiniAppSheet(
                initialName: miniApp.name,
                initialIcon: miniApp.iconSystemName,
                initialColorIndex: store.colorIndex(for: miniApp.id)
            ) { newName, newIcon, newColorIndex in
                store.renameMiniApp(miniApp.id, to: newName)
                store.setIconSystemName(newIcon, for: miniApp.id)
                store.setColorIndex(newColorIndex, for: miniApp.id)
                editingMiniAppId = nil
            } onCancel: {
                editingMiniAppId = nil
            }
        }
        // Base app chrome reads neutral grey, not system blue. MiniApp rows keep
        // their per-app icon color (set explicitly in `miniAppRow`).
        .tint(.appBase)
    }

    /// One rendered sidebar row: a loose MiniApp, or a folder with its visible
    /// members. Folders sit at the position of their first visible member, so
    /// grouping never reshuffles the roster order the user already knows.
    private enum SidebarEntry: Identifiable {
        case miniApp(MiniApp)
        case folder(MiniAppFolder, [MiniApp])

        var id: String {
            switch self {
            case .miniApp(let a): return "app-\(a.id.uuidString)"
            case .folder(let f, _): return "folder-\(f.id)"
            }
        }
    }

    /// Group `visibleMiniApps` by the folder layout. A folder whose members are
    /// all archived emits nothing — the layout keeps the assignments, so
    /// unarchiving brings the folder back with its apps.
    private var sidebarEntries: [SidebarEntry] {
        let layout = store.miniAppFolders
        var emitted = Set<String>()
        var out: [SidebarEntry] = []
        for miniApp in store.visibleMiniApps {
            guard let fid = layout.folderId(forMiniApp: miniApp.id),
                  let folder = layout.folder(id: fid) else {
                out.append(.miniApp(miniApp))
                continue
            }
            guard emitted.insert(fid).inserted else { continue }
            let members = store.visibleMiniApps.filter { layout.folderId(forMiniApp: $0.id) == fid }
            out.append(.folder(folder, members))
        }
        return out
    }

    private var collapsedFolders: Set<String> {
        Set(collapsedFolderIds.split(separator: ",").map(String.init))
    }

    private func setFolder(_ folderId: String, expanded: Bool) {
        var ids = collapsedFolders
        if expanded { ids.remove(folderId) } else { ids.insert(folderId) }
        collapsedFolderIds = ids.sorted().joined(separator: ",")
    }

    private var miniAppsSection: some View {
        Section {
            ForEach(sidebarEntries) { entry in
                switch entry {
                case .miniApp(let miniApp):
                    miniAppRow(miniApp)
                case .folder(let folder, let members):
                    folderRow(folder, members)
                }
            }
        } header: {
            HStack(spacing: 6) {
                Text("MiniApps")
                InfoBadge(
                    title: "MiniApps",
                    message: "Each miniapp is a separate canvas with its own chat, thread, and tool surface. Open one to browse its components, memories, and history from its home page and bottom bar."
                )
                Spacer()
                Button {
                    newSheetPresented = true
                } label: {
                    Image(systemName: "plus")
                        .accessibilityLabel("New miniapp")
                }
                .buttonStyle(.borderless)
                if let onClose {
                    Button(action: onClose) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Close")
                    }
                    .buttonStyle(.borderless)
                    .keyboardShortcut(.cancelAction)
                }
            }
            // As a sheet this header is the first thing under the grab
            // indicator, with no navigation bar between them, and the first
            // row lands right below it — so the title and its two buttons sit
            // pinched between the sheet edge and the list. The macOS sidebar
            // is a permanent column with its own inset and needs none of this.
            .padding(.top, onClose == nil ? 0 : 8)
            .padding(.bottom, onClose == nil ? 0 : 4)
        }
    }

    /// Palette slot for a miniApp's dot — the app's own stable stored slot, so
    /// deleting another app never slides this dot's color onto a neighbour.
    private func colorIndex(for miniApp: MiniApp) -> Int {
        store.colorIndex(for: miniApp.id)
    }

    private func folderRow(_ folder: MiniAppFolder, _ members: [MiniApp]) -> some View {
        DisclosureGroup(
            isExpanded: Binding(
                get: { !collapsedFolders.contains(folder.id) },
                set: { setFolder(folder.id, expanded: $0) }
            )
        ) {
            ForEach(members) { miniAppRow($0) }
        } label: {
            Label {
                Text(folder.name).lineLimit(1)
            } icon: {
                Image(systemName: "folder")
                    .foregroundStyle(.secondary)
            }
            .contextMenu {
                Button {
                    folderNameDraft = folder.name
                    renamingFolderId = folder.id
                } label: {
                    Label("Rename Folder", systemImage: "pencil")
                }
                Button {
                    store.removeMiniAppFolder(folderId: folder.id)
                } label: {
                    Label("Ungroup", systemImage: "folder.badge.minus")
                }
            }
        }
    }

    /// Folder moves for one row. Folders are only ever created holding an app,
    /// so there is no bare "new empty folder" action.
    @ViewBuilder
    private func moveToFolderMenu(_ miniApp: MiniApp) -> some View {
        let current = store.miniAppFolders.folderId(forMiniApp: miniApp.id)
        Menu {
            ForEach(store.miniAppFolders.folders) { folder in
                Button {
                    store.setMiniAppFolder(miniAppId: miniApp.id, folderId: folder.id)
                } label: {
                    Label(folder.name, systemImage: folder.id == current ? "checkmark" : "folder")
                }
                .disabled(folder.id == current)
            }
            Button {
                folderNameDraft = ""
                newFolderSeedApp = miniApp.id
            } label: {
                Label("New Folder…", systemImage: "folder.badge.plus")
            }
            if current != nil {
                Divider()
                Button {
                    store.setMiniAppFolder(miniAppId: miniApp.id, folderId: nil)
                } label: {
                    Label("Remove from Folder", systemImage: "folder.badge.minus")
                }
            }
        } label: {
            Label("Move to Folder", systemImage: "folder")
        }
    }

    private func miniAppRow(_ miniApp: MiniApp) -> some View {
        let tag = SidebarSelection.miniAppHome(miniApp.id)
        return HStack(spacing: 8) {
            Label {
                Text(miniApp.name).lineLimit(1)
                    .foregroundStyle(.primary)
            } icon: {
                Image(systemName: miniApp.iconSystemName)
                    .foregroundStyle(Color.color(atIndex: colorIndex(for: miniApp)))
            }
            Spacer(minLength: 0)
            if busyMiniApps.contains(miniApp.id) {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Streaming")
            }
        }
        .tag(tag)
        // One element, not three: without this the identifier propagates to
        // the row's icon and label separately, and a query resolves to the
        // 28pt icon rather than the row.
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(PupaID.sidebarMiniApp(miniApp.id))
        // iOS `List(selection:)` only tap-selects rows in edit mode, so plain
        // taps landed on the binding unreliably — routing to the wrong (stale)
        // MiniApp. Drive it explicitly from a full-row tap; macOS keeps using
        // `List(selection:)` via the `.tag` above for its row highlight.
        #if os(iOS)
        .contentShape(Rectangle())
        .onTapGesture {
            // Call through directly rather than relying on `selection` to
            // *change*: it already equals `tag` for the active app, so the
            // `onChange` observers never fire and the tap does nothing.
            selection = tag
            onSelectionChange(tag)
        }
        #endif
        .contextMenu {
            Button {
                editingMiniAppId = miniApp.id
            } label: {
                Label("Edit", systemImage: "pencil")
            }
            moveToFolderMenu(miniApp)
            Button {
                onArchiveMiniApp(miniApp.id)
            } label: {
                Label("Archive", systemImage: "archivebox")
            }
            .disabled(store.visibleMiniApps.count <= 1)
            Button(role: .destructive) {
                onDeleteMiniApp(miniApp.id)
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .disabled(store.miniApps.count <= 1)
        }
    }
}

private struct NewMiniAppSheet: View {
    @Bindable var store: MiniAppStore
    var onClose: () -> Void
    @State private var name: String = ""
    @State private var selectedKinds: Set<String> = ["tracker"]
    @FocusState private var nameFocused: Bool

    /// The MiniAppType backing every new MiniApp. Today only the tracker
    /// container is registered; if more types appear, this falls back
    /// to whatever the registry exposes first.
    private var appType: MiniAppType {
        MiniAppTypeRegistry.shared.allTypes.first ?? .tracker
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
            .navigationTitle("New miniapp")
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
        let miniAppId = store.addMiniApp(
            typeId: appType.id,
            name: trimmed,
            iconSystemName: appType.iconSystemName
        )
        // Seed each ticked component. `addComponent` collapses the
        // `.empty` placeholder MiniApp.init drops in, so the first call
        // replaces it and the rest append cleanly. Zero ticks leaves
        // the MiniApp on its placeholder — the user can add via the +
        // button later.
        for kind in availableKinds where selectedKinds.contains(kind) {
            store.addComponent(
                kind: kind,
                name: displayLabel(for: kind),
                iconSystemName: icon(for: kind),
                miniAppId: miniAppId
            )
        }
        onClose()
    }
}

/// Combined edit sheet for a miniApp's identity: name, icon, and accent color,
/// all in one place. Opened from the sidebar row context menu ("Edit"). The
/// orchestrator can drive the same three mutators via tools, but this is the
/// user's direct, hold-down-and-edit path.
private struct EditMiniAppSheet: View {
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
    /// can run Pupa — including a phone importing a shared miniApp.
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
                        ForEach(Array(Color.miniAppColorPalette.enumerated()), id: \.offset) { index, swatch in
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
            .navigationTitle("Edit miniapp")
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
