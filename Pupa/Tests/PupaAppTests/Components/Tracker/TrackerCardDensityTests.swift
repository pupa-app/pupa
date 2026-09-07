import Foundation
import Testing
@testable import PupaApp

/// Card density derivation and the per-density caps, plus the `CardLayout`
/// contract that links are no longer truncated at layout time.
@Suite("Tracker card density")
struct TrackerCardDensityTests {

    @Test("Density is the view mode unless shrink collapses both onto minimal")
    func resolveTruthTable() {
        #expect(CardDensity.resolve(viewMode: .grid, shrink: false) == .comfortable)
        #expect(CardDensity.resolve(viewMode: .kanban, shrink: false) == .compact)
        #expect(CardDensity.resolve(viewMode: .grid, shrink: true) == .minimal)
        #expect(CardDensity.resolve(viewMode: .kanban, shrink: true) == .minimal)
    }

    @Test("A peeked card lifts back to its view mode's density")
    func resolveWithPeek() {
        #expect(CardDensity.resolve(viewMode: .grid, shrink: true, expanded: true) == .comfortable)
        #expect(CardDensity.resolve(viewMode: .kanban, shrink: true, expanded: true) == .compact)
    }

    @Test("The peek is inert on a board that is not shrunk")
    func peekWithoutShrinkIsInert() {
        // Reachable on every render: the views read `expandedIds.contains(...)`
        // unconditionally, and a set outlives the flag until the `onChange`
        // clears it. The resolver must not invent a fourth behaviour.
        #expect(CardDensity.resolve(viewMode: .grid, shrink: false, expanded: true) == .comfortable)
        #expect(CardDensity.resolve(viewMode: .kanban, shrink: false, expanded: true) == .compact)
    }

    // MARK: - Peek state

    private static let appA = UUID()
    private static let appB = UUID()
    private static func board(_ app: UUID, _ cid: String?) -> TrackerBoardKey {
        TrackerBoardKey(myAppId: app, componentId: cid)
    }

    @Test("Toggling the same card twice opens then closes it")
    func toggleRoundTrip() {
        let id = UUID()
        let b = Self.board(Self.appA, "tracker-1")
        var peeks = TrackerPeekState()
        peeks.toggle(id, for: b)
        #expect(peeks.ids(for: b) == [id])
        peeks.toggle(id, for: b)
        #expect(peeks.ids(for: b).isEmpty)
    }

    @Test("Peeks do not leak between boards sharing one view's state")
    func peeksAreBoardScoped() {
        let one = UUID(), two = UUID()
        let b1 = Self.board(Self.appA, "tracker-1")
        let b2 = Self.board(Self.appA, "tracker-2")
        var peeks = TrackerPeekState()
        peeks.toggle(one, for: b1)
        peeks.toggle(two, for: b2)
        #expect(peeks.ids(for: b1) == [one])
        #expect(peeks.ids(for: b2) == [two])
        peeks.clear(for: b1)
        #expect(peeks.ids(for: b1).isEmpty)
        #expect(peeks.ids(for: b2) == [two], "clearing one board must not touch the other")
    }

    @Test("Two MyApps' first trackers are different boards despite sharing a component id")
    func componentIdIsNotUniqueAcrossMyApps() {
        // `MyAppStore.makeComponentId` uniques ids against one MyApp's own
        // components, so every MyApp's first tracker is "tracker-1". Keying on
        // the component id alone merged their peeks and made a MyApp switch
        // look like a shrink press.
        let mine = UUID(), theirs = UUID()
        let inA = Self.board(Self.appA, "tracker-1")
        let inB = Self.board(Self.appB, "tracker-1")
        #expect(inA != inB)

        var peeks = TrackerPeekState()
        peeks.toggle(mine, for: inA)
        peeks.toggle(theirs, for: inB)
        #expect(peeks.ids(for: inA) == [mine])
        #expect(peeks.ids(for: inB) == [theirs])

        peeks.clear(for: inB)
        #expect(peeks.ids(for: inA) == [mine], "clearing one MyApp's board must not touch another's")
    }

    @Test("A nil component id is its own key, not a wildcard")
    func nilComponentIdIsItsOwnKey() {
        let id = UUID()
        var peeks = TrackerPeekState()
        peeks.toggle(id, for: Self.board(Self.appA, nil))
        #expect(peeks.ids(for: Self.board(Self.appA, nil)) == [id])
        #expect(peeks.ids(for: Self.board(Self.appA, "tracker-1")).isEmpty)
    }

    @Test("Only a same-board flag flip is the shrink button")
    func shrinkKeyDistinguishesButtonFromBoardSwap() {
        let shrunkA = TrackerShrinkKey(board: Self.board(Self.appA, "tracker-1"), shrink: true)
        let openA = TrackerShrinkKey(board: Self.board(Self.appA, "tracker-1"), shrink: false)
        let openA2 = TrackerShrinkKey(board: Self.board(Self.appA, "tracker-2"), shrink: false)
        // The board the old componentId-only key could not tell from `shrunkA`.
        let openB = TrackerShrinkKey(board: Self.board(Self.appB, "tracker-1"), shrink: false)

        // The button: one board, flag moved.
        #expect(TrackerShrinkKey.isShrinkToggle(from: shrunkA, to: openA))
        #expect(TrackerShrinkKey.isShrinkToggle(from: openA, to: shrunkA))

        // The canvas swapping a tracker into the same structural slot. The flag
        // moves too, which is why the flag alone cannot be the trigger.
        #expect(!TrackerShrinkKey.isShrinkToggle(from: shrunkA, to: openA2))
        #expect(!TrackerShrinkKey.isShrinkToggle(from: shrunkA, to: openB),
                "a sidebar MyApp switch is not a shrink press, even though both boards are \"tracker-1\"")
        #expect(!TrackerShrinkKey.isShrinkToggle(from: openB, to: shrunkA))
    }

    // MARK: - Density

    @Test("Chip and link caps tighten with density")
    func caps() {
        #expect(CardDensityMetrics.chipCap(.comfortable) == 3)
        #expect(CardDensityMetrics.chipCap(.compact) == 1)
        #expect(CardDensityMetrics.chipCap(.minimal) == 0)

        #expect(CardDensityMetrics.linkCap(.comfortable) == 3)
        #expect(CardDensityMetrics.linkCap(.compact) == 2)
        #expect(CardDensityMetrics.linkCap(.minimal) == 0)
    }

    @Test("CardLayout keeps every link field — capping is the card's job")
    func layoutDoesNotTruncateLinks() {
        // Regression: `from` used to `prefix(2)` the links, so a card could
        // not offer a "+k more" for what it had never been handed.
        let layout = CardLayout.from(fields: [
            FieldDef(name: "title", type: .text),
            FieldDef(name: "spec", type: .link),
            FieldDef(name: "pr", type: .link),
            FieldDef(name: "design", type: .link),
            FieldDef(name: "issue", type: .link),
        ])
        #expect(layout.linkFields.count == 4)
        #expect(layout.titleField?.name == "title")
    }

    @Test("excluding still drops the kanban column field")
    func layoutExcludesColumnField() {
        let layout = CardLayout.from(
            fields: [
                FieldDef(name: "title", type: .text),
                FieldDef(name: "status", type: .select, options: ["a", "b"]),
                FieldDef(name: "priority", type: .select, options: ["low"]),
            ],
            excluding: "status"
        )
        #expect(layout.chipFields.map(\.name) == ["priority"])
    }
}
