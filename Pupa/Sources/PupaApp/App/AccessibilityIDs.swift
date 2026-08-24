import Foundation

/// Stable identifiers for the anchors UI tests drive.
///
/// Accessibility *labels* are user-facing copy and change with the wording;
/// these don't. A test that queries by label is one rewrite away from the
/// swipe-guessing in `ScreenshotTests`. Add an id when a test needs to reach
/// something, not preemptively — and keep the value stable once added.
///
/// Mirrored in `PupaHostUITests`, which can't import this module.
public enum PupaID {
    public static let chatComposer = "chat.composer"
    public static let chatSend = "chat.send"
    public static let chatToggle = "chat.toggle"

    /// Per-component; `component(_:)` builds the id from the component's own
    /// stable id, so a test can wait for exactly the one a tool created.
    public static func component(_ id: String) -> String { "canvas.component.\(id)" }
}
