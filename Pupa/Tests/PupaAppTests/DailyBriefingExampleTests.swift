import Foundation
import Testing
@testable import PupaApp

/// Pins the shape of the seeded "Example: Daily Briefing" workspace: the
/// component graph, the Today's-Briefing→Sources link graph, the live feed
/// chart source, evergreen calendar dates, and a clean export → import
/// round-trip.
@MainActor
@Suite("DailyBriefingExample seed")
struct DailyBriefingExampleTests {

    @Test("make() returns the five-component briefing workspace")
    func makeSeedHasAllComponents() {
        let myApp = DailyBriefingExample.make()
        #expect(myApp.name == DailyBriefingExample.name)
        #expect(myApp.typeId == "tracker")
        #expect(myApp.iconSystemName == "sun.horizon")
        #expect(myApp.activeComponentId == "tracker-2")
        #expect(myApp.components.map(\.id) == ["tracker-1", "tracker-2", "tracker-3", "chart-1", "calendar-1"])
    }

    @Test("Briefing Sources name a tool per feed and ship Markets Off")
    func sourcesNameToolsAndDegradeMarkets() {
        let myApp = DailyBriefingExample.make()
        guard case .tracker(let data) = body(myApp, id: "tracker-1") else {
            Issue.record("tracker-1 missing or wrong kind"); return
        }
        #expect(data.items.count == 6)
        #expect(data.fields.contains { $0.name == "tool" })
        #expect(data.fields.contains { $0.name == "enabled" && $0.type == .select })
        // Every source declares the tool/MCP it depends on (the capability contract).
        #expect(data.items.allSatisfy { ($0.values["tool"] ?? "").isEmpty == false })
        // Markets is the honest "tool absent" example.
        let markets = data.items.first { $0.values["source"] == "Markets" }
        #expect(markets?.values["enabled"] == "Off")
    }

    @Test("Every Today's Briefing section but the focus item links back to a Source")
    func sectionsLinkToSources() {
        let myApp = DailyBriefingExample.make()
        let sourceIds = trackerItemIds(myApp, id: "tracker-1")
        guard case .tracker(let data) = body(myApp, id: "tracker-2") else {
            Issue.record("tracker-2 missing or wrong kind"); return
        }
        #expect(data.items.count == 5)
        #expect(data.fields.contains { $0.name == "priority" && $0.type == .select })
        let linked = data.items.filter { !$0.linkedItems.isEmpty }
        #expect(linked.count == 4, "Four feed-backed sections should link a Source; the focus item stands alone")
        for section in linked {
            for ref in section.linkedItems {
                #expect(ref.componentId == "tracker-1")
                #expect(sourceIds.contains(ref.itemId), "Section links to a missing Source row")
            }
        }
    }

    @Test("Feed Volume chart sums Briefing History per day")
    func chartSourcesHistory() {
        let myApp = DailyBriefingExample.make()
        guard case .chart(let chart) = body(myApp, id: "chart-1") else {
            Issue.record("chart-1 missing or wrong kind"); return
        }
        #expect(chart.series.count == 2)
        for spec in chart.series {
            guard case .tracker(let componentId, let groupBy, _, let reduce, _, _) = spec.source else {
                Issue.record("series is not a tracker source"); continue
            }
            #expect(componentId == "tracker-3")
            #expect(groupBy == "day")
            #expect(reduce == .sum)
        }
    }

    @Test("Schedule events are evergreen (no past dates) and include the 7am push")
    func scheduleIsEvergreen() {
        let myApp = DailyBriefingExample.make()
        guard case .calendar(let data) = body(myApp, id: "calendar-1") else {
            Issue.record("calendar-1 missing or wrong kind"); return
        }
        #expect(data.events.contains { $0.title == "Daily Briefing" })
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime]
        let startOfToday = Calendar(identifier: .gregorian).startOfDay(for: Date())
        for event in data.events {
            guard let date = formatter.date(from: event.start) else {
                Issue.record("Event '\(event.title)' has unparseable date: \(event.start)"); continue
            }
            #expect(date >= startOfToday, "Event '\(event.title)' is in the past — seed dates must be relative")
        }
    }

    @Test("seedAgentsMd writes the app AGENTS.md (no slack personas), idempotent on user edits")
    func seedAgentsMdWritesAndIsIdempotent() throws {
        let tmpBase = FileManager.default.temporaryDirectory
            .appendingPathComponent("pupa-briefing-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmpBase) }
        let global = MemoryStore(rootOverride: tmpBase)
        let appRoot = tmpBase.appendingPathComponent("example-daily-briefing", isDirectory: true)

        DailyBriefingExample.seedAgentsMd(globalMemory: global, appRootOverride: appRoot)
        let appMemory = MemoryStore(rootOverride: appRoot)
        #expect(appMemory.fileExists(at: "AGENTS.md"))
        let appMd = try String(contentsOf: appRoot.appendingPathComponent("AGENTS.md"), encoding: .utf8)
        #expect(appMd.contains("Keeping yourself updated"))
        #expect(appMd.contains("Capability boundaries"))

        let url = appRoot.appendingPathComponent("AGENTS.md")
        try "# User-edited\n".write(to: url, atomically: true, encoding: .utf8)
        DailyBriefingExample.seedAgentsMd(globalMemory: global, appRootOverride: appRoot)
        #expect(try String(contentsOf: url, encoding: .utf8) == "# User-edited\n")
    }

    @Test("Exports + re-imports cleanly with fresh identity")
    func bundleRoundTrips() throws {
        MyAppTypeRegistry.shared.registerBuiltins()
        let mem = MemoryStore(rootOverride: FileManager.default.temporaryDirectory
            .appendingPathComponent("pupa-briefing-rt-\(UUID().uuidString)", isDirectory: true))
        let app = DailyBriefingExample.make()
        let store = MyAppStore(initial: ([], UUID()))
        let opts = MyAppExporter.Options(
            selectedComponentIds: Set(app.components.map(\.id)), includeRecords: true, includeMemories: true)
        let data = try MyAppExporter.makeBundle(app: app, options: opts, memory: mem).encoded()
        let result = try MyAppImporter.importBundle(data, into: store, memory: mem)

        let imported = try #require(store.myApps.first { $0.id == result.myAppId })
        #expect(imported.components.map(\.id) == ["tracker-1", "tracker-2", "tracker-3", "chart-1", "calendar-1"])
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
