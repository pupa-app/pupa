import SwiftUI

/// Detail-pane browse page for a memory filesystem — a myApp's notes or the
/// orchestrator's shared notes, selected by `subject`. Reached from the bottom
/// bar's Memories button; folders drill in, files push the scope's file
/// selection (`.myAppMemoryFile` / `.memoryFile`). Reuses `MemoryLandingRow`,
/// the same recursive row the page tree renders for either scope.
///
/// Direct editing: the header `+` adds a note or folder at the scope root; each
/// folder row's context menu adds inside it, and any row can be renamed / moved
/// / deleted — all via the `MemorySheet` shells over `MemoryStore`.
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
    /// Active create / rename sheet (`.newNote` / `.newFolder` / `.rename`).
    @State private var activeSheet: MemorySheet?
    /// Node awaiting delete confirmation (context menu → Delete).
    @State private var pendingDelete: MemoryNode?

    private var myAppId: UUID? {
        if case .myApp(let id) = subject { return id }
        return nil
    }

    private var myApp: MyApp? {
        guard let id = myAppId else { return nil }
        return store.myApps.first(where: { $0.id == id })
    }

    /// Scope-root folder new items land in and the tree renders from.
    private var slug: String {
        if let app = myApp { return MemoryStore.myAppFolder(myAppName: app.name) }
        return MemoryStore.orchestratorFolder()
    }

    /// Path → selection for a tapped file, scoped to the subject.
    private func fileSelection(_ path: String) -> SidebarSelection {
        if let id = myAppId { return .myAppMemoryFile(id, path) }
        return .memoryFile(path)
    }

    /// Closures the tree rows call for direct edits, all funnelled into
    /// `activeSheet` / `pendingDelete` so presentation lives in one place.
    private var rowActions: MemoryRowActions {
        MemoryRowActions(
            newNote: { activeSheet = .newNote(parent: $0) },
            newFolder: { activeSheet = .newFolder(parent: $0) },
            rename: { activeSheet = .rename(path: $0.path) },
            delete: { pendingDelete = $0 }
        )
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                switch subject {
                case .myApp:
                    if let app = myApp {
                        header(
                            name: app.name,
                            color: Color.color(atIndex: store.colorIndex(for: app.id))
                        )
                        Divider()
                        tree(slug: slug)
                    } else {
                        Text("App not found.")
                            .foregroundStyle(.secondary)
                    }
                case .orchestrator:
                    header(name: "Orchestrator", color: .orchestratorColor)
                    Divider()
                    tree(slug: slug)
                }
            }
            .padding(24)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .background(Color.canvasBackground)
        .sheet(item: $activeSheet) { sheet in
            sheetView(sheet)
        }
        .confirmationDialog(
            pendingDelete.map { "Delete “\($0.name)”?" } ?? "",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingDelete
        ) { node in
            Button("Delete", role: .destructive) { delete(node) }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: { node in
            Text(node.isFolder
                 ? "This folder and everything in it is permanently deleted."
                 : "This note is permanently deleted.")
        }
    }

    @ViewBuilder
    private func sheetView(_ sheet: MemorySheet) -> some View {
        switch sheet {
        case .newNote(let parent):
            NewMemoryNoteSheet(memory: memory, parent: parent) {
                activeSheet = nil
            } onCreated: { path in
                onNavigate(fileSelection(path))
            }
        case .newFolder(let parent):
            NewMemoryFolderSheet(memory: memory, parent: parent) {
                activeSheet = nil
            } onCreated: { path in
                // Reveal the new (empty) folder so the user sees it landed.
                expanded.insert(path)
            }
        case .rename(let path):
            RenameMemorySheet(memory: memory, path: path) {
                activeSheet = nil
            }
        }
    }

    /// Header with a `+` menu (New Note / New Folder at the scope root).
    private func header(name: String, color: Color) -> some View {
        HStack(alignment: .top) {
            MyAppPageHeader(page: "Memories", name: name, icon: "brain", color: color)
            Menu {
                Button { activeSheet = .newNote(parent: slug) } label: {
                    Label("New Note", systemImage: "doc.badge.plus")
                }
                Button { activeSheet = .newFolder(parent: slug) } label: {
                    Label("New Folder", systemImage: "folder.badge.plus")
                }
            } label: {
                Image(systemName: "plus")
                    .font(.title3)
                    .accessibilityLabel("Add note or folder")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }

    private func delete(_ node: MemoryNode) {
        try? memory.delete(path: node.path, recursive: node.isFolder)
        pendingDelete = nil
    }

    private func tree(slug: String) -> some View {
        let nodes = memory.tree.children?
            .first(where: { $0.name == slug })?
            .children ?? []

        return VStack(alignment: .leading, spacing: 4) {
            if nodes.isEmpty {
                Text("No notes yet — tap ＋ to add one.")
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
                        onNavigate: onNavigate,
                        actions: rowActions
                    )
                }
            }
        }
    }
}
