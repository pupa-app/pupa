import Foundation
import Testing
@testable import PupaApp

/// House style for the copy every example puts on the Settings · Examples
/// list. The tour's own copy is pinned the same way in `GuidedTourStoreTests`.
@MainActor
@Suite("Example copy")
struct ExampleRegistryCopyTests {

    @Test("No example name or tagline contains an em dash")
    func copyHasNoEmDashes() {
        for example in ExampleRegistry.all {
            #expect(!example.name.contains("\u{2014}"), "em dash in \(example.name) name")
            #expect(!example.tagline.contains("\u{2014}"), "em dash in \(example.name) tagline")
        }
    }

    /// The row shows the tagline under the name with no other context, so an
    /// empty one would render as a blank second line.
    @Test("Every example has a non-empty tagline")
    func taglinesArePresent() {
        for example in ExampleRegistry.all {
            #expect(!example.tagline.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }
}
