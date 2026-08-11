import SwiftUI

/// Editable extended-thinking selector rendered as a `Menu`. Options are the
/// harness-advertised levels (`ThinkingLevel`) plus a leading "Default" sentinel
/// that clears the per-agent override (backend applies its own default).
///
/// Mirrors `ModelPickerRow`'s full style — a labelled chip + chevron — so the
/// agent-details page reads consistently. There is no compact variant yet
/// (thinking is not surfaced in the chat header).
struct ThinkingPickerRow: View {
    /// Currently-selected level string, or `thinkingDefaultId` for no override.
    let selectedLevel: String
    let options: [ThinkingLevel]
    var onSelect: (String) -> Void

    private var currentLabel: String {
        options.first(where: { $0.level == selectedLevel })?.label ?? "Default"
    }

    var body: some View {
        Menu {
            Button {
                onSelect(KnownLLMModelCatalog.thinkingDefaultId)
            } label: {
                if selectedLevel == KnownLLMModelCatalog.thinkingDefaultId {
                    Label("Default", systemImage: "checkmark")
                } else {
                    Text("Default")
                }
            }
            Divider()
            ForEach(options) { level in
                Button {
                    onSelect(level.level)
                } label: {
                    if level.level == selectedLevel {
                        Label(level.label, systemImage: "checkmark")
                    } else {
                        Text(level.label)
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text(currentLabel)
                    .font(.callout)
                    .fontWeight(.medium)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.accentColor.opacity(0.12))
                    )
                Image(systemName: "chevron.down")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
