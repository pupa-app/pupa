import Foundation
import Testing
@testable import PupaApp

/// Pins the shape of the seeded "Example: Research Tracker" workspace: the
/// component graph the agent addresses by id, the Findings→Watchlist link
/// graph the demo's value depends on, the chart's live source, and a clean
/// export → import round-trip (the marketplace acceptance criterion).
@MainActor
@Suite("ResearchTrackerExample seed")
struct ResearchTrackerExampleTests {

    @Test("make() returns the five-component competitive-intel workspace")
    func makeSeedHasAllComponents() {
        let myApp = ResearchTrackerExample.make()
        #expect(myApp.name == ResearchTrackerExample.name)
        #expect(myApp.typeId == "tracker")
        #expect(myApp.iconSystemName == "chart.line.uptrend.xyaxis.circle")
        #expect(myApp.activeComponentId == "tracker-1")
        #expect(myApp.components.map(\.id) == ["tracker-1", "tracker-2", "chart-1", "calculator-1", "slack-1"])
    }

    @Test("Watchlist is a threat-kanban with the seeded landscape rows")
    func watchlistIsKanban() {
        let myApp = ResearchTrackerExample.make()
        guard case .tracker(let data) = body(myApp, id: "tracker-1") else {
            Issue.record("tracker-1 missing or wrong kind"); return
        }
        #expect(data.viewMode == .kanban)
        #expect(data.columnField == "threat")
        #expect(data.fields.contains { $0.name == "threat" && $0.type == .select })
        #expect(data.items.count == 5)
        // The "us" anchor must be present — the board is meaningless without it.
        #expect(data.items.contains { $0.values["threat"] == "Us" })
        #expect(data.items.allSatisfy { ($0.values["name"] ?? "").isEmpty == false })
    }

    @Test("Every Findings Log row links its subject back to a Watchlist row")
    func findingsLinkToWatchlist() {
        let myApp = ResearchTrackerExample.make()
        let watchlistIds = trackerItemIds(myApp, id: "tracker-1")
        guard case .tracker(let data) = body(myApp, id: "tracker-2") else {
            Issue.record("tracker-2 missing or wrong kind"); return
        }
        #expect(data.items.count >= 6)
        #expect(data.fields.contains { $0.name == "signal" && $0.type == .select })
        #expect(data.fields.contains { $0.name == "week" && $0.type == .select })
        for f in data.items {
            #expect(!f.linkedItems.isEmpty, "Finding '\(f.values["finding"] ?? "?")' has no subject link")
            for ref in f.linkedItems {
                #expect(ref.componentId == "tracker-1")
                #expect(watchlistIds.contains(ref.itemId), "Finding links to a missing Watchlist row")
            }
        }
    }

    @Test("Signal Trend chart resolves live from the Findings Log")
    func chartSourcesFindings() {
        let myApp = ResearchTrackerExample.make()
        guard case .chart(let chart) = body(myApp, id: "chart-1") else {
            Issue.record("chart-1 missing or wrong kind"); return
        }
        #expect(chart.series.count == 2)
        for spec in chart.series {
            guard case .tracker(let componentId, let groupBy, _, let reduce, _, _) = spec.source else {
                Issue.record("series is not a tracker source"); continue
            }
            #expect(componentId == "tracker-2")
            #expect(groupBy == "week")
            #expect(reduce == .count)
        }
    }

    @Test("Deltas calculator counts findings and computes the week-over-week change")
    func deltasComputeWeekOverWeek() {
        let myApp = ResearchTrackerExample.make()
        guard case .calculator(let calc) = body(myApp, id: "calculator-1") else {
            Issue.record("calculator-1 missing or wrong kind"); return
        }
        let keys = Set(calc.rows.map(\.key))
        #expect(keys.isSuperset(of: ["strong", "notable", "weak", "strong_w2", "strong_w3", "new_strong"]))
        // The aggregate rows must point at the Findings Log.
        for row in calc.rows {
            if case .aggregate(let spec) = row.kind {
                #expect(spec.sourceComponentId == "tracker-2")
                #expect(spec.reduce == .count)
            }
        }
        // The delta is a formula over the two weekly counts.
        let delta = calc.rows.first { $0.key == "new_strong" }
        guard case .formula(let expr)? = delta?.kind else {
            Issue.record("new_strong is not a formula"); return
        }
        #expect(expr.contains("strong_w3") && expr.contains("strong_w2"))
    }

    @Test("Research Room has three distinct-persona agents in #research")
    func researchRoomAgents() {
        let myApp = ResearchTrackerExample.make()
        guard case .slack(let data) = body(myApp, id: "slack-1") else {
            Issue.record("slack-1 missing or wrong kind"); return
        }
        #expect(Set(data.agents.map(\.id)) == ["scout", "analyst", "digest"])
        #expect(data.agents.allSatisfy { !$0.systemPromptAddition.isEmpty })
        #expect(data.channels.first?.name == "research")
        // No seeded transcript — the user starts the conversation.
        #expect(data.messagesByChannel.isEmpty)
    }

    @Test("seedAgentsMd writes the app + three persona files, idempotent on user edits")
    func seedAgentsMdWritesAndIsIdempotent() throws {
        let tmpBase = FileManager.default.temporaryDirectory
            .appendingPathComponent("pupa-research-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmpBase) }
        let global = MemoryStore(rootOverride: tmpBase)
        let appRoot = tmpBase.appendingPathComponent("example-research-tracker", isDirectory: true)

        ResearchTrackerExample.seedAgentsMd(globalMemory: global, appRootOverride: appRoot)
        let appMemory = MemoryStore(rootOverride: appRoot)
        for path in ["pupa/AGENTS.md", "pupa/agents/scout/AGENTS.md", "pupa/agents/analyst/AGENTS.md", "pupa/agents/digest/AGENTS.md"] {
            #expect(appMemory.fileExists(at: path), "\(path) missing after seed")
        }
        let appMd = try String(contentsOf: appRoot.appendingPathComponent("pupa/AGENTS.md"), encoding: .utf8)
        #expect(appMd.contains("Keeping yourself updated"))

        let scoutUrl = appRoot.appendingPathComponent("pupa/agents/scout/AGENTS.md")
        try "# User-edited\n".write(to: scoutUrl, atomically: true, encoding: .utf8)
        ResearchTrackerExample.seedAgentsMd(globalMemory: global, appRootOverride: appRoot)
        #expect(try String(contentsOf: scoutUrl, encoding: .utf8) == "# User-edited\n")
    }

    @Test("Exports + re-imports cleanly with fresh identity")
    func bundleRoundTrips() throws {
        MyAppTypeRegistry.shared.registerBuiltins()
        let mem = MemoryStore(rootOverride: FileManager.default.temporaryDirectory
            .appendingPathComponent("pupa-research-rt-\(UUID().uuidString)", isDirectory: true))
        let app = ResearchTrackerExample.make()
        let store = MyAppStore(initial: ([], UUID()))
        let opts = MyAppExporter.Options(
            selectedComponentIds: Set(app.components.map(\.id)), includeRecords: true, includeMemories: true)
        let data = try MyAppExporter.makeBundle(app: app, options: opts, memory: mem).encoded()
        let result = try MyAppImporter.importBundle(data, into: store, memory: mem)

        let imported = try #require(store.myApps.first { $0.id == result.myAppId })
        #expect(imported.components.map(\.id) == ["tracker-1", "tracker-2", "chart-1", "calculator-1", "slack-1"])
        #expect(imported.id != app.id)
    }

    // MARK: - Helpers

    private func body(_ myApp: MyApp, id: String) -> CanvasApp? {
        myApp.components.first(where: { $0.id == id })?.body
    }

    private func trackerItemIds(_ myApp: MyApp, id: String) -> Set<UUID> {
        guard case .tracker(let data) = body(myApp, id: id) else { return [] }
        return Set(data.items.map(\.id))
    }
}
