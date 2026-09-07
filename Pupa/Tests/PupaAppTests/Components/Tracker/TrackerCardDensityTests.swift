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

    @Test("Toggling the same card twice opens then closes it")
    func toggleRoundTrip() {
        let id = UUID()
        var peeks = TrackerPeekState()
        peeks.toggle(id, for: "tracker-1")
        #expect(peeks.ids(for: "tracker-1") == [id])
        peeks.toggle(id, for: "tracker-1")
        #expect(peeks.ids(for: "tracker-1").isEmpty)
    }

    @Test("Peeks do not leak between components sharing one view's state")
    func peeksAreComponentScoped() {
        let a = UUID(), b = UUID()
        var peeks = TrackerPeekState()
        peeks.toggle(a, for: "tracker-1")
        peeks.toggle(b, for: "tracker-2")
        #expect(peeks.ids(for: "tracker-1") == [a])
        #expect(peeks.ids(for: "tracker-2") == [b])
        peeks.clear(for: "tracker-1")
        #expect(peeks.ids(for: "tracker-1").isEmpty)
        #expect(peeks.ids(for: "tracker-2") == [b], "clearing one board must not touch the other")
    }

    @Test("A nil component id is its own key, not a wildcard")
    func nilComponentIdIsItsOwnKey() {
        let id = UUID()
        var peeks = TrackerPeekState()
        peeks.toggle(id, for: nil)
        #expect(peeks.ids(for: nil) == [id])
        #expect(peeks.ids(for: "tracker-1").isEmpty)
    }

    @Test("Only a same-component flag flip is the shrink button")
    func shrinkKeyDistinguishesButtonFromComponentSwap() {
        let shrunkA = TrackerShrinkKey(componentId: "tracker-1", shrink: true)
        let openA = TrackerShrinkKey(componentId: "tracker-1", shrink: false)
        let openB = TrackerShrinkKey(componentId: "tracker-2", shrink: false)

        // The button: one board, flag moved.
        #expect(TrackerShrinkKey.isShrinkToggle(from: shrunkA, to: openA))
        #expect(TrackerShrinkKey.isShrinkToggle(from: openA, to: shrunkA))

        // The canvas swapping a tracker into the same structural slot. The
        // flag moves too, which is why the flag alone cannot be the trigger.
        #expect(!TrackerShrinkKey.isShrinkToggle(from: shrunkA, to: openB))
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
