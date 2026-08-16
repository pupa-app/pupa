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
