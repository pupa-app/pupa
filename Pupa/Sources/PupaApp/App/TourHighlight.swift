import SwiftUI

/// A control the guided tour can ring to point at the thing a step is talking
/// about. Identifies a target by *role*, not geometry — the host tags the live
/// view with `.tourAnchor(id)` and the overlay resolves its bounds at render
/// time, so the highlight survives layout changes the way the rest of the tour
/// survives a redesign.
enum TourHighlight: Hashable {
    /// The whole bottom bar, ringed as one region. The opening step names the
    /// bar itself; the steps after it ring one slot each.
    case bottomBar
    case bottomBarHome
    case bottomBarMemories
    case bottomBarChat
    /// The bar's menu — Agents, History, MyApps, Orchestrator and Settings all
    /// live behind it, so every step describing one of those rings this.
    case bottomBarMore
    /// The chat's agent switcher + thread selector — two adjacent controls
    /// ringed together as one region.
    case chatHeader
    /// The Settings · Account iCloud section.
    case settingsAccount
    /// The Settings · Examples list. The closing step rings it so the user
    /// knows where to tap Restore.
    case settingsExamples
    /// The marketplace link at the top of Settings · Examples, ringed before
    /// the bundled examples: it is where the current official apps live.
    case settingsMarketplace
    /// The Settings root's opening section (Account, Backend, Notifications).
    /// Ringed on the root before the tour dives into one of its pages, so the
    /// user sees where the page they land on came from.
    case settingsEssentials
    /// The Settings root's "Manage MyApps" section. Same rule.
    case settingsManageMyApps
}

/// Collects the bounds of every `.tourAnchor`-tagged view in a subtree, keyed
/// by role, so the highlight overlay can look up the active step's target. A
/// role may be tagged on several views (e.g. `chatHeader` spans the agent and
/// thread pickers); their bounds are gathered into a list and the overlay rings
/// the union.
struct TourAnchorKey: PreferenceKey {
    static let defaultValue: [TourHighlight: [Anchor<CGRect>]] = [:]

    static func reduce(
        value: inout [TourHighlight: [Anchor<CGRect>]],
        nextValue: () -> [TourHighlight: [Anchor<CGRect>]]
    ) {
        value.merge(nextValue(), uniquingKeysWith: { $0 + $1 })
    }
}

extension View {
    /// Publish this view's bounds under `id` so `TourHighlightOverlay` can ring
    /// it. Non-intrusive: pure preference, no layout or hit-testing change.
    func tourAnchor(_ id: TourHighlight) -> some View {
        anchorPreference(key: TourAnchorKey.self, value: .bounds) { [id: [$0]] }
    }

    /// `tourAnchor` for an optional role — a no-op when `id` is `nil`, so call
    /// sites with a per-button optional stay one-liners.
    @ViewBuilder
    func tourAnchorIfPresent(_ id: TourHighlight?) -> some View {
        if let id { tourAnchor(id) } else { self }
    }

    /// Draw the active tour step's highlight ring over this subtree, resolving
    /// whichever `.tourAnchor` it targets. Apply once at a level that contains
    /// every taggable surface (sidebar + bottom bar + chat). Non-blocking —
    /// taps fall through to the control it rings.
    func tourHighlightLayer(_ tour: GuidedTourStore) -> some View {
        overlayPreferenceValue(TourAnchorKey.self) { anchors in
            GeometryReader { geo in
                if tour.isActive, let id = tour.wantHighlight,
                   let rect = TourHighlightOverlay.ringRect(for: id, anchors: anchors, in: geo) {
                    TourHighlightOverlay(rect: rect, bounds: geo.size)
                }
            }
            .allowsHitTesting(false)
        }
    }
}

/// The non-blocking glow ring drawn around the active step's target. A brand
/// rounded rectangle traces `rect` with a soft outer glow and a gentle
/// breathing pulse. Always rendered behind `.allowsHitTesting(false)` by the
/// host so taps fall straight through to the control underneath — the user can
/// still use what the tour is pointing at. Reduce Motion drops the pulse.
struct TourHighlightOverlay: View {
    /// Resolve `id`'s tagged bounds into one ring rect in `geo`'s space, or
    /// `nil` when nothing is tagged. Multi-anchor roles (e.g. `chatHeader`) are
    /// unioned into a single enclosing rect.
    static func ringRect(
        for id: TourHighlight,
        anchors: [TourHighlight: [Anchor<CGRect>]],
        in geo: GeometryProxy
    ) -> CGRect? {
        guard let list = anchors[id], !list.isEmpty else { return nil }
        let union = list.reduce(CGRect.null) { $0.union(geo[$1]) }
        // Keep the ring on screen. A full-width target (the whole bottom bar)
        // otherwise has its left and right strokes drawn past the edges, so it
        // reads as two loose horizontal rules rather than one enclosing ring.
        let limit = CGRect(origin: .zero, size: geo.size).insetBy(dx: inset, dy: inset)
        let clamped = union.intersection(limit)
        return clamped.isNull ? union : clamped
    }

    /// How far the ring sits outside the control it traces. Also the margin
    /// kept between a clamped ring and the screen edge, so the two agree.
    private static let inset: CGFloat = 6

    let rect: CGRect
    /// The layer's own size, so the pulse can be capped to what fits.
    let bounds: CGSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    private let cornerRadius: CGFloat = 12
    private let outset: CGFloat = -4

    var body: some View {
        // Grow by `outset`, but never past what `ringRect` already clamped to.
        let ring = rect.insetBy(dx: outset, dy: outset)
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .strokeBorder(Color.brandColor, lineWidth: 2.5)
            .shadow(color: Color.brandColor.opacity(0.6), radius: 8)
            .frame(width: ring.width, height: ring.height)
            // Pulse: enlarge then back to base. Floor is 1 (the emphasised
            // size) — the ring never shrinks below the control it rings.
            // Scale BEFORE positioning so it grows about the ring's own
            // centre; scaling after `.position` scales about the full
            // overlay centre and drags the ring up/down.
            .scaleEffect(reduceMotion ? 1 : (pulse ? peak(for: ring) : 1))
            .position(x: ring.midX, y: ring.midY)
            .animation(
                reduceMotion
                    ? nil
                    : .easeInOut(duration: 0.9).repeatForever(autoreverses: true),
                value: pulse
            )
            .onAppear { pulse = true }
    }

    /// How far the pulse may grow this ring. A ring around one bar button has
    /// room to spare; one around the whole bar is already the width of the
    /// screen, and a flat 1.08 pushed its left and right strokes off both
    /// edges — so it read as two loose horizontal rules, not a ring.
    private func peak(for ring: CGRect) -> CGFloat {
        let room = min(
            ring.width > 0 ? bounds.width / ring.width : .infinity,
            ring.height > 0 ? bounds.height / ring.height : .infinity
        )
        return max(1, min(1.08, room))
    }
}
