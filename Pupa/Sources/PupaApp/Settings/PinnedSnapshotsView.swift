import SwiftUI

/// Settings ▸ Pinned snapshots. Every permanent pin the user has taken,
/// grouped per MyApp. Pins **survive deleting the MyApp** (kept by
/// `SnapshotStore.deleteNonPinned`), so a deleted app's milestones still appear
/// here — flagged "deleted" — and can be **Restore**d (which revives the whole
/// app) or **Export**ed as a `.pupa` bundle. Reached from Settings when at
/// least one pin exists.
struct PinnedSnapshotsView: View {
    @Bindable var store: MyAppStore
    /// Called with the affected app's id after a restore/revive — the host
    /// selects it and dismisses Settings. Reuses the import selection path.
    var onRestored: ((UUID) -> Void)?

    @State private var pendingRestore: PendingRestore?
    @State private var exportItem: SnapshotExportItem?
    /// App ids whose pin list is expanded. Empty by default → all collapsed.
    @State private var expanded: Set<UUID> = []

    private struct PendingRestore: Identifiable {
        let group: MyAppStore.PinnedSnapshotGroup
        let snap: SnapshotMeta
        var id: UUID { snap.id }
    }

    private let relFmt: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    private var groups: [MyAppStore.PinnedSnapshotGroup] { store.pinnedSnapshotGroups() }

    var body: some View {
        List {
            if groups.isEmpty {
                Section {
                    Text("No pinned snapshots yet.")
                        .foregroundStyle(.secondary)
                } footer: {
                    Text("Open a MyApp's History and tap Take snapshot to pin a state permanently. Pins are kept forever — even if you delete the app.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Section {
                    ForEach(groups) { group in
                        DisclosureGroup(
                            isExpanded: Binding(
                                get: { expanded.contains(group.appId) },
                                set: { open in
                                    if open { expanded.insert(group.appId) }
                                    else { expanded.remove(group.appId) }
                                }
                            )
                        ) {
                            ForEach(group.snapshots) { snap in
                                row(group: group, snap: snap)
                            }
                        } label: {
                            groupLabel(group)
                        }
                    }
                } footer: {
                    Text("Pins are grouped by app and kept forever — even after you delete the app. Tap an app to see its snapshots, then Export or Restore one.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Pinned snapshots")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .confirmationDialog(
            pendingRestore.map { $0.group.isLive ? "Restore this snapshot?" : "Recreate this app?" } ?? "",
            isPresented: Binding(
                get: { pendingRestore != nil },
                set: { if !$0 { pendingRestore = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingRestore
        ) { pending in
            Button(pending.group.isLive ? "Restore" : "Recreate") {
                if let id = store.restorePinnedSnapshot(
                    appId: pending.group.appId, snapshotId: pending.snap.id) {
                    onRestored?(id)
                }
                pendingRestore = nil
            }
            Button("Cancel", role: .cancel) { pendingRestore = nil }
        } message: { pending in
            Text(pending.group.isLive
                 ? "Your current state is snapshotted first, so you can switch back."
                 : "This deleted app is rebuilt from the snapshot and added back to your apps.")
        }
        .sheet(item: $exportItem) { item in
            SnapshotExportSheet(url: item.url)
        }
    }

    private func groupLabel(_ group: MyAppStore.PinnedSnapshotGroup) -> some View {
        HStack(spacing: 8) {
            Image(systemName: group.iconSystemName)
                .foregroundStyle(.secondary)
                .frame(width: 20)
            Text(group.appName)
            if !group.isLive {
                Text("deleted")
                    .font(.caption2)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Capsule().fill(.secondary.opacity(0.2)))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("\(group.snapshots.count)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func row(group: MyAppStore.PinnedSnapshotGroup, snap: SnapshotMeta) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "pin.fill")
                .foregroundStyle(.tint)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(snap.label?.isEmpty == false ? snap.label! : "Saved snapshot")
                    .font(.subheadline)
                Text(relFmt.localizedString(for: snap.timestamp, relativeTo: Date()))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Export") {
                exportItem = makeSnapshotExportItem(
                    store: store, snapshotId: snap.id, appId: group.appId,
                    baseName: group.appName)
            }
            .font(.caption).buttonStyle(.bordered).controlSize(.mini)
            Button(group.isLive ? "Restore" : "Recreate") {
                pendingRestore = PendingRestore(group: group, snap: snap)
            }
            .font(.caption).buttonStyle(.bordered).controlSize(.mini)
        }
        .padding(.vertical, 2)
    }
}
