import Foundation

/// Where a coach card sits relative to the surface it's explaining. The tour
/// only needs two anchors — content at the top or bottom edge of the detail
/// pane — and never pixel-anchors to a specific control, so it survives a UI
/// redesign.
enum CardPlacement {
    case top, bottom
}

/// Which page inside the Settings sheet a tour step lands on. `.root` shows the
/// category list (so the step can describe the entries); `.backend`, `.sharing`
/// and `.examples` deep-link straight to those screens. Mirrors a subset of
/// `SettingsSheet`'s internal navigation.
enum TourSettingsPage: Equatable {
    case root
    case backend
    case sharing
    case examples
    case account
}

/// One stop on the guided tour. Pure data — reorder / add / remove entries in
/// `TourContent` without touching any view. The stable string `id` lets
/// persistence or telemetry survive a reordering of the step list.
///
/// Effects are **composable, independent intents** (a step may navigate *and*
/// open the chat with a prefill) rather than a single mutually-exclusive case —
/// every field targets the app's stable routing layer (`SidebarSelection`, a
/// settings page, a couple of booleans), never view geometry, so a redesign
/// still lands the tour on the right surface. `AppView.applyTourStep()`
/// translates them into concrete `selection` / sidebar / sheet / chat state.
struct TourStep: Identifiable, Equatable {
    let id: String
    let title: String
    let body: String
    let placement: CardPlacement
    /// Sidebar route to select when this step activates (drives `selection`
    /// and, via `dispatchSelection`, the chat scope). `nil` leaves the current
    /// selection in place.
    var selection: SidebarSelection?
    /// Open the slide-in sidebar menu (iOS) so the user sees the app's
    /// navigation. No-op on macOS, where the sidebar is always visible.
    var opensSidebar: Bool
    /// Open the Settings sheet at this page. `nil` keeps it closed.
    var settingsPage: TourSettingsPage?
    /// Expand the chat overlay for this step.
    var opensChat: Bool
    /// Pre-fill the chat composer (only meaningful with `opensChat`). "/"
    /// surfaces the live `SlashCommandPalette`.
    var chatPrefill: String?
    /// Ring this control while the step is active (the bottom-bar button it's
    /// describing). `nil` leaves no highlight. Resolved to live bounds by
    /// `TourHighlightOverlay` via the `.tourAnchor` tags, never pixel-pinned.
    var highlight: TourHighlight?

    init(
        id: String,
        title: String,
        body: String,
        placement: CardPlacement,
        selection: SidebarSelection? = nil,
        opensSidebar: Bool = false,
        settingsPage: TourSettingsPage? = nil,
        opensChat: Bool = false,
        chatPrefill: String? = nil,
        highlight: TourHighlight? = nil
    ) {
        self.id = id
        self.title = title
        self.body = body
        self.placement = placement
        self.selection = selection
        self.opensSidebar = opensSidebar
        self.settingsPage = settingsPage
        self.opensChat = opensChat
        self.chatPrefill = chatPrefill
        self.highlight = highlight
    }
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
                body: "Pupa is a workspace your agent can see and edit alongside you. This "
                    + "is your menu — your MyApps, the orchestrator, and Settings all live "
                    + "here. The tour takes about a minute; tap Next to begin.",
                placement: .bottom,
                opensSidebar: true
            ),
            TourStep(
                id: "settings-overview",
                title: "Settings",
                body: "Settings is where you wire Pupa up. Like backend pairing, Tools "
                    + "(which tools/permissions agents have), "
                    + "Notifications, and Examples. Let's start with Backend.",
                placement: .bottom,
                settingsPage: .root
            ),
            TourStep(
                id: "settings-backend",
                title: "Settings · Backend",
                body: "Point Pupa at your backend and pair it here. Until you do, the agent "
                    + "can't run as the LLM/Agent runs there. If you do not have a QR code already, "
                    + "find the backend installation [here](https://github.com/pupa-app/pupa-backend).",
                placement: .bottom,
                settingsPage: .backend
            ),
            TourStep(
                id: "myapp-home",
                title: "Home",
                body: "Each MyApp is a canvas of components, like trackers, calendars, "
                    + "checklists, that the agent reads and edits as you chat. The bar "
                    + "below is how you move around one — let's walk it left to right, "
                    + "starting here on Home.",
                placement: .bottom,
                selection: .myAppHome(activeMyAppId),
                highlight: .bottomBarHome
            ),
            TourStep(
                id: "myapp-memories",
                title: "Memories",
                body: "Long-term memory for this MyApp — markdown notes the agent writes "
                    + "and reads back across sessions, so it remembers what matters to you. "
                    + "Moreover the pupa folder is the equivalent of a .claude folder, where "
                    + "custom prompts, configurations and skills are managed.",
                placement: .bottom,
                selection: .myAppMemories(activeMyAppId),
                highlight: .bottomBarMemories
            ),
            TourStep(
                id: "myapp-agents",
                title: "Agents",
                body: "Every MyApp has its own main agent. Here you can see the tools it "
                    + "can call, open its AGENTS.md persona file, and review the components "
                    + "it manages.",
                placement: .bottom,
                selection: .myAppAgents(activeMyAppId),
                highlight: .bottomBarAgents
            ),
            TourStep(
                id: "myapp-history",
                title: "History",
                body: "Every change the agent makes to the canvas is logged here, so you "
                    + "can see what happened and when. Tap the clock anytime to review it.",
                placement: .bottom,
                selection: .myAppHistory(activeMyAppId),
                highlight: .bottomBarHistory
            ),
            TourStep(
                id: "chat",
                title: "Pupa",
                body: isPaired
                    ? "This is your agent. Ask it to add, change, or explain anything on the "
                        + "canvas — we've parked an example message you can send with one tap."
                    : "This is your agent. Once you connect a backend it can add, change, and "
                        + "explain anything on the canvas. We've parked an example message in "
                        + "the composer to show the idea.",
                placement: .top,
                selection: .myAppHome(activeMyAppId),
                opensChat: true,
                chatPrefill: "Can you prepare my daily briefing while I get my coffee?",
                highlight: .bottomBarChat
            ),
            TourStep(
                id: "agents-threads",
                title: "Agents & threads",
                body: "Along the top of the chat you can switch which agent you're talking "
                    + "to and pick — or start — a conversation thread. Every MyApp and the "
                    + "orchestrator keeps its own history.",
                placement: .top,
                opensChat: true,
                highlight: .chatHeader
            ),
            TourStep(
                id: "orchestrator-menu",
                title: "The Orchestrator",
                body: "Open the menu and you'll find the Orchestrator down here — a "
                    + "meta-agent that spans every MyApp. Tap it to start a cross-app "
                    + "conversation.",
                placement: .top,
                opensSidebar: true,
                highlight: .sidebarOrchestrator
            ),
            TourStep(
                id: "orchestrator",
                title: "Orchestrator",
                body: "Here it is. Ask it for cross-app work — even spinning up a whole new "
                    + "MyApp. We've parked an example you can send.",
                placement: .top,
                selection: .orchestrator,
                opensChat: true,
                chatPrefill: "Create a new myapp to organise my books"
            ),
            TourStep(
                id: "slash-commands",
                title: "Slash commands",
                body: "Type \"/\" in the composer for quick commands — /help lists them all "
                    + "and /tools shows what the agent can do. Also skills created by the "
                    + "agent can be invoked here.",
                placement: .top,
                opensChat: true,
                chatPrefill: "/"
            ),
            TourStep(
                id: "screen-share",
                title: "Screen share",
                body: "Next to it, screen share lets the agent see what's on your screen "
                    + "in your backend — handy when you want to see what the backend agent "
                    + "is cooking.",
                placement: .top,
                opensSidebar: true,
                highlight: .sidebarScreenShare
            ),
            TourStep(
                id: "share-myapp",
                title: "Share a MyApp",
                body: "Inside Settings is Import & Export — send any MyApp as a bundle, or "
                    + "import one a friend shared. Components, agent prompts, and memories "
                    + "all travel with it.",
                placement: .top,
                opensSidebar: true,
                highlight: .sidebarSettings
            ),
            TourStep(
                id: "settings-account",
                title: "Your account",
                body: "There's no Pupa account! Your Apple ID is the identity, and iCloud "
                    + "carries your MyApps, memories and settings between devices. This page "
                    + "also links out to [pupa-app.com](https://pupa-app.com) for docs, "
                    + "updates and support.",
                placement: .bottom,
                settingsPage: .account,
                highlight: .settingsAccount
            ),
            TourStep(
                id: "add-example",
                title: "Add one to explore",
                body: "That's the tour. The best way to get a feel for Pupa is to play with "
                    + "a ready-made workspace — tap **Restore** on any example below to drop "
                    + "it into your sidebar, then poke around and chat with it.",
                placement: .bottom,
                settingsPage: .examples,
                highlight: .settingsExamples
            ),
        ]
    }
}

/// Shared, app-wide store driving the interactive guided tour. Mirrors the
/// `OnboardingHandoff.shared` singleton pattern: a single `@Observable`
/// instance holds the step list + current
/// index and exposes the *desired UI state* for the active step. Host views
/// reconcile to it declaratively (`AppView.applyTourStep()` for navigation +
/// the sidebar; `.onChange` on the intent flags in `MyAppSidebarView` /
/// `SettingsSheet` / `ChatOverlay` / `ChatPanel` for the sheet + chat surfaces).
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
    var wantSettingsPage: TourSettingsPage?
    var wantChatOpen: Bool = false
    var chatPrefill: String?
    /// Prompt to send as an agent turn on the active chat scope. Not a tour
    /// flag — the bridge for a notification's `runAgent` tap action (set by
    /// `AppView`, consumed once by `ChatPanel`). Mirrors `chatPrefill`.
    var chatAutoSend: String?
    /// The control the active step rings, or `nil`. Read by `TourHighlightOverlay`.
    var wantHighlight: TourHighlight?

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

    /// The selection the active step targets, or `nil` when it doesn't
    /// navigate. Exposed for host views / tests that want the desired route
    /// without re-reading the step.
    var desiredSelection: SidebarSelection? { currentStep?.selection }

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
        wantSettingsPage = nil
        wantChatOpen = false
        chatPrefill = nil
        chatAutoSend = nil
        wantHighlight = nil
    }
}
