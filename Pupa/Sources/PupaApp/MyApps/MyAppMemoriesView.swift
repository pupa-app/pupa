import SwiftUI

/// Detail-pane browse page for a memory filesystem — a myApp's notes or the
/// orchestrator's shared notes, selected by `subject`. Reached from the bottom
/// bar's Memories button; folders drill in, files push the scope's file
/// selection (`.myAppMemoryFile` / `.memoryFile`). Reuses `MemoryLandingRow`,
/// the same recursive row the page tree renders for either scope.
public struct MyAppMemoriesView: View {
    let store: MyAppStore
    let memory: MemoryStore
    let subject: MyAppHomeView.Subject
    var onNavigate: (SidebarSelection) -> Void

    public init(
        store: MyAppStore,
        memory: MemoryStore,
        subject: MyAppHomeView.Subject,
        onNavigate: @escaping (SidebarSelection) -> Void
    ) {
        self.store = store
        self.memory = memory
        self.subject = subject
        self.onNavigate = onNavigate
    }

    @State private var expanded: Set<String> = []

    private var myAppId: UUID? {
        if case .myApp(let id) = subject { return id }
        return nil
    }

    private var myApp: MyApp? {
        guard let id = myAppId else { return nil }
        return store.myApps.first(where: { $0.id == id })
    }

    /// Path → selection for a tapped file, scoped to the subject.
    private func fileSelection(_ path: String) -> SidebarSelection {
        if let id = myAppId { return .myAppMemoryFile(id, path) }
        return .memoryFile(path)
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                switch subject {
                case .myApp:
                    if let app = myApp {
                        header(
                            title: "\(app.name) memories",
                            color: Color.color(atIndex: store.colorIndex(for: app.id))
                        )
                        Divider()
                        tree(slug: MemoryStore.myAppFolder(myAppName: app.name))
                    } else {
                        Text("App not found.")
                            .foregroundStyle(.secondary)
                    }
                case .orchestrator:
                    header(title: "Orchestrator memories", color: .orchestratorColor)
                    Divider()
                    tree(slug: MemoryStore.orchestratorFolder())
                }
            }
            .padding(24)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .background(Color.canvasBackground)
    }

    private func header(title: String, color: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "brain")
                .font(.title2)
                .foregroundStyle(color)
            Text(title)
                .font(.title)
                .fontWeight(.semibold)
            Spacer()
        }
    }

    private func tree(slug: String) -> some View {
        let nodes = memory.tree.children?
            .first(where: { $0.name == slug })?
            .children ?? []

        return VStack(alignment: .leading, spacing: 4) {
            if nodes.isEmpty {
                Text("No notes yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                ForEach(nodes) { node in
                    MemoryLandingRow(
                        node: node,
                        depth: 0,
                        expanded: $expanded,
                        fileSelection: fileSelection,
                        onNavigate: onNavigate
                    )
                }
            }
        }
    }
}
