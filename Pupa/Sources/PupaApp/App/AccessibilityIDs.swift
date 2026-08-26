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
    /// Drawer toggle in the top-left toolbar. The drawer covers the bottom
    /// bar while open, so a test has to close it before anything down there
    /// is hittable.
    public static let sidebarToggle = "sidebar.toggle"
    /// The dropped-turn banner's Continue button.
    public static let chatContinue = "chat.continue"
    /// Machine-readable turn state, mounted only on a driven launch. See
    /// `DebugProbeView` — this is how a UI test reads recovery state across
    /// the sandbox boundary.
    public static let debugTurnState = "debug.turnState"

    /// Per-MyApp drawer row. Selecting one is how a test dismisses the drawer
    /// — its own bottom bar sits on top of the main one, so nothing down
    /// there is reachable while it is open.
    public static func sidebarMyApp(_ id: UUID) -> String { "sidebar.myApp.\(id)" }

    /// Per-component; `component(_:)` builds the id from the component's own
    /// stable id, so a test can wait for exactly the one a tool created.
    public static func component(_ id: String) -> String { "canvas.component.\(id)" }
}
