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

    // MARK: - Agent color coding

    static let orchestratorColor: Color = .purple

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
