import SwiftUI

/// Detail-pane landing page shown when the sidebar's myApp row label is
/// clicked (as opposed to the expansion chevron). Gives an at-a-glance
/// overview of the app — components, their agent-written summaries, and
/// the app's memory files — without diving into a specific component canvas.
public struct MyAppHomeView: View {
    let store: MyAppStore
    let memory: MemoryStore
    let settings: SettingsStore
    let myAppId: UUID
    /// Called when the user taps a component card or a memory file to
    /// navigate deeper. AppView handles the actual selection update.
    var onNavigate: (SidebarSelection) -> Void

    public init(
        store: MyAppStore,
        memory: MemoryStore,
        settings: SettingsStore,
        myAppId: UUID,
        onNavigate: @escaping (SidebarSelection) -> Void
    ) {
        self.store = store
        self.memory = memory
        self.settings = settings
        self.myAppId = myAppId
        self.onNavigate = onNavigate
    }

    /// Summary panel is collapsed by default so the landing page leads
    /// with components/agents/memories — the agent-written summary is
    /// often verbose and pushes the rest of the content off-screen.
    @State private var summaryExpanded: Bool = false
    /// Expansion set for memory folder rows in the Memories panel — same
    /// pattern the sidebar `MemoryRowView` uses so users can drill into
    /// the directory tree without leaving the landing page.
    @State private var expandedMemoryFolders: Set<String> = []
    /// Drives the full Change History sheet opened from the History panel's
    /// "View all" row.
    @State private var historySheetPresented: Bool = false

    private let relFmt: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    private var myApp: MyApp? {
        store.myApps.first(where: { $0.id == myAppId })
    }

    private var appColor: Color {
        let sorted = store.myApps.sorted { $0.createdAt < $1.createdAt }
        let index = sorted.firstIndex(where: { $0.id == myAppId }) ?? 0
        return Color.color(atIndex: index)
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let app = myApp {
                    header(app)
                    Divider()
                    if hasSummaries(app) {
                        summaryPanel(app)
                    }
                    componentsPanel(app)
                    agentsPanel(app)
                    memoriesPanel(app)
                    historyPanel(app)
                } else {
                    Text("App not found.")
                        .foregroundStyle(.secondary)
                }
            }
            .padding(24)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .background(Color.canvasBackground)
        .sheet(isPresented: $historySheetPresented) {
            ChangeHistorySheet(store: store, myAppId: myAppId) {
                historySheetPresented = false
            }
        }
    }

    private func header(_ app: MyApp) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: app.iconSystemName)
                .font(.title2)
                .foregroundStyle(appColor)
            Text(app.name)
                .font(.title)
                .fontWeight(.semibold)
            Spacer()
        }
    }

    private func hasSummaries(_ app: MyApp) -> Bool {
        app.components.contains(where: { $0.summary != nil })
    }

    private func summaryPanel(_ app: MyApp) -> some View {
        DisclosureGroup(isExpanded: $summaryExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(app.components.filter { $0.summary != nil }) { component in
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
        } label: {
            Text("Summary")
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

    private func componentsPanel(_ app: MyApp) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Components")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Spacer()
                Text("\(app.components.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if app.components.isEmpty {
                Text("No components yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(app.components) { component in
                        componentCard(app: app, component: component)
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

    private func componentCard(app: MyApp, component: Component) -> some View {
        Button {
            onNavigate(.myAppComponent(app.id, component.id))
        } label: {
            HStack(spacing: 10) {
                Image(systemName: component.iconSystemName)
                    .frame(width: 22)
                    .foregroundStyle(appColor)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(component.name)
                            .font(.callout)
                            .fontWeight(.medium)
                        Text(component.kindString)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(Color.secondary.opacity(0.12))
                            )
                    }
                    if let summary = component.summary {
                        Text(summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    } else {
                        Text("No summary yet — chat with this app to populate it.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
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

    /// Compact agent preview — up to three rows, then a "View all" footer
    /// row. Both routes push `.myAppAgents(app.id)` so the dedicated page
    /// owns the full list. Built via `AgentRegistry.enumerateAgents` so
    /// ordering and metadata stay in lockstep with the details page.
    private func agentsPanel(_ app: MyApp) -> some View {
        let descriptors = AgentRegistry.enumerateAgents(
            myApp: app,
            store: store,
            settings: settings
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

    private func memoriesPanel(_ app: MyApp) -> some View {
        let slug = MemoryStore.myAppFolder(myAppName: app.name)
        let nodes = memory.tree.children?
            .first(where: { $0.name == slug })?
            .children ?? []

        return VStack(alignment: .leading, spacing: 10) {
            Text("Memories")
                .font(.subheadline)
                .fontWeight(.semibold)
            if nodes.isEmpty {
                Text("No notes yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(nodes) { node in
                        MemoryLandingRow(
                            app: app,
                            node: node,
                            depth: 0,
                            expanded: $expandedMemoryFolders,
                            onNavigate: onNavigate
                        )
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

    /// Recent change history, sitting below Memories. Shows up to three
    /// newest events inline; the header and "View all" row both open the
    /// full `ChangeHistorySheet` (with per-row undo).
    private func historyPanel(_ app: MyApp) -> some View {
        let events = Array(store.itemEventLog.events(forMyApp: myAppId).reversed())
        let preview = Array(events.prefix(3))

        return VStack(alignment: .leading, spacing: 10) {
            Button {
                historySheetPresented = true
            } label: {
                HStack(alignment: .firstTextBaseline) {
                    Text("History")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundStyle(.primary)
                    Spacer()
                    Text("\(events.count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(events.isEmpty)

            if preview.isEmpty {
                Text("No changes yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(preview) { event in
                        historyPreviewRow(event)
                    }
                    if events.count > preview.count {
                        Button {
                            historySheetPresented = true
                        } label: {
                            HStack {
                                Text("View all \(events.count) changes")
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

    private func historyPreviewRow(_ event: ItemEvent) -> some View {
        let isAgent: Bool = { if case .agent = event.actor { return true } else { return false } }()
        return HStack(spacing: 10) {
            Image(systemName: isAgent ? "sparkles" : "person.fill")
                .font(.caption)
                .frame(width: 22)
                .foregroundStyle(isAgent ? Color.orchestratorColor : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(store.changeSummary(for: event))
                    .font(.callout)
                    .foregroundStyle(event.undone ? .secondary : .primary)
                    .strikethrough(event.undone)
                    .lineLimit(1)
                Text(relFmt.localizedString(for: event.timestamp, relativeTo: Date()))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 6)
    }
}

/// Recursive memory row used by `MyAppHomeView.memoriesPanel` and the
/// `MyAppMemoriesView` browse page. Folders toggle their children on tap
/// (tracked via the shared `expanded` set, keyed by full path); files
/// navigate via the `onNavigate` callback. Extracted to its own `View`
/// because SwiftUI's opaque-type inference doesn't handle a self-recursive
/// `@ViewBuilder` instance method.
struct MemoryLandingRow: View {
    let app: MyApp
    let node: MemoryNode
    let depth: Int
    @Binding var expanded: Set<String>
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
                    app: app,
                    node: child,
                    depth: depth + 1,
                    expanded: $expanded,
                    onNavigate: onNavigate
                )
            }
        }
    }

    private var fileRow: some View {
        Button {
            onNavigate(.myAppMemoryFile(app.id, node.path))
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
