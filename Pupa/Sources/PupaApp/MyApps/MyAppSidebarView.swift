import SwiftUI

public struct MyAppSidebarView: View {
    @Bindable var store: MyAppStore
    @Bindable var memory: MemoryStore
    @Bindable var settings: SettingsStore
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
    @State private var renameDraft: String = ""
    @State private var expanded: Set<String> = []
    /// Which MyApp rows are currently expanded in the sidebar. Seeded with
    /// the active myApp on first render so the user's current canvas is
    /// already revealed when the app opens. Tracks UUIDs so renames don't
    /// invalidate expansion state.
    @State private var expandedMyApps: Set<UUID> = []
    /// Tracks which myApp memory DisclosureGroups are open.
    @State private var expandedAppMemories: Set<UUID> = []
    /// Outer Orchestrator row expansion (mirrors per-MyApp expansion).
    @State private var orchestratorExpanded: Bool = false
    /// Inner "memories" accordion under the Orchestrator row (mirrors the
    /// per-MyApp memories accordion via `expandedAppMemories`).
    @State private var orchestratorMemoriesExpanded: Bool = false
    /// Drives the create/rename sheets for the Memories filesystem. One state
    /// var + a single `.sheet(item:)` lets the section header `+` menu and
    /// every row's context menu share the same dispatch.
    @State private var activeMemorySheet: MemorySheet?
    /// Pending delete confirmation for a memory file or folder.
    @State private var pendingMemoryDelete: PendingMemoryDelete?
    /// Drives the per-MyApp Change History sheet.
    @State private var activeChangeHistorySheet: ChangeHistorySheetDestination?

    public init(
        store: MyAppStore,
        memory: MemoryStore,
        settings: SettingsStore,
        selection: Binding<SidebarSelection?>,
        busyMyApps: Set<UUID>,
        onSelectionChange: @escaping (SidebarSelection) -> Void,
        onDeleteMyApp: @escaping (UUID) -> Void
    ) {
        self.store = store
        self.memory = memory
        self.settings = settings
        self._selection = selection
        self.busyMyApps = busyMyApps
        self.onSelectionChange = onSelectionChange
        self.onDeleteMyApp = onDeleteMyApp
    }

    public var body: some View {
        VStack(spacing: 0) {
            brandHeader
            Divider()
            // `selection` is optional so iOS compact `NavigationSplitView`
            // can clear it on Back — a non-optional binding (with the
            // common `if let new = $0 { … }` bridge) silently swallowed
            // SwiftUI's `nil` write, leaving the just-popped row stuck
            // "selected" and blocking re-tap until a different row was
            // touched.
            // MyApps scroll and fill the available space…
            List(selection: $selection) {
                myAppsSection
            }
            #if os(macOS)
            .listStyle(.sidebar)
            #endif
            .frame(maxHeight: .infinity)

            // …while the Orchestrator is pinned to the bottom in its own list
            // (a separate `List(selection:)` so its row + memory-file tags keep
            // driving the shared `selection`). Collapsed it sits as a single
            // slim footer row; expanding grows it to a height-capped scroll so
            // the memories disclosure scrolls inside it rather than shoving
            // MyApps off-screen.
            Divider()
            List(selection: $selection) {
                orchestratorSection
            }
            #if os(macOS)
            .listStyle(.sidebar)
            #else
            .listStyle(.plain)
            // Blend with the footer instead of reading as a raised white card
            // on the grouped MyApps background — a single hairline divider above
            // is the only separator, matching the Settings section delimiters.
            .scrollContentBackground(.hidden)
            #endif
            .scrollDisabled(!orchestratorExpanded)
            .frame(maxHeight: orchestratorExpanded ? 240 : 52)

            HStack(spacing: 8) {
                Button {
                    selection = .screenShare
                    onSelectionChange(.screenShare)
                } label: {
                    Label("Screen share", systemImage: "rectangle.on.rectangle")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.borderless)
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
        // Fires for selection changes from either list (shared binding).
        .onChange(of: selection) { _, new in
            if let new { onSelectionChange(new) }
        }
        // Guided tour drives the Settings sheet through its intent flag so the
        // step's coach card and the sheet stay in sync.
        .onChange(of: tour.wantSettingsOpen) { _, want in
            settingsSheetPresented = want
        }
        .sheet(isPresented: $newSheetPresented) {
            NewMyAppSheet(store: store) { newSheetPresented = false }
        }
        .sheet(isPresented: $settingsSheetPresented) {
            SettingsSheet(
                settings: settings,
                onRestoreExample: { example in
                    let id = store.restoreExample(example)
                    // Refresh the example's AGENTS.md files so the
                    // user-triggered restore writes any that are
                    // missing (idempotent — user edits stick).
                    example.seedAgentsMd(globalMemory: memory, appRootOverride: nil)
                    selection = .myApp(id)
                    onSelectionChange(.myApp(id))
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
                }
            ) {
                settingsSheetPresented = false
            }
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
        .sheet(item: $activeMemorySheet) { sheet in
            memorySheet(for: sheet)
        }
        .sheet(item: $activeChangeHistorySheet) { dest in
            switch dest {
            case .forMyApp(let id):
                ChangeHistorySheet(store: store, myAppId: id) {
                    activeChangeHistorySheet = nil
                }
            }
        }
        .alert(
            pendingMemoryDelete.map(Self.deleteAlertTitle) ?? "",
            isPresented: Binding(
                get: { pendingMemoryDelete != nil },
                set: { if !$0 { pendingMemoryDelete = nil } }
            ),
            presenting: pendingMemoryDelete
        ) { pending in
            Button("Delete", role: .destructive) {
                performMemoryDelete(pending)
            }
            Button("Cancel", role: .cancel) {}
        } message: { pending in
            Text(Self.deleteAlertMessage(pending))
        }
    }

    @ViewBuilder
    private func memorySheet(for sheet: MemorySheet) -> some View {
        switch sheet {
        case .newNote(let parent):
            NewMemoryNoteSheet(memory: memory, parent: parent) {
                activeMemorySheet = nil
            } onCreated: { fullPath in
                expandAncestors(of: fullPath)
                selection = .memoryFile(fullPath)
            }
        case .newFolder(let parent):
            NewMemoryFolderSheet(memory: memory, parent: parent) {
                activeMemorySheet = nil
            } onCreated: { fullPath in
                expandAncestors(of: fullPath)
                expanded.insert(fullPath)
            }
        case .rename(let path):
            RenameMemorySheet(memory: memory, path: path) {
                activeMemorySheet = nil
            } onMoved: { from, to in
                handleMemoryMove(from: from, to: to)
            }
        }
    }

    /// Insert every ancestor folder of `path` into the `expanded` set so a
    /// newly-created note or folder is visible in the sidebar without the
    /// user manually disclosing each level.
    private func expandAncestors(of path: String) {
        var parts = path.split(separator: "/").map(String.init)
        guard parts.count > 1 else { return }
        parts.removeLast()
        var acc = ""
        for part in parts {
            acc = acc.isEmpty ? part : "\(acc)/\(part)"
            expanded.insert(acc)
        }
    }

    /// Re-route the sidebar selection and the expansion set after a move so
    /// the user keeps tracking the same node under its new path.
    private func handleMemoryMove(from: String, to: String) {
        switch selection {
        case .some(.memoryFile(let p)) where p == from || p.hasPrefix(from + "/"):
            selection = .memoryFile(to + String(p.dropFirst(from.count)))
        case .some(.myAppMemoryFile(let id, let p)) where p == from || p.hasPrefix(from + "/"):
            selection = .myAppMemoryFile(id, to + String(p.dropFirst(from.count)))
        default: break
        }
        expanded = Set(expanded.map { node -> String in
            if node == from { return to }
            if node.hasPrefix(from + "/") {
                return to + String(node.dropFirst(from.count))
            }
            return node
        })
        expandAncestors(of: to)
    }

    private func performMemoryDelete(_ pending: PendingMemoryDelete) {
        let recursive = pending.isFolder && pending.childCount > 0
        do {
            try memory.delete(path: pending.path, recursive: recursive)
            let deletedPath = pending.path
            switch selection {
            case .some(.memoryFile(let p)) where p == deletedPath || p.hasPrefix(deletedPath + "/"):
                selection = .myApp(store.activeMyAppId)
            case .some(.myAppMemoryFile(let id, let p))
                    where p == deletedPath || p.hasPrefix(deletedPath + "/"):
                selection = .myApp(id)
            default: break
            }
        } catch {
            // Surface to the console; the alert is gone by this point and
            // wiring a second alert here for a rare failure is more noise
            // than signal. The sidebar will simply not refresh.
            print("Memory delete failed: \(error)")
        }
        pendingMemoryDelete = nil
    }

    private static func deleteAlertTitle(_ pending: PendingMemoryDelete) -> String {
        pending.isFolder ? "Delete folder “\(pending.path)”?" : "Delete “\(pending.path)”?"
    }

    private static func deleteAlertMessage(_ pending: PendingMemoryDelete) -> String {
        if pending.isFolder && pending.childCount > 0 {
            let noun = pending.childCount == 1 ? "item" : "items"
            return "This folder contains \(pending.childCount) \(noun). They will all be removed."
        }
        return "This action can’t be undone."
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

    private var orchestratorSection: some View {
        Section {
            // Flat rows (header + conditional children) instead of an outer
            // DisclosureGroup — `List(selection:)` only recognizes `.tag()`
            // on its direct row descendants, so a custom DisclosureGroupStyle
            // that wraps rows in a VStack silently breaks selection.
            HStack(spacing: 8) {
                Label {
                    Text("Orchestrator").lineLimit(1)
                } icon: {
                    Image(systemName: "square.stack.3d.up.fill")
                }
                .foregroundStyle(Color.orchestratorColor)
                InfoBadge(
                    title: "Orchestrator",
                    message: "A global agent with its own chat and shared memory that spans every myapp. Use it for cross-app tasks and notes that aren't tied to a single canvas. Expand the row to browse its memories."
                )
                Spacer(minLength: 0)
                chevronButton(
                    isOpen: orchestratorExpanded,
                    toggle: {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            orchestratorExpanded.toggle()
                        }
                    }
                )
            }
            .tag(SidebarSelection.orchestrator)

            if orchestratorExpanded {
                orchestratorMemoriesDisclosure
                    .padding(.leading, 16)
            }
        }
    }

    private var orchestratorMemoriesDisclosure: some View {
        let slug = MemoryStore.orchestratorFolder()
        return DisclosureGroup(
            isExpanded: $orchestratorMemoriesExpanded
        ) {
            appMemoryRows(rootSlug: slug)
        } label: {
            HStack {
                Label("memories", systemImage: "brain")
                    .foregroundStyle(.secondary)
                    .font(.subheadline)
                Spacer()
                Menu {
                    Button {
                        activeMemorySheet = .newNote(parent: slug + "/")
                    } label: { Label("New note…", systemImage: "doc.text") }
                    Button {
                        activeMemorySheet = .newFolder(parent: slug + "/")
                    } label: { Label("New folder…", systemImage: "folder.badge.plus") }
                } label: {
                    Image(systemName: "plus.circle")
                        .accessibilityLabel("Add memory")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .padding(.trailing, 4)
            }
            .contextMenu {
                Button {
                    activeMemorySheet = .newNote(parent: slug + "/")
                } label: { Label("New note…", systemImage: "doc.text") }
                Button {
                    activeMemorySheet = .newFolder(parent: slug + "/")
                } label: { Label("New folder…", systemImage: "folder.badge.plus") }
            }
        }
    }

    private var screenShareSection: some View {
        Section {
            Label {
                Text("Screen share").lineLimit(1)
            } icon: {
                Image(systemName: "rectangle.on.rectangle")
            }
            .tag(SidebarSelection.screenShare)
        }
    }

    private var myAppsSection: some View {
        Section {
            ForEach(store.myApps) { myApp in
                myAppDisclosure(for: myApp)
            }
        } header: {
            HStack(spacing: 6) {
                Text("MyApps")
                InfoBadge(
                    title: "MyApps",
                    message: "Each myapp is a separate canvas with its own chat, thread, and tool surface. A myApp can host multiple components (a tracker plus a calendar, say) — expand the row to switch between them."
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
        // MyApp rows start collapsed and only expand when the user taps the
        // chevron. (Previously we auto-expanded the active myApp on appear,
        // which also re-opened it every time the menu was reopened — e.g. on
        // returning from a pushed section.)
    }

    @ViewBuilder
    private func myAppDisclosure(for myApp: MyApp) -> some View {
        // Flat rows (header + conditional children) so List can recognise
        // each `.tag()` as a selectable row. The header row navigates to
        // the myApp landing page; the trailing chevron button only toggles
        // sidebar expansion (it is `selectionDisabled`).
        myAppRow(myApp)

        if expandedMyApps.contains(myApp.id) {
            myAppMemoriesDisclosure(for: myApp)
                .padding(.leading, 16)
            Button {
                activeChangeHistorySheet = .forMyApp(myAppId: myApp.id)
            } label: {
                Label("history", systemImage: "clock")
                    .foregroundStyle(.secondary)
                    .font(.subheadline)
            }
            .buttonStyle(.plain)
            .padding(.leading, 16)
            ForEach(myApp.components) { component in
                componentRow(myApp: myApp, component: component)
                    .padding(.leading, 16)
            }
        }
    }

    private func myAppMemoriesDisclosure(for myApp: MyApp) -> some View {
        let slug = MemoryStore.myAppFolder(myAppName: myApp.name)
        return DisclosureGroup(
            isExpanded: Binding(
                get: { expandedAppMemories.contains(myApp.id) },
                set: { isOpen in
                    if isOpen { expandedAppMemories.insert(myApp.id) }
                    else { expandedAppMemories.remove(myApp.id) }
                }
            )
        ) {
            appMemoryRows(rootSlug: slug, myAppId: myApp.id)
        } label: {
            HStack {
                Label("memories", systemImage: "brain")
                    .foregroundStyle(.secondary)
                    .font(.subheadline)
                Spacer()
                Menu {
                    Button {
                        activeMemorySheet = .newNote(parent: slug + "/")
                    } label: { Label("New note…", systemImage: "doc.text") }
                    Button {
                        activeMemorySheet = .newFolder(parent: slug + "/")
                    } label: { Label("New folder…", systemImage: "folder.badge.plus") }
                } label: {
                    Image(systemName: "plus.circle")
                        .accessibilityLabel("Add memory")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .padding(.trailing, 4)
            }
            .contextMenu {
                Button {
                    activeMemorySheet = .newNote(parent: slug + "/")
                } label: { Label("New note…", systemImage: "doc.text") }
                Button {
                    activeMemorySheet = .newFolder(parent: slug + "/")
                } label: { Label("New folder…", systemImage: "folder.badge.plus") }
            }
        }
    }

    /// Tappable chevron button that only toggles sidebar expansion — never
    /// changes List selection (so the row's main tap target stays free for
    /// navigation to the landing page). `.selectionDisabled()` stops the
    /// List from interpreting a tap here as a row selection.
    private func chevronButton(isOpen: Bool, toggle: @escaping () -> Void) -> some View {
        Button(action: toggle) {
            Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .selectionDisabled()
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
            chevronButton(
                isOpen: expandedMyApps.contains(myApp.id),
                toggle: {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        if expandedMyApps.contains(myApp.id) {
                            expandedMyApps.remove(myApp.id)
                        } else {
                            expandedMyApps.insert(myApp.id)
                        }
                    }
                }
            )
        }
        .tag(SidebarSelection.myAppHome(myApp.id))
        .contextMenu {
            Button {
                renameDraft = myApp.name
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

    private func componentRow(myApp: MyApp, component: Component) -> some View {
        Label {
            Text(component.name).lineLimit(1)
        } icon: {
            Image(systemName: component.iconSystemName)
        }
        .tag(SidebarSelection.myAppComponent(myApp.id, component.id))
    }

    /// Renders the memory subtree rooted at `rootSlug` (a top-level folder
    /// in the global `memory` store). Shows an empty hint when the folder
    /// doesn't exist yet or is empty.
    @ViewBuilder
    private func appMemoryRows(rootSlug: String, myAppId: UUID? = nil) -> some View {
        let subtreeChildren = memory.tree.children?
            .first(where: { $0.name == rootSlug })?
            .children ?? []
        if subtreeChildren.isEmpty {
            Text("No notes yet")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.leading, 12)
        } else {
            ForEach(subtreeChildren) { node in
                MemoryRowView(
                    node: node,
                    depth: 0,
                    expanded: $expanded,
                    selection: $selection,
                    activeSheet: $activeMemorySheet,
                    pendingDelete: $pendingMemoryDelete,
                    memory: memory,
                    myAppId: myAppId
                )
            }
        }
    }
}

/// Pending memory delete request driving the confirmation alert. `childCount`
/// is the total number of nested files + folders so the alert can be specific
/// about the blast radius of a recursive delete.
struct PendingMemoryDelete: Identifiable {
    let path: String
    let isFolder: Bool
    let childCount: Int
    var id: String { path }
}

/// Recursive sidebar row for the memories filesystem. Extracted to its own
/// `View` struct so SwiftUI's opaque-type inference doesn't trip on the
/// self-recursion (a `@ViewBuilder func` calling itself fails to infer).
private struct MemoryRowView: View {
    let node: MemoryNode
    let depth: Int
    @Binding var expanded: Set<String>
    @Binding var selection: SidebarSelection?
    @Binding var activeSheet: MemorySheet?
    @Binding var pendingDelete: PendingMemoryDelete?
    let memory: MemoryStore
    /// When set, file rows use `.myAppMemoryFile` so clicks stay in the
    /// myApp's chat context instead of switching to the orchestrator.
    var myAppId: UUID? = nil

    var body: some View {
        if node.isFolder {
            folderRow
        } else {
            fileRow
        }
    }

    @ViewBuilder
    private var folderRow: some View {
        let isOpen = expanded.contains(node.path)
        HStack(spacing: 0) {
            Button {
                if isOpen { expanded.remove(node.path) } else { expanded.insert(node.path) }
            } label: {
                HStack {
                    Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Image(systemName: "folder")
                    Text(node.name).lineLimit(1)
                    Spacer()
                }
                .padding(.leading, CGFloat(depth) * 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // Force the Button to claim the row's full width so the trailing
            // Menu lands at the right edge (matching the section header `+`).
            // Without this, Button sizes to its label's intrinsic content and
            // the inner `Spacer()` only expands within that intrinsic size.
            .frame(maxWidth: .infinity, alignment: .leading)
            // Always-visible `+` menu so users can reach the add / rename /
            // delete actions without knowing the right-click context-menu
            // shortcut. The same `folderActionsMenu` items are also attached
            // via `.contextMenu` below — both paths work. No explicit tint:
            // `.foregroundStyle(.secondary)` resolves near-black against the
            // dark sidebar — defer to the system accent like the header `+`.
            Menu {
                folderActionsMenu
            } label: {
                Image(systemName: "plus.circle")
                    .accessibilityLabel("Add to \(node.name)")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .padding(.trailing, 6)
        }
        .contextMenu {
            folderActionsMenu
        }
        // Folders are not selectable — prevent macOS List from inheriting the
        // nearest tagged ancestor's selection when a folder row is clicked.
        .selectionDisabled()
        if isOpen, let children = node.children {
            ForEach(children) { child in
                MemoryRowView(
                    node: child,
                    depth: depth + 1,
                    expanded: $expanded,
                    selection: $selection,
                    activeSheet: $activeSheet,
                    pendingDelete: $pendingDelete,
                    memory: memory,
                    myAppId: myAppId
                )
            }
        }
    }

    private var fileRow: some View {
        Label {
            Text(node.name).lineLimit(1)
        } icon: {
            Image(systemName: "doc.text")
        }
        .padding(.leading, CGFloat(depth) * 12 + 16)
        .tag(myAppId.map { SidebarSelection.myAppMemoryFile($0, node.path) }
             ?? SidebarSelection.memoryFile(node.path))
        .contextMenu {
            Button {
                activeSheet = .rename(path: node.path)
            } label: {
                Label("Rename or move…", systemImage: "pencil")
            }
            Divider()
            Button(role: .destructive) {
                requestDelete()
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    /// Shared menu items for folder rows. Reused by the inline `+` Menu and
    /// the right-click `.contextMenu`.
    @ViewBuilder
    private var folderActionsMenu: some View {
        Button {
            activeSheet = .newNote(parent: node.path)
        } label: {
            Label("New note inside…", systemImage: "doc.text")
        }
        Button {
            activeSheet = .newFolder(parent: node.path)
        } label: {
            Label("New subfolder…", systemImage: "folder.badge.plus")
        }
        Divider()
        Button {
            activeSheet = .rename(path: node.path)
        } label: {
            Label("Rename or move…", systemImage: "pencil")
        }
        Divider()
        Button(role: .destructive) {
            requestDelete()
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    private func requestDelete() {
        pendingDelete = PendingMemoryDelete(
            path: node.path,
            isFolder: node.isFolder,
            childCount: descendantCount(of: node)
        )
    }

    /// Total count of every descendant node (files + folders) under `n`, used
    /// to surface the blast radius of a recursive delete in the confirmation
    /// alert. The root `n` itself is not counted.
    private func descendantCount(of n: MemoryNode) -> Int {
        guard let kids = n.children else { return 0 }
        return kids.reduce(0) { acc, kid in acc + 1 + descendantCount(of: kid) }
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
