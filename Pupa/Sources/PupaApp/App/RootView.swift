import SwiftUI

/// Top-level coordinator that layers the launch splash and first-install
/// onboarding over the real app.
///
/// Layout is a `ZStack`: `AppView` is always built underneath (so the seeded
/// example is ready the instant onboarding dismisses), the onboarding flow
/// covers it on first install, and the splash sits on top every cold launch.
///
/// State:
///   - `showSplash` is view state, so the splash plays on every launch.
///   - `onboardingCompleted` is persisted, so the flow runs only once.
///   - `settings` is owned here and injected into both `AppView` and
///     `OnboardingFlowView` so a backend paired during onboarding is the same
///     live `SettingsStore` the app reads — no second instance, no divergence.
public struct RootView: View {
    @State private var settings = SettingsStore()
    @State private var showSplash = true
    @AppStorage(OnboardingKeys.completed) private var onboardingCompleted = false

    public init() {
        // Migration: users who already configured the app before this feature
        // shipped shouldn't have onboarding replayed on update. A fresh install
        // has no persisted settings snapshot yet (SettingsStore only writes on
        // first mutation), so its absence is a reliable "new user" signal.
        let defaults = UserDefaults.standard
        if defaults.object(forKey: OnboardingKeys.completed) == nil {
            let isExistingUser = defaults.data(forKey: SettingsStore.storageKey) != nil
            defaults.set(isExistingUser, forKey: OnboardingKeys.completed)
        }
    }

    public var body: some View {
        ZStack {
            AppView(settings: settings)

            if !onboardingCompleted {
                OnboardingFlowView(settings: settings) {
                    withAnimation(.easeInOut(duration: 0.4)) {
                        onboardingCompleted = true
                    }
                }
                .transition(.opacity)
                .zIndex(1)
            }

            if showSplash {
                SplashView {
                    withAnimation(.easeInOut(duration: 0.4)) {
                        showSplash = false
                    }
                }
                .transition(.opacity)
                .zIndex(2)
            }
        }
    }
}
