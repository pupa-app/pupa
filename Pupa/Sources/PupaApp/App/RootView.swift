import AGUIKit
import SwiftUI

/// Top-level coordinator that layers the launch splash and first-install
/// onboarding over the real app.
///
/// The launch is a **strict two-phase sequence**, not a simultaneous stack:
/// the splash plays alone and fully fades out *first*, and only once it is gone
/// does the next surface fade in — the onboarding flow on first install, or the
/// app itself for an existing user. The splash and onboarding are therefore
/// never on screen at the same time, so there is no cross-dissolve between two
/// different layouts. `AppView` is still always built underneath so the seeded
/// example is ready the instant onboarding dismisses.
///
/// State:
///   - `phase` drives the sequence; it starts at `.splash` on every launch, so
///     the splash plays every cold launch.
///   - `onboardingCompleted` is persisted, so the flow runs only once.
///   - `settings` is owned here and injected into both `AppView` and
///     `OnboardingFlowView` so a backend paired during onboarding is the same
///     live `SettingsStore` the app reads — no second instance, no divergence.
public struct RootView: View {
    /// Launch sequence phases, advanced strictly in order:
    ///   - `.splash`       — only the splash is on screen.
    ///   - `.transitioning`— the splash has been told to leave and is fading
    ///                       out; the next surface has not started fading in yet.
    ///   - `.content`      — the onboarding (first install) or bare app fades in.
    /// Splitting `.transitioning` out from `.content` is what makes the handoff
    /// a sequence rather than a cross-dissolve: the splash's fade-out and the
    /// content's fade-in run back-to-back, never simultaneously.
    private enum Phase { case splash, transitioning, content }

    /// Launch arguments are applied here — the first thing that builds any
    /// store, since all three entry points build a `RootView` and nothing may
    /// construct a store before `PupaStorage.overrideRoot` is set.
    ///
    /// Not the first thing to run, though: `PupaAppDelegate` fires at the
    /// platform launch hook, before this. Nothing on that path may touch
    /// storage — it only installs the notification delegate.
    private static let launch = LaunchOptions.apply()

    @State private var settings = RootView.makeSettings()
    @State private var phase: Phase = .splash
    @AppStorage(OnboardingKeys.completed) private var onboardingCompleted = false

    /// Diagnostics are off in a release build; this is how a user chasing a
    /// bug on their own device turns the trace on. Applied before any session
    /// exists, so a turn started from a cold launch is covered.
    private static let diagnostics: Void = {
        // Only when the user has actually chosen. Seeding the key from this
        // build's default would leave a debug run's `true` behind for the next
        // release build in the same container — diagnostics silently on.
        guard UserDefaults.standard.object(forKey: DiagnosticsKeys.enabled) != nil
        else { return }
        AGUIKitLog.enabled = UserDefaults.standard.bool(forKey: DiagnosticsKeys.enabled)
    }()

    private static func makeSettings() -> SettingsStore {
        _ = diagnostics
        // Touching `launch` forces the launch arguments to apply first.
        guard let token = launch.backendToken else {
            return SettingsStore(backendURL: launch.backendURL, harnessID: launch.harnessID)
        }
        // A driven launch reaches a paired backend without the Keychain, which
        // a UI test can't seed. The backend's UUID only exists once the store
        // is built, so the token goes in after.
        let credentials = InMemoryCredentialStore()
        let settings = SettingsStore(
            backendURL: launch.backendURL,
            harnessID: launch.harnessID,
            credentials: credentials)
        try? credentials.setToken(token, for: settings.activeBackend.id)
        return settings
    }

    public init() {
        // Migration: users who already configured the app before onboarding +
        // the guided tour shipped shouldn't have either replayed on update. A
        // fresh install has no persisted settings snapshot yet (SettingsStore
        // only writes on first mutation), so its absence is a reliable "new
        // user" signal. See `OnboardingMigration` for the back-fill rules.
        OnboardingMigration.migrate(defaults: .standard)
    }

    public var body: some View {
        ZStack {
            AppView(settings: settings)

            // First-install bridge: a calm, opaque surface (the onboarding's own
            // background) that covers the app for the whole launch on first run.
            // It is mounted from the very start — hidden under the opaque splash
            // during `.splash` — so it is already fully opaque when the splash
            // begins fading. The splash therefore dissolves onto this neutral
            // surface instead of the seeded canvas, with no app peeking through
            // mid-fade. `.transition(.identity)` keeps it from fading in or out,
            // so it never momentarily uncovers the app. Existing users skip the
            // bridge so the splash hands straight off to their app.
            if !onboardingCompleted {
                Color.cardBackground
                    .ignoresSafeArea()
                    .transition(.identity)
                    .zIndex(0.5)
            }

            // Onboarding only mounts in `.content`, i.e. after the splash has
            // fully faded out, so it never shows through the splash. Fades in
            // on its own over the bridge.
            if phase == .content && !onboardingCompleted {
                OnboardingFlowView(settings: settings) {
                    withAnimation(.easeInOut(duration: 0.4)) {
                        onboardingCompleted = true
                    }
                }
                .transition(.opacity)
                .zIndex(1)
            }

            if phase == .splash {
                SplashView { advancePastSplash() }
                    .transition(.opacity)
                    .zIndex(2)
            }
        }
    }

    /// Hands off from the splash to the content as a strict sequence: fade the
    /// splash fully out (`.transitioning`), then — only once that animation has
    /// completed — fade the next surface in (`.content`). Running the two fades
    /// back-to-back rather than together is what stops the splash and onboarding
    /// from ever blending on screen. Idempotent: re-entry while already past the
    /// splash is a no-op.
    private func advancePastSplash() {
        guard phase == .splash else { return }
        withAnimation(.easeInOut(duration: 0.4)) {
            phase = .transitioning
        } completion: {
            withAnimation(.easeInOut(duration: 0.4)) {
                phase = .content
            }
        }
    }
}
