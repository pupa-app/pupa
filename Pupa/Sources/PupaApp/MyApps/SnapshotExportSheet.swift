import SwiftUI

/// Identifiable wrapper so a prepared export URL can drive a `.sheet(item:)`.
struct SnapshotExportItem: Identifiable {
    let url: URL
    var id: String { url.path }
}

/// Minimal share sheet hosting a `ShareLink` for a prepared `.pupa` file.
/// Shared by the per-MyApp History page and the Settings ▸ Pinned snapshots page.
struct SnapshotExportSheet: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "pin.fill")
                .font(.largeTitle)
                .foregroundStyle(.tint)
            Text("Export snapshot")
                .font(.headline)
            Text("Save this pinned state as a .\(MyAppBundle.fileExtension) file — AirDrop, Messages, Mail, or Save to Files.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            ShareLink(item: url, preview: SharePreview(url.lastPathComponent)) {
                Label("Share…", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.borderedProminent)
            Button("Done") { dismiss() }
        }
        .padding(32)
        #if os(macOS)
        .frame(minWidth: 320)
        #else
        .presentationDetents([.medium])
        #endif
    }
}

/// Encode a snapshot to a temp `.pupa` file and return an export item for a
/// `.sheet(item:)`. Reuses the marketplace exporter via
/// `MyAppStore.snapshotBundleData`. Returns nil on a transient write failure.
@MainActor
func makeSnapshotExportItem(
    store: MyAppStore, snapshotId: UUID, appId: UUID, baseName: String
) -> SnapshotExportItem? {
    guard let data = store.snapshotBundleData(forSnapshot: snapshotId, appId: appId)
    else { return nil }
    let name = "\(baseName).\(MyAppBundle.fileExtension)"
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent(snapshotId.uuidString, isDirectory: true)
    let url = dir.appendingPathComponent(name)
    do {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try data.write(to: url)
        return SnapshotExportItem(url: url)
    } catch {
        return nil
    }
}
