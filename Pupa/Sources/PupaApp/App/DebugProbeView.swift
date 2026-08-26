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
/// The value is the *primary* channel but not the only one — a backgrounded
/// app has no accessibility tree to query, so every change is also written to
/// the unified log, which keeps reporting while the app is away.
struct DebugProbeView: View {
    let json: String

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .allowsHitTesting(false)
            .accessibilityElement(children: .ignore)
            .accessibilityIdentifier(PupaID.debugTurnState)
            .accessibilityValue(json)
            .onChange(of: json, initial: true) { _, value in
                AGUIKitLog.probe(value)
            }
    }
}
