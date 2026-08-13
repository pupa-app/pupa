import SwiftUI

/// Settings ▸ Recently deleted: MyApps whose tombstone is still on disk (180
/// days, then `gcTombstones` reaps it), restorable from whatever survives them
/// — see `MyAppStore.restorableApp`. The undo for a delete that is otherwise
/// silent and final, including one made on another device.
struct RecentlyDeletedAppsView: View {
    let store: MyAppStore

    /// Held in state, not recomputed per `body`: building it reads every
    /// tombstone and probes a restore source for each.
    @State private var deleted: [MyAppStore.DeletedMyApp] = []
    @State private var loaded = false
    /// Set when a Restore we offered didn't take — the source can go away
    /// between the scan and the tap. Doing nothing reads as a broken button.
    @State private var failedToRestore: String?
    /// The row awaiting confirmation of a permanent delete.
    @State private var pendingPurge: MyAppStore.DeletedMyApp?

    var body: some View {
        List {
            Section {
                if !loaded {
                    ProgressView()
                } else if deleted.isEmpty {
                    Text("Nothing deleted recently.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(deleted) { app in
                        row(app)
                    }
                }
            } footer: {
                Text("Deleted apps are listed here for 180 days. Restoring brings back the last saved state — chats and components included — and clears the delete on your other devices. Deleting permanently erases that saved state everywhere.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Recently deleted")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        // Off-main: the scan touches the filesystem once per tombstone.
        .task {
            deleted = await Task.detached(priority: .userInitiated) {
                MyAppStore.deletedMyApps()
            }.value
            loaded = true
        }
        // Two-way, not `.constant`: SwiftUI writes `false` back on any dismiss
        // (Esc, swipe, outside tap), and a constant binding drops it — leaving
        // `failedToRestore` set and the alert able to re-present.
        .alert("Couldn't restore", isPresented: Binding(
            get: { failedToRestore != nil },
            set: { if !$0 { failedToRestore = nil } }
        )) {
            Button("OK") { failedToRestore = nil }
        } message: {
            Text("\(failedToRestore ?? "") can no longer be restored — its saved state is gone.")
        }
        .confirmationDialog(
            "Delete \(pendingPurge?.name ?? "") permanently?",
            isPresented: Binding(
                get: { pendingPurge != nil },
                set: { if !$0 { pendingPurge = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingPurge
        ) { app in
            Button("Delete permanently", role: .destructive) { purge(app) }
            Button("Cancel", role: .cancel) { pendingPurge = nil }
        } message: { _ in
            Text("Erases its saved state on all your devices — pinned snapshots included. This can't be undone.")
        }
    }

    @ViewBuilder
    private func row(_ app: MyAppStore.DeletedMyApp) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(app.name)
                Text(caption(app))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            // `.borderless` on both: a plain-styled button inside a List row
            // takes the whole row's tap on iOS, so the two would be one control.
            Button("Restore") { restore(app) }
                .buttonStyle(.borderless)
                .disabled(!app.isRestorable)
            Button(role: .destructive) { pendingPurge = app } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .tint(.red)
            .accessibilityLabel("Delete \(app.name) permanently")
        }
    }

    /// "Deleted 3 days ago · no restore point". The date is dropped entirely
    /// when the tombstone didn't decode — better blank than invented.
    private func caption(_ app: MyAppStore.DeletedMyApp) -> String {
        var parts = ["Deleted"]
        if let at = app.deletedAt {
            parts.append(at.formatted(.relative(presentation: .named)))
        }
        let head = parts.joined(separator: " ")
        return app.isRestorable ? head : "\(head) · no restore point"
    }

    private func restore(_ app: MyAppStore.DeletedMyApp) {
        guard store.restoreDeletedMyApp(app.id) else {
            failedToRestore = app.name
            return
        }
        deleted.removeAll { $0.id == app.id }
    }

    /// Off-main like the scan: this unlinks a snapshot directory.
    private func purge(_ app: MyAppStore.DeletedMyApp) {
        pendingPurge = nil
        deleted.removeAll { $0.id == app.id }
        Task.detached(priority: .userInitiated) {
            MyAppStore.purgeDeletedMyApp(app.id)
        }
    }
}
