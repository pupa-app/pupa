import Foundation
import Testing
@testable import AGUIKit

/// What a release build is allowed to write to the device log.
///
/// Diagnostics can be switched on in a shipped app to chase a bug on a real
/// device, and every line goes out as `%{public}@` — readable by anyone who can
/// pull logs off the phone. Turn recovery is explained by structure (cursors,
/// parks, retries), never by the user's own material, so none of it may ride
/// along.
/// `.serialized`: `includesUserContent` is process-global, so a sibling
/// flipping it mid-read is a false failure.
@Suite("Logging redaction", .serialized)
struct LoggingRedactionTests {

    /// Restores the build's own default, whatever this suite did to it.
    private func withUserContent(_ allowed: Bool, _ body: () -> Void) {
        let previous = AGUIKitLog.includesUserContent
        AGUIKitLog.includesUserContent = allowed
        defer { AGUIKitLog.includesUserContent = previous }
        body()
    }

    @Test("a redactable value becomes a size when user content is off")
    func redactable_hidesContent() {
        withUserContent(false) {
            let secret = "the user's shopping list"
            let out = AGUIKitLog.redactable(secret)
            #expect(!out.contains("shopping"))
            #expect(out == "<\(secret.utf8.count)B>")
        }
        withUserContent(true) {
            #expect(AGUIKitLog.redactable("the user's shopping list")
                    == "the user's shopping list")
        }
    }

    /// A backend error can quote the prompt or a tool payload back at you.
    @Test("a run error's text is redacted with everything else")
    func runError_isRedacted() {
        let event = AgentEvent.runError(AgentEvent.RunError(message: "secret detail", code: nil))
        withUserContent(false) {
            #expect(!AGUIKitLog.shortLabel(event).contains("secret"))
        }
        withUserContent(true) {
            #expect(AGUIKitLog.shortLabel(event).contains("secret detail"))
        }
    }

    /// The default is what actually ships, so pin it rather than the override.
    @Test("user content follows the build, not a call site")
    func default_matchesTheBuild() {
        #if DEBUG
        #expect(AGUIKitLog.includesUserContent)
        #else
        #expect(!AGUIKitLog.includesUserContent, "a release build must not log the user's material")
        #endif
    }
}
