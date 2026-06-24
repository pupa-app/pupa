import SwiftUI

/// Detail-pane landing page shown when a sidebar myApp row is tapped. A
/// minimal overview that leads with structure — an **Outline** (the
/// agent-written component summaries), the **Components** grid, and the
/// **Agents** preview. Memories and History live on the per-MyApp bottom bar,
/// not here.
public struct MyAppHomeView: View {
    let store: MyAppStore
    let memory: MemoryStore
    let settings: SettingsStore
    let modelCatalog: ModelCatalogStore
    /// What this home renders: a real MyApp, or the special **Orchestrator**
    /// (no store entry, no components — its Outline explains what it is and
    /// the myapps it can drive).
    public enum Subject: Equatable {
        case myApp(UUID)
        case orchestrator
    }
    let subject: Subject
    /// Called when the user taps a component tile or an agent row to navigate
    /// deeper. AppView handles the actual selection update.
    var onNavigate: (SidebarSelection) -> Void

    public init(
        store: MyAppStore,
        memory: MemoryStore,
        settings: SettingsStore,
        modelCatalog: ModelCatalogStore,
        subject: Subject,
        onNavigate: @escaping (SidebarSelection) -> Void
    ) {
        self.store = store
        self.memory = memory
        self.settings = settings
        self.modelCatalog = modelCatalog
        self.subject = subject
        self.onNavigate = onNavigate
        // The Orchestrator's Outline is the point of its page, so lead with it
        // expanded; a real MyApp keeps it collapsed behind the components.
        _outlineExpanded = State(initialValue: subject == .orchestrator)
    }

    /// Outline leads the page but collapses so a verbose agent-written summary
    /// doesn't push the components/agents off-screen.
    @State private var outlineExpanded: Bool = false
    /// Components are the core of a myApp, so the grid is expanded by default.
    @State private var componentsExpanded: Bool = true
    /// The component whose name + icon the user is editing, or `nil`.
    @State private var editingComponent: EditingComponentRef?
    /// The component pending delete confirmation, or `nil`.
    @State private var deletingComponent: EditingComponentRef?

    private let componentColumns = [GridItem(.adaptive(minimum: 92), spacing: 12)]

    private var myAppId: UUID? {
        if case .myApp(let id) = subject { return id }
        return nil
    }

    private var myApp: MyApp? {
        guard let id = myAppId else { return nil }
        return store.myApps.first(where: { $0.id == id })
    }

    private var appColor: Color {
        guard let id = myAppId else { return .orchestratorColor }
        return Color.color(atIndex: store.colorIndex(for: id))
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                switch subject {
                case .myApp:
                    if let app = myApp {
                        header(name: app.name, icon: app.iconSystemName)
                        Divider()
                        outlinePanel(app)
                        componentsPanel(app)
                        agentsPanel(app)
                    } else {
                        Text("App not found.")
                            .foregroundStyle(.secondary)
                    }
                case .orchestrator:
                    header(name: "Orchestrator", icon: "square.stack.3d.up.fill")
                    Divider()
                    orchestratorOutlinePanel()
                    orchestratorComponentsPanel()
                    orchestratorAgentsPanel()
                }
            }
            .padding(24)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .background(Color.canvasBackground)
        .sheet(item: $editingComponent) { ref in
            if let component = store.myApps
                .first(where: { $0.id == ref.myAppId })?
                .components.first(where: { $0.id == ref.componentId }) {
                EditComponentSheet(initial: component) { newName, newIcon in
                    store.updateComponentMeta(
                        componentId: ref.componentId,
                        name: newName,
                        iconSystemName: newIcon,
                        myAppId: ref.myAppId
                    )
                    editingComponent = nil
                } onCancel: {
                    editingComponent = nil
                }
            }
        }
        .alert(
            "Delete component?",
            isPresented: Binding(
                get: { deletingComponent != nil },
                set: { if !$0 { deletingComponent = nil } }
            ),
            presenting: deletingComponent
        ) { ref in
            Button("Delete", role: .destructive) {
                store.removeComponent(componentId: ref.componentId, myAppId: ref.myAppId)
                deletingComponent = nil
            }
            Button("Cancel", role: .cancel) { deletingComponent = nil }
        } message: { ref in
            if let name = store.myApps
                .first(where: { $0.id == ref.myAppId })?
                .components.first(where: { $0.id == ref.componentId })?.name {
                Text("\"\(name)\" and its contents will be removed. This can't be undone.")
            }
        }
    }

    private func header(name: String, icon: String) -> some View {
        MyAppPageHeader(page: "Home", name: name, icon: icon, color: appColor)
    }

    /// Renamed from "Summary": the agent-written per-component summaries, the
    /// at-a-glance description of what the app holds.
    private func outlinePanel(_ app: MyApp) -> some View {
        let summarized = app.components.filter { $0.summary != nil }
        return DisclosureGroup(isExpanded: $outlineExpanded) {
            if summarized.isEmpty {
                Text("No summary yet — chat with this app to populate it.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.top, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(summarized) { component in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: component.iconSystemName)
                                .frame(width: 18)
                                .foregroundStyle(.secondary)
                                .padding(.top, 2)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(component.name)
                                    .font(.callout)
                                    .fontWeight(.medium)
                                Text(component.summary ?? "")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .padding(.top, 8)
            }
        } label: {
            Text("Outline")
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundStyle(.primary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.secondary.opacity(0.06))
        )
    }

    /// Collapsible grid of component tiles + an "Add" menu. Tapping a tile
    /// opens that component's canvas; "Add" picks a kind and creates one.
    private func componentsPanel(_ app: MyApp) -> some View {
        DisclosureGroup(isExpanded: $componentsExpanded) {
            LazyVGrid(columns: componentColumns, spacing: 12) {
                ForEach(app.components) { component in
                    componentTile(app: app, component: component)
                }
                addComponentMenu(app)
            }
            .padding(.top, 12)
        } label: {
            HStack(alignment: .firstTextBaseline) {
                Text("Components")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(.primary)
                Spacer()
                Text("\(app.components.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.secondary.opacity(0.06))
        )
    }

    private func componentTile(app: MyApp, component: Component) -> some View {
        Button {
            onNavigate(.myAppComponent(app.id, component.id))
        } label: {
            VStack(spacing: 6) {
                Image(systemName: component.iconSystemName)
                    .font(.system(size: 22))
                    .foregroundStyle(appColor)
                    .frame(width: 48, height: 48)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(appColor.opacity(0.12))
                    )
                Text(component.name)
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                editingComponent = EditingComponentRef(myAppId: app.id, componentId: component.id)
            } label: {
                Label("Rename / icon…", systemImage: "pencil")
            }
            // Last component can't be deleted (store guards count > 1).
            if app.components.count > 1 {
                Button(role: .destructive) {
                    deletingComponent = EditingComponentRef(myAppId: app.id, componentId: component.id)
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
    }

    /// "+" tile → a menu of the app type's component kinds. Picking one creates
    /// the component (`MyAppStore.addComponent`) and opens it; name/icon can be
    /// tweaked afterward from the tile's context menu.
    private func addComponentMenu(_ app: MyApp) -> some View {
        Menu {
            ForEach(availableKinds, id: \.self) { kind in
                Button {
                    if let newId = store.addComponent(
                        kind: kind,
                        name: displayLabel(for: kind),
                        iconSystemName: icon(for: kind),
                        myAppId: app.id
                    ) {
                        onNavigate(.myAppComponent(app.id, newId))
                    }
                } label: {
                    Label(displayLabel(for: kind), systemImage: icon(for: kind))
                }
            }
        } label: {
            VStack(spacing: 6) {
                Image(systemName: "plus")
                    .font(.system(size: 22))
                    .foregroundStyle(.secondary)
                    .frame(width: 48, height: 48)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(
                                Color.secondary.opacity(0.3),
                                style: StrokeStyle(lineWidth: 1, dash: [4])
                            )
                    )
                Text("Add")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .accessibilityLabel("Add component")
    }

    /// Component kinds the user can add, in stable display order, filtered to
    /// what the app type supports. Mirrors `NewMyAppSheet`.
    private var availableKinds: [String] {
        let appType = MyAppTypeRegistry.shared.allTypes.first ?? .tracker
        return ["tracker", "calendar", "checklist", "slack", "calculator", "chart"]
            .filter { appType.supportedComponentKinds.contains($0) }
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

    /// Compact agent preview — up to three rows, then a "View all" footer
    /// row. Both routes push `.myAppAgents(app.id)` so the dedicated page
    /// owns the full list. Built via `AgentRegistry.enumerateAgents` so
    /// ordering and metadata stay in lockstep with the details page.
    private func agentsPanel(_ app: MyApp) -> some View {
        let descriptors = AgentRegistry.enumerateAgents(
            myApp: app,
            store: store,
            settings: settings,
            catalog: modelCatalog
        )
        let preview = Array(descriptors.prefix(3))
        let extra = descriptors.count - preview.count

        return VStack(alignment: .leading, spacing: 10) {
            Button {
                onNavigate(.myAppAgents(app.id))
            } label: {
                HStack(alignment: .firstTextBaseline) {
                    Text("Agents")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundStyle(.primary)
                    Spacer()
                    Text("\(descriptors.count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if descriptors.isEmpty {
                Text("No agents yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(preview) { descriptor in
                        agentPreviewRow(app: app, descriptor: descriptor)
                    }
                    if extra > 0 {
                        Button {
                            onNavigate(.myAppAgents(app.id))
                        } label: {
                            HStack {
                                Text("View all \(descriptors.count) agents")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.top, 4)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.secondary.opacity(0.06))
        )
    }

    private func agentPreviewRow(app: MyApp, descriptor: AgentDescriptor) -> some View {
        Button {
            onNavigate(.myAppAgentDetail(app.id, agentId: descriptor.id))
        } label: {
            HStack(spacing: 10) {
                Image(systemName: descriptor.iconSystemName)
                    .frame(width: 22)
                    .foregroundStyle(appColor)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(descriptor.name)
                            .font(.callout)
                            .fontWeight(.medium)
                        Text(descriptor.kind.displayName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(Color.secondary.opacity(0.12))
                            )
                    }
                    if let subtitle = descriptor.subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Orchestrator variant

    /// Orchestrator Outline: why it's special + the myapps it can drive (each
    /// row jumps to that myapp's home). Leads the page (expanded by default).
    private func orchestratorOutlinePanel() -> some View {
        DisclosureGroup(isExpanded: $outlineExpanded) {
            VStack(alignment: .leading, spacing: 12) {
                Text("The orchestrator is a global agent with its own chat and shared memory that spans every myapp. Use it to plan, delegate work to a myapp's agent, or spin up a new myapp — without opening any single canvas. Each delegation runs as a fresh sub-agent against the target myapp, and it can fan out to several at once.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                if !store.myApps.isEmpty {
                    Divider()
                    Text("Can orchestrate")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(store.myApps) { app in
                            orchestrableRow(app)
                        }
                    }
                }
            }
            .padding(.top, 8)
        } label: {
            Text("Outline")
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundStyle(.primary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.secondary.opacity(0.06))
        )
    }

    private func orchestrableRow(_ app: MyApp) -> some View {
        Button {
            onNavigate(.myAppHome(app.id))
        } label: {
            HStack(spacing: 10) {
                Image(systemName: app.iconSystemName)
                    .frame(width: 22)
                    .foregroundStyle(Color.color(atIndex: store.colorIndex(for: app.id)))
                Text(app.name)
                    .font(.callout)
                    .foregroundStyle(.primary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Orchestrator has no components of its own — show the same Components
    /// panel, empty, so the page reads like any other myapp home.
    private func orchestratorComponentsPanel() -> some View {
        DisclosureGroup(isExpanded: $componentsExpanded) {
            Text("None — the orchestrator coordinates your myapps rather than holding its own canvas.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 12)
        } label: {
            HStack(alignment: .firstTextBaseline) {
                Text("Components")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(.primary)
                Spacer()
                Text("0")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.secondary.opacity(0.06))
        )
    }

    /// Orchestrator Agents panel: one row for the orchestrator agent itself,
    /// mirroring the per-myapp Agents panel; both routes open its detail page.
    private func orchestratorAgentsPanel() -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                onNavigate(.orchestratorAgentDetail)
            } label: {
                HStack(alignment: .firstTextBaseline) {
                    Text("Agents")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundStyle(.primary)
                    Spacer()
                    Text("1")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                onNavigate(.orchestratorAgentDetail)
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "square.stack.3d.up.fill")
                        .frame(width: 22)
                        .foregroundStyle(Color.orchestratorColor)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Orchestrator")
                            .font(.callout)
                            .fontWeight(.medium)
                        Text("Model, permissions, prompt, tool surface")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.secondary.opacity(0.06))
        )
    }
}

/// Recursive memory row used by the `MyAppMemoriesView` browse page (reached
/// from the bottom bar). Folders toggle their children on tap (tracked via the
/// shared `expanded` set, keyed by full path); files navigate via the
/// `onNavigate` callback. Extracted to its own `View` because SwiftUI's
/// opaque-type inference doesn't handle a self-recursive `@ViewBuilder` method.
struct MemoryLandingRow: View {
    let node: MemoryNode
    let depth: Int
    @Binding var expanded: Set<String>
    /// Maps a tapped file's path to the selection to open — `.myAppMemoryFile`
    /// for a myapp, `.memoryFile` for the orchestrator — so one row serves
    /// both scopes.
    let fileSelection: (String) -> SidebarSelection
    var onNavigate: (SidebarSelection) -> Void

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
        Button {
            if isOpen { expanded.remove(node.path) } else { expanded.insert(node.path) }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(width: 12)
                Image(systemName: "folder")
                    .frame(width: 18)
                    .foregroundStyle(.secondary)
                Text(node.name)
                    .font(.callout)
                    .foregroundStyle(.primary)
                Spacer()
            }
            .padding(.leading, CGFloat(depth) * 12)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)

        if isOpen, let children = node.children {
            ForEach(children) { child in
                MemoryLandingRow(
                    node: child,
                    depth: depth + 1,
                    expanded: $expanded,
                    fileSelection: fileSelection,
                    onNavigate: onNavigate
                )
            }
        }
    }

    private var fileRow: some View {
        Button {
            onNavigate(fileSelection(node.path))
        } label: {
            HStack(spacing: 8) {
                Spacer().frame(width: 12)
                Image(systemName: "doc.text")
                    .frame(width: 18)
                    .foregroundStyle(.secondary)
                Text(node.name)
                    .font(.callout)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.leading, CGFloat(depth) * 12)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Identifies the component being edited in `EditComponentSheet`. Component
/// ids (`"tracker-1"`) repeat across myApps, so the myApp id is part of the
/// identity.
private struct EditingComponentRef: Identifiable {
    let myAppId: UUID
    let componentId: String
    var id: String { "\(myAppId.uuidString)/\(componentId)" }
}

/// Edits a component's name + icon (its `id` and data are untouched). An SF
/// Symbol field with a live preview and a quick-pick grid of common glyphs.
/// Reached from the Components grid's per-tile context menu.
private struct EditComponentSheet: View {
    let initial: Component
    var onCommit: (_ name: String, _ icon: String) -> Void
    var onCancel: () -> Void

    @State private var name: String = ""
    @State private var icon: String = ""
    @FocusState private var nameFocused: Bool

    /// A small palette so the common case needs no typing. Any valid SF
    /// Symbol name still works via the text field.
    private let suggestions = [
        "list.bullet.rectangle", "calendar", "checklist", "bubble.left.and.bubble.right",
        "function", "chart.pie", "book", "star", "flag", "tag",
        "folder", "tray", "cart", "dumbbell", "fork.knife", "heart",
        "dollarsign.circle", "briefcase", "house", "person.2",
    ]

    private let columns = [GridItem(.adaptive(minimum: 44), spacing: 8)]

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("e.g. Books, Wardrobe, Workouts", text: $name)
                        .focused($nameFocused)
                        .onSubmit(commit)
                }
                Section("Icon") {
                    HStack(spacing: 10) {
                        Image(systemName: icon.isEmpty ? "square.dashed" : icon)
                            .font(.system(size: 22))
                            .frame(width: 32, height: 32)
                        TextField("SF Symbol name", text: $icon)
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            #endif
                    }
                    LazyVGrid(columns: columns, spacing: 8) {
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
            }
            .navigationTitle("Edit component")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: commit)
                        .disabled(!isDirty || name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            #if os(macOS)
            .frame(minWidth: 340, idealWidth: 400, minHeight: 320, idealHeight: 380)
            #endif
        }
        .onAppear {
            name = initial.name
            icon = initial.iconSystemName
            nameFocused = true
        }
    }

    private var isDirty: Bool {
        name != initial.name || icon != initial.iconSystemName
    }

    private func commit() {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }
        onCommit(trimmedName, icon.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
