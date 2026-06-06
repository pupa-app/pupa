import Foundation
import Testing
import AGUIKit
@testable import PupaApp

/// Tests for embedding a frozen chart into the chat transcript (Phase 3 of
/// #20, #23): `embedComponent` hostKind "chat" resolves a `ChartData` to a
/// `ChatChartSnapshot` NOW, the `ChatViewModel` drops it in as an assistant
/// bubble on the tool finish, and `TranscriptMapper` rebuilds it on reload.
@MainActor
@Suite("Chat chart embed")
struct ChatChartEmbedTests {

    private func freshStore() -> (MyAppStore, UUID) {
        MyAppTypeRegistry.shared.registerBuiltins()
        let myApp = MyApp(name: "T", iconSystemName: "chart.pie", typeId: MyAppType.tracker.id)
        let store = MyAppStore(initial: ([myApp], myApp.id))
        return (store, myApp.id)
    }

    private func registry(_ store: MyAppStore, _ id: UUID) -> ToolRegistry {
        let r = ToolRegistry()
        AppTools.registerMyAppTools(on: r, store: store, myAppId: id)
        return r
    }

    private let inlineChartArg: AnyJSON = .object([
        "title": .string("Spend"),
        "kind": .string("bar"),
        "series": .array([
            .object(["source": .object([
                "type": .string("inline"),
                "points": .array([
                    .object(["label": .string("Jan"), "y": .double(10)]),
                    .object(["label": .string("Feb"), "y": .double(20)]),
                ]),
            ])]),
        ]),
    ])

    // MARK: - Tool

    @Test("embedComponent host \"chat\" returns a resolved chartSnapshot")
    func chatEmbedResolves() async throws {
        let (store, id) = freshStore()
        let embed = try #require(registry(store, id).resolve("embedComponent"))
        let result = try await embed.handler(.object([
            "hostKind": .string("chat"),
            "guestKind": .string("chart"),
            "chart": inlineChartArg,
        ]))
        #expect(result["ok"]?.boolValue == true)
        #expect(result["pointCount"]?.intValue == 2)
        let snap = try #require(decodeSnapshot(result["chartSnapshot"]))
        #expect(snap.title == "Spend")
        #expect(snap.kind == .bar)
        #expect(snap.series.first?.points.count == 2)
    }

    @Test("embedComponent host \"chat\" with no resolvable points fails")
    func chatEmbedEmptyFails() async throws {
        let (store, id) = freshStore()
        let embed = try #require(registry(store, id).resolve("embedComponent"))
        let result = try await embed.handler(.object([
            "hostKind": .string("chat"),
            "guestKind": .string("chart"),
            "chart": .object([
                "title": .string("X"), "kind": .string("bar"),
                "series": .array([.object(["source": .object(["type": .string("inline"), "points": .array([])])])]),
            ]),
        ]))
        #expect(result["ok"]?.boolValue == false)
        #expect(result["chartSnapshot"] == nil)
    }

    // MARK: - ChatViewModel

    @Test("Finishing an embedComponent(chat) call drops in an assistant chart bubble")
    func viewModelAppendsChartBubble() {
        let (store, id) = freshStore()
        let vm = ChatViewModel(
            store: store,
            memory: MemoryStore(rootOverride: URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("pupa-tests-\(UUID().uuidString)")),
            settings: SettingsStore(backendURL: URL(string: "http://localhost:65535/")!),
            registry: ToolRegistry(),
            scope: .myApp(id),
            threadId: store.currentThreadId(for: .myApp(id)),
            skillState: SkillState()
        )
        let snapshot = ChatChartSnapshot(title: "Spend", kind: .bar,
            series: [ChartSeries(name: "S", points: [ChartPoint(label: "Jan", y: 10)])])
        let snapJSON = try? JSONDecoder().decode(AnyJSON.self, from: JSONEncoder().encode(snapshot))

        vm.apply(.toolCallStarted(id: "c1", name: "embedComponent"))
        vm.apply(.toolCallFinished(
            id: "c1", name: "embedComponent",
            arguments: .object([:]),
            result: .object(["ok": .bool(true), "chartSnapshot": snapJSON ?? .null])
        ))

        let chartBubble = vm.bubbles.first(where: { $0.chartSnapshot != nil })
        #expect(chartBubble?.role == .assistant)
        #expect(chartBubble?.chartSnapshot?.title == "Spend")
        #expect(chartBubble?.chartSnapshot?.series.first?.points.count == 1)
    }

    // MARK: - Transcript reload

    @Test("TranscriptMapper rebuilds the chart bubble from the embed result")
    func transcriptRebuildsChart() throws {
        let snapshot = ChatChartSnapshot(title: "Spend", kind: .line,
            series: [ChartSeries(name: "S", points: [ChartPoint(label: "Jan", y: 10), ChartPoint(label: "Feb", y: 20)])])
        let result = String(data: try JSONEncoder().encode(["chartSnapshot": snapshot]), encoding: .utf8)!

        let messages = [
            TranscriptMessage(id: "a1", role: "ai", content: "",
                toolCalls: [TranscriptToolCall(id: "c1", name: "embedComponent", args: [:])], toolCallId: nil),
            TranscriptMessage(id: "t1", role: "tool", content: result, toolCalls: [], toolCallId: "c1"),
        ]
        let bubbles = TranscriptMapper.bubbles(from: messages)
        #expect(bubbles.contains(where: { $0.role == .toolRound }))
        let chart = try #require(bubbles.first(where: { $0.chartSnapshot != nil }))
        #expect(chart.chartSnapshot?.title == "Spend")
        #expect(chart.chartSnapshot?.kind == .line)
        #expect(chart.chartSnapshot?.series.first?.points.count == 2)
    }

    private func decodeSnapshot(_ json: AnyJSON?) -> ChatChartSnapshot? {
        guard let json, let data = try? JSONEncoder().encode(json) else { return nil }
        return try? JSONDecoder().decode(ChatChartSnapshot.self, from: data)
    }
}
