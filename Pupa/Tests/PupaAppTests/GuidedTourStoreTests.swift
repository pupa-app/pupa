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
        #expect(store.steps.count == 15)
        #expect(store.isFirstStep)
        #expect(!store.isLastStep)
        #expect(store.currentStep?.id == "welcome")
        // The welcome step opens the sidebar menu rather than navigating.
        #expect(store.currentStep?.opensSidebar == true)
        #expect(store.currentStep?.selection == nil)
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
        // Settings is two steps: an overview on the category list, then a
        // deep-link to the Backend page.
        let overview = steps.first { $0.id == "settings-overview" }!
        #expect(overview.settingsPage == .root)
        let backend = steps.first { $0.id == "settings-backend" }!
        #expect(backend.settingsPage == .backend)
        #expect(backend.selection == nil)
        #expect(!backend.opensChat)
        // The overview comes before the backend deep-link.
        let overviewIndex = steps.firstIndex { $0.id == "settings-overview" }!
        let backendIndex = steps.firstIndex { $0.id == "settings-backend" }!
        #expect(overviewIndex < backendIndex)
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

    @Test("MyApp steps walk the bottom bar left to right, each ringing its tab")
    func myAppStepsWalkBottomBar() {
        let id = UUID()
        let steps = TourContent.steps(activeMyAppId: id, isPaired: true)
        // Ordered Home → Agents → Memories → History → Pupa(chat), each
        // navigating to its page and highlighting the matching bottom-bar
        // control. The Pupa step returns to the home canvas and opens the chat.
        let expected: [(String, SidebarSelection?, TourHighlight)] = [
            ("myapp-home", .myAppHome(id), .bottomBarHome),
            ("myapp-agents", .myAppAgents(id), .bottomBarAgents),
            ("myapp-memories", .myAppMemories(id), .bottomBarMemories),
            ("myapp-history", .myAppHistory(id), .bottomBarHistory),
            ("chat", .myAppHome(id), .bottomBarChat),
        ]
        // Indices are strictly increasing and contiguous in this order.
        let indices = expected.map { id in steps.firstIndex { $0.id == id.0 }! }
        #expect(indices == indices.sorted())
        for (stepId, selection, highlight) in expected {
            let step = steps.first { $0.id == stepId }!
            #expect(step.highlight == highlight)
            if let selection { #expect(step.selection == selection) }
        }
        // The chat step opens the overlay and parks its example prefill.
        let chat = steps.first { $0.id == "chat" }!
        #expect(chat.opensChat)
        #expect(chat.chatPrefill == "Add a prep task for my Friday interview")
    }

    @Test("Menu steps open the sidebar and ring the right footer action, in order")
    func menuStepsRingSidebarFooter() {
        let steps = TourContent.steps(activeMyAppId: UUID(), isPaired: true)
        // The Orchestrator is introduced from its menu button, then opened; then
        // screen share, then Import & Export — each ringing its sidebar icon.
        let expected: [(String, TourHighlight)] = [
            ("orchestrator-menu", .sidebarOrchestrator),
            ("screen-share", .sidebarScreenShare),
            ("share-myapp", .sidebarSettings),
        ]
        for (stepId, highlight) in expected {
            let step = steps.first { $0.id == stepId }!
            #expect(step.opensSidebar)
            #expect(step.highlight == highlight)
            #expect(step.selection == nil)
        }
        // The menu intro for the Orchestrator comes right before opening it.
        let menuIndex = steps.firstIndex { $0.id == "orchestrator-menu" }!
        let openIndex = steps.firstIndex { $0.id == "orchestrator" }!
        #expect(menuIndex < openIndex)
    }

    @Test("The final step is the add-an-example card")
    func finalStepAddsExample() {
        let steps = TourContent.steps(activeMyAppId: UUID(), isPaired: true)
        let last = steps.last!
        #expect(last.id == "add-example")
        #expect(last.addsExampleNamed == HomeBuyingExample.name)
        // No other step offers to add an example.
        #expect(steps.filter { $0.addsExampleNamed != nil }.count == 1)
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
