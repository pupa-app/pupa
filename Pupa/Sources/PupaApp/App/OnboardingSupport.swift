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
    /// Set once the user finishes or skips the interactive guided tour
    /// (`GuidedTourStore`). Gates the auto-start in `AppView` so the tour runs
    /// exactly once. Absent on a fresh install; `OnboardingMigration` back-fills
    /// it `true` for pre-existing users so an app update never replays the tour.
    static let tourCompleted = "pupa.tour.completed"
}

/// One-time back-fill of the onboarding / tour flags for users who installed
/// before these features shipped. Extracted from `RootView.init` so it can be
/// unit-tested against an isolated `UserDefaults` suite.
enum OnboardingMigration {
    /// Migrate `defaults` in place. Runs only when `completed` is absent — a
    /// true fresh install or a pre-feature user's first launch. A pre-existing
    /// user (detected by a persisted `SettingsStore` snapshot) is marked as
    /// having completed *both* onboarding and the tour, so neither replays on
    /// update. A genuine fresh install leaves both flags `false` so onboarding
    /// runs and then hands off to the tour. Idempotent.
    @MainActor
    static func migrate(
        defaults: UserDefaults,
        settingsKey: String = SettingsStore.storageKey
    ) {
        guard defaults.object(forKey: OnboardingKeys.completed) == nil else { return }
        let isExistingUser = defaults.data(forKey: settingsKey) != nil
        defaults.set(isExistingUser, forKey: OnboardingKeys.completed)
        // Existing users have already configured the app; don't drop them into
        // the tour on their next launch. New installs leave this false so the
        // onboarding → tour sequence runs once.
        if isExistingUser {
            defaults.set(true, forKey: OnboardingKeys.tourCompleted)
        }
    }
}

/// One-shot channel from onboarding to the chat composer. When onboarding
/// completes with a paired backend it parks a suggested first message here;
/// the first `ChatPanel` to appear consumes it into its draft so the user's
/// first action is a single tap away. Consume-once semantics mean ordinary
/// chat opens (after the value is taken) are unaffected.
///
/// Holds transient UI state outside SwiftUI so it survives `LazyVStack`
/// recycling, without threading a binding through `ChatOverlay` →
/// `ConversationPager`. Note the limit: this type is not `@Observable`, so
/// writing to it does not by itself invalidate a view — only use it for state
/// read alongside an observable change (the trap that made `ask_user_questions`
/// cards ignore the first "Other…" tap).
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
