import SwiftUI

/// Settings → Recently deleted. Lists MyApps whose tombstone is still on disk
/// (180 days, then `gcTombstones` reaps it) and restores one from the snapshot
/// `removeMyApp` captures on the way out.
///
/// Deleting used to be silent and final: the body file goes, the tombstone
/// suppresses the id on every device, and nothing surfaced either. This screen
/// is the undo — including for a delete made on another device, which is how a
/// missing app usually gets noticed.
struct RecentlyDeletedAppsView: View {
    @Bindable var store: MyAppStore

    /// Snapshot of the tombstone list. Held in state (not recomputed per body)
    /// because building it reads every tombstone and, for legacy ones, resolves
    /// a snapshot chain to recover the name.
    @State private var deleted: [MyAppStore.DeletedMyApp] = []
    @State private var restoring: UUID?

    var body: some View {
        List {
            Section {
                if deleted.isEmpty {
                    Text("Nothing deleted recently.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(deleted) { app in
                        row(app)
                    }
                }
            } footer: {
                Text("Deleted apps are listed here for 180 days. Restoring brings back the last saved state — chats and components included — and clears the delete on your other devices.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Recently deleted")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task { deleted = MyAppStore.deletedMyApps() }
    }

    @ViewBuilder
    private func row(_ app: MyAppStore.DeletedMyApp) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(app.name)
                Text(app.isRestorable
                     ? "Deleted \(app.deletedAt.formatted(.relative(presentation: .named)))"
                     : "Deleted \(app.deletedAt.formatted(.relative(presentation: .named))) · no restore point")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if restoring == app.id {
                ProgressView()
            } else {
                Button("Restore") { restore(app) }
                    .buttonStyle(.borderless)
                    .disabled(!app.isRestorable)
            }
        }
    }

    private func restore(_ app: MyAppStore.DeletedMyApp) {
        restoring = app.id
        defer { restoring = nil }
        guard store.restoreDeletedMyApp(app.id) else { return }
        deleted.removeAll { $0.id == app.id }
    }
}
