import SwiftUI

/// Small `info.circle` button that presents a popover with a one or two
/// sentence explanation of the adjacent concept. Used next to the
/// "Memories" and "MyApps" sidebar section headers and in the Settings
/// sheet's toolbar — three locations matching the three concepts the user
/// can ask about ("what are memories?", "what is a myapp?", "what does
/// Settings do?").
public struct InfoBadge: View {
    let title: String
    let message: String
    @State private var isShown = false

    public init(title: String, message: String) {
        self.title = title
        self.message = message
    }

    public var body: some View {
        Button {
            isShown.toggle()
        } label: {
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("About \(title)")
        .popover(isPresented: $isShown, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.headline)
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
            // A fixed width (rather than a min/max range) so the popover
            // measures the wrapped text's height deterministically — the range
            // let it under-size and clip the last line.
            .frame(width: 280, alignment: .leading)
            .presentationCompactAdaptation(.popover)
        }
    }
}
