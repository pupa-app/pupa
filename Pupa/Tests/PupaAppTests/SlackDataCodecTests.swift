import Foundation
import Testing
@testable import PupaApp

/// Tests for the Slack component's data model: round-trip encode /
/// decode of every type, backward-compatible decoding of partial
/// blobs, and `CanvasApp.slack(...)` integration with the existing
/// discriminated-union codec. Agents are filesystem subagents now —
/// `SlackData` holds only channels + messages.
@Suite("Slack data codec")
struct SlackDataCodecTests {

    private func roundTrip<T: Codable & Equatable>(_ value: T) throws -> T {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(T.self, from: data)
    }

    @Test("SlackChannel round-trips with members + subscribers")
    func slackChannelRoundTrip() throws {
        let channel = SlackChannel(
            id: "planning",
            name: "planning",
            type: .channel,
            memberAgentIds: ["scout", "analyst"],
            subscriberAgentIds: ["digest"]
        )
        #expect(try roundTrip(channel) == channel)
    }

    @Test("SlackMessage round-trips with mentions and timestamp")
    func slackMessageRoundTrip() throws {
        let msg = SlackMessage(
            id: "m1",
            channelId: "planning",
            authorKind: .user,
            authorId: "user",
            text: "hello @marketing",
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            mentionedAgentIds: ["marketing"]
        )
        #expect(try roundTrip(msg) == msg)
    }

    @Test("SlackData round-trips a fully populated blob")
    func slackDataRoundTrip() throws {
        let data = SlackData(
            channels: [
                SlackChannel(id: "c1", name: "planning", type: .channel, memberAgentIds: ["scout", "dev"]),
            ],
            messagesByChannel: [
                "c1": [
                    SlackMessage(channelId: "c1", authorKind: .user, authorId: "user", text: "kickoff"),
                ],
            ],
            activeChannelId: "c1"
        )
        #expect(try roundTrip(data) == data)
    }

    @Test("SlackData decodes from an empty JSON object — every field defaults")
    func slackDataDecodesFromEmpty() throws {
        let json = Data("{}".utf8)
        let decoded = try JSONDecoder().decode(SlackData.self, from: json)
        #expect(decoded.channels.isEmpty)
        #expect(decoded.messagesByChannel.isEmpty)
        #expect(decoded.activeChannelId == nil)
    }

    @Test("A legacy `agents` key is ignored (pre-subagent blob decodes cleanly)")
    func legacyAgentsKeyIgnored() throws {
        let json = Data("""
        {"agents":[{"id":"a1","name":"marketing","role":"","systemPromptAddition":""}],
         "channels":[{"id":"c1","name":"planning","type":"channel","memberAgentIds":["a1"],"subscriberAgentIds":[]}],
         "messagesByChannel":{},"activeChannelId":"c1"}
        """.utf8)
        let decoded = try JSONDecoder().decode(SlackData.self, from: json)
        #expect(decoded.channels.map(\.id) == ["c1"])
        #expect(decoded.channels.first?.memberAgentIds == ["a1"])
        #expect(decoded.activeChannelId == "c1")
    }

    @Test("CanvasApp.slack encodes with kind=slack and round-trips")
    func canvasAppSlackRoundTrip() throws {
        let body: CanvasApp = .slack(SlackData(
            channels: [SlackChannel(id: "c1", name: "planning", type: .channel, memberAgentIds: ["scout"])]
        ))
        let encoded = try JSONEncoder().encode(body)
        let envelope = try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        #expect(envelope?["kind"] as? String == "slack")
        let decoded = try JSONDecoder().decode(CanvasApp.self, from: encoded)
        #expect(decoded == body)
        #expect(decoded.kindString == "slack")
    }

    @Test("CanvasApp.emptyBody(forKind: \"slack\") returns an empty SlackData")
    func emptyBodyForSlack() {
        let body = CanvasApp.emptyBody(forKind: "slack")
        guard case .slack(let s) = body else {
            Issue.record("expected .slack")
            return
        }
        #expect(s.channels.isEmpty)
        #expect(s.messagesByChannel.isEmpty)
        #expect(s.activeChannelId == nil)
        #expect(body.kindString == "slack")
    }
}
