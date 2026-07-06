import Foundation
import Testing
import AGUIKit
@testable import PupaApp

/// Tests for `AppTools.registerSlackTools` — admin gating, the
/// `slackPostMessage` fan-out shape, and per-channel discovery. Agents are
/// filesystem subagents (`pupa/agents/`), seeded via `AgentStore` and read by
/// the tools through the passed-in `memory`. The full invocation path (real
/// `AgentSession`) is exercised via `make mac-demo`; here we pin the tool
/// surface with stubbed `invoke` / `markMessagePosted` closures.
@MainActor
@Suite("Slack tools")
struct SlackToolsTests {

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

    /// A temp, isolated memory store to hold the subagent roster. Seed agents
    /// into it via `AgentStore(memory:).createAgent`.
    private func tempMemory() -> MemoryStore {
        MemoryStore(rootOverride: FileManager.default.temporaryDirectory
            .appendingPathComponent("pupa-slacktools-\(UUID().uuidString)", isDirectory: true))
    }

    private func makeRegistry(
        store: MyAppStore,
        myAppId: UUID,
        memory: MemoryStore? = nil,
        currentAgentId: String?,
        invokeOutcome: SlackInvoker.InvocationOutcome = .completed(text: "ok", postedMessageId: "msg-x")
    ) -> ToolRegistry {
        let registry = ToolRegistry()
        let logBox = CallLogBox()
        AppTools.registerSlackTools(
            on: registry,
            store: store,
            myAppId: myAppId,
            memory: memory,
            context: AppTools.SlackToolContext(
                currentAgentId: currentAgentId,
                invoke: { agentId, channelId in
                    await logBox.recordInvocation(agentId: agentId, channelId: channelId)
                    return invokeOutcome
                },
                resolveAgentId: { _ in nil },
                markMessagePosted: { agentId in
                    await logBox.recordPost(agentId: agentId)
                }
            )
        )
        return registry
    }

    private actor CallLogBox {
        func recordInvocation(agentId: String, channelId: String) {}
        func recordPost(agentId: String) {}
    }

    @Test("Discovery tools return the live channel + agent rosters")
    func discovery() async throws {
        let (store, myAppId) = freshStore()
        let mem = tempMemory()
        try AgentStore(memory: mem).createAgent(name: "marketing", description: "marketing")
        _ = store.slackAddChannel(name: "planning", type: .channel, myAppId: myAppId)
        let registry = makeRegistry(store: store, myAppId: myAppId, memory: mem, currentAgentId: nil)

        let agents = try await registry.resolve("slackListAgents")!.handler(.object([:]))
        let agentList = agents.objectValue?["agents"]?.arrayValue?.compactMap { $0.objectValue?["name"]?.stringValue }
        #expect(agentList == ["marketing"])

        let channels = try await registry.resolve("slackListChannels")!.handler(.object([:]))
        let channelList = channels.objectValue?["channels"]?.arrayValue?.compactMap { $0.objectValue?["name"]?.stringValue }
        #expect(channelList == ["planning"])
    }

    @Test("slackPostMessage refuses when there's no sub-agent context (main chat caller)")
    func postMessageRefusedForMainChat() async throws {
        let (store, myAppId) = freshStore()
        let registry = makeRegistry(store: store, myAppId: myAppId, currentAgentId: nil)
        let result = try await registry.resolve("slackPostMessage")!.handler(.object([
            "channelId": .string("channel-1"),
            "text": .string("hi"),
        ]))
        #expect(result.objectValue?["ok"]?.boolValue == false)
        #expect(result.objectValue?["error"]?.stringValue?.contains("sub-agent context") == true)
    }

    @Test("Channel-admin tools refuse when called by a sub-agent")
    func adminToolsRefuseForSubAgents() async throws {
        let (store, myAppId) = freshStore()
        let registry = makeRegistry(store: store, myAppId: myAppId, currentAgentId: "agent-x")

        let createCh = try await registry.resolve("slackCreateChannels")!.handler(.object([
            "channels": .array([.object([
                "name": .string("planning"),
                "type": .string("channel"),
            ])]),
        ]))
        #expect(createCh.objectValue?["ok"]?.boolValue == false)
        #expect(createCh.objectValue?["error"]?.stringValue?.contains("main chat agent") == true)
    }

    @Test("Channel-admin tools succeed for the main chat agent (currentAgentId: nil)")
    func adminToolsSucceedForMainChat() async throws {
        let (store, myAppId) = freshStore()
        let registry = makeRegistry(store: store, myAppId: myAppId, currentAgentId: nil)

        let createCh = try await registry.resolve("slackCreateChannels")!.handler(.object([
            "channels": .array([
                .object(["name": .string("planning"), "type": .string("channel")]),
                .object(["name": .string("design"), "type": .string("channel")]),
            ]),
        ]))
        let createdNames = createCh.objectValue?["created"]?.arrayValue?
            .compactMap { $0.objectValue?["name"]?.stringValue }
        #expect(createdNames == ["planning", "design"])
    }

    @Test("slackPostMessage fans out to @-mentioned agents and surfaces outcomes")
    func postMessageFanOut() async throws {
        let (store, myAppId) = freshStore()
        let mem = tempMemory()
        try AgentStore(memory: mem).createAgent(name: "dev", description: "dev")
        try AgentStore(memory: mem).createAgent(name: "research", description: "")
        let channelId = store.slackAddChannel(name: "planning", type: .channel, myAppId: myAppId)!

        let registry = makeRegistry(
            store: store, myAppId: myAppId, memory: mem, currentAgentId: "dev",
            invokeOutcome: .completed(text: "researched it", postedMessageId: "msg-research")
        )

        let result = try await registry.resolve("slackPostMessage")!.handler(.object([
            "channelId": .string(channelId),
            "text": .string("found a bug, @research take a look"),
        ]))
        #expect(result.objectValue?["ok"]?.boolValue == true)
        #expect(result.objectValue?["channelId"]?.stringValue == channelId)
        let fanOut = result.objectValue?["fanOut"]?.arrayValue ?? []
        #expect(fanOut.count == 1)
        #expect(fanOut.first?.objectValue?["agentId"]?.stringValue == "research")
        #expect(fanOut.first?.objectValue?["outcome"]?.stringValue == "completed")
        // The message landed in the store with the agent author (the dev slug).
        let posted = (store.myApps.first?.components.compactMap { c -> SlackData? in
            if case .slack(let s) = c.body { return s }
            return nil
        }.first?.messagesByChannel[channelId] ?? [])
        #expect(posted.count == 1)
        #expect(posted.first?.authorKind == .agent)
        #expect(posted.first?.authorId == "dev")
    }

    @Test("slackPostMessage encodes a reentrant fan-out outcome with an error message")
    func postMessageReentrantOutcome() async throws {
        let (store, myAppId) = freshStore()
        let mem = tempMemory()
        try AgentStore(memory: mem).createAgent(name: "dev", description: "")
        try AgentStore(memory: mem).createAgent(name: "marketing", description: "")
        let channelId = store.slackAddChannel(name: "planning", type: .channel, myAppId: myAppId)!

        let registry = makeRegistry(
            store: store, myAppId: myAppId, memory: mem, currentAgentId: "dev",
            invokeOutcome: .reentrant(targetName: "marketing")
        )

        let result = try await registry.resolve("slackPostMessage")!.handler(.object([
            "channelId": .string(channelId),
            "text": .string("@marketing what do you think"),
        ]))
        let fanOut = result.objectValue?["fanOut"]?.arrayValue ?? []
        #expect(fanOut.first?.objectValue?["outcome"]?.stringValue == "reentrant")
        #expect(fanOut.first?.objectValue?["error"]?.stringValue?.contains("marketing") == true)
    }

    @Test("slackPostMessage with empty text returns an error")
    func postMessageEmpty() async throws {
        let (store, myAppId) = freshStore()
        let registry = makeRegistry(store: store, myAppId: myAppId, currentAgentId: "agent-1")
        let result = try await registry.resolve("slackPostMessage")!.handler(.object([
            "channelId": .string("channel-x"),
            "text": .string("   "),
        ]))
        #expect(result.objectValue?["ok"]?.boolValue == false)
    }

    private func seedMessages(
        store: MyAppStore,
        myAppId: UUID,
        count: Int
    ) -> (channelId: String, ids: [String]) {
        let channelId = store.slackAddChannel(name: "planning", type: .channel, myAppId: myAppId)!
        var ids: [String] = []
        let base: TimeInterval = 1_700_000_000
        for i in 0..<count {
            let id = store.slackPostMessage(
                channelId: channelId,
                authorKind: .user,
                authorId: "user",
                text: "m\(i)",
                timestamp: Date(timeIntervalSince1970: base + TimeInterval(i * 60)),
                myAppId: myAppId
            )!
            ids.append(id)
        }
        return (channelId, ids)
    }

    @Test("slackReadChannelHistory returns the tail when no cursor is passed, and signals hasMore when clipped")
    func readChannelHistoryTail() async throws {
        let (store, myAppId) = freshStore()
        let registry = makeRegistry(store: store, myAppId: myAppId, currentAgentId: nil)
        let (channelId, ids) = seedMessages(store: store, myAppId: myAppId, count: 5)

        let result = try await registry.resolve("slackReadChannelHistory")!.handler(.object([
            "channelId": .string(channelId),
            "limit": .int(2),
        ]))
        let messages = result.objectValue?["messages"]?.arrayValue ?? []
        let returnedIds = messages.compactMap { $0.objectValue?["id"]?.stringValue }
        #expect(returnedIds == [ids[3], ids[4]])
        #expect(result.objectValue?["hasMore"]?.boolValue == true)
        #expect(result.objectValue?["totalMessages"]?.intValue == 5)
    }

    @Test("slackReadChannelHistory `before` cursor returns the page strictly older than the given message id")
    func readChannelHistoryBeforeCursor() async throws {
        let (store, myAppId) = freshStore()
        let registry = makeRegistry(store: store, myAppId: myAppId, currentAgentId: nil)
        let (channelId, ids) = seedMessages(store: store, myAppId: myAppId, count: 5)

        let result = try await registry.resolve("slackReadChannelHistory")!.handler(.object([
            "channelId": .string(channelId),
            "limit": .int(10),
            "before": .string(ids[3]),
        ]))
        let messages = result.objectValue?["messages"]?.arrayValue ?? []
        let returnedIds = messages.compactMap { $0.objectValue?["id"]?.stringValue }
        #expect(returnedIds == [ids[0], ids[1], ids[2]])
        #expect(result.objectValue?["hasMore"]?.boolValue == false)
    }

    @Test("slackReadChannelHistory `before` cursor still respects limit and reports hasMore for an older page")
    func readChannelHistoryBeforeWithLimit() async throws {
        let (store, myAppId) = freshStore()
        let registry = makeRegistry(store: store, myAppId: myAppId, currentAgentId: nil)
        let (channelId, ids) = seedMessages(store: store, myAppId: myAppId, count: 5)

        let result = try await registry.resolve("slackReadChannelHistory")!.handler(.object([
            "channelId": .string(channelId),
            "limit": .int(2),
            "before": .string(ids[3]),
        ]))
        let messages = result.objectValue?["messages"]?.arrayValue ?? []
        let returnedIds = messages.compactMap { $0.objectValue?["id"]?.stringValue }
        #expect(returnedIds == [ids[1], ids[2]])
        #expect(result.objectValue?["hasMore"]?.boolValue == true)
    }

    @Test("slackReadChannelHistory ignores an unknown `before` cursor and returns the tail of all messages")
    func readChannelHistoryUnknownBefore() async throws {
        let (store, myAppId) = freshStore()
        let registry = makeRegistry(store: store, myAppId: myAppId, currentAgentId: nil)
        let (channelId, ids) = seedMessages(store: store, myAppId: myAppId, count: 3)

        let result = try await registry.resolve("slackReadChannelHistory")!.handler(.object([
            "channelId": .string(channelId),
            "limit": .int(10),
            "before": .string("not-a-real-id"),
        ]))
        let messages = result.objectValue?["messages"]?.arrayValue ?? []
        let returnedIds = messages.compactMap { $0.objectValue?["id"]?.stringValue }
        #expect(returnedIds == ids)
        #expect(result.objectValue?["hasMore"]?.boolValue == false)
    }
}
