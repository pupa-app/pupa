import Foundation
import Testing
@testable import PupaApp

/// Tracker link-field values are content: the agent writes them, and an
/// imported bundle ships them. They become `Link(destination:)`, so the scheme
/// decides what one tap does — `parse` accepting any scheme meant a bundle
/// could put a tel:, file: or custom-scheme link in a card and have the OS
/// hand it to whatever app claims it.
@Suite("Tracker link URLs")
struct TrackerLinkURLTests {

    @Test("https and http pass through")
    func webSchemesAccepted() {
        #expect(TrackerLinkURL.parse("https://example.com/x")?.absoluteString == "https://example.com/x")
        #expect(TrackerLinkURL.parse("http://example.com")?.absoluteString == "http://example.com")
    }

    @Test("Domain-only shorthand still becomes https")
    func shorthandStillWorks() {
        // The reason the loose parse existed — the agent writes "github.com/foo".
        #expect(TrackerLinkURL.parse("github.com/foo")?.absoluteString == "https://github.com/foo")
    }

    @Test("In-app pupa:// links still work")
    func inAppSchemeAllowed() {
        // `chatLinkAction` intercepts these to open a note or component in-app;
        // the scheme is unregistered, so it never reaches the OS. Tracker cards
        // linking to a note is a built feature — see `LinkPill.displayText`.
        #expect(TrackerLinkURL.parse("pupa://memory/notes/a.md") != nil)
        #expect(TrackerLinkURL.parse("pupa://component/abc") != nil)
    }

    @Test("The registered install scheme is still refused")
    func installSchemeRefused() {
        // `pupa-install` IS registered in Info.plist, so unlike `pupa` it
        // reaches the OS and comes back into the app's own import flow.
        #expect(TrackerLinkURL.parse("pupa-install://import?url=x&sha256=y") == nil)
        #expect(TrackerLinkURL.parse("pupa-pair://x") == nil)
    }

    @Test(
        "Non-web schemes are refused",
        arguments: [
            "file:///etc/passwd",
            "tel:+15550100",
            "sms:+15550100",
            "mailto:a@b.c",
            "javascript:alert(1)",
            "data:text/html,<script>alert(1)</script>",
            "shortcuts://run-shortcut?name=wipe",
        ]
    )
    func nonWebSchemesRefused(value: String) {
        #expect(TrackerLinkURL.parse(value) == nil, "\(value) was accepted")
    }

    @Test("Scheme matching is case-insensitive")
    func schemeCaseInsensitive() {
        #expect(TrackerLinkURL.parse("HTTPS://example.com") != nil)
        #expect(TrackerLinkURL.parse("FILE:///etc/passwd") == nil)
        #expect(TrackerLinkURL.parse("JavaScript:alert(1)") == nil)
    }

    @Test("Junk is still nil")
    func junkRejected() {
        #expect(TrackerLinkURL.parse("") == nil)
        #expect(TrackerLinkURL.parse("not a url") == nil)
        #expect(TrackerLinkURL.parse("   ") == nil)
    }
}
