import Foundation
import Testing
@testable import PupaApp

/// The init override that lets a driven launch pick a backend harness. Without
/// it every driven turn — headless, CLI, and simulator — hits whichever harness
/// the backend defaults to, which is silently the right answer often enough to
/// hide the gap.
@MainActor
@Suite("Harness override")
struct HarnessOverrideTests {

    init() { TestStorage.activate() }

    @Test("the init override routes the run to that harness")
    func harnessOverride_reachesAgentRunURL() {
        let url = URL(string: "http://example.invalid:8004/")!
        let plain = SettingsStore(backendURL: url)
        #expect(plain.agentRunURL.absoluteString == "http://example.invalid:8004/",
                "no harness → the backend's default, mounted at POST /")

        let scoped = SettingsStore(backendURL: url, harnessID: "claude_code")
        #expect(scoped.agentRunURL.absoluteString
            == "http://example.invalid:8004/harnesses/claude_code")
    }
}
