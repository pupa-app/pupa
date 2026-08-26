import AGUIKit
import SwiftUI

/// Machine-readable turn state for a driven launch, carried in one
/// accessibility value so a UI test can read it across the sandbox boundary
/// (the runner and the app don't share one, so a trace file is unreachable).
///
/// Mounted only under `-PupaStorageRoot`. Deliberately 1x1 rather than
/// zero-sized or `.hidden()`: SwiftUI prunes those from the accessibility
/// tree entirely. For the same reason it must not sit in a lazy container,
/// and must not be conditioned on the chat panel being open.
///
/// The accessibility value is the only thing this view does. The unified-log
/// series comes off the event path in `ChatViewModel`, not from here: this
/// view reads `appliedEventSeq`, so it re-renders on every streamed token, and
/// logging from that put a write and a root-view invalidation on the main
/// thread per token.
struct DebugProbeView: View {
    let json: String

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .allowsHitTesting(false)
            .accessibilityElement(children: .ignore)
            .accessibilityIdentifier(PupaID.debugTurnState)
            .accessibilityValue(json)
    }
}
