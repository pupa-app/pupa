import SwiftUI

/// Which mock "art" a value slide renders above its title. The art is built
/// from real in-app styling (component cards, chat bubbles, a memory file) so
/// the carousel demos the actual product rather than stock illustration.
enum OnboardingArt {
    case logo
    case myApps
    case chat
    case memory
}

/// Copy + art for one value slide. Static content — no localization layer
/// exists in the app yet, so the strings live inline like the rest of the UI.
struct OnboardingSlideContent: Identifiable {
    let id = UUID()
    let art: OnboardingArt
    let title: String
    let subtitle: String
}

enum OnboardingContent {
    /// The value slides shown before the backend-connect step. The marketing
    /// funnel is Hook → Value → Magic → Moat: one idea per slide, benefit-first.
    static let valueSlides: [OnboardingSlideContent] = [
        OnboardingSlideContent(
            art: .logo,
            title: "Meet Pupa",
            subtitle: "Apps that build themselves around you. Describe what you need. Pupa assembles it."
        ),
        OnboardingSlideContent(
            art: .myApps,
            title: "Living workspaces",
            subtitle: "Trackers, calendars, checklists and chat rooms. All bundled into apps that reshape on demand."
        ),
        OnboardingSlideContent(
            art: .chat,
            title: "Just ask",
            subtitle: "Tell your agent what you want. It edits the canvas in real time. No forms, no menus."
        ),
        OnboardingSlideContent(
            art: .memory,
            title: "It remembers",
            subtitle: "Pupa keeps memories of your goals and preferences, plus a full history of every change. So nothing gets lost and every undo is one tap away."
        ),
    ]
}

/// One value slide: mock art on top, title + subtitle below.
struct OnboardingSlide: View {
    let content: OnboardingSlideContent

    var body: some View {
        VStack(spacing: 28) {
            OnboardingArtView(art: content.art)
                .frame(height: 240)
                .frame(maxWidth: .infinity)

            VStack(spacing: 12) {
                Text(content.title)
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .multilineTextAlignment(.center)
                Text(content.subtitle)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Renders the mock preview for a slide. Kept deliberately lightweight (SF
/// Symbols + brand palette + the app's card styling) so it reads as "Pupa"
/// without depending on live stores.
struct OnboardingArtView: View {
    let art: OnboardingArt

    var body: some View {
        switch art {
        case .logo: logoArt
        case .myApps: myAppsArt
        case .chat: chatArt
        case .memory: memoryArt
        }
    }

    // MARK: - Logo

    private var logoArt: some View {
        ZStack {
            Circle()
                .fill(Color.brandColor.opacity(0.12))
                .frame(width: 200, height: 200)
            Group {
                if let icon = AppIcon.swiftUIImage {
                    icon
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 120, height: 120)
                        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                } else {
                    Image(systemName: "square.stack.3d.up.fill")
                        .font(.system(size: 80))
                        .foregroundStyle(Color.brandColor)
                }
            }
            .shadow(color: .black.opacity(0.18), radius: 14, x: 0, y: 8)
        }
    }

    // MARK: - MyApps

    private var myAppsArt: some View {
        // One domain each, deliberately: three of the four onboarding
        // illustrations used to be job hunting, which read as the app's
        // subject rather than one example of it.
        let cards: [(String, String, Int)] = [
            ("checklist", "Habit Tracker", 0),
            ("calendar", "Trip Planner", 1),
            ("checkmark.circle", "Reading List", 2),
            ("bubble.left.and.bubble.right.fill", "Recipe Room", 3),
        ]
        return LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            ForEach(cards.indices, id: \.self) { i in
                let card = cards[i]
                componentCard(icon: card.0, title: card.1, tint: .color(atIndex: card.2))
            }
        }
        .frame(maxWidth: 320)
    }

    private func componentCard(icon: String, title: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .foregroundStyle(tint)
                Text(title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            RoundedRectangle(cornerRadius: 3).fill(Color.secondary.opacity(0.18)).frame(height: 6)
            RoundedRectangle(cornerRadius: 3).fill(Color.secondary.opacity(0.12)).frame(height: 6).padding(.trailing, 24)
        }
        .padding(10)
        .background(Color.brandSurface)
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.brandColor.opacity(0.18)))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Chat

    private var chatArt: some View {
        VStack(alignment: .leading, spacing: 10) {
            bubble("Plan a weekend in Lisbon", isUser: true)
            bubble("On it! Adding a calendar and a packing checklist.", isUser: false)
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.caption2)
                    .foregroundStyle(.green)
                Text("Used 2 tools")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.secondary.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .frame(maxWidth: 320)
    }

    private func bubble(_ text: String, isUser: Bool) -> some View {
        HStack {
            if isUser { Spacer(minLength: 32) }
            Text(text)
                .font(.callout)
                .padding(10)
                .background(isUser ? Color.accentColor.opacity(0.15) : Color.gray.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 12))
            if !isUser { Spacer(minLength: 32) }
        }
    }

    // MARK: - Memory

    private var memoryArt: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "doc.text.fill")
                    .foregroundStyle(Color.brandColor)
                Text("Preferences.md")
                    .font(.subheadline.weight(.semibold))
                Spacer()
            }
            ForEach(0..<4, id: \.self) { i in
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.secondary.opacity(i == 0 ? 0.22 : 0.12))
                    .frame(height: 8)
                    .padding(.trailing, CGFloat([0, 60, 30, 90][i]))
            }
        }
        .padding(16)
        .frame(maxWidth: 300)
        .background(Color.brandSurface)
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.brandColor.opacity(0.18)))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

/// Row of page-position dots. The active dot fills with the brand color and
/// widens slightly. Used by `OnboardingFlowView` (the page TabView style is
/// iOS-only, so the carousel and its indicator are built by hand for macOS
/// parity).
struct PageDots: View {
    let count: Int
    let current: Int

    var body: some View {
        HStack(spacing: 8) {
            ForEach(0..<count, id: \.self) { i in
                Capsule()
                    .fill(i == current ? Color.brandColor : Color.secondary.opacity(0.3))
                    .frame(width: i == current ? 20 : 8, height: 8)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: current)
        .accessibilityLabel("Page \(current + 1) of \(count)")
    }
}
