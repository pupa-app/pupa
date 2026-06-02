import SwiftUI

/// First-install onboarding: a marketing carousel (value slides) followed by a
/// live backend-connect step, then a hand-off into the seeded example with a
/// suggested first message. Presented above `AppView` by `RootView` and shown
/// only while `OnboardingKeys.completed` is `false`.
///
/// Cross-platform note: SwiftUI's paging `TabView` style is iOS-only, so the
/// carousel is a hand-rolled `page`-index + transition rather than a paged
/// `TabView` — this compiles and behaves identically on the macOS demo target.
///
/// The backend step reuses the production pairing UI (`BackendEditSheet` + the
/// `BackendPairingClient` / Keychain stack behind it) rather than duplicating
/// any pairing logic; it operates on the same shared `SettingsStore` instance
/// that `AppView` uses, so a pair completed here is live immediately.
public struct OnboardingFlowView: View {
    @Bindable var settings: SettingsStore
    /// Called when onboarding is done (finished or skipped through). `RootView`
    /// flips `OnboardingKeys.completed` in response.
    var onFinish: () -> Void

    @State private var page = 0
    @State private var presentingPairing = false
    @AppStorage(OnboardingKeys.backendSkipped) private var backendSkipped = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let slides = OnboardingContent.valueSlides
    private var backendPage: Int { slides.count }
    private var totalPages: Int { slides.count + 1 }
    private var onBackendPage: Bool { page == backendPage }
    /// Read `activeBackend` first so the view observes `backends` and re-renders
    /// when pairing completes — `isPaired` alone reads the Keychain and would
    /// register no observation dependency.
    private var isPaired: Bool {
        let active = settings.activeBackend
        return settings.isPaired(active.id)
    }

    public init(settings: SettingsStore, onFinish: @escaping () -> Void) {
        self.settings = settings
        self.onFinish = onFinish
    }

    public var body: some View {
        ZStack {
            // Opaque — fully covers the AppView built underneath in RootView.
            Color.cardBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                topBar
                Spacer(minLength: 12)
                slideContent
                    .frame(maxWidth: 520)
                    .padding(.horizontal, 28)
                Spacer(minLength: 12)
                PageDots(count: totalPages, current: page)
                    .padding(.bottom, 20)
                footer
                    .frame(maxWidth: 520)
                    .padding(.horizontal, 28)
                    .padding(.bottom, 28)
            }
        }
        .sheet(isPresented: $presentingPairing) { pairingSheet }
    }

    // MARK: - Top bar

    @ViewBuilder
    private var topBar: some View {
        HStack {
            Spacer()
            if !onBackendPage {
                Button("Skip") { goToBackend() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .padding(.trailing, 4)
            }
        }
        .frame(height: 28)
        .padding(.horizontal, 20)
        .padding(.top, 8)
    }

    // MARK: - Slides

    @ViewBuilder
    private var slideContent: some View {
        ZStack {
            if onBackendPage {
                backendSlide
                    .id("backend")
                    .transition(slideTransition)
            } else {
                OnboardingSlide(content: slides[page])
                    .id(page)
                    .transition(slideTransition)
            }
        }
    }

    private var slideTransition: AnyTransition {
        if reduceMotion { return .opacity }
        return .asymmetric(
            insertion: .move(edge: .trailing).combined(with: .opacity),
            removal: .move(edge: .leading).combined(with: .opacity)
        )
    }

    private var backendSlide: some View {
        VStack(spacing: 24) {
            OnboardingArtView(art: .logo)
                .frame(height: 200)
            VStack(spacing: 12) {
                Text(isPaired ? "You're all set" : "Bring it to life")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .multilineTextAlignment(.center)
                if isPaired {
                    Label("Backend connected", systemImage: "link.circle.fill")
                        .foregroundStyle(.green)
                        .font(.headline)
                    Text("Your agent is ready. Open the chat bubble and ask it anything.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Pair your Pupa backend to power the agent. You can do this now, or later from Settings.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: - Footer buttons

    @ViewBuilder
    private var footer: some View {
        if onBackendPage {
            VStack(spacing: 12) {
                if isPaired {
                    primaryButton("Start using Pupa") { finish() }
                } else {
                    primaryButton("Connect backend", icon: "link") { presentingPairing = true }
                    Button("Skip for now") {
                        backendSkipped = true
                        finish()
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }
        } else {
            primaryButton("Continue") { advance() }
        }
    }

    private func primaryButton(_ title: String, icon: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let icon { Image(systemName: icon) }
                Text(title).fontWeight(.semibold)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .tint(.orchestratorColor)
    }

    // MARK: - Pairing sheet (reuses production BackendEditSheet)

    private var pairingSheet: some View {
        let entry = settings.activeBackend
        return BackendEditSheet(
            title: "Connect backend",
            initialEntry: entry,
            onSave: { updated in
                settings.updateBackend(
                    entry.id,
                    label: updated.label,
                    url: updated.url,
                    certFingerprint: .some(updated.certFingerprint)
                )
                presentingPairing = false
            },
            onDelete: nil,
            onCancel: { presentingPairing = false },
            settings: settings
        )
    }

    // MARK: - Navigation

    private func advance() {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.3)) {
            page = min(page + 1, backendPage)
        }
    }

    private func goToBackend() {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.3)) {
            page = backendPage
        }
    }

    private func finish() {
        // Only pre-seed a first message when chatting will actually work —
        // a prompt the user can't send (no backend) is a dead end, not a win.
        if isPaired {
            OnboardingHandoff.shared.suggestedPrompt = "Add a prep task for my Friday interview"
        }
        onFinish()
    }
}
