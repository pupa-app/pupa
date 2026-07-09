import SwiftUI

/// Agent selector dropdown. Lives in the chat card's top bar (alongside the
/// resize / close controls) so the active agent's name and colour read as the
/// card's title; thread selection stays one row below in `ChatPanel.header`.
///
/// Uses a custom popover (not a native `Menu`) so each agent row keeps its own
/// colour — system menus ignore per-row text/icon tints.
struct AgentDropdown: View {
    let viewModel: ChatViewModel
    let agents: [AgentPickerEntry]
    let onSwitchAgent: (ChatScope) -> Void

    @State private var showAgentList: Bool = false

    /// Agent name, hard-capped so it never wraps to a second line — the icon +
    /// chevron stay on one row regardless of name length.
    private var headerLabel: String {
        let name = viewModel.agentDisplayName
        let maxChars = 14
        return name.count > maxChars ? name.prefix(maxChars - 1) + "…" : name
    }

    var body: some View {
        let current = agents.first(where: { $0.scope == viewModel.pinnedScope })
        Button { showAgentList = true } label: {
            HStack(spacing: 4) {
                if let icon = current?.icon {
                    Image(systemName: icon)
                        .foregroundStyle(viewModel.agentColor)
                }
                Text(headerLabel)
                    .font(.subheadline).bold()
                    .foregroundStyle(viewModel.agentColor)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: true, vertical: false)
                Image(systemName: "chevron.down")
                    .font(.caption2)
                    .foregroundStyle(viewModel.agentColor.opacity(0.7))
            }
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showAgentList) {
            popover
                .presentationCompactAdaptation(.popover)
        }
    }

    @ViewBuilder
    private var popover: some View {
        // Wrap the roster in a ScrollView so a long agent list (Orchestrator +
        // one entry per MyApp) stays fully reachable — without it the popover
        // grows past the screen and the bottom apps become inaccessible. The
        // max height caps the popover so it scrolls instead of overflowing;
        // `.basedOnSize` bounce keeps a short list feeling static.
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(agents.enumerated()), id: \.element.id) { idx, entry in
                    if idx > 0 { Divider() }
                    Button {
                        onSwitchAgent(entry.scope)
                        showAgentList = false
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark")
                                .font(.caption)
                                .foregroundStyle(entry.color)
                                .opacity(entry.scope == viewModel.pinnedScope ? 1 : 0)
                                .frame(width: 16)
                            Image(systemName: entry.icon)
                                .foregroundStyle(entry.color)
                                .frame(width: 20)
                            Text(entry.name)
                                .font(.subheadline)
                                .foregroundStyle(entry.color)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(minWidth: 180)
        .frame(maxHeight: 360)
    }
}
