import Foundation
import Testing
@testable import PupaApp

/// Behaviour tests for the interactive guided tour: the `GuidedTourStore`
/// step machine (start / next / back / finish / skip bounds + completion
/// persistence) and the `OnboardingMigration` back-fill that keeps the tour
/// from replaying for users who installed before it shipped.
///
/// Both run against an isolated `UserDefaults` suite so they never touch
/// `.standard` — the store takes an injectable `defaults` and the migration
/// helper takes one explicitly.
@MainActor
@Suite("Guided tour")
struct GuidedTourStoreTests {

    /// A throwaway suite, unique per call, removed at the end of each test.
    private func freshDefaults() -> UserDefaults {
        let name = "tour-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private func startedStore(defaults: UserDefaults, isPaired: Bool = true) -> GuidedTourStore {
        let store = GuidedTourStore(defaults: defaults)
        store.start(activeMyAppId: UUID(), isPaired: isPaired)
        return store
    }

    // MARK: - Start

    @Test("start builds the full step list and activates from index 0")
    func startActivates() {
        let store = startedStore(defaults: freshDefaults())
        #expect(store.isActive)
        #expect(store.index == 0)
        #expect(store.steps.count == 18)
        #expect(store.isFirstStep)
        #expect(!store.isLastStep)
        #expect(store.currentStep?.id == "welcome")
        // The welcome step just introduces the app: it navigates nowhere and
        // rings nothing.
        #expect(store.currentStep?.selection == nil)
        #expect(store.currentStep?.highlight == nil)
    }

    @Test("start clears any stale intent flags")
    func startClearsFlags() {
        let defaults = freshDefaults()
        let store = GuidedTourStore(defaults: defaults)
        store.wantSettingsOpen = true
        store.wantChatOpen = true
        store.chatPrefill = "stale"
        store.start(activeMyAppId: UUID(), isPaired: true)
        #expect(!store.wantSettingsOpen)
        #expect(!store.wantChatOpen)
        #expect(store.chatPrefill == nil)
    }

    // MARK: - next / back bounds

    @Test("next advances through every step then finishes on the last")
    func nextAdvancesAndFinishes() {
        let defaults = freshDefaults()
        let store = startedStore(defaults: defaults)
        let lastIndex = store.steps.count - 1

        for expected in 1...lastIndex {
            store.next()
            #expect(store.index == expected)
        }
        #expect(store.isLastStep)
        #expect(!defaults.bool(forKey: OnboardingKeys.tourCompleted))

        // Next on the last step finishes the tour.
        store.next()
        #expect(!store.isActive)
        #expect(defaults.bool(forKey: OnboardingKeys.tourCompleted))
    }

    @Test("back is clamped at the first step")
    func backClampsAtStart() {
        let store = startedStore(defaults: freshDefaults())
        store.back()
        #expect(store.index == 0)
        store.next()
        store.next()
        #expect(store.index == 2)
        store.back()
        #expect(store.index == 1)
    }

    @Test("next / back are no-ops once the tour is inactive")
    func movementRequiresActive() {
        let store = startedStore(defaults: freshDefaults())
        store.finish()
        #expect(!store.isActive)
        store.next()
        store.back()
        #expect(store.index == 0)
        #expect(!store.isActive)
    }

    // MARK: - finish / skip

    @Test("finish persists completion, deactivates, and resets to index 0")
    func finishCompletes() {
        let defaults = freshDefaults()
        let store = startedStore(defaults: defaults)
        store.next()
        store.next()
        store.finish()
        #expect(!store.isActive)
        #expect(store.index == 0)
        #expect(defaults.bool(forKey: OnboardingKeys.tourCompleted))
        #expect(!store.wantSettingsOpen)
        #expect(!store.wantChatOpen)
        #expect(store.chatPrefill == nil)
    }

    @Test("skip also marks the tour completed so it doesn't replay")
    func skipCompletes() {
        let defaults = freshDefaults()
        let store = startedStore(defaults: defaults)
        store.skip()
        #expect(!store.isActive)
        #expect(defaults.bool(forKey: OnboardingKeys.tourCompleted))
    }

    // MARK: - desiredSelection

    @Test("desiredSelection mirrors the active step's navigate target")
    func desiredSelectionTracksNavigate() {
        let id = UUID()
        let store = GuidedTourStore(defaults: freshDefaults())
        store.start(activeMyAppId: id, isPaired: true)
        // Welcome step has no navigation.
        #expect(store.desiredSelection == nil)
        // Walk to the Home step (.navigate(.myAppHome(id))).
        let myAppStepIndex = store.steps.firstIndex { $0.id == "myapp-home" }!
        while store.index < myAppStepIndex { store.next() }
        #expect(store.desiredSelection == .myAppHome(id))
    }

    @Test("chat copy adapts to the paired state")
    func chatCopyAdaptsToPairing() {
        let pairedSteps = TourContent.steps(activeMyAppId: UUID(), isPaired: true)
        let unpairedSteps = TourContent.steps(activeMyAppId: UUID(), isPaired: false)
        let pairedChat = pairedSteps.first { $0.id == "chat" }!
        let unpairedChat = unpairedSteps.first { $0.id == "chat" }!
        #expect(pairedChat.body != unpairedChat.body)
        // The slash step always parks "/" to surface the palette.
        let slash = pairedSteps.first { $0.id == "slash-commands" }!
        #expect(slash.opensChat)
        #expect(slash.chatPrefill == "/")
    }

    @Test("composable steps combine navigation, chat, and prefill")
    func composableEffects() {
        let id = UUID()
        let steps = TourContent.steps(activeMyAppId: id, isPaired: true)
        // Every Settings page the tour opens is introduced by a step that
        // lands on the root list and rings the section it lives in, so the
        // page has a visible origin rather than appearing from nowhere.
        let essentials = steps.first { $0.id == "settings-essentials" }!
        #expect(essentials.settingsPage == .root)
        #expect(essentials.highlight == .settingsEssentials)
        let backend = steps.first { $0.id == "settings-backend" }!
        #expect(backend.settingsPage == .backend)
        #expect(backend.selection == nil)
        #expect(!backend.opensChat)
        let manage = steps.first { $0.id == "settings-manage" }!
        #expect(manage.settingsPage == .root)
        #expect(manage.highlight == .settingsManageMyApps)
        // Each section step precedes the page it introduces.
        let index = { (id: String) in steps.firstIndex { $0.id == id }! }
        #expect(index("settings-essentials") < index("settings-backend"))
        #expect(index("settings-essentials") < index("settings-account"))
        #expect(index("settings-manage") < index("share-myapp"))
        // The agents/threads step keeps the chat open without a prefill and
        // rings the chat header (agent switcher + thread picker).
        let agentsThreads = steps.first { $0.id == "agents-threads" }!
        #expect(agentsThreads.opensChat)
        #expect(agentsThreads.chatPrefill == nil)
        #expect(agentsThreads.highlight == .chatHeader)
        // Orchestrator step navigates AND opens the chat with a prefill.
        let orchestrator = steps.first { $0.id == "orchestrator" }!
        #expect(orchestrator.selection == .orchestrator)
        #expect(orchestrator.opensChat)
        #expect(orchestrator.chatPrefill == "Create a new myapp to organise my books")
    }

    @Test("MyApp steps walk the bottom bar left to right, each ringing its slot")
    func myAppStepsWalkBottomBar() {
        let id = UUID()
        let steps = TourContent.steps(activeMyAppId: id, isPaired: true)
        // Ordered Home, Memories, Pupa(chat), then the menu. One step per bar
        // slot, and the bar walk comes before any Settings step: the app is
        // easier to grasp than the settings that wire it up.
        let expected: [(String, SidebarSelection?, TourHighlight)] = [
            ("myapp-home", .myAppHome(id), .bottomBarHome),
            ("myapp-memories", .myAppMemories(id), .bottomBarMemories),
            ("chat", .myAppHome(id), .bottomBarChat),
            ("bar-more", .myAppHome(id), .bottomBarMore),
        ]
        // Indices are strictly increasing in this order.
        let indices = expected.map { id in steps.firstIndex { $0.id == id.0 }! }
        #expect(indices == indices.sorted())
        for (stepId, selection, highlight) in expected {
            let step = steps.first { $0.id == stepId }!
            #expect(step.highlight == highlight)
            if let selection { #expect(step.selection == selection) }
        }
        #expect(indices.last! < steps.firstIndex { $0.settingsPage != nil }!)
        // The chat step opens the overlay and parks its example prefill.
        let chat = steps.first { $0.id == "chat" }!
        #expect(chat.opensChat)
        #expect(chat.chatPrefill == "Can you prepare my daily briefing while I get my coffee?")
    }

    /// Agents and History are named, not visited: the tour points at the menu
    /// row instead of navigating into the page, so it never strands the user
    /// somewhere they did not choose to go.
    @Test("Agents and History are shown in the menu preview, never navigated to")
    func agentsAndHistoryAreNamedNotVisited() {
        let id = UUID()
        let steps = TourContent.steps(activeMyAppId: id, isPaired: true)
        #expect(!steps.contains { $0.id == "myapp-agents" })
        #expect(!steps.contains { $0.id == "myapp-history" })
        #expect(!steps.contains { $0.selection == .myAppAgents(id) })
        #expect(!steps.contains { $0.selection == .myAppHistory(id) })
        let pages = steps.first { $0.id == "menu-pages" }!
        #expect(pages.menuPreview == [.agents, .history])
        #expect(pages.selection == .myAppHome(id))
    }

    /// The preview is the answer to a `Menu` that cannot be opened
    /// programmatically, so every row it lights must be a row the real menu
    /// actually builds for the bar the step leaves on screen.
    @Test("Every menu-preview step lights rows the real menu offers")
    func menuPreviewRowsExist() {
        let id = UUID()
        let steps = TourContent.steps(activeMyAppId: id, isPaired: true)
        let previews = steps.filter { $0.menuPreview != nil }
        #expect(previews.count == 3)
        let myAppRows = Set(BarMenuRow.rows(isMyApp: true, hasMyApps: true))
        let orchestratorRows = Set(BarMenuRow.rows(isMyApp: false, hasMyApps: true))
        for step in previews {
            // A preview step never also rings a control: the lit row is the
            // one thing it is pointing at.
            #expect(step.highlight == nil)
            // The preview is anchored above the bar, so a bottom-placed card
            // would sit right on top of it.
            #expect(step.placement == .top)
            let onOrchestrator = step.selection == .orchestrator
                || (step.selection == nil && step.id == "menu-settings")
            let available = onOrchestrator ? orchestratorRows : myAppRows
            #expect(step.menuPreview!.isSubset(of: available))
        }
    }

    /// The invariant that keeps the tour honest: a SwiftUI `Menu` can't be
    /// opened programmatically, so a second ring on More would point the user
    /// at a closed menu. Exactly one step may ring it.
    @Test("Exactly one step rings More")
    func onlyOneStepRingsMore() {
        let steps = TourContent.steps(activeMyAppId: UUID(), isPaired: true)
        #expect(steps.filter { $0.highlight == .bottomBarMore }.count == 1)
        #expect(steps.first { $0.highlight == .bottomBarMore }?.id == "bar-more")
    }

    @Test("Global steps land somewhere instead of ringing the closed menu")
    func globalStepsLandSomewhere() {
        let steps = TourContent.steps(activeMyAppId: UUID(), isPaired: true)
        // The Orchestrator opens for real; Import & Export deep-links into
        // Settings.
        let orchestrator = steps.first { $0.id == "orchestrator" }!
        #expect(orchestrator.selection == .orchestrator)
        #expect(orchestrator.opensChat)

        let share = steps.first { $0.id == "share-myapp" }!
        #expect(share.settingsPage == .sharing)

        // Screen share has no card at all: it is a secondary feature living in
        // Settings, and a step that only described itself earned no place.
        #expect(!steps.contains { $0.id == "screen-share" })

        // The step that introduced the Orchestrator from the sidebar footer is
        // gone; `menu-scope` names it instead.
        #expect(!steps.contains { $0.id == "orchestrator-menu" })
    }

    @Test("The final step lands on Settings · Examples and rings the list")
    func finalStepOpensExamples() {
        let steps = TourContent.steps(activeMyAppId: UUID(), isPaired: true)
        let last = steps.last!
        #expect(last.id == "add-example")
        #expect(last.settingsPage == .examples)
        #expect(last.highlight == .settingsExamples)
    }

    /// The marketplace is where the current official apps live, so it is
    /// introduced before the bundled examples, which are toys.
    @Test("The marketplace card precedes the bundled examples card")
    func marketplacePrecedesExamples() {
        let steps = TourContent.steps(activeMyAppId: UUID(), isPaired: true)
        let market = steps.firstIndex { $0.id == "marketplace" }!
        let example = steps.firstIndex { $0.id == "add-example" }!
        #expect(market == example - 1)
        #expect(steps[market].settingsPage == .examples)
        #expect(steps[market].highlight == .settingsMarketplace)
    }

    /// House style: no em dashes in user-facing tour copy.
    @Test("No step copy contains an em dash")
    func copyHasNoEmDashes() {
        for step in TourContent.steps(activeMyAppId: UUID(), isPaired: true) {
            #expect(!step.title.contains("\u{2014}"), "em dash in \(step.id) title")
            #expect(!step.body.contains("\u{2014}"), "em dash in \(step.id) body")
        }
        for step in TourContent.steps(activeMyAppId: UUID(), isPaired: false) {
            #expect(!step.body.contains("\u{2014}"), "em dash in \(step.id) body")
        }
    }

    @Test("The account card sits in the Settings block, before the closing pair")
    func accountStepPrecedesExamples() {
        let steps = TourContent.steps(activeMyAppId: UUID(), isPaired: true)
        let account = steps.firstIndex { $0.id == "settings-account" }!
        let example = steps.firstIndex { $0.id == "add-example" }!
        #expect(account < example)
        #expect(steps[account].settingsPage == .account)
        #expect(steps[account].highlight == .settingsAccount)
    }

    @Test("Walking the tour reaches the example card, then finishing completes it")
    func walkReachesExampleCardThenFinishes() {
        let defaults = freshDefaults()
        let store = startedStore(defaults: defaults)
        // Advance to the last step.
        while !store.isLastStep { store.next() }
        // The closing card is the add-an-example deep-link to Settings.
        #expect(store.currentStep?.id == "add-example")
        #expect(store.currentStep?.settingsPage == .examples)
        #expect(store.currentStep?.highlight == .settingsExamples)
        #expect(store.isActive)
        // Finishing from the last step tears the tour down and persists, so it
        // never replays.
        store.next()
        #expect(!store.isActive)
        #expect(defaults.bool(forKey: OnboardingKeys.tourCompleted))
    }
}

/// Migration back-fill: a pre-existing user (with a persisted settings
/// snapshot) is marked as having completed both onboarding and the tour, so
/// an app update replays neither. A fresh install leaves both false.
@MainActor
@Suite("Onboarding/tour migration")
struct OnboardingMigrationTests {

    private func freshDefaults() -> (UserDefaults, String) {
        let name = "migration-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return (defaults, "settings.test.key")
    }

    @Test("Existing user (settings snapshot present) is back-filled as completed")
    func existingUserBackfilled() {
        let (defaults, key) = freshDefaults()
        defaults.set(Data("{}".utf8), forKey: key)
        OnboardingMigration.migrate(defaults: defaults, settingsKey: key)
        #expect(defaults.bool(forKey: OnboardingKeys.completed))
        #expect(defaults.bool(forKey: OnboardingKeys.tourCompleted))
    }

    @Test("Fresh install leaves onboarding and tour flags false")
    func freshInstallLeavesBothFalse() {
        let (defaults, key) = freshDefaults()
        OnboardingMigration.migrate(defaults: defaults, settingsKey: key)
        #expect(defaults.object(forKey: OnboardingKeys.completed) != nil)
        #expect(!defaults.bool(forKey: OnboardingKeys.completed))
        // Tour flag is never written for a fresh install — onboarding hands
        // off to the tour live.
        #expect(defaults.object(forKey: OnboardingKeys.tourCompleted) == nil)
    }

    @Test("Migration is idempotent once completed is set")
    func idempotentAfterCompleted() {
        let (defaults, key) = freshDefaults()
        // Simulate a user who already finished onboarding but not the tour.
        defaults.set(true, forKey: OnboardingKeys.completed)
        OnboardingMigration.migrate(defaults: defaults, settingsKey: key)
        // Must not back-fill tourCompleted — they're mid-feature, the tour
        // should still run for them.
        #expect(defaults.object(forKey: OnboardingKeys.tourCompleted) == nil)
    }
}
