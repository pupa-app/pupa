import SwiftUI

/// One row in a Settings category list: icon + title + one-line caption.
/// Shared by the root list, the Agents hub and the Import & Export hub so all
/// three stay visually identical.
struct SettingsHubRow: View {
    let icon: String
    let title: String
    let caption: String

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .foregroundStyle(.primary)
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
        }
    }
}
