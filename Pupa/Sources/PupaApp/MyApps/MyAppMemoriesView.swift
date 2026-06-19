import SwiftUI

/// Detail-pane browse page for a myApp's memory filesystem. Reached from the
/// dock's Memories button; shows the app's note tree (folders drill in, files
/// push `.myAppMemoryFile`). Reuses `MemoryLandingRow` — the same recursive
/// row the Home page's Memories panel renders.
public struct MyAppMemoriesView: View {
    let store: MyAppStore
    let memory: MemoryStore
    let myAppId: UUID
    var onNavigate: (SidebarSelection) -> Void

    public init(
        store: MyAppStore,
        memory: MemoryStore,
        myAppId: UUID,
        onNavigate: @escaping (SidebarSelection) -> Void
    ) {
        self.store = store
        self.memory = memory
        self.myAppId = myAppId
        self.onNavigate = onNavigate
    }

    @State private var expanded: Set<String> = []

    private var myApp: MyApp? {
        store.myApps.first(where: { $0.id == myAppId })
    }

    private var appColor: Color {
        Color.color(atIndex: store.colorIndex(for: myAppId))
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let app = myApp {
                    header(app)
                    Divider()
                    tree(app)
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
    }

    private func header(_ app: MyApp) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "brain")
                .font(.title2)
                .foregroundStyle(appColor)
            Text("\(app.name) memories")
                .font(.title)
                .fontWeight(.semibold)
            Spacer()
        }
    }

    private func tree(_ app: MyApp) -> some View {
        let slug = MemoryStore.myAppFolder(myAppName: app.name)
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
                        app: app,
                        node: node,
                        depth: 0,
                        expanded: $expanded,
                        onNavigate: onNavigate
                    )
                }
            }
        }
    }
}
