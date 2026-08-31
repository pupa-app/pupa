import SwiftUI

/// The bar's menu, drawn open, for the guided tour.
///
/// A SwiftUI `Menu` cannot be opened programmatically, so a tour step that says
/// "the menu holds MyApps" used to either ring a closed button or teleport the
/// user to the destination with no visible tap in between. This draws the menu
/// as it looks when open, above the bar's trailing corner, with the rows the
/// step is talking about lit up.
///
/// Rows come from `BarMenuRow.rows` — the same list the real menu builds from —
/// so the preview cannot describe a menu that no longer exists. It is
/// presentation only: `.allowsHitTesting(false)`, no actions, nothing to tap.
struct TourMenuPreview: View {
    /// Rows to draw, in the real menu's declaration order.
    let rows: [BarMenuRow]
    /// The rows this step is about. Everything else dims.
    let emphasised: Set<BarMenuRow>
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                card
            }
        }
        .padding(.horizontal, 12)
        // Clear the bar itself, the way the real menu sits above it.
        .padding(.bottom, MyAppBottomBar.rowHeight + MyAppBottomBar.verticalPadding * 2 + 8)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// iOS reverses a bottom-anchored menu's whole item list, so the row
    /// nearest the thumb is the one declared first. Draw what the user sees.
    private var visualRows: [BarMenuRow] {
        rows.reversed()
    }

    private var card: some View {
        VStack(spacing: 0) {
            ForEach(Array(visualRows.enumerated()), id: \.element) { index, row in
                if index > 0, visualRows[index - 1].group != row.group {
                    Divider().padding(.leading, 44)
                }
                rowLabel(row)
            }
        }
        .frame(width: 240)
        .background(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.18), radius: 16, y: 6)
        )
        .transition(reduceMotion ? .opacity : .scale(scale: 0.92, anchor: .bottomTrailing).combined(with: .opacity))
    }

    private func rowLabel(_ row: BarMenuRow) -> some View {
        let lit = emphasised.contains(row)
        return HStack(spacing: 12) {
            Image(systemName: row.icon)
                .font(.system(size: 15))
                .frame(width: 20)
            Text(row.title)
                .font(.body)
            Spacer(minLength: 0)
        }
        .foregroundStyle(lit ? AnyShapeStyle(Color.brandColor) : AnyShapeStyle(.secondary))
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background {
            if lit {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.brandColor.opacity(0.14))
                    .padding(.horizontal, 5)
                    // Same breathing pulse the highlight ring uses, so a lit
                    // row reads as the thing the card is pointing at.
                    .scaleEffect(reduceMotion ? 1 : (pulse ? 1.03 : 1))
                    .animation(
                        reduceMotion
                            ? nil
                            : .easeInOut(duration: 0.9).repeatForever(autoreverses: true),
                        value: pulse
                    )
            }
        }
        .onAppear { pulse = true }
    }
}
