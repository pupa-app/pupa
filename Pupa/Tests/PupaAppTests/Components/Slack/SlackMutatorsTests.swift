import Foundation
import Testing
@testable import PupaApp

/// Tests for the `MyAppStore.slack*` mutators + `SlackView` pure helpers.
/// Slack agents are filesystem subagents now — channels reference them by
/// slug, and the store stores member slugs verbatim (roster validation is
/// the caller's job).
@MainActor
@Suite("Slack mutators")
struct SlackMutatorsTests {

    private func freshStore() -> (MyAppStore, UUID) {
        MyAppTypeRegistry.shared.registerBuiltins()
        let myApp = MyApp(
            name: "T",
            iconSystemName: "bubble.left.and.bubble.right",
            typeId: MyAppType.tracker.id
        )
        let store = MyAppStore(initial: ([myApp], myApp.id))
        store.addComponent(
            kind: "slack",
            name: "Slack",
            iconSystemName: "bubble.left.and.bubble.right",
            myAppId: myApp.id
        )
        return (store, myApp.id)
    }

    private func slack(_ store: MyAppStore, id: UUID) -> SlackData? {
        guard let myApp = store.myApps.first(where: { $0.id == id }) else { return nil }
        for comp in myApp.components {
            if case .slack(let s) = comp.body { return s }
        }
        return nil
    }

    /// A lightweight subagent for the pure-helper tests: slug + display name.
    private func sub(_ slug: String, _ display: String) -> Subagent {
        Subagent(name: slug, displayName: display, sourcePath: "pupa/agents/\(slug)/AGENTS.md")
    }

    @Test("addComponent(kind: slack) seeds an empty SlackData body")
    func addComponentSlack() {
        let (store, id) = freshStore()
        let s = slack(store, id: id)
        #expect(s != nil)
        #expect(s?.channels.isEmpty == true)
        #expect(s?.activeChannelId == nil)
    }

    @Test("slackAddChannel stores member slugs verbatim and sets active when first")
    func addChannel() {
        let (store, id) = freshStore()
        let cId = store.slackAddChannel(
            name: "planning",
            type: .channel,
            memberAgentIds: ["scout", "dev"],
            myAppId: id
        )
        #expect(cId == "channel-1")
        let s = slack(store, id: id)
        #expect(s?.channels.first?.memberAgentIds == ["scout", "dev"])
        #expect(s?.activeChannelId == cId)
    }

    @Test("slackAddAgentsToChannel is idempotent and appends new slugs")
    func addAgentsToChannel() {
        let (store, id) = freshStore()
        let cId = store.slackAddChannel(name: "planning", type: .channel, myAppId: id)!

        let first = store.slackAddAgentsToChannel(channelId: cId, agentIds: ["scout"], myAppId: id)
        #expect(first == true)
        // Idempotent: same slug again is a no-op.
        let second = store.slackAddAgentsToChannel(channelId: cId, agentIds: ["scout"], myAppId: id)
        #expect(second == false)
        let more = store.slackAddAgentsToChannel(channelId: cId, agentIds: ["dev"], myAppId: id)
        #expect(more == true)
        #expect(slack(store, id: id)?.channels.first?.memberAgentIds == ["scout", "dev"])
    }

    @Test("slackSetActiveChannel toggles activeChannelId and rejects unknown ids")
    func setActiveChannel() {
        let (store, id) = freshStore()
        let c1 = store.slackAddChannel(name: "a", type: .channel, myAppId: id)!
        let c2 = store.slackAddChannel(name: "b", type: .channel, myAppId: id)!
        #expect(slack(store, id: id)?.activeChannelId == c1)

        let switched = store.slackSetActiveChannel(channelId: c2, myAppId: id)
        #expect(switched == true)
        #expect(slack(store, id: id)?.activeChannelId == c2)

        let bogus = store.slackSetActiveChannel(channelId: "channel-bogus", myAppId: id)
        #expect(bogus == false)
        #expect(slack(store, id: id)?.activeChannelId == c2)
    }

    @Test("slackPostMessage appends to messagesByChannel; returns nil for unknown channel")
    func postMessage() {
        let (store, id) = freshStore()
        let cId = store.slackAddChannel(name: "planning", type: .channel, myAppId: id)!
        let msgId = store.slackPostMessage(
            channelId: cId, authorKind: .user, authorId: "user", text: "kickoff", myAppId: id
        )
        #expect(msgId != nil)
        let msgs = slack(store, id: id)?.messagesByChannel[cId] ?? []
        #expect(msgs.count == 1)
        #expect(msgs.first?.text == "kickoff")
        #expect(msgs.first?.authorKind == .user)

        let bogus = store.slackPostMessage(
            channelId: "channel-bogus", authorKind: .user, authorId: "user", text: "x", myAppId: id
        )
        #expect(bogus == nil)
    }

    @Test("slackPostMessage rejects empty / whitespace-only text")
    func postMessageEmpty() {
        let (store, id) = freshStore()
        let cId = store.slackAddChannel(name: "planning", type: .channel, myAppId: id)!
        let bad = store.slackPostMessage(
            channelId: cId, authorKind: .user, authorId: "user", text: "   ", myAppId: id
        )
        #expect(bad == nil)
        #expect((slack(store, id: id)?.messagesByChannel[cId] ?? []).isEmpty)
    }

    @Test("SlackView.parseMentions matches slug or display name, dedupes, preserves order")
    func parseMentions() {
        let agents = [sub("agent-1", "marketing"), sub("agent-2", "dev"), sub("agent-3", "research")]
        let text = "hey @marketing and @DEV — also @agent-1 again and @nobody"
        let ids = SlackView.parseMentions(text: text, agents: agents)
        #expect(ids == ["agent-1", "agent-2"])
    }

    @Test("slackComponentId resolves active / first slack component")
    func componentResolver() {
        let (store, id) = freshStore()
        let resolved = store.slackComponentId(myAppId: id)
        #expect(resolved == "slack-1")
    }

    @Test("slackOpenDM creates a DM channel the first time, returns the same one on repeat")
    func openDMIdempotent() {
        let (store, id) = freshStore()
        let firstDM = store.slackOpenDM(agentId: "marketing", displayName: "Marketing", myAppId: id)
        #expect(firstDM != nil)
        let s1 = slack(store, id: id)!
        let channel = s1.channels.first { $0.id == firstDM }!
        #expect(channel.type == .dm)
        #expect(channel.memberAgentIds == ["marketing"])
        #expect(channel.name == "Marketing")

        // Second call should reuse the same channel — no duplicates.
        let secondDM = store.slackOpenDM(agentId: "marketing", displayName: "Marketing", myAppId: id)
        #expect(secondDM == firstDM)
        #expect(slack(store, id: id)?.channels.count == 1)
    }

    @Test("slackOpenDM does NOT match a group DM that happens to contain the agent")
    func openDMNotConfusedByGroupDM() {
        let (store, id) = freshStore()
        _ = store.slackAddChannel(name: "team", type: .groupDM, memberAgentIds: ["marketing", "dev"], myAppId: id)
        let dm = store.slackOpenDM(agentId: "marketing", displayName: "Marketing", myAppId: id)
        let channel = slack(store, id: id)?.channels.first { $0.id == dm }
        #expect(channel?.type == .dm)
        #expect(channel?.memberAgentIds == ["marketing"])
    }

    @Test("activeMentionToken detects trailing @<partial> at end of text")
    func mentionTokenTrailing() {
        #expect(SlackView.activeMentionToken(in: "hey @mark")?.partial == "mark")
    }

    @Test("activeMentionToken detects a bare @ as empty-partial (show all agents)")
    func mentionTokenBareAt() {
        #expect(SlackView.activeMentionToken(in: "hey @")?.partial == "")
    }

    @Test("activeMentionToken returns nil when the @ is followed by whitespace")
    func mentionTokenFollowedBySpace() {
        #expect(SlackView.activeMentionToken(in: "hey @marketing draft a") == nil)
    }

    @Test("activeMentionToken requires @ at start-of-string or after whitespace")
    func mentionTokenWordBoundary() {
        #expect(SlackView.activeMentionToken(in: "foo@bar") == nil)
    }

    @Test("activeMentionToken handles @ at the very start of the composer")
    func mentionTokenAtStart() {
        #expect(SlackView.activeMentionToken(in: "@dev")?.partial == "dev")
    }

    // MARK: - Header / composer copy

    @Test("memberCountLabel pluralises: 0/1/N")
    func memberCountLabel() {
        #expect(SlackView.memberCountLabel(0) == "No members")
        #expect(SlackView.memberCountLabel(1) == "1 member")
        #expect(SlackView.memberCountLabel(2) == "2 members")
        #expect(SlackView.memberCountLabel(17) == "17 members")
    }

    @Test("composerPlaceholder includes the mention hint on regular widths, drops it on compact")
    func composerPlaceholderRegularVsCompact() {
        let channel = SlackChannel(id: "c1", name: "planning", type: .channel)
        #expect(SlackView.composerPlaceholder(for: channel, agents: [], compact: false)
            == "Message #planning — use @name to mention")
        #expect(SlackView.composerPlaceholder(for: channel, agents: [], compact: true)
            == "Message #planning")
    }

    @Test("composerPlaceholder for a DM names the recipient agent and drops the mention hint")
    func composerPlaceholderDM() {
        let agent = sub("marketing", "Marketing")
        let dm = SlackChannel(id: "c1", name: "Marketing", type: .dm, memberAgentIds: ["marketing"])
        #expect(SlackView.composerPlaceholder(for: dm, agents: [agent], compact: false) == "Message @Marketing")
        #expect(SlackView.composerPlaceholder(for: dm, agents: [agent], compact: true) == "Message @Marketing")
    }

    @Test("composerPlaceholder for a group DM uses the channel name without a # prefix")
    func composerPlaceholderGroupDM() {
        let channel = SlackChannel(id: "c1", name: "team-leads", type: .groupDM)
        #expect(SlackView.composerPlaceholder(for: channel, agents: [], compact: false)
            == "Message team-leads — use @name to mention")
        #expect(SlackView.composerPlaceholder(for: channel, agents: [], compact: true)
            == "Message team-leads")
    }

    // MARK: - Message-bubble mention rendering

    @Test("mentions(in:agents:) preserves order and includes EVERY occurrence (no dedup)")
    func mentionsRangesPreserveAllOccurrences() {
        let agents = [sub("a1", "marketing"), sub("a2", "dev")]
        let text = "hey @marketing and @dev — also @marketing again"
        let m = SlackView.mentions(in: text, agents: agents)
        #expect(m.map(\.agentId) == ["a1", "a2", "a1"])
        for mention in m {
            let substring = String(text[mention.range])
            #expect(substring.lowercased() == "@\(mention.agentName.lowercased())")
        }
    }

    @Test("mentions(in:agents:) is case-insensitive on the agent name")
    func mentionsCaseInsensitive() {
        let m = SlackView.mentions(in: "ping @MARKETING please", agents: [sub("a1", "marketing")])
        #expect(m.count == 1)
        #expect(m.first?.agentId == "a1")
    }

    @Test("mentions(in:agents:) skips unknown names")
    func mentionsSkipUnknown() {
        let m = SlackView.mentions(in: "@marketing @nobody @marketing", agents: [sub("a1", "marketing")])
        #expect(m.map(\.agentId) == ["a1", "a1"])
    }

    @Test("attributedMessageText links each @mention to pupa-mention://<agentId>")
    func attributedMessageTextLinks() {
        let attributed = SlackView.attributedMessageText(
            "@marketing then @dev", agents: [sub("a1", "marketing"), sub("a2", "dev")]
        )
        var foundLinks: Set<String> = []
        for run in attributed.runs where run.link != nil {
            foundLinks.insert(run.link!.absoluteString)
        }
        #expect(foundLinks == [
            "\(SlackView.mentionURLScheme)://a1",
            "\(SlackView.mentionURLScheme)://a2",
        ])
    }

    @Test("attributedMessageText leaves the string untouched when there are no mentions")
    func attributedMessageTextNoMentions() {
        let attributed = SlackView.attributedMessageText("just a plain message", agents: [])
        for run in attributed.runs { #expect(run.link == nil) }
        #expect(String(attributed.characters) == "just a plain message")
    }

    @Test("attributedMessageText renders **bold** as inlinePresentationIntent .stronglyEmphasized")
    func attributedMessageTextBold() {
        let attributed = SlackView.attributedMessageText("hello **world**", agents: [])
        #expect(String(attributed.characters) == "hello world")
        var sawStrong = false
        for run in attributed.runs {
            if run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true {
                if String(attributed.characters[run.range]).contains("world") { sawStrong = true }
            }
        }
        #expect(sawStrong)
    }

    @Test("attributedMessageText keeps @mention styling alongside bold markdown")
    func attributedMessageTextMentionAndBold() {
        let attributed = SlackView.attributedMessageText("Hello @dev **friend**", agents: [sub("a1", "dev")])
        let plain = String(attributed.characters)
        #expect(plain == "Hello @dev friend")
        #expect(!plain.contains("**"))
        var mentionURL: URL?
        var sawStrong = false
        for run in attributed.runs {
            let runText = String(attributed.characters[run.range])
            if runText.contains("@dev"), let link = run.link { mentionURL = link }
            if run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true { sawStrong = true }
        }
        #expect(mentionURL?.absoluteString == "\(SlackView.mentionURLScheme)://a1")
        #expect(sawStrong)
    }

    @Test("attributedMessageText falls back to plain text on malformed markdown")
    func attributedMessageTextMalformedFallback() {
        let attributed = SlackView.attributedMessageText("oops **unterminated", agents: [])
        let plain = String(attributed.characters)
        #expect(!plain.isEmpty)
        #expect(plain.contains("unterminated"))
    }
}
