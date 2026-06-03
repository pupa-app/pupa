import CoreGraphics
import Testing
@testable import PupaApp

/// Tests the pure sizing math behind the floating chat card
/// (`ChatCardSizing`). The interesting behaviour is keyboard avoidance: the
/// view subtracts the keyboard overlap from the container before sizing, so
/// these tests feed in already-reduced containers and assert the card always
/// fits — the regression that left the composer behind the keyboard in
/// landscape. The SwiftUI plumbing in `ChatOverlay` is exercised by hand under
/// `make mac-demo`.
@Suite("Chat card sizing")
struct ChatCardSizingTests {
    let sizing = ChatCardSizing()

    // MARK: - Roomy container (keyboard down)

    @Test("Default size is the configured fraction of a large container")
    func defaultSizeUsesFraction() {
        let container = CGSize(width: 1200, height: 800)
        let size = sizing.defaultSize(in: container)
        #expect(size.width == 1200 * sizing.widthFraction)
        #expect(size.height == 800 * sizing.heightFraction)
    }

    @Test("Default size never drops below the minimum when there is room")
    func defaultSizeRespectsMinimum() {
        // 0.5 * 700 = 350 width, 0.6 * 640 = 384 height — width would fall
        // below the 320 floor only if the container were tiny; here both clamp
        // up to at least the minimum.
        let container = CGSize(width: 620, height: 560)
        let size = sizing.defaultSize(in: container)
        #expect(size.width >= sizing.minSize.width)
        #expect(size.height >= sizing.minSize.height)
    }

    // MARK: - Squeezed container (keyboard up)

    @Test("Card shrinks below its minimum height to fit a keyboard-squeezed container")
    func cardShrinksBelowMinimumHeight() {
        // Landscape-ish: plenty of width, but the keyboard has eaten the height
        // down to ~150pt of usable space — well under the 360pt min.
        let squeezed = CGSize(width: 700, height: 150)
        let size = sizing.resolvedSize(user: nil, in: squeezed)
        // The whole point: it must NOT stay 360 (which overflowed downward and
        // hid the composer) — it fits within the available height.
        #expect(size.height < sizing.minSize.height)
        #expect(size.height <= squeezed.height - sizing.edgePadding * 2)
    }

    @Test("Resolved size always fits within the container's padded bounds")
    func resolvedSizeNeverOverflows() {
        let containers = [
            CGSize(width: 400, height: 900),   // narrow & tall (portrait phone)
            CGSize(width: 900, height: 380),   // wide & short (landscape phone)
            CGSize(width: 1366, height: 1024), // iPad
            CGSize(width: 360, height: 120),   // extreme keyboard squeeze
        ]
        for container in containers {
            let size = sizing.resolvedSize(user: nil, in: container)
            #expect(size.height <= max(0, container.height - sizing.edgePadding * 2) + 0.001)
            // Width keeps its min floor (may slightly exceed a very narrow
            // container by design), but never exceeds the padded width once the
            // container is at least min-wide.
            if container.width >= sizing.minSize.width + sizing.edgePadding * 2 {
                #expect(size.width <= container.width - sizing.edgePadding * 2 + 0.001)
            }
        }
    }

    // MARK: - User-dragged size

    @Test("A user-dragged size is clamped back into a shrunk container")
    func userSizeClampedToContainer() {
        // User had dragged the card large; then the keyboard appears and the
        // container shrinks. The oversized user size must clamp down to fit.
        let dragged = CGSize(width: 600, height: 700)
        let squeezed = CGSize(width: 700, height: 200)
        let size = sizing.resolvedSize(user: dragged, in: squeezed)
        #expect(size.height <= squeezed.height - sizing.edgePadding * 2)
        #expect(size.width <= squeezed.width - sizing.edgePadding * 2)
    }

    @Test("A user-dragged size within bounds is preserved")
    func userSizePreservedWhenItFits() {
        let dragged = CGSize(width: 500, height: 500)
        let container = CGSize(width: 1200, height: 800)
        let size = sizing.resolvedSize(user: dragged, in: container)
        #expect(size == dragged)
    }
}
