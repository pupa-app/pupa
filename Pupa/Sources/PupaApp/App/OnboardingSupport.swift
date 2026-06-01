import Foundation

/// UserDefaults keys backing the first-install onboarding flow. Stored as
/// bare booleans via `@AppStorage` (same `UserDefaults.standard` suite the
/// `SettingsStore` snapshot lives in) rather than a JSON snapshot — there are
/// only two flags and both are read from more than one view, so plain keys
/// keep the wiring obvious.
enum OnboardingKeys {
    /// Set once the user finishes (or skips through) onboarding. Gates the
    /// whole `OnboardingFlowView`. Absent on a fresh install; `RootView`
    /// migrates pre-existing users to `true` so an app update doesn't replay
    /// onboarding for people who already configured the app.
    static let completed = "pupa.onboarding.completed"
    /// Set when the user taps "Skip for now" on the backend step without
    /// pairing. Drives the dismissible "connect your backend" reminder banner
    /// in `AppView` until a backend is paired (or the banner is dismissed).
    static let backendSkipped = "pupa.onboarding.backendSkipped"
}

/// One-shot channel from onboarding to the chat composer. When onboarding
/// completes with a paired backend it parks a suggested first message here;
/// the first `ChatPanel` to appear consumes it into its draft so the user's
/// first action is a single tap away. Consume-once semantics mean ordinary
/// chat opens (after the value is taken) are unaffected.
///
/// Mirrors the `OtherInteractionStore.shared` pattern already used in
/// `ChatPanel` for transient UI state that must survive `LazyVStack` recycling
/// without threading a binding through `ChatOverlay` → `ConversationPager`.
@MainActor
final class OnboardingHandoff {
    static let shared = OnboardingHandoff()

    /// The suggested first message, or `nil` once consumed / never set.
    var suggestedPrompt: String?

    private init() {}

    /// Returns the pending prompt and clears it, so only the first reader wins.
    func consumeSuggestedPrompt() -> String? {
        defer { suggestedPrompt = nil }
        return suggestedPrompt
    }
}
