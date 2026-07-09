import SwiftUI

/// Change-history page — a newest-first list of snapshot restore points for a
/// given MyApp, grouped by calendar day. The newest snapshot is the current
/// state; every older one has a **Restore** button. Restore is append-only
/// (the current state is snapshotted first), so nothing is ever lost.
/// **Take snapshot** captures a permanent, labelled pin (kept forever, exempt
/// from prune) that can be **Export**ed as a `.pupa` bundle.
/// Pushed onto the detail `NavigationStack` from the bottom bar's History
/// button (the parent stack supplies the nav bar + back button).
public struct ChangeHistoryView: View {
    @Bindable var store: MyAppStore
    let myAppId: UUID

    @State private var pendingRestore: SnapshotMeta?
    @State private var showingSnapshotPrompt = false
    @State private var draftLabel = ""
    @State private var exportItem: SnapshotExportItem?

    private let cal = Calendar.autoupdatingCurrent
    private let relFmt: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    private var app: MyApp? { store.myApps.first { $0.id == myAppId } }
    private var appColor: Color { .color(atIndex: store.colorIndex(for: myAppId)) }

    private var snapshots: [SnapshotMeta] { store.snapshots(forMyApp: myAppId) }
    private var events: [ItemEvent] { store.itemEventLog.events(forMyApp: myAppId) }

    private var groupedByDay: [(label: String, snaps: [SnapshotMeta])] {
        var result: [(label: String, snaps: [SnapshotMeta])] = []
        var current: (label: String, snaps: [SnapshotMeta])? = nil
        for snap in snapshots {
            let label = dayLabel(for: snap.timestamp)
            if current?.label == label {
                current!.snaps.append(snap)
            } else {
                if let c = current { result.append(c) }
                current = (label, [snap])
            }
        }
        if let c = current { result.append(c) }
        return result
    }

    public var body: some View {
        Group {
            if snapshots.isEmpty {
                ContentUnavailableView(
                    "No history yet",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("As you and the agent edit this MyApp, restore points appear here.")
                )
            } else {
                List {
                    ForEach(groupedByDay, id: \.label) { group in
                        Section(group.label) {
                            ForEach(group.snaps) { snap in
                                SnapshotRow(
                                    caption: caption(for: snap),
                                    reason: snap.reason,
                                    isCurrent: snap.id == snapshots.first?.id,
                                    fromThisDevice: snap.device == SnapshotStore.deviceLabel,
                                    relative: relFmt.localizedString(for: snap.timestamp, relativeTo: Date()),
                                    onRestore: { pendingRestore = snap },
                                    onExport: snap.reason == .pinned
                                        ? { exportSnapshot(snap) } : nil
                                )
                            }
                        }
                    }
                }
                #if os(iOS)
                .listStyle(.insetGrouped)
                #endif
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    draftLabel = ""
                    showingSnapshotPrompt = true
                } label: {
                    Label("Take snapshot", systemImage: "pin")
                }
            }
        }
        .alert("Save a snapshot", isPresented: $showingSnapshotPrompt) {
            TextField("Label (e.g. \"before redesign\")", text: $draftLabel)
            Button("Save") { store.takeSnapshot(myAppId: myAppId, label: draftLabel) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Pins this exact state to your history and keeps it forever. You can export it later.")
        }
        .sheet(item: $exportItem) { item in
            SnapshotExportSheet(url: item.url)
        }
        .confirmationDialog(
            "Restore this version?",
            isPresented: Binding(
                get: { pendingRestore != nil },
                set: { if !$0 { pendingRestore = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Restore") {
                if let snap = pendingRestore { store.restore(myAppId: myAppId, snapshotId: snap.id) }
                pendingRestore = nil
            }
            Button("Cancel", role: .cancel) { pendingRestore = nil }
        } message: {
            Text("Your current state is snapshotted first, so you can switch back.")
        }
        // Pinned page header so it's always clear this is a MyApp's History —
        // matches the eyebrow + name header on the other MyApp pages.
        .safeAreaInset(edge: .top, spacing: 0) {
            MyAppPageHeader(
                page: "History",
                name: app?.name ?? "History",
                icon: "clock",
                color: appColor
            )
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.bar)
            .overlay(alignment: .bottom) { Divider() }
        }
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    /// One-line caption for a restore point: reason-driven for sync/conflict/
    /// restore, else the most recent change-feed summary at that moment.
    private func caption(for snap: SnapshotMeta) -> String {
        switch snap.reason {
        case .pinned: return snap.label?.isEmpty == false ? snap.label! : "Saved snapshot"
        case .conflict: return "Recovered from a sync conflict"
        case .preReload: return "Before syncing another device"
        case .restored: return "Restored an earlier version"
        case .edit:
            if let e = events.filter({ $0.timestamp <= snap.timestamp })
                .max(by: { $0.timestamp < $1.timestamp }) {
                return store.changeSummary(for: e)
            }
            return "Edited"
        }
    }

    private func dayLabel(for date: Date) -> String {
        if cal.isDateInToday(date) { return "Today" }
        if cal.isDateInYesterday(date) { return "Yesterday" }
        let fmt = DateFormatter()
        fmt.dateStyle = .medium
        fmt.timeStyle = .none
        return fmt.string(from: date)
    }

    /// Encode the pinned snapshot to a temp `.pupa` file and present the share
    /// sheet. Reuses `makeSnapshotExportItem` (shared with Settings).
    private func exportSnapshot(_ snap: SnapshotMeta) {
        exportItem = makeSnapshotExportItem(
            store: store, snapshotId: snap.id, appId: myAppId,
            baseName: app?.name ?? "snapshot")
    }
}

private struct SnapshotRow: View {
    let caption: String
    let reason: SnapshotReason
    let isCurrent: Bool
    let fromThisDevice: Bool
    let relative: String
    var onRestore: () -> Void
    /// Non-nil only for pinned snapshots — drives the Export affordance.
    var onExport: (() -> Void)?

    private var isPinned: Bool { reason == .pinned }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            glyph
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(caption)
                    .font(.subheadline)
                    .fontWeight(isPinned ? .semibold : .regular)
                HStack(spacing: 4) {
                    if isPinned {
                        Text("Saved")
                            .font(.caption2)
                            .foregroundStyle(.tint)
                        Text("·")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Text(relative)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    if isCurrent {
                        Text("· current")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if !fromThisDevice {
                        Text("· another device")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer()

            if let onExport {
                Button("Export") { onExport() }
                    .font(.caption)
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
            }
            if !isCurrent {
                Button("Restore") { onRestore() }
                    .font(.caption)
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var glyph: some View {
        switch reason {
        case .pinned:
            Image(systemName: "pin.fill")
                .foregroundStyle(.tint)
        case .conflict:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        case .restored:
            Image(systemName: "arrow.uturn.backward.circle.fill")
                .foregroundStyle(Color.orchestratorColor)
        case .preReload:
            Image(systemName: "arrow.triangle.2.circlepath")
                .foregroundStyle(.secondary)
        case .edit:
            Image(systemName: "circle.fill")
                .font(.system(size: 8))
                .foregroundStyle(.secondary)
        }
    }
}
