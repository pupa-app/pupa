import Foundation
import Testing
@testable import PupaApp

/// Tests for the `MyAppStore.slack*` mutators that back both the
/// inline SlackView buttons and (in step 4) the Slack frontend tools.
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

    @Test("addComponent(kind: slack) seeds an empty SlackData body")
    func addComponentSlack() {
        let (store, id) = freshStore()
        let s = slack(store, id: id)
        #expect(s != nil)
        #expect(s?.agents.isEmpty == true)
        #expect(s?.channels.isEmpty == true)
        #expect(s?.activeChannelId == nil)
    }

    @Test("slackAddAgent allocates stable agent-N ids and appends")
    func addAgent() {
        let (store, id) = freshStore()
        let a1 = store.slackAddAgent(name: "marketing", role: "", systemPromptAddition: "", myAppId: id)
        let a2 = store.slackAddAgent(name: "dev", role: "", systemPromptAddition: "", myAppId: id)
        #expect(a1 == "agent-1")
        #expect(a2 == "agent-2")
        #expect(slack(store, id: id)?.agents.count == 2)
    }

    @Test("slackAddAgent refuses empty names")
    func addAgentEmpty() {
        let (store, id) = freshStore()
        let bad = store.slackAddAgent(name: "   ", role: "", systemPromptAddition: "", myAppId: id)
        #expect(bad == nil)
        #expect(slack(store, id: id)?.agents.isEmpty == true)
    }

    @Test("slackAddChannel filters memberAgentIds to known agents and sets active when first")
    func addChannel() {
        let (store, id) = freshStore()
        _ = store.slackAddAgent(name: "marketing", role: "", systemPromptAddition: "", myAppId: id)
        _ = store.slackAddAgent(name: "dev", role: "", systemPromptAddition: "", myAppId: id)
        let cId = store.slackAddChannel(
            name: "planning",
            type: .channel,
            memberAgentIds: ["agent-1", "agent-2", "agent-bogus"],
            myAppId: id
        )
        #expect(cId == "channel-1")
        let s = slack(store, id: id)
        #expect(s?.channels.first?.memberAgentIds == ["agent-1", "agent-2"])
        #expect(s?.activeChannelId == cId)
    }

    @Test("slackAddAgentsToChannel is idempotent and ignores unknown agent ids")
    func addAgentsToChannel() {
        let (store, id) = freshStore()
        _ = store.slackAddAgent(name: "marketing", role: "", systemPromptAddition: "", myAppId: id)
        _ = store.slackAddAgent(name: "dev", role: "", systemPromptAddition: "", myAppId: id)
        let cId = store.slackAddChannel(name: "planning", type: .channel, myAppId: id)!

        let first = store.slackAddAgentsToChannel(channelId: cId, agentIds: ["agent-1"], myAppId: id)
        #expect(first == true)
        // Idempotent: same id again is a no-op.
        let second = store.slackAddAgentsToChannel(channelId: cId, agentIds: ["agent-1"], myAppId: id)
        #expect(second == false)
        // Unknown id is dropped, but agent-2 is added.
        let mixed = store.slackAddAgentsToChannel(channelId: cId, agentIds: ["agent-bogus", "agent-2"], myAppId: id)
        #expect(mixed == true)
        #expect(slack(store, id: id)?.channels.first?.memberAgentIds == ["agent-1", "agent-2"])
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
            channelId: cId,
            authorKind: .user,
            authorId: "user",
            text: "kickoff",
            myAppId: id
        )
        #expect(msgId != nil)
        let msgs = slack(store, id: id)?.messagesByChannel[cId] ?? []
        #expect(msgs.count == 1)
        #expect(msgs.first?.text == "kickoff")
        #expect(msgs.first?.authorKind == .user)

        let bogus = store.slackPostMessage(
            channelId: "channel-bogus",
            authorKind: .user,
            authorId: "user",
            text: "x",
            myAppId: id
        )
        #expect(bogus == nil)
    }

    @Test("slackPostMessage rejects empty / whitespace-only text")
    func postMessageEmpty() {
        let (store, id) = freshStore()
        let cId = store.slackAddChannel(name: "planning", type: .channel, myAppId: id)!
        let bad = store.slackPostMessage(
            channelId: cId,
            authorKind: .user,
            authorId: "user",
            text: "   ",
            myAppId: id
        )
        #expect(bad == nil)
        #expect((slack(store, id: id)?.messagesByChannel[cId] ?? []).isEmpty)
    }

    @Test("SlackView.parseMentions is case-insensitive, dedupes, preserves order")
    func parseMentions() {
        let agents = [
            SlackAgent(id: "agent-1", name: "marketing", role: "", systemPromptAddition: ""),
            SlackAgent(id: "agent-2", name: "dev", role: "", systemPromptAddition: ""),
            SlackAgent(id: "agent-3", name: "research", role: "", systemPromptAddition: ""),
        ]
        let text = "hey @marketing and @DEV — also @marketing again and @nobody"
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
        let agentId = store.slackAddAgent(name: "marketing", role: "", systemPromptAddition: "", myAppId: id)!

        let firstDM = store.slackOpenDM(agentId: agentId, myAppId: id)
        #expect(firstDM != nil)
        let s1 = slack(store, id: id)!
        let channel = s1.channels.first { $0.id == firstDM }!
        #expect(channel.type == .dm)
        #expect(channel.memberAgentIds == [agentId])
        #expect(channel.name == "marketing")

        // Second call should reuse the same channel — no duplicates.
        let secondDM = store.slackOpenDM(agentId: agentId, myAppId: id)
        #expect(secondDM == firstDM)
        #expect(slack(store, id: id)?.channels.count == 1)
    }

    @Test("slackOpenDM does NOT match a group DM that happens to contain the agent")
    func openDMNotConfusedByGroupDM() {
        let (store, id) = freshStore()
        let a1 = store.slackAddAgent(name: "marketing", role: "", systemPromptAddition: "", myAppId: id)!
        let a2 = store.slackAddAgent(name: "dev", role: "", systemPromptAddition: "", myAppId: id)!
        // Group DM with both agents — must not be confused with a 1-on-1.
        _ = store.slackAddChannel(
            name: "team",
            type: .groupDM,
            memberAgentIds: [a1, a2],
            myAppId: id
        )
        let dm = store.slackOpenDM(agentId: a1, myAppId: id)
        let channel = slack(store, id: id)?.channels.first { $0.id == dm }
        #expect(channel?.type == .dm)
        #expect(channel?.memberAgentIds == [a1])
    }

    @Test("slackOpenDM returns nil for unknown agent")
    func openDMUnknownAgent() {
        let (store, id) = freshStore()
        let dm = store.slackOpenDM(agentId: "agent-bogus", myAppId: id)
        #expect(dm == nil)
    }

    @Test("activeMentionToken detects trailing @<partial> at end of text")
    func mentionTokenTrailing() {
        let token = SlackView.activeMentionToken(in: "hey @mark")
        #expect(token?.partial == "mark")
    }

    @Test("activeMentionToken detects a bare @ as empty-partial (show all agents)")
    func mentionTokenBareAt() {
        let token = SlackView.activeMentionToken(in: "hey @")
        #expect(token?.partial == "")
    }

    @Test("activeMentionToken returns nil when the @ is followed by whitespace")
    func mentionTokenFollowedBySpace() {
        // Once the user finishes typing the mention by hitting space,
        // the palette should dismiss.
        let token = SlackView.activeMentionToken(in: "hey @marketing draft a")
        #expect(token == nil)
    }

    @Test("activeMentionToken requires @ at start-of-string or after whitespace")
    func mentionTokenWordBoundary() {
        // Embedded `@` in an email-like token is not a mention.
        let token = SlackView.activeMentionToken(in: "foo@bar")
        #expect(token == nil)
    }

    @Test("activeMentionToken handles @ at the very start of the composer")
    func mentionTokenAtStart() {
        let token = SlackView.activeMentionToken(in: "@dev")
        #expect(token?.partial == "dev")
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
        let regular = SlackView.composerPlaceholder(for: channel, agents: [], compact: false)
        let compact = SlackView.composerPlaceholder(for: channel, agents: [], compact: true)
        #expect(regular == "Message #planning — use @name to mention")
        #expect(compact == "Message #planning")
    }

    @Test("composerPlaceholder for a DM names the recipient agent and drops the mention hint")
    func composerPlaceholderDM() {
        let agent = SlackAgent(id: "a1", name: "marketing", role: "", systemPromptAddition: "")
        let dm = SlackChannel(id: "c1", name: "marketing", type: .dm, memberAgentIds: ["a1"])
        let regular = SlackView.composerPlaceholder(for: dm, agents: [agent], compact: false)
        let compact = SlackView.composerPlaceholder(for: dm, agents: [agent], compact: true)
        // Both densities show the same string in DMs — the hint
        // was already irrelevant there.
        #expect(regular == "Message @marketing")
        #expect(compact == "Message @marketing")
    }

    @Test("composerPlaceholder for a group DM uses the channel name without a # prefix")
    func composerPlaceholderGroupDM() {
        let channel = SlackChannel(id: "c1", name: "team-leads", type: .groupDM)
        let regular = SlackView.composerPlaceholder(for: channel, agents: [], compact: false)
        let compact = SlackView.composerPlaceholder(for: channel, agents: [], compact: true)
        #expect(regular == "Message team-leads — use @name to mention")
        #expect(compact == "Message team-leads")
    }

    // MARK: - Message-bubble mention rendering

    @Test("mentions(in:agents:) preserves order and includes EVERY occurrence (no dedup)")
    func mentionsRangesPreserveAllOccurrences() {
        let agents = [
            SlackAgent(id: "a1", name: "marketing", role: "", systemPromptAddition: ""),
            SlackAgent(id: "a2", name: "dev", role: "", systemPromptAddition: ""),
        ]
        let text = "hey @marketing and @dev — also @marketing again"
        let m = SlackView.mentions(in: text, agents: agents)
        // Three matches: marketing, dev, marketing — keep all three
        // (unlike `parseMentions` which dedups for fan-out).
        #expect(m.map(\.agentId) == ["a1", "a2", "a1"])
        // Each range should map back to the literal @name in the
        // source text.
        for mention in m {
            let substring = String(text[mention.range])
            #expect(substring.lowercased() == "@\(mention.agentName.lowercased())")
        }
    }

    @Test("mentions(in:agents:) is case-insensitive on the agent name")
    func mentionsCaseInsensitive() {
        let agents = [SlackAgent(id: "a1", name: "marketing", role: "", systemPromptAddition: "")]
        let m = SlackView.mentions(in: "ping @MARKETING please", agents: agents)
        #expect(m.count == 1)
        #expect(m.first?.agentId == "a1")
    }

    @Test("mentions(in:agents:) skips unknown names")
    func mentionsSkipUnknown() {
        let agents = [SlackAgent(id: "a1", name: "marketing", role: "", systemPromptAddition: "")]
        let m = SlackView.mentions(in: "@marketing @nobody @marketing", agents: agents)
        #expect(m.map(\.agentId) == ["a1", "a1"])
    }

    @Test("attributedMessageText links each @mention to pupa-mention://<agentId>")
    func attributedMessageTextLinks() {
        let a1 = SlackAgent(id: "a1", name: "marketing", role: "", systemPromptAddition: "")
        let a2 = SlackAgent(id: "a2", name: "dev", role: "", systemPromptAddition: "")
        let attributed = SlackView.attributedMessageText("@marketing then @dev", agents: [a1, a2])
        // Scan every run; collect the URLs found on attributed
        // runs. Should be two distinct mention URLs.
        var foundLinks: Set<String> = []
        for run in attributed.runs {
            if let url = run.link {
                foundLinks.insert(url.absoluteString)
            }
        }
        #expect(foundLinks == [
            "\(SlackView.mentionURLScheme)://a1",
            "\(SlackView.mentionURLScheme)://a2",
        ])
    }

    @Test("attributedMessageText leaves the string untouched when there are no mentions")
    func attributedMessageTextNoMentions() {
        let attributed = SlackView.attributedMessageText("just a plain message", agents: [])
        // No runs should carry a link attribute.
        for run in attributed.runs {
            #expect(run.link == nil)
        }
        #expect(String(attributed.characters) == "just a plain message")
    }

    @Test("attributedMessageText renders **bold** as inlinePresentationIntent .stronglyEmphasized")
    func attributedMessageTextBold() {
        let attributed = SlackView.attributedMessageText("hello **world**", agents: [])
        // The asterisks should be gone from the parsed plain text.
        let plain = String(attributed.characters)
        #expect(plain == "hello world")
        // Some run covering the word "world" should carry
        // .stronglyEmphasized.
        var sawStrong = false
        for run in attributed.runs {
            if run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true {
                let runText = String(attributed.characters[run.range])
                if runText.contains("world") {
                    sawStrong = true
                }
            }
        }
        #expect(sawStrong)
    }

    @Test("attributedMessageText keeps @mention styling alongside bold markdown")
    func attributedMessageTextMentionAndBold() {
        let a1 = SlackAgent(id: "a1", name: "dev", role: "", systemPromptAddition: "")
        let attributed = SlackView.attributedMessageText("Hello @dev **friend**", agents: [a1])
        let plain = String(attributed.characters)
        // Asterisks are stripped; mention text is preserved.
        #expect(plain == "Hello @dev friend")
        #expect(!plain.contains("**"))
        // (a) "@dev" run should carry the mention URL.
        var mentionURL: URL?
        var sawStrong = false
        for run in attributed.runs {
            let runText = String(attributed.characters[run.range])
            if runText.contains("@dev"), let link = run.link {
                mentionURL = link
            }
            if run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true {
                sawStrong = true
            }
        }
        #expect(mentionURL?.absoluteString == "\(SlackView.mentionURLScheme)://a1")
        // (b) some run carries .stronglyEmphasized.
        #expect(sawStrong)
    }

    @Test("attributedMessageText falls back to plain text on malformed markdown")
    func attributedMessageTextMalformedFallback() {
        // Apple's parser is lenient; we only assert no crash and
        // that the visible characters still contain the word
        // "unterminated".
        let attributed = SlackView.attributedMessageText("oops **unterminated", agents: [])
        let plain = String(attributed.characters)
        #expect(!plain.isEmpty)
        #expect(plain.contains("unterminated"))
    }
}
