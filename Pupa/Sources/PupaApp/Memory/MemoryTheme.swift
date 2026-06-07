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
    /// Brand-tinted card surface — light-pink matching the icon background in
    /// light mode, a dark muted plum in dark mode so white label text stays
    /// legible. Adaptive: resolves per light/dark trait rather than baking one
    /// fixed light value (which left white text invisible on the pink in dark).
    /// Used for cards that sit on top of other content (tour, onboarding art).
    static let brandSurface: Color = {
        #if os(macOS)
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(red: 0.22, green: 0.10, blue: 0.10, alpha: 1.0)
                : NSColor(red: 1.0, green: 0.93, blue: 0.92, alpha: 1.0)
        })
        #else
        Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 0.22, green: 0.10, blue: 0.10, alpha: 1.0)
                : UIColor(red: 1.0, green: 0.93, blue: 0.92, alpha: 1.0)
        })
        #endif
    }()

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
