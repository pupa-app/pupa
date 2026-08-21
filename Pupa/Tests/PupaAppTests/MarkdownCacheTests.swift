import Foundation
import Testing
@testable import PupaApp

/// `Markdown(String)` parses through cmark inside its initializer — i.e. in
/// `body`. Without a cache, every unrelated `AppView` body pass re-parsed the
/// whole visible transcript. Parse counts are deterministic where timings are
/// not, same reasoning as `DiskIO`.
@MainActor
@Suite("Markdown cache")
struct MarkdownCacheTests {

    private let text = """
        ### Heading

        Some **bold** prose with a [link](https://example.com).

        - one
        - two
        """

    @Test("re-rendering an unchanged bubble does not re-parse")
    func unchangedBubbleReuses() {
        MarkdownCache.reset()
        for _ in 0..<25 { _ = MarkdownCache.content(id: "b1", text: text) }
        #expect(MarkdownCache.parses == 1, "parsed \(MarkdownCache.parses) times")
    }

    @Test("distinct bubbles each parse once")
    func distinctBubblesParseOnce() {
        MarkdownCache.reset()
        for pass in 0..<5 {
            for i in 0..<40 {
                _ = MarkdownCache.content(id: "b\(i)", text: "\(text)\n\nbody \(i)")
            }
            #expect(MarkdownCache.parses == 40, "after pass \(pass)")
        }
    }

    @Test("a streaming bubble replaces its own entry instead of growing")
    func streamingReplacesEntry() {
        MarkdownCache.reset()
        // Same id, text growing a token at a time — the streaming shape.
        for n in 1...50 { _ = MarkdownCache.content(id: "stream", text: String(repeating: "tok ", count: n)) }
        #expect(MarkdownCache.parses == 50)
        // The final text is still served without re-parsing.
        _ = MarkdownCache.content(id: "stream", text: String(repeating: "tok ", count: 50))
        #expect(MarkdownCache.parses == 50)
    }

    @Test("edited text re-parses")
    func editedTextReparses() {
        MarkdownCache.reset()
        _ = MarkdownCache.content(id: "b1", text: "one")
        _ = MarkdownCache.content(id: "b1", text: "two")
        _ = MarkdownCache.content(id: "b1", text: "two")
        #expect(MarkdownCache.parses == 2)
    }
}
