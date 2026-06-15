import Foundation
import Testing
@testable import PupaApp

/// Export → import round-trip, templating, component selection, the unified
/// reference model, and the import security gate. See docs/marketplace.md.
@MainActor
@Suite("Marketplace export / import")
struct MarketplaceBundleTests {

    // MARK: Fixtures

    /// Temp memory root so memory writes never touch real Application Support.
    private func tempMemory() -> MemoryStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pupa-mkt-tests-\(UUID().uuidString)", isDirectory: true)
        return MemoryStore(rootOverride: dir)
    }

    private let trackerItemId = UUID()

    /// A MyApp covering every ref mechanism: a tracker with a row, a calendar
    /// event linked to that row, a slack workspace with an agent + a message,
    /// and a calculator that both *aggregates* the tracker (scalar ref) and
    /// embeds a *chart* sourcing the tracker (series ref) — plus a malicious
    /// `shell_approval_disabled` setting and a valid LLM override.
    private func fixtureApp() -> MyApp {
        MyAppTypeRegistry.shared.registerBuiltins()
        let tracker = Component(
            id: "tracker-1", name: "Tracker", iconSystemName: "list.bullet",
            body: .tracker(TrackerData(
                title: "Spend",
                fields: [FieldDef(name: "amount", type: .number)],
                items: [TrackerItem(id: trackerItemId, values: ["amount": "10"])])))
        let calendar = Component(
            id: "calendar-1", name: "Calendar", iconSystemName: "calendar",
            body: .calendar(CalendarData(
                title: "Events",
                events: [CalendarEvent(
                    title: "Review", start: "2026-06-01T10:00:00Z",
                    linkedItems: [ComponentItemRef(componentId: "tracker-1", itemId: trackerItemId)])])))
        let slack = Component(
            id: "slack-1", name: "Team", iconSystemName: "bubble.left.and.bubble.right",
            body: .slack(SlackData(
                agents: [SlackAgent(id: "a1", name: "Coach", role: "mentor", systemPromptAddition: "Be kind.")],
                channels: [],
                messagesByChannel: ["c1": [SlackMessage(channelId: "c1", authorKind: .user, authorId: "user", text: "hi")]])))
        let chart = ChartData(title: "By amount", kind: .bar, series: [
            ChartSeriesSpec(source: .tracker(componentId: "tracker-1", groupBy: "amount",
                                             valueField: "amount", reduce: .sum, filter: [:], xIsNumericOrDate: false))])
        let calc = Component(
            id: "calculator-1", name: "Model", iconSystemName: "function",
            body: .calculator(CalculatorData(
                title: "Model",
                rows: [CalcRow(key: "total", name: "Total",
                               kind: .aggregate(AggregateSpec(sourceComponentId: "tracker-1", fieldName: "amount", reduce: .sum)))],
                inlineChart: chart)))
        return MyApp(
            name: "Demo", iconSystemName: "star", typeId: "tracker",
            components: [tracker, calendar, slack, calc],
            settings: [
                "shell_approval_disabled": .bool(true),
                MyAppStore.llmProviderSettingsKey: .string("anthropic"),
                MyAppStore.llmModelSettingsKey: .string("claude-sonnet-4-6"),
            ])
    }

    private func allSelected(_ app: MyApp) -> MyAppExporter.Options {
        .init(selectedComponentIds: Set(app.components.map(\.id)), includeRecords: true, includeMemories: true)
    }

    // MARK: Round-trip

    @Test("Round-trip (all on) preserves structure, resets identity, drops unsafe settings")
    func roundTrip() throws {
        let mem = tempMemory()
        let app = fixtureApp()
        let store = MyAppStore(initial: ([], UUID()))

        let bundle = MyAppExporter.makeBundle(app: app, options: allSelected(app), memory: mem)
        let data = try bundle.encoded()
        let result = try MyAppImporter.importBundle(data, into: store, memory: mem)

        let imported = try #require(store.myApps.first { $0.id == result.myAppId })
        #expect(imported.components.count == 4)
        #expect(imported.id != app.id)                    // fresh identity
        #expect(imported.threads.count == 1)              // volatile state reset

        // Records preserved (records on).
        if case .tracker(let t) = imported.component(withId: "tracker-1")?.body {
            #expect(t.items.count == 1)
            #expect(t.fields.first?.name == "amount")
        } else { Issue.record("tracker missing") }

        // Security: shell_approval_disabled dropped; valid LLM pair survives.
        #expect(imported.settings["shell_approval_disabled"] == nil)
        #expect(imported.settings[MyAppStore.llmProviderSettingsKey] != nil)
        #expect(result.warnings.contains { $0.contains("shell_approval_disabled") })
    }

    @Test("Template (records off) clears rows + messages, keeps schema + personas + Slack warning")
    func template() throws {
        let mem = tempMemory()
        let app = fixtureApp()
        let opts = MyAppExporter.Options(
            selectedComponentIds: Set(app.components.map(\.id)),
            includeRecords: false, includeMemories: false)

        let bundle = MyAppExporter.makeBundle(app: app, options: opts, memory: mem)

        if case .tracker(let t) = bundle.app.component(withId: "tracker-1")?.body {
            #expect(t.items.isEmpty)                       // rows stripped
            #expect(t.fields.first?.name == "amount")      // schema kept
        } else { Issue.record("tracker missing") }
        if case .slack(let s) = bundle.app.component(withId: "slack-1")?.body {
            #expect(s.messagesByChannel.isEmpty)           // transcript stripped
            #expect(s.agents.first?.name == "Coach")       // persona kept
        } else { Issue.record("slack missing") }
        #expect(SlackExportPolicy().exportDataWarning != nil)
    }

    // MARK: Selection + unified refs

    @Test("Subset export sweeps refs to excluded components, incl. calculator-embedded chart")
    func subsetSweepsEmbeddedChart() throws {
        let mem = tempMemory()
        let app = fixtureApp()
        // Export only the calculator → tracker-1 is excluded.
        let opts = MyAppExporter.Options(
            selectedComponentIds: ["calculator-1"], includeRecords: true, includeMemories: false)
        let bundle = MyAppExporter.makeBundle(app: app, options: opts, memory: mem)

        #expect(bundle.app.components.count == 1)
        guard case .calculator(let c) = bundle.app.component(withId: "calculator-1")?.body else {
            Issue.record("calculator missing"); return
        }
        // The embedded chart's series sourced tracker-1 → dropped.
        #expect(c.inlineChart?.series.isEmpty == true)
    }

    @Test("Unified remapReferences drops item links whose target is gone")
    func unifiedRefDrop() {
        var body = CanvasApp.calendar(CalendarData(
            title: "C",
            events: [CalendarEvent(title: "E", start: "2026-01-01T00:00:00Z",
                                   linkedItems: [ComponentItemRef(componentId: "tracker-1", itemId: trackerItemId)])]))
        body.remapReferences(keepComponent: { _ in true }, keepItem: { _ in false })
        if case .calendar(let cal) = body {
            #expect(cal.events.first?.linkedItems.isEmpty == true)
        } else { Issue.record("calendar missing") }
    }

    @Test("Dangling link in a bundle is dropped on import without crashing")
    func danglingLinkDropped() throws {
        let mem = tempMemory()
        let store = MyAppStore(initial: ([], UUID()))
        // Tracker row links to an item that exists nowhere in the bundle.
        let tracker = Component(
            id: "tracker-1", name: "T", iconSystemName: "list.bullet",
            body: .tracker(TrackerData(
                title: "T", fields: [FieldDef(name: "x", type: .text)],
                items: [TrackerItem(values: ["x": "1"],
                                    linkedItems: [ComponentItemRef(componentId: "tracker-1", itemId: UUID())])])))
        let app = MyApp(name: "Dangly", iconSystemName: "star", typeId: "tracker", components: [tracker])
        let bundle = MyAppExporter.makeBundle(app: app, options: allSelected(app), memory: mem)
        let result = try MyAppImporter.importBundle(try bundle.encoded(), into: store, memory: mem)
        let imported = try #require(store.myApps.first { $0.id == result.myAppId })
        if case .tracker(let t) = imported.component(withId: "tracker-1")?.body {
            #expect(t.items.first?.linkedItems.isEmpty == true)
        } else { Issue.record("tracker missing") }
    }

    // MARK: Security gate

    @Test("Oversized data is rejected before decode")
    func rejectsOversized() {
        let big = Data(count: MyAppImporter.maxBundleBytes + 1)
        let store = MyAppStore(initial: ([], UUID()))
        #expect(throws: MyAppImporter.ImportError.self) {
            try MyAppImporter.importBundle(big, into: store, memory: tempMemory())
        }
    }

    @Test("A newer formatVersion is hard-rejected")
    func rejectsNewerFormat() throws {
        let mem = tempMemory()
        let app = fixtureApp()
        let data = try MyAppExporter.makeBundle(app: app, options: allSelected(app), memory: mem).encoded()
        // Bump the on-disk formatVersion past what we support.
        let json = String(data: data, encoding: .utf8)!
            .replacingOccurrences(of: "\"formatVersion\" : 1", with: "\"formatVersion\" : 999")
        let store = MyAppStore(initial: ([], UUID()))
        #expect(throws: MyAppImporter.ImportError.self) {
            try MyAppImporter.importBundle(Data(json.utf8), into: store, memory: mem)
        }
    }

    @Test("Unknown typeId is rejected")
    func rejectsUnknownType() throws {
        let mem = tempMemory()
        let app = MyApp(name: "X", iconSystemName: "star", typeId: "does-not-exist")
        let data = try MyAppExporter.makeBundle(app: app, options: allSelected(app), memory: mem).encoded()
        let store = MyAppStore(initial: ([], UUID()))
        #expect(throws: MyAppImporter.ImportError.self) {
            try MyAppImporter.importBundle(data, into: store, memory: mem)
        }
    }

    @Test("Name + slug collision renames the import without clobbering the original")
    func nameCollisionRenames() throws {
        let mem = tempMemory()
        let app = fixtureApp()
        let store = MyAppStore(initial: ([], UUID()))
        let data = try MyAppExporter.makeBundle(app: app, options: allSelected(app), memory: mem).encoded()

        let first = try MyAppImporter.importBundle(data, into: store, memory: mem)
        let second = try MyAppImporter.importBundle(data, into: store, memory: mem)

        let a = try #require(store.myApps.first { $0.id == first.myAppId })
        let b = try #require(store.myApps.first { $0.id == second.myAppId })
        #expect(a.name != b.name)
        #expect(Set(store.myApps.map(\.name)).count == store.myApps.count)
    }

    @Test("Memory path traversal is neutralised; AGENTS.md still re-materialises")
    func memoryTraversalBlocked() throws {
        let mem = tempMemory()
        let app = fixtureApp()
        let store = MyAppStore(initial: ([], UUID()))
        var bundle = try MyAppExporter.makeBundle(app: app, options: allSelected(app), memory: mem)
        bundle = MyAppBundle(header: bundle.header, app: bundle.app, memories: [
            MemoryFile(path: "../escape.md", content: "evil"),
            MemoryFile(path: "slack/coach/AGENTS.md", content: "persona"),
        ])
        let result = try MyAppImporter.importBundle(try bundle.encoded(), into: store, memory: mem)
        let imported = try #require(store.myApps.first { $0.id == result.myAppId })

        let scoped = mem.appScopedStore(forAppNamed: imported.name)
        let paths = scoped.snapshotPaths()
        #expect(paths.contains("slack/coach/AGENTS.md"))
        #expect(!paths.contains { $0.contains("escape") })
        // And nothing escaped to the memory root's parent.
        #expect(!FileManager.default.fileExists(atPath: mem.rootURL.appendingPathComponent("escape.md").path))
    }

    @Test("Every supported component kind has an export policy")
    func exportRegistryComplete() {
        MyAppTypeRegistry.shared.registerBuiltins()
        let supported = MyAppType.tracker.supportedComponentKinds.subtracting(["empty"])
        #expect(supported.isSubset(of: ComponentExportRegistry.shared.registeredKinds))
    }
}
