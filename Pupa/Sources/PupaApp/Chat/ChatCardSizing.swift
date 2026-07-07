import CoreGraphics

/// Pure sizing math for the floating `ChatOverlay` card, extracted from the
/// view so the keyboard-avoidance invariants can be unit-tested without
/// standing up SwiftUI (the view plumbing — gestures, transitions, keyboard
/// observers — is still exercised by hand under `make mac-demo`).
///
/// The card is bottom-anchored, so the composer lives at its bottom edge. The
/// view feeds in a container size **already reduced by any keyboard overlap**;
/// the key invariant here is that the card never exceeds that container, even
/// when doing so means shrinking below `minSize.height` — otherwise the card
/// overflows downward and the composer ends up behind the keyboard (the
/// landscape bug this replaced).
struct ChatCardSizing {
    var minSize: CGSize = CGSize(width: 320, height: 360)
    var edgePadding: CGFloat = 16
    // macOS is a floating side card over a wide window, so it takes a smaller
    // slice and caps out — a 50% slice pinned bottom-right buried the canvas.
    // iOS fills more of the phone screen and needs no ceiling.
    #if os(macOS)
    var widthFraction: CGFloat = 0.34
    var heightFraction: CGFloat = 0.62
    var maxDefault: CGSize? = CGSize(width: 480, height: 760)
    #else
    var widthFraction: CGFloat = 0.5
    var heightFraction: CGFloat = 0.6
    var maxDefault: CGSize? = nil
    #endif

    /// Default card size: a fraction of the container, capped on wide screens,
    /// then clamped to fit.
    func defaultSize(in container: CGSize) -> CGSize {
        var w = container.width * widthFraction
        var h = container.height * heightFraction
        if let cap = maxDefault {
            w = min(w, cap.width)
            h = min(h, cap.height)
        }
        return clamp(CGSize(width: w, height: h), in: container)
    }

    /// On-screen size, preferring a user-dragged size when one exists.
    func resolvedSize(user: CGSize?, in container: CGSize) -> CGSize {
        clamp(user ?? defaultSize(in: container), in: container)
    }

    /// Clamp `size` into the container. The ceiling is the container minus
    /// edge padding on each side. Width keeps a `minSize.width` floor (the card
    /// is allowed to be a touch wider than a narrow container). Height's floor
    /// is `minSize.height` **only when it fits** — a shorter container lowers
    /// the floor so the card shrinks rather than overflowing past the bottom.
    func clamp(_ size: CGSize, in container: CGSize) -> CGSize {
        let maxW = max(minSize.width, container.width - edgePadding * 2)
        let maxH = max(0, container.height - edgePadding * 2)
        let minH = min(minSize.height, maxH)
        return CGSize(
            width: max(minSize.width, min(maxW, size.width)),
            height: max(minH, min(maxH, size.height))
        )
    }
}
