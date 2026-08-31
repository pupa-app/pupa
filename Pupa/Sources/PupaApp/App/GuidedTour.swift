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
/// translates them into concrete `selection` / sheet / chat state.
struct TourStep: Identifiable, Equatable {
    let id: String
    let title: String
    let body: String
    let placement: CardPlacement
    /// Sidebar route to select when this step activates (drives `selection`
    /// and, via `dispatchSelection`, the chat scope). `nil` leaves the current
    /// selection in place.
    var selection: SidebarSelection?
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
    /// Draw the bar's menu open, with these rows lit. `nil` draws no preview.
    /// A SwiftUI `Menu` cannot be opened programmatically, so steps that talk
    /// about what is behind the hamburger show `TourMenuPreview` instead of
    /// teleporting the user to the destination with no visible tap.
    var menuPreview: Set<BarMenuRow>?

    init(
        id: String,
        title: String,
        body: String,
        placement: CardPlacement,
        selection: SidebarSelection? = nil,
        settingsPage: TourSettingsPage? = nil,
        opensChat: Bool = false,
        chatPrefill: String? = nil,
        highlight: TourHighlight? = nil,
        menuPreview: Set<BarMenuRow>? = nil
    ) {
        self.id = id
        self.title = title
        self.body = body
        self.placement = placement
        self.selection = selection
        self.settingsPage = settingsPage
        self.opensChat = opensChat
        self.chatPrefill = chatPrefill
        self.highlight = highlight
        self.menuPreview = menuPreview
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
                body: "Pupa is a workspace your agent can see and edit alongside you. "
                    + "Everything you need is on the bar along the bottom. The tour takes "
                    + "a minute or two; tap Next to begin.",
                placement: .bottom
            ),

            // The bar, left to right. Configuration comes after: the app is
            // easier to understand than the settings that wire it up.
            TourStep(
                id: "myapp-home",
                title: "Home",
                body: "Each MyApp is a canvas of components, like trackers, calendars and "
                    + "checklists, that the agent reads and edits as you chat. The bar below "
                    + "is the only one in the app: Home, Memories, Pupa, and the menu. "
                    + "Let's walk it left to right, starting here on Home.",
                placement: .bottom,
                selection: .myAppHome(activeMyAppId),
                highlight: .bottomBarHome
            ),
            TourStep(
                id: "myapp-memories",
                title: "Memories",
                body: "Long-term memory for this MyApp: markdown notes the agent writes "
                    + "and reads back across sessions, so it remembers what matters to you. "
                    + "The pupa folder is the equivalent of a .claude folder, where custom "
                    + "prompts, configurations and skills are managed.",
                placement: .bottom,
                selection: .myAppMemories(activeMyAppId),
                highlight: .bottomBarMemories
            ),
            TourStep(
                id: "chat",
                title: "Pupa",
                body: isPaired
                    ? "This is your agent. Ask it to add, change, or explain anything on the "
                        + "canvas. We've parked an example message you can send with one tap."
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
                    + "to and pick, or start, a conversation thread. Every MyApp and the "
                    + "orchestrator keeps its own history.",
                placement: .top,
                opensChat: true,
                highlight: .chatHeader
            ),
            TourStep(
                id: "slash-commands",
                title: "Slash commands",
                body: "Type \"/\" in the composer for quick commands. /help lists them all "
                    + "and /tools shows what the agent can do. Skills the agent creates can "
                    + "be invoked here too.",
                placement: .top,
                opensChat: true,
                chatPrefill: "/"
            ),

            // The menu. A SwiftUI `Menu` cannot be opened programmatically, so
            // the next steps draw it open (`menuPreview`) rather than
            // teleporting to each destination with no visible tap in between.
            // Every preview step places its card at the top: the preview is
            // anchored above the bar, so a bottom card sits right on it.
            TourStep(
                id: "bar-more",
                title: "Menu",
                body: "The last slot on the bar is the menu. Everything the three buttons "
                    + "don't cover lives behind it. Tap it and it opens upward, grouped into "
                    + "three: this app's pages, which workspace you're in, and Settings.",
                placement: .bottom,
                selection: .myAppHome(activeMyAppId),
                highlight: .bottomBarMore
            ),
            TourStep(
                id: "menu-pages",
                title: "This app's pages",
                body: "Agents opens the main agent for this MyApp, where you can see the "
                    + "tools it can call and open its persona file. History logs every change "
                    + "the agent makes to the canvas. Both are here whenever you want them.",
                placement: .top,
                selection: .myAppHome(activeMyAppId),
                menuPreview: [.agents, .history]
            ),
            TourStep(
                id: "menu-scope",
                title: "Moving between workspaces",
                body: "MyApps lists everything you've built and switches between them. "
                    + "Orchestrator is the meta-agent that spans all of them. Let's open it.",
                placement: .top,
                selection: .myAppHome(activeMyAppId),
                menuPreview: [.myApps, .orchestrator]
            ),
            TourStep(
                id: "orchestrator",
                title: "Orchestrator",
                body: "A meta-agent that spans every MyApp. Ask it for cross-app work, even "
                    + "spinning up a whole new MyApp. We've parked an example you can send.",
                placement: .top,
                selection: .orchestrator,
                opensChat: true,
                chatPrefill: "Create a new myapp to organise my books"
            ),
            TourStep(
                id: "menu-settings",
                title: "Settings",
                body: "The last row in the menu is Settings, where Pupa is wired up. "
                    + "It opens as a sheet from the bottom. Let's look inside.",
                placement: .top,
                menuPreview: [.settings]
            ),

            // Settings. Each step rings the section on the root list first, so
            // the page it then opens has a visible origin.
            TourStep(
                id: "settings-essentials",
                title: "The essentials",
                body: "Settings opens on the three things you need first: your Account, the "
                    + "Backend that runs the agent, and Notifications. Everything else is "
                    + "grouped below. Let's start with Backend.",
                placement: .bottom,
                settingsPage: .root,
                highlight: .settingsEssentials
            ),
            TourStep(
                id: "settings-backend",
                title: "Settings · Backend",
                body: "Point Pupa at your backend and pair it here. Until you do, the agent "
                    + "can't run, because the LLM runs there. If you don't have a QR code "
                    + "yet, find the backend install steps "
                    + "[here](https://github.com/pupa-app/pupa-backend).",
                placement: .bottom,
                settingsPage: .backend
            ),
            TourStep(
                id: "settings-account",
                title: "Settings · Account",
                body: "There's no Pupa account. Your Apple ID is the identity, and iCloud "
                    + "carries your MyApps, memories and settings between devices. This page "
                    + "also links out to [pupa-app.com](https://pupa-app.com) for docs, "
                    + "updates and support.",
                placement: .bottom,
                settingsPage: .account,
                highlight: .settingsAccount
            ),
            TourStep(
                id: "settings-manage",
                title: "Manage MyApps",
                body: "The second section is housekeeping for the apps you already have: "
                    + "their agents, sharing, pinned snapshots, the archive, and anything "
                    + "you recently deleted. Rows appear here as you need them.",
                placement: .top,
                settingsPage: .root,
                highlight: .settingsManageMyApps
            ),
            TourStep(
                id: "share-myapp",
                title: "Share a MyApp",
                body: "Send any MyApp as a bundle, or import one a friend shared. "
                    + "Components, agent prompts, and memories all travel with it.",
                placement: .bottom,
                settingsPage: .sharing
            ),

            // Closing pair: the marketplace is where the current official apps
            // live, so it leads. The bundled examples follow as toys.
            TourStep(
                id: "marketplace",
                title: "The marketplace",
                body: "This is where to find the latest official MyApps, kept up to date "
                    + "and ready to install. Start here when you want something real to "
                    + "use rather than something to poke at.",
                placement: .bottom,
                settingsPage: .examples,
                highlight: .settingsMarketplace
            ),
            TourStep(
                id: "add-example",
                title: "Or start with a toy",
                body: "That's the tour. The examples below are small, self-contained "
                    + "workspaces for getting a feel for Pupa. Tap Restore on any of them "
                    + "to drop it into your MyApps, then poke around and chat with it.",
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
    /// Rows to light in the open-menu preview, or `nil` to draw no preview.
    /// Read by `AppView`, which hosts `TourMenuPreview` over the bar.
    var wantMenuPreview: Set<BarMenuRow>?

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
        wantMenuPreview = nil
    }
}
