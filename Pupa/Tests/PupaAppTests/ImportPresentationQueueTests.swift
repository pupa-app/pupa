import Foundation
import Testing
@testable import PupaApp

/// Issue #323: an install link that arrives while Settings is open used to set
/// `pendingImport` into an occupied presentation slot, where it sat unpresented
/// until the sheet went away. These cover the queue that sequences it instead.
@Suite("Import presentation queue")
struct ImportPresentationQueueTests {

    private static func confirm(_ name: String) -> ImportPresentation {
        .confirm(PendingImport(
            data: Data(), isLibrary: false, appNames: [name],
            agentPrompts: [], automationRuleCount: 0))
    }

    private static func notice(_ message: String) -> ImportPresentation {
        .notice(ImportNotice(message: message))
    }

    private let first = ImportPresentationQueueTests.confirm("Job Search & Apply")
    private let second = ImportPresentationQueueTests.confirm("Maladaptive Mechanisms")
    private let error = ImportPresentationQueueTests.notice("Couldn't download that app.")

    /// The plain path — nothing on screen, so the confirm step presents at once.
    @Test("a link with no sheet open presents directly")
    func presentsDirectlyWhenIdle() {
        var queue = ImportPresentationQueue()
        queue.arrived(behindSheet: false)
        queue.stage(first)

        #expect(queue.active == first)
        #expect(queue.held == nil)
        #expect(queue.awaitingSlot == false)
    }

    /// The bug. The slot is taken, so the confirm step is held rather than
    /// dropped into a presentation that can't happen.
    @Test("a link behind an open sheet is held, then presented on dismiss")
    func holdsBehindASheet() {
        var queue = ImportPresentationQueue()
        queue.arrived(behindSheet: true)
        queue.stage(first)

        #expect(queue.active == nil, "presenting into an occupied slot is the bug")
        #expect(queue.held == first)

        queue.slotFreed()

        #expect(queue.active == first)
        #expect(queue.held == nil)
        #expect(queue.awaitingSlot == false)
    }

    /// The sheet can finish dismissing before the download does. The queue is
    /// ordering-independent: whichever lands second presents.
    @Test("a dismissal that lands before the download still presents it")
    func slotFreesBeforeStaging() {
        var queue = ImportPresentationQueue()
        queue.arrived(behindSheet: true)
        queue.slotFreed()
        queue.stage(first)

        #expect(queue.active == first)
        #expect(queue.held == nil)
    }

    /// The app foregrounds on every tap, so two links race for one slot. The
    /// newest wins — matching `remoteImport?.cancel()` killing the older fetch.
    @Test("a second link supersedes a held first one")
    func secondLinkSupersedesHeld() {
        var queue = ImportPresentationQueue()
        queue.arrived(behindSheet: true)
        queue.stage(first)

        queue.arrived(behindSheet: true)
        #expect(queue.held == nil, "the stale hold should not survive a newer link")

        queue.stage(second)
        queue.slotFreed()

        #expect(queue.active == second)
    }

    /// Same contract with the first link already on screen: its confirm sheet
    /// is closed, and the replacement waits for that dismissal to complete.
    @Test("a second link supersedes one already presented")
    func secondLinkSupersedesActive() {
        var queue = ImportPresentationQueue()
        queue.arrived(behindSheet: false)
        queue.stage(first)

        queue.arrived(behindSheet: false)
        #expect(queue.active == nil, "the stale confirm sheet should be closed")
        #expect(queue.awaitingSlot, "its dismissal has to finish before the next presents")

        queue.stage(second)
        #expect(queue.active == nil)

        queue.slotFreed()
        #expect(queue.active == second)
    }

    /// Errors ride the same slot: an alert raised behind a sheet is swallowed
    /// exactly like the confirm step.
    @Test("an error behind an open sheet is held too")
    func holdsNoticeBehindASheet() {
        var queue = ImportPresentationQueue()
        queue.arrived(behindSheet: true)
        queue.stage(error)

        #expect(queue.active == nil)
        queue.slotFreed()
        #expect(queue.active == error)
    }

    /// An alert has no `onDismiss`, so it is left up rather than swapped out
    /// from under the user: the new import waits for them to acknowledge it.
    @Test("a link arriving over an alert waits for it to be acknowledged")
    func waitsBehindAnAlert() {
        var queue = ImportPresentationQueue()
        queue.arrived(behindSheet: false)
        queue.stage(error)

        queue.arrived(behindSheet: false)
        #expect(queue.active == error,
                "the alert stays up — nothing would report a programmatic clear")
        #expect(queue.awaitingSlot)

        queue.stage(first)
        #expect(queue.active == error)

        queue.activeDismissed()
        #expect(queue.active == first)
    }

    /// Dismissing the confirm step empties the slot. Clearing and freeing are
    /// separate because `onDismiss` is what says the dismissal finished.
    @Test("dismissing the confirm step clears the slot")
    func dismissClearsTheSlot() {
        var queue = ImportPresentationQueue()
        queue.arrived(behindSheet: false)
        queue.stage(first)

        queue.clearActive()
        queue.slotFreed()

        #expect(queue.active == nil)
        #expect(queue.held == nil)
        #expect(queue.awaitingSlot == false)
    }

    /// The bindings `AppView` presents from only ever see their own case.
    @Test("only the matching binding sees the active presentation")
    func bindingsAreDisjoint() {
        var queue = ImportPresentationQueue()
        queue.stage(first)
        #expect(queue.confirm != nil)
        #expect(queue.notice == nil)

        queue.clearActive()
        queue.stage(error)
        #expect(queue.confirm == nil)
        #expect(queue.notice != nil)
    }
}
