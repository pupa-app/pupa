import Foundation
import Testing
@testable import PupaApp

/// `SlackChannelKey` scopes `SlackView`'s per-channel scroll anchor. These
/// tests pin the premise it exists for: channel ids are unique within one
/// Slack component, not across components or MiniApps.
@MainActor
@Suite("Slack channel key")
struct SlackChannelKeyTests {

    private func miniApp(_ name: String) -> MiniApp {
        MiniAppTypeRegistry.shared.registerBuiltins()
        return MiniApp(
            name: name,
            iconSystemName: "bubble.left.and.bubble.right",
            typeId: MiniAppType.tracker.id
        )
    }

    /// The bug: `MiniAppStore.nextSlackId` uniques against one Slack component's
    /// own channels, so the first channel of every component is `channel-1`.
    /// A scroll anchor keyed on the channel id alone therefore aliases two
    /// different channels — one workspace's scroll position restored into
    /// another's message list.
    @Test("Two Slack components each mint channel-1, in one MiniApp and across two")
    func channelIdsRepeatAcrossComponents() throws {
        let a = miniApp("A")
        let b = miniApp("B")
        let store = MiniAppStore(initial: ([a, b], a.id))

        let slackA1 = try #require(store.addComponent(
            kind: "slack", name: "One", iconSystemName: "bubble.left", miniAppId: a.id))
        let slackA2 = try #require(store.addComponent(
            kind: "slack", name: "Two", iconSystemName: "bubble.left", miniAppId: a.id))
        let slackB1 = try #require(store.addComponent(
            kind: "slack", name: "One", iconSystemName: "bubble.left", miniAppId: b.id))

        let chA1 = try #require(store.slackAddChannel(
            name: "general", type: .channel, miniAppId: a.id, componentId: slackA1))
        let chA2 = try #require(store.slackAddChannel(
            name: "general", type: .channel, miniAppId: a.id, componentId: slackA2))
        let chB1 = try #require(store.slackAddChannel(
            name: "general", type: .channel, miniAppId: b.id, componentId: slackB1))

        // Two Slack components inside ONE MiniApp collide too — which is why the
        // MiniApp id alone is not enough to separate them.
        #expect(chA1 == chA2)
        // And so do two MiniApps' first components.
        #expect(chA1 == chB1)

        // ... so the channel id cannot be the key. All three must stay apart.
        let keys = Set([
            SlackChannelKey(miniAppId: a.id, componentId: slackA1, channelId: chA1),
            SlackChannelKey(miniAppId: a.id, componentId: slackA2, channelId: chA2),
            SlackChannelKey(miniAppId: b.id, componentId: slackB1, channelId: chB1),
        ])
        #expect(keys.count == 3, "three distinct channels must be three distinct keys")
    }

    /// Channels within one component still separate, so switching channels in
    /// a workspace keeps each one's own scroll position.
    @Test("Channels inside one component keep distinct keys")
    func channelsWithinOneComponentAreDistinct() throws {
        let a = miniApp("A")
        let store = MiniAppStore(initial: ([a], a.id))
        let slack = try #require(store.addComponent(
            kind: "slack", name: "S", iconSystemName: "bubble.left", miniAppId: a.id))

        let first = try #require(store.slackAddChannel(
            name: "general", type: .channel, miniAppId: a.id, componentId: slack))
        let second = try #require(store.slackAddChannel(
            name: "random", type: .channel, miniAppId: a.id, componentId: slack))

        #expect(first == "channel-1")
        #expect(second == "channel-2")
        #expect(
            SlackChannelKey(miniAppId: a.id, componentId: slack, channelId: first)
            != SlackChannelKey(miniAppId: a.id, componentId: slack, channelId: second)
        )
    }

    /// Same channel, two lookups: equal and same hash, so a read finds the
    /// entry its own write left behind.
    @Test("Same miniApp + component + channel is one key")
    func sameChannelIsOneKey() {
        let id = UUID()
        let lhs = SlackChannelKey(miniAppId: id, componentId: "slack-1", channelId: "channel-1")
        let rhs = SlackChannelKey(miniAppId: id, componentId: "slack-1", channelId: "channel-1")

        #expect(lhs == rhs)
        #expect(lhs.hashValue == rhs.hashValue)
        var anchors: [SlackChannelKey: String] = [:]
        anchors[lhs] = "message-7"
        #expect(anchors[rhs] == "message-7")
    }

    /// The leak itself, at the dictionary the view actually keeps: two
    /// workspaces' `channel-1` must not read each other's anchor.
    @Test("A second workspace's channel-1 does not inherit the first's anchor")
    func anchorsDoNotAliasAcrossComponents() {
        let id = UUID()
        let inFirst = SlackChannelKey(miniAppId: id, componentId: "slack-1", channelId: "channel-1")
        let inSecond = SlackChannelKey(miniAppId: id, componentId: "slack-2", channelId: "channel-1")

        var anchors: [SlackChannelKey: String] = [:]
        anchors[inFirst] = "message-42"

        #expect(anchors[inSecond] == nil, "the second workspace falls back to the bottom anchor")
        #expect(anchors.count == 1)
    }
}
