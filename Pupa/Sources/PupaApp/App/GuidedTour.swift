import Foundation

/// Where a coach card sits relative to the surface it's explaining. The tour
/// only needs two anchors — content at the top or bottom edge of the detail
/// pane — and never pixel-anchors to a specific control, so it survives a UI
/// redesign.
enum CardPlacement {
    case top, bottom
}

/// The UI mutation a tour step asks the host views to perform when it becomes
/// active. Pure *intent*: every case targets the app's stable routing enums
/// (`SidebarSelection`) or a couple of boolean flags — never view geometry —
/// so a future redesign still lands the tour on the right surface.
/// `AppView.applyTourStep()` translates each case into concrete `selection` /
/// sheet / chat state.
enum TourEffect: Equatable {
    /// No navigation — the card just narrates (the welcome step).
    case none
    /// Open the Settings sheet.
    case openSettings
    /// Route the sidebar selection (and chat scope, via `dispatchSelection`).
    case navigate(SidebarSelection)
    /// Expand the chat overlay, optionally pre-filling the composer.
    case openChat(prefill: String?)
}

/// One stop on the guided tour. Pure data — reorder / add / remove entries in
/// `TourContent` without touching any view. The stable string `id` lets
/// persistence or telemetry survive a reordering of the step list.
struct TourStep: Identifiable, Equatable {
    let id: String
    let title: String
    let body: String
    let placement: CardPlacement
    let effect: TourEffect
}

/// All step copy + effects in one place so the tour is easy to edit, reorder,
/// or localize without touching view code. `steps(activeMyAppId:isPaired:)`
/// binds the route enums to the live active myApp and adapts the chat copy to
/// whether a backend is paired (an unpaired user can't actually send, so the
/// prompt is framed as a preview rather than a call to action).
enum TourContent {
    static func steps(activeMyAppId: UUID, isPaired: Bool) -> [TourStep] {
        [
            TourStep(
                id: "welcome",
                title: "Welcome to Pupa",
                body: "Pupa is a workspace your agent can see and edit alongside you. "
                    + "This quick tour walks through the main surfaces — about a minute. "
                    + "Tap Next to begin.",
                placement: .bottom,
                effect: .none
            ),
            TourStep(
                id: "settings",
                title: "Settings",
                body: "Point Pupa at your backend, choose which tools the agent may call, "
                    + "and tune the agent-to-agent guardrails. Everything here takes effect "
                    + "on your next message.",
                placement: .bottom,
                effect: .openSettings
            ),
            TourStep(
                id: "myapp",
                title: "A MyApp",
                body: "Each MyApp is a canvas of components — trackers, calendars, "
                    + "checklists — that the agent reads and edits as you chat. This is one "
                    + "of your example apps.",
                placement: .top,
                effect: .navigate(.myAppHome(activeMyAppId))
            ),
            TourStep(
                id: "chat",
                title: "Chat",
                body: isPaired
                    ? "This is your agent. Ask it to add, change, or explain anything on the "
                        + "canvas — we've parked an example message you can send with one tap."
                    : "This is your agent. Once you connect a backend it can add, change, and "
                        + "explain anything on the canvas. We've parked an example message in "
                        + "the composer to show the idea.",
                placement: .top,
                effect: .openChat(prefill: "Add a prep task for my Friday interview")
            ),
            TourStep(
                id: "orchestrator",
                title: "Orchestrator",
                body: "The orchestrator is a meta-agent that spans every MyApp. Use it for "
                    + "cross-app tasks and shared notes that don't belong to a single canvas.",
                placement: .top,
                effect: .navigate(.orchestrator)
            ),
            TourStep(
                id: "agent-settings",
                title: "Agent settings",
                body: "Every MyApp has its own agent. Here you can see the tools it can call, "
                    + "open its AGENTS.md persona file, and review the components it manages.",
                placement: .top,
                effect: .navigate(.myAppAgentDetail(activeMyAppId, agentId: AgentRegistry.mainAgentId))
            ),
            TourStep(
                id: "slash-commands",
                title: "Slash commands",
                body: "Type \"/\" in the composer for quick commands — /help lists them all, "
                    + "/tools shows what the agent can do, and /reset starts a fresh "
                    + "conversation.",
                placement: .top,
                effect: .openChat(prefill: "/")
            ),
        ]
    }
}

/// Shared, app-wide store driving the interactive guided tour. Mirrors the
/// `OnboardingHandoff.shared` / `OtherInteractionStore.shared` singleton
/// pattern: a single `@Observable` instance holds the step list + current
/// index and exposes the *desired UI state* for the active step. Host views
/// reconcile to it declaratively (`AppView.applyTourStep()` for navigation;
/// `.onChange` on the intent flags in `MyAppSidebarView` / `ChatOverlay` /
/// `ChatPanel` for the sheet + chat surfaces).
///
/// The tour drives the app through its stable routing layer, never view
/// geometry, so it keeps working through future UI redesigns.
@MainActor
@Observable
final class GuidedTourStore {
    static let shared = GuidedTourStore()

    /// Whether the tour is on screen. Gates the coach card in `AppView` /
    /// `SettingsSheet` and the "start the tour" check in `AppView`.
    private(set) var isActive: Bool = false
    /// Index of the active step within `steps`. Bounds-checked by `next`/`back`.
    private(set) var index: Int = 0
    /// The step list for this run — built by `start` from `TourContent` against
    /// the live active myApp. Empty until the tour starts.
    private(set) var steps: [TourStep] = []

    /// Intent flags reconciled by host views. `AppView.applyTourStep()` owns
    /// writing these per step (setting the relevant ones, clearing the rest) so
    /// each step fully defines the intended UI state and transitions stay
    /// deterministic.
    var wantSettingsOpen: Bool = false
    var wantChatOpen: Bool = false
    var chatPrefill: String?

    /// `UserDefaults` the completion flag is written to. Injectable so tests can
    /// run hermetically against an isolated suite; `.shared` uses `.standard`,
    /// the same suite `@AppStorage(OnboardingKeys.tourCompleted)` reads.
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The active step, or `nil` when the index is out of range (tour inactive
    /// or empty step list).
    var currentStep: TourStep? {
        steps.indices.contains(index) ? steps[index] : nil
    }

    var isFirstStep: Bool { index == 0 }
    var isLastStep: Bool { index >= steps.count - 1 }

    /// The selection a `.navigate` step targets, or `nil` for other effects.
    /// Exposed for host views / tests that want the desired route without
    /// re-matching the effect enum.
    var desiredSelection: SidebarSelection? {
        if case .navigate(let sel) = currentStep?.effect { return sel }
        return nil
    }

    /// Begin the tour from the first step. Rebuilds the step list against the
    /// current active myApp + pairing state so the copy and route targets are
    /// fresh each run (this is also the replay entry point from Settings).
    func start(activeMyAppId: UUID, isPaired: Bool) {
        steps = TourContent.steps(activeMyAppId: activeMyAppId, isPaired: isPaired)
        guard !steps.isEmpty else { return }
        index = 0
        clearFlags()
        isActive = true
    }

    /// Advance to the next step, or finish the tour when already on the last.
    func next() {
        guard isActive else { return }
        if index >= steps.count - 1 {
            finish()
        } else {
            index += 1
        }
    }

    /// Step back one, clamped at the first step.
    func back() {
        guard isActive, index > 0 else { return }
        index -= 1
    }

    /// Finish the tour: persist the completed flag (so it never replays) and
    /// tear down. Reaching the end via `next()` routes here too.
    func finish() {
        complete()
    }

    /// Dismiss the tour early. Counts as "seen" — same persistence as `finish`
    /// so it doesn't replay on the next launch; kept as a separate entry point
    /// for clarity and future telemetry.
    func skip() {
        complete()
    }

    private func complete() {
        defaults.set(true, forKey: OnboardingKeys.tourCompleted)
        isActive = false
        index = 0
        clearFlags()
    }

    private func clearFlags() {
        wantSettingsOpen = false
        wantChatOpen = false
        chatPrefill = nil
    }
}
