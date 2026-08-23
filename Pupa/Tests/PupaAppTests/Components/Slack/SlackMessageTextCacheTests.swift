import Foundation
import Testing
@testable import PupaApp

/// `SlackView.body` re-runs on every composer keystroke, so the message
/// bubbles' markdown must be memoized rather than re-parsed per render.
/// These pin the cache's correctness — a memo that returns the wrong text is
/// far worse than a slow one — plus the cost of one roster read, which is what
/// the view must not do per message.
@Suite("Slack message text cache")
struct SlackMessageTextCacheTests {

    private func agents(_ names: [String]) -> [Subagent] {
        names.map {
            Subagent(name: $0, displayName: $0.capitalized, description: "",
                     body: "", sourcePath: "pupa/agents/\($0)/AGENTS.md")
        }
    }

    /// One agent whose slug and display name differ — the case a key built
    /// from slugs alone cannot tell apart.
    private func agent(slug: String, displayName: String) -> Subagent {
        Subagent(name: slug, displayName: displayName, description: "",
                 body: "", sourcePath: "pupa/agents/\(slug)/AGENTS.md")
    }

    @Test("Repeat calls return the same rendered text")
    func repeatCallsAgree() {
        let roster = agents(["dev", "research"])
        let text = "Hey @dev look at **this** with @research"
        let first = SlackView.attributedMessageText(text, agents: roster)
        let second = SlackView.attributedMessageText(text, agents: roster)
        #expect(first == second)
        #expect(String(first.characters) == "Hey @dev look at this with @research")
    }

    @Test("The same text under a different roster re-resolves its mentions")
    func rosterChangeInvalidates() {
        let text = "ping @dev"
        let known = SlackView.attributedMessageText(text, agents: agents(["dev"]))
        let unknown = SlackView.attributedMessageText(text, agents: agents(["research"]))

        // `@dev` is a link only when `dev` is on the roster — so a cache keyed
        // on the text alone would hand back the wrong bubble after the roster
        // changes.
        let knownHasLink = known.runs.contains { $0.link != nil }
        let unknownHasLink = unknown.runs.contains { $0.link != nil }
        #expect(knownHasLink)
        #expect(!unknownHasLink)
    }

    @Test("Different texts do not collide")
    func distinctTextsDistinctResults() {
        let roster = agents(["dev"])
        let a = SlackView.attributedMessageText("first message", agents: roster)
        let b = SlackView.attributedMessageText("second message", agents: roster)
        #expect(String(a.characters) == "first message")
        #expect(String(b.characters) == "second message")
    }

    @Test("Mention links still carry the agent id")
    func mentionLinkSurvivesCaching() {
        let roster = agents(["dev"])
        let attributed = SlackView.attributedMessageText("hi @dev", agents: roster)
        let links = attributed.runs.compactMap(\.link)
        #expect(links.count == 1)
        #expect(links.first?.scheme == SlackView.mentionURLScheme)
        #expect(links.first?.host == "dev")
    }

    /// Mentions resolve against the display name as well as the slug, so a
    /// rename must not keep serving the old rendering. Both rosters here have
    /// the identical slug list — a key on slugs alone collides.
    @Test("Renaming an agent's display name re-resolves its mentions")
    func displayNameChangeInvalidates() {
        let text = "ping @dev"
        let asDev = SlackView.attributedMessageText(text, agents: [agent(slug: "a1", displayName: "dev")])
        let asOps = SlackView.attributedMessageText(text, agents: [agent(slug: "a1", displayName: "ops")])

        #expect(asDev.runs.contains { $0.link != nil })
        // `@dev` matches nothing once the agent is displayed as `ops`.
        #expect(!asOps.runs.contains { $0.link != nil })
    }

    @Test("A display-name mention links to the agent's slug, not its display name")
    func displayNameMentionLinksToSlug() {
        let attributed = SlackView.attributedMessageText(
            "ping @dev", agents: [agent(slug: "a1", displayName: "dev")]
        )
        #expect(attributed.runs.compactMap(\.link).first?.host == "a1")
    }

    /// The roster read is the expensive half of a Slack render: `SlackView`
    /// takes this hit **once per render** and threads the result down, rather
    /// than per message. Pinning the unit cost here means a regression that
    /// makes a single read pricier fails loudly, and gives the still-open
    /// "hoist it out of `body` entirely" work a number to beat.
    ///
    /// One *counted* scan, from `MemoryStore.init`. Note the real cost is two
    /// full recursive walks — `AgentStore.rescan` does a second one through
    /// `snapshotPaths()` → `filesUnder`, which `DiskIO` does not instrument —
    /// plus a read and a frontmatter parse per agent. What this pins is that
    /// the cost is *fixed*, not per-agent.
    @MainActor
    @Test("Building the agent roster costs a fixed number of tree scans, not one per agent")
    func rosterReadCostIsFixed() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("roster-cost-\(UUID().uuidString)")
        let agentsDir = root.appendingPathComponent(MemoryStore.pupaAgentsDir)
        try FileManager.default.createDirectory(at: agentsDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for i in 0..<6 {
            let dir = agentsDir.appendingPathComponent("agent\(i)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try "---\nname: Agent \(i)\ndescription: d\n---\nbody"
                .write(to: dir.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)
        }

        DiskIO.reset()
        let roster = AgentStore(memory: MemoryStore(rootOverride: root)).agents
        let scans = DiskIO.scans

        #expect(roster.count == 6)
        // Fixed cost — it must not scale with the number of agents.
        #expect(scans == 1)
    }
}
