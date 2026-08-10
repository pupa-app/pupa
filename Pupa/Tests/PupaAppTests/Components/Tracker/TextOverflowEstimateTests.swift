import Foundation
import Testing
@testable import PupaApp

/// Tests the truncation predictor behind `ExpandableText`'s "Show more"
/// toggle. The predictor must stay a pure function of the string: measuring
/// the rendered text instead is what hung the app in pupa#120, because the
/// measurement decided whether the toggle button existed and the button
/// changed the height being measured.
@Suite("Text overflow estimate")
struct TextOverflowEstimateTests {

    @Test("Short single-line text needs no toggle")
    func shortTextFits() {
        #expect(!TextOverflowEstimate.mayOverflow("Draft post", lineLimit: 2, charsPerLine: 34))
    }

    @Test("Empty text needs no toggle")
    func emptyFits() {
        #expect(!TextOverflowEstimate.mayOverflow("", lineLimit: 2, charsPerLine: 34))
    }

    @Test("Text past the wrapped-line budget needs a toggle")
    func longTextOverflows() {
        let text = String(repeating: "a", count: 2 * 34 + 1)
        #expect(TextOverflowEstimate.mayOverflow(text, lineLimit: 2, charsPerLine: 34))
    }

    @Test("Text exactly at the budget still fits")
    func boundaryFits() {
        let text = String(repeating: "a", count: 2 * 34)
        #expect(!TextOverflowEstimate.mayOverflow(text, lineLimit: 2, charsPerLine: 34))
    }

    @Test("More hard line breaks than the limit needs a toggle, however short")
    func hardBreaksOverflow() {
        #expect(TextOverflowEstimate.mayOverflow("a\nb\nc", lineLimit: 2, charsPerLine: 34))
    }

    @Test("Hard breaks within the limit still fit")
    func hardBreaksWithinLimitFit() {
        #expect(!TextOverflowEstimate.mayOverflow("a\nb", lineLimit: 2, charsPerLine: 34))
    }

    /// The wider grid card fits more per line than a 260pt kanban lane, so the
    /// same string can need a toggle in kanban and not in grid.
    @Test("Wider cards fit more before needing a toggle")
    func widerCardsFitMore() {
        let text = String(repeating: "a", count: 80)
        #expect(TextOverflowEstimate.mayOverflow(text, lineLimit: 2, charsPerLine: 34))
        #expect(!TextOverflowEstimate.mayOverflow(text, lineLimit: 2, charsPerLine: 52))
    }

    @Test("A zero line limit never offers a toggle")
    func zeroLineLimit() {
        #expect(!TextOverflowEstimate.mayOverflow("anything at all", lineLimit: 0, charsPerLine: 34))
    }
}
