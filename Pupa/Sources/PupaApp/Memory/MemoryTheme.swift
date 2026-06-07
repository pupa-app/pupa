import SwiftUI

extension Color {
    static var cardBackground: Color {
        #if os(macOS)
        Color(nsColor: .windowBackgroundColor)
        #else
        Color(uiColor: .systemBackground)
        #endif
    }
    static var cardBorder: Color {
        Color.gray.opacity(0.25)
    }
    static var canvasBackground: Color {
        #if os(macOS)
        Color(nsColor: .underPageBackgroundColor)
        #else
        Color(uiColor: .secondarySystemBackground)
        #endif
    }

    // MARK: - Brand + agent color coding

    /// Soft purple used for the splash gradient, onboarding surfaces, and
    /// any other brand-identity moments. Kept separate from orchestratorColor
    /// so agent UI can stay neutral without washing out the brand palette.
    static let brandColor: Color = Color(red: 0.91, green: 0.13, blue: 0.09)

    // Deliberately understated — a dark neutral grey so the orchestrator
    // reads as the "meta" agent without competing with the per-MyApp colors.
    static let orchestratorColor: Color = Color(white: 0.32)

    /// Palette chosen for maximum visual distinction (no two look alike in
    /// light or dark mode). Assigned by creation order, not UUID hash, so
    /// apps never share a color within a 7-app session.
    static let myAppColorPalette: [Color] = [
        .blue, .green, .orange, .red, .yellow, .indigo, .brown
    ]

    static func color(atIndex index: Int) -> Color {
        myAppColorPalette[index % myAppColorPalette.count]
    }
}
