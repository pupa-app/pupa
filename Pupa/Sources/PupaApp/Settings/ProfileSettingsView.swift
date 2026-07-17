import SwiftUI

/// Read-only Account screen pushed from `SettingsSheet`.
///
/// Pupa has no auth of its own — identity is the Apple ID behind iCloud, which
/// Apple won't expose to a sandboxed app (no email/avatar/device list). So this
/// screen only shows what's true: iCloud sync status, this device, a data
/// overview, and Support/About. Everything is system-derived; nothing editable.
struct ProfileSettingsView: View {
    @Bindable var settings: SettingsStore
    /// Optional so the screen degrades in previews (matches SettingsSheet's
    /// `canShare` / `canShowAgents` pattern). When nil the Data section hides.
    var store: MyAppStore?
    var memory: MemoryStore?

    private var iCloudActive: Bool { PupaStorage.iCloudActive }

    /// Real convergence state, not just "container resolved". Reads
    /// `SyncStatus.shared` during body eval so `@Observable` tracks updates.
    private var statusText: String {
        guard iCloudActive else { return "Inactive" }
        let s = SyncStatus.shared
        if s.pendingDownloads > 0 { return "Syncing \(s.pendingDownloads)…" }
        guard let at = s.lastConvergedAt else { return "Waiting for iCloud" }
        return "Up to date · \(Self.relativeFmt.localizedString(for: at, relativeTo: Date()))"
    }

    private static let relativeFmt: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    var body: some View {
        Form {
            header
            iCloudSection
            if let store, let memory {
                dataSection(store: store, memory: memory)
            }
            supportSection
        }
        .navigationTitle("Account")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    // MARK: Header

    private var header: some View {
        Section {
            HStack(spacing: 14) {
                Image(systemName: "person.crop.circle")
                    .font(.system(size: 44))
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(DeviceInfo.localName)
                        .font(.headline)
                    Text(iCloudActive ? "iCloud sync on" : "iCloud sync off")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: iCloud

    private var iCloudSection: some View {
        Section {
            LabeledContent("Status", value: statusText)
            LabeledContent("This device", value: DeviceInfo.localName)
            LabeledContent("Data location", value: iCloudActive ? "iCloud" : "On this device")
        } header: {
            Text("iCloud Sync")
        } footer: {
            Text(iCloudActive
                 ? "Your MyApps, memories and settings sync automatically across your devices signed in to the same Apple ID."
                 : "Sign in to iCloud to sync your MyApps, memories and settings across your devices. Data is kept on this device until then.")
        }
    }

    // MARK: Data overview

    private func dataSection(store: MyAppStore, memory: MemoryStore) -> some View {
        let fileCount = memory.snapshotPaths().count
        let totalBytes = Self.totalBytes(memory.tree)
        return Section("Data") {
            LabeledContent("MyApps", value: "\(store.myApps.count)")
            LabeledContent("Memories") {
                Text(fileCount == 1 ? "1 file" : "\(fileCount) files")
                    + Text(totalBytes > 0 ? " · \(Self.byteString(totalBytes))" : "")
            }
            LabeledContent("Backends", value: "\(settings.backends.count)")
        }
    }

    // MARK: Support / About

    private var supportSection: some View {
        Section("Support") {
            LabeledContent("Version", value: PupaAppVersion)
        }
    }

    // MARK: Helpers

    /// Sum of every file's `sizeBytes` under a memory node.
    private static func totalBytes(_ node: MemoryNode) -> Int {
        var sum = 0
        if case let .file(size) = node.kind { sum += size }
        for child in node.children ?? [] { sum += totalBytes(child) }
        return sum
    }

    private static func byteString(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}
