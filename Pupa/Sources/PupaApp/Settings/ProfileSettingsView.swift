import AGUIKit
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
    /// `canShare` pattern). When nil the Data section hides.
    var store: MyAppStore?
    var memory: MemoryStore?

    /// Gate the destructive first prune behind a confirmation (enabling the cap
    /// deletes old chats here and on synced devices).
    @State private var confirmEnableCap = false
    /// Debounces the prune while the MB `Stepper` is being scrubbed so a
    /// press-and-hold doesn't run a full prune + persist on every 0.1 tick.
    @State private var capPruneTask: Task<Void, Never>?
    /// Drives the "Sync now" spinner while a manual reconcile runs.
    @State private var isSyncing = false

    private var iCloudActive: Bool { PupaStorage.iCloudActive }

    /// Real convergence state, not just "container resolved". Reads
    /// `SyncStatus.shared` during body eval so `@Observable` tracks updates.
    private var statusText: String {
        guard iCloudActive else { return "Inactive" }
        let s = SyncStatus.shared
        // Before the generic count, which is non-zero by definition while the
        // roster is inbound — that's what we're waiting on. Checked second,
        // this branch was unreachable in the one case it exists for, leaving a
        // bare "Syncing 43…" that said nothing about the roster being partial.
        if store?.awaitingCloudRoster == true {
            let pending = max(store?.pendingCloudDownloads ?? 0, s.pendingDownloads)
            return pending > 0 ? "Restoring your apps · \(pending) left" : "Restoring your apps…"
        }
        if s.pendingDownloads > 0 { return "Syncing \(s.pendingDownloads)…" }
        guard let at = s.lastConvergedAt else { return "Waiting for iCloud" }
        return "Up to date · \(Self.relativeFmt.localizedString(for: at, relativeTo: Date()))"
    }

    private static let relativeFmt: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    /// Force an iCloud reconcile on demand and republish the stores if it pulled
    /// anything. Gives the user a way to unstick a laggy sync without editing
    /// something to "change the device itself". Updates `lastConvergedAt`.
    @MainActor private func syncNow() async {
        guard !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }
        // Kick downloads first: `reconcile()` only copies already-materialized
        // files, so against dataless cloud placeholders — exactly the state
        // this button is meant to unstick — a bare reconcile did nothing.
        //
        // Concurrent and on a short deadline, since the button is disabled
        // throughout and two sequential 60s defaults would park it for two
        // minutes. The kick is what matters; downloads continue regardless.
        async let state: Bool = PupaStorage.downloadSubtreeUntilSettled("state", timeout: .seconds(15))
        async let memories: Bool = PupaStorage.downloadSubtreeUntilSettled("memories", timeout: .seconds(15))
        _ = await (state, memories)
        let changed = await StorageMirror.shared.reconcile()
        guard changed else { return }
        await store?.reloadFromDisk()
        await memory?.reloadFromDisk()
        await settings.reloadFromDisk()
    }

    var body: some View {
        Form {
            header
            iCloudSection
            if let store, let memory {
                dataSection(store: store, memory: memory)
                chatStorageSection(store: store)
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
            Group {
                LabeledContent("Status", value: statusText)
                LabeledContent("This device", value: DeviceInfo.localName)
                LabeledContent("Data location", value: iCloudActive ? "iCloud" : "On this device")
            }
            .tourAnchor(.settingsAccount)
            if iCloudActive {
                Button {
                    Task { await syncNow() }
                } label: {
                    HStack {
                        Text("Sync now")
                        if isSyncing {
                            Spacer()
                            ProgressView().controlSize(.small)
                        }
                    }
                }
                .disabled(isSyncing)
            }
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
        let chatCount = store.myApps.reduce(0) { $0 + $1.threads.count } + store.memoryThreads.count
        return Section("Data") {
            LabeledContent("MyApps", value: "\(store.myApps.count)")
            LabeledContent("Chats", value: "\(chatCount)")
            LabeledContent("Memories") {
                Text(fileCount == 1 ? "1 file" : "\(fileCount) files")
                    + Text(totalBytes > 0 ? " · \(Self.byteString(totalBytes))" : "")
            }
            LabeledContent("Backends", value: "\(settings.backends.count)")
        }
    }

    // MARK: Chat storage cap

    /// Opt-in per-MyApp chat-storage cap. A stored chat is only local metadata
    /// (its transcript lives on the backend), so the limit is fractional-MB and
    /// deletes the oldest chats once a MyApp exceeds it. Enabling is confirmed
    /// (it's destructive and syncs); lowering the limit prunes on a debounce so
    /// scrubbing the `Stepper` doesn't fire a full prune per 0.1 tick.
    private func chatStorageSection(store: MyAppStore) -> some View {
        Section {
            Toggle(isOn: Binding(
                get: { settings.threadCapEnabled },
                // Enabling deletes old chats (here + synced devices) — confirm
                // first. Disabling only stops future pruning, so it's immediate.
                set: { on in
                    if on { confirmEnableCap = true }
                    else { settings.setThreadCapEnabled(false) }
                }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Auto-delete old chats")
                    Text("Keep only recent chats per MyApp within a size limit.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .confirmationDialog("Auto-delete old chats?", isPresented: $confirmEnableCap, titleVisibility: .visible) {
                Button("Enable & delete old chats", role: .destructive) {
                    settings.setThreadCapEnabled(true)
                    store.pruneAllThreads()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Chats beyond the size limit are removed on this device and any synced devices. This can't be undone. Backend history is unaffected.")
            }
            Stepper(value: Binding(
                get: { settings.threadCapMB },
                // Update the limit live (label tracks the scrub); defer the
                // actual prune until the value settles.
                set: { settings.setThreadCapMB($0); scheduleCapPrune(store) }
            ), in: SettingsStore.threadCapMBRange, step: 0.1) {
                LabeledContent(
                    "Limit per MyApp",
                    value: settings.threadCapMB.formatted(.number.precision(.fractionLength(1))) + " MB"
                )
            }
            .disabled(!settings.threadCapEnabled)
        } header: {
            Text("Chat storage")
        } footer: {
            Text("Keeps only the most recent chats per MyApp within this size. Older chats are removed here and on synced devices; backend history is unaffected.")
        }
    }

    /// Coalesce rapid `Stepper` changes into one prune ~400ms after the last
    /// edit, so a press-and-hold doesn't run a full prune + persist per tick.
    private func scheduleCapPrune(_ store: MyAppStore) {
        capPruneTask?.cancel()
        capPruneTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            store.pruneAllThreads()
        }
    }

    // MARK: Support / About

    /// pupa-app.com pages. The privacy policy must be reachable in-app, not only
    /// in App Store Connect (App Review 5.1.2).
    private struct WebLink: Identifiable {
        let title: String
        let url: URL
        var id: String { title }
        init(_ title: String, _ path: String) {
            self.title = title
            self.url = URL(string: "https://pupa-app.com" + path)!
        }
    }

    /// Seeded from what this build is actually doing, not from the key —
    /// a debug build logs by default, and a toggle reading "off" while the
    /// log fills up is worse than no toggle. `RootView` has already applied
    /// the stored choice by the time Settings can be opened.
    @State private var diagnosticsEnabled = AGUIKitLog.enabled

    private static let webLinks = [
        WebLink("Website", ""),
        WebLink("Privacy Policy", "/privacy"),
        WebLink("Terms of Use", "/terms"),
        WebLink("Help & Support", "/support"),
    ]

    private var supportSection: some View {
        Section {
            LabeledContent("Version", value: PupaAppVersion)
            Toggle("Diagnostic logging", isOn: $diagnosticsEnabled)
                .onChange(of: diagnosticsEnabled) { _, on in
                    // Live, so a reproduction doesn't need a relaunch. Turning
                    // it off stops new lines; what is already in the system log
                    // stays until the device rotates it.
                    AGUIKitLog.enabled = on
                    UserDefaults.standard.set(on, forKey: DiagnosticsKeys.enabled)
                    AGUIKitLog.session("diagnostics \(on ? "enabled" : "disabled") by the user")
                }
            ForEach(Self.webLinks) { link in
                Link(destination: link.url) {
                    HStack {
                        Text(link.title)
                        Spacer()
                        Image(systemName: "arrow.up.right")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            Text("Support")
        } footer: {
            if diagnosticsEnabled {
                Text("Recording what the agent does, so a dropped reply can be "
                     + "diagnosed. Read it with Console on a Mac, filtering "
                     + "dev.pupa. Your messages are not recorded — only their "
                     + "length. Turn this off when you're done.")
            } else {
                Text("Turn on Diagnostic logging only if you've been asked to — "
                     + "it records what the agent is doing so a dropped reply "
                     + "can be traced.")
            }
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
