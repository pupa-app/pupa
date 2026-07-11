import Foundation
import Testing
@testable import PupaApp

/// Tests for `ChatSessionCoordinator.slackInvocationPrompt` — the
/// channel-transcript-to-user-message rendering that drives every
/// Slack subagent invocation. The string the model receives is the
/// only signal it gets about "who's saying what and what should I
/// respond to", so we pin its shape.
@MainActor
@Suite("Slack invocation prompt")
struct SlackInvocationPromptTests {

    private func channel(name: String, type: SlackChannelType = .channel) -> SlackChannel {
        SlackChannel(id: "c1", name: name, type: type)
    }

    private func msg(
        _ kind: SlackAuthorKind,
        _ authorId: String,
        _ text: String,
        time: TimeInterval,
        id: String? = nil
    ) -> SlackMessage {
        SlackMessage(
            id: id ?? UUID().uuidString,
            channelId: "c1",
            authorKind: kind,
            authorId: authorId,
            text: text,
            timestamp: Date(timeIntervalSince1970: time)
        )
    }

    @Test("Channel prefix is `#` for .channel, blank for DMs / group DMs")
    func channelPrefix() {
        let normalPrompt = ChatSessionCoordinator.slackInvocationPrompt(
            agentName: "marketing", agentSlug: "marketing",
            channel: channel(name: "planning", type: .channel),
            history: []
        )
        let dmPrompt = ChatSessionCoordinator.slackInvocationPrompt(
            agentName: "marketing", agentSlug: "marketing",
            channel: channel(name: "marketing", type: .dm),
            history: []
        )
        #expect(normalPrompt.contains("#planning"))
        #expect(!dmPrompt.contains("#marketing"))
        #expect(dmPrompt.contains("in marketing"))
    }

    @Test("Agent's own prior messages render as `you:`; other agents render by their slug")
    func ownVsOthers() {
        let history: [SlackMessage] = [
            msg(.user, "user", "hi @marketing", time: 1_700_000_000),
            msg(.agent, "marketing", "hello!", time: 1_700_000_060),
            msg(.agent, "dev", "i jumped in", time: 1_700_000_120),
        ]
        let prompt = ChatSessionCoordinator.slackInvocationPrompt(
            agentName: "marketing", agentSlug: "marketing",
            channel: channel(name: "planning"),
            history: history
        )
        #expect(prompt.contains("user: hi @marketing"))
        #expect(prompt.contains("you: hello!"))
        #expect(prompt.contains("dev: i jumped in"))
        // The agent must NOT see its own posts labelled as themselves
        // by slug — that would conflict with the `you:` convention.
        #expect(!prompt.contains("marketing: hello!"))
    }

    @Test("Reply instruction names the invoked agent")
    func replyInstructionPersonalised() {
        let prompt = ChatSessionCoordinator.slackInvocationPrompt(
            agentName: "research", agentSlug: "research",
            channel: channel(name: "planning"),
            history: []
        )
        #expect(prompt.contains("Reply once as research"))
    }

    @Test("Transcript respects chronological order regardless of input order")
    func transcriptChronology() {
        let history: [SlackMessage] = [
            msg(.user, "user", "first", time: 1_700_000_000),
            msg(.agent, "marketing", "second", time: 1_700_000_060),
            msg(.user, "user", "third", time: 1_700_000_120),
        ]
        let prompt = ChatSessionCoordinator.slackInvocationPrompt(
            agentName: "marketing", agentSlug: "marketing",
            channel: channel(name: "planning"),
            history: history
        )
        let lines = prompt.split(separator: "\n").map(String.init)
        let firstIdx = lines.firstIndex(where: { $0.contains("first") })
        let secondIdx = lines.firstIndex(where: { $0.contains("second") })
        let thirdIdx = lines.firstIndex(where: { $0.contains("third") })
        #expect(firstIdx != nil && secondIdx != nil && thirdIdx != nil)
        #expect(firstIdx! < secondIdx!)
        #expect(secondIdx! < thirdIdx!)
    }

    @Test("Transcript is capped to the last N messages with a pagination hint when history exceeds the cap")
    func transcriptCappedWithHint() {
        let totalCount = ChatSessionCoordinator.slackInvocationHistoryLimit + 5
        var history: [SlackMessage] = []
        for i in 0..<totalCount {
            history.append(msg(
                .user, "user", "msg-\(i)",
                time: 1_700_000_000 + TimeInterval(i * 60),
                id: "id-\(i)"
            ))
        }
        let cap = ChatSessionCoordinator.slackInvocationHistoryLimit
        let visibleStart = totalCount - cap
        let prompt = ChatSessionCoordinator.slackInvocationPrompt(
            agentName: "marketing", agentSlug: "marketing",
            channel: channel(name: "planning"),
            history: history
        )
        #expect(prompt.contains("last \(cap) of \(totalCount) messages"))
        #expect(prompt.contains("slackReadChannelHistory"))
        #expect(prompt.contains("id-\(visibleStart)"))
        #expect(!prompt.contains("msg-0:"))
        #expect(!prompt.contains("msg-0\n"))
        #expect(prompt.contains("msg-\(totalCount - 1)"))
    }

    @Test("No truncation hint when history fits within the cap")
    func noHintWhenWithinCap() {
        let history: [SlackMessage] = [
            msg(.user, "user", "only", time: 1_700_000_000, id: "id-0"),
        ]
        let prompt = ChatSessionCoordinator.slackInvocationPrompt(
            agentName: "marketing", agentSlug: "marketing",
            channel: channel(name: "planning"),
            history: history
        )
        #expect(!prompt.contains("of 1 messages"))
        #expect(!prompt.contains("slackReadChannelHistory"))
        #expect(prompt.contains("user: only"))
    }

    @Test("Explicit historyLimit override is honoured")
    func explicitLimitOverride() {
        let history: [SlackMessage] = (0..<4).map { i in
            msg(.user, "user", "m\(i)", time: 1_700_000_000 + TimeInterval(i * 60), id: "id-\(i)")
        }
        let prompt = ChatSessionCoordinator.slackInvocationPrompt(
            agentName: "marketing", agentSlug: "marketing",
            channel: channel(name: "planning"),
            history: history,
            historyLimit: 2
        )
        #expect(prompt.contains("last 2 of 4 messages"))
        #expect(prompt.contains("id-2"))
        #expect(!prompt.contains("user: m0"))
        #expect(!prompt.contains("user: m1"))
        #expect(prompt.contains("user: m2"))
        #expect(prompt.contains("user: m3"))
    }
}
