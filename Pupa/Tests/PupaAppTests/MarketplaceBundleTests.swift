import Foundation
import Testing
@testable import PupaApp

/// Export → import round-trip, templating, component selection, the unified
/// reference model, and the import security gate. See docs/marketplace.md.
@MainActor
@Suite("Marketplace export / import")
struct MarketplaceBundleTests {

    init() { TestStorage.activate() }

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
                channels: [SlackChannel(id: "c1", name: "general", type: .channel, memberAgentIds: ["coach"])],
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
            #expect(s.messagesByChannel.isEmpty)                 // transcript stripped
            #expect(s.channels.first?.memberAgentIds == ["coach"]) // channel roster kept
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

    @Test("Skills + subagent prompts ride the bundle and survive memories-off")
    func skillsAndSubagentPromptsRideTheBundle() throws {
        let mem = tempMemory()
        let app = fixtureApp()
        let store = MyAppStore(initial: ([], UUID()))
        // Seed config (pupa/) + a user note into the app's scoped memory.
        let appMem = mem.appScopedStore(forAppNamed: app.name)
        try appMem.writeFile(path: "pupa/skills/greet/SKILL.md", content: "---\ndescription: greet\n---\nSay hi.")
        try appMem.writeFile(path: "pupa/agents/coach/AGENTS.md", content: "Coach persona.")
        try appMem.writeFile(path: "notes/scratch.md", content: "user note")

        // Memories OFF — config under pupa/ survives; user data is dropped.
        let opts = MyAppExporter.Options(
            selectedComponentIds: Set(app.components.map(\.id)),
            includeRecords: true, includeMemories: false)
        let bundle = MyAppExporter.makeBundle(app: app, options: opts, memory: mem)
        let bundlePaths = Set(bundle.memories.map(\.path))
        #expect(bundlePaths.contains("pupa/skills/greet/SKILL.md"))
        #expect(bundlePaths.contains("pupa/agents/coach/AGENTS.md"))
        #expect(!bundlePaths.contains("notes/scratch.md"))

        // Re-import: skill re-materialises on disk and is discoverable again.
        let result = try MyAppImporter.importBundle(try bundle.encoded(), into: store, memory: mem)
        let imported = try #require(store.myApps.first { $0.id == result.myAppId })
        let scoped = mem.appScopedStore(forAppNamed: imported.name)
        #expect(scoped.fileExists(at: "pupa/skills/greet/SKILL.md"))
        #expect(scoped.fileExists(at: "pupa/agents/coach/AGENTS.md"))
        #expect(SkillStore(memory: scoped).skill(named: "greet") != nil)
    }

    // MARK: Memories round-trip (issue #112)

    /// Every file path in a memory tree, read from the *in-memory* `tree`
    /// (not disk) — asserts what the Memories tab would actually render.
    private func treePaths(_ store: MemoryStore) -> Set<String> {
        var out: Set<String> = []
        func walk(_ n: MemoryNode) {
            if !n.isFolder { out.insert(n.path) }
            n.children?.forEach(walk)
        }
        walk(store.tree)
        return out
    }

    @Test("User memories round-trip a single-app export with Include memories ON")
    func memoriesRoundTrip() throws {
        let mem = tempMemory()
        let app = fixtureApp()
        let store = MyAppStore(initial: ([], UUID()))
        try mem.appScopedStore(forAppNamed: app.name)
            .writeFile(path: "notes/scratch.md", content: "user note")

        let bundle = MyAppExporter.makeBundle(app: app, options: allSelected(app), memory: mem)
        #expect(bundle.memories.contains { $0.path == "notes/scratch.md" })

        let result = try MyAppImporter.importBundle(try bundle.encoded(), into: store, memory: mem)
        let imported = try #require(store.myApps.first { $0.id == result.myAppId })
        let scoped = mem.appScopedStore(forAppNamed: imported.name)
        #expect(scoped.fileExists(at: "notes/scratch.md"))
        #expect(try scoped.readFile(path: "notes/scratch.md").content == "user note")
    }

    @Test("Rename before export keeps memories attached (slug migration)")
    func renameThenExportKeepsMemories() throws {
        let mem = tempMemory()
        let app = fixtureApp()
        let store = MyAppStore(initial: ([app], app.id))
        store.globalMemory = mem
        try mem.appScopedStore(forAppNamed: app.name)
            .writeFile(path: "notes/scratch.md", content: "user note")

        store.renameMyApp(app.id, to: "Demo Renamed")
        let renamed = try #require(store.myApp(withId: app.id))
        #expect(renamed.name == "Demo Renamed")
        // The folder followed the rename…
        #expect(mem.appScopedStore(forAppNamed: "Demo Renamed").fileExists(at: "notes/scratch.md"))
        #expect(!mem.folderExists(at: MemoryStore.myAppFolder(myAppName: "Demo")))
        // …so the export still ships the user memory.
        let bundle = MyAppExporter.makeBundle(app: renamed, options: allSelected(renamed), memory: mem)
        #expect(bundle.memories.contains { $0.path == "notes/scratch.md" })
    }

    @Test("Import refreshes the global memory tree — no relaunch needed")
    func importRefreshesGlobalTree() throws {
        let mem = tempMemory()
        let app = fixtureApp()
        // "Demo" already exists, so the import lands under a fresh slug.
        let store = MyAppStore(initial: ([app], app.id))
        try mem.appScopedStore(forAppNamed: app.name)
            .writeFile(path: "notes/scratch.md", content: "user note")

        let bundle = MyAppExporter.makeBundle(app: app, options: allSelected(app), memory: mem)
        let result = try MyAppImporter.importBundle(try bundle.encoded(), into: store, memory: mem)
        let imported = try #require(store.myApps.first { $0.id == result.myAppId })
        let slug = MemoryStore.myAppFolder(myAppName: imported.name)
        #expect(slug != MemoryStore.myAppFolder(myAppName: app.name))
        // The *live* tree (what the Memories tab renders) has the new files.
        #expect(treePaths(mem).contains("\(slug)/notes/scratch.md"))
    }

    @Test("Every supported component kind has an export policy")
    func exportRegistryComplete() {
        MyAppTypeRegistry.shared.registerBuiltins()
        let supported = MyAppType.tracker.supportedComponentKinds.subtracting(["empty"])
        #expect(supported.isSubset(of: ComponentExportRegistry.shared.registeredKinds))
    }

    // MARK: Library (multi-app) round-trip

    @Test("probeFormat distinguishes a single bundle from a library")
    func probeFormatDistinguishes() throws {
        let mem = tempMemory()
        let app = fixtureApp()
        let single = try MyAppExporter.makeBundle(app: app, options: allSelected(app), memory: mem).encoded()
        let library = try MyAppExporter.makeLibraryBundle(
            apps: [app], includeRecords: true, includeMemories: true, memory: mem).encoded()
        #expect(MyAppImporter.probeFormat(single) == .single)
        #expect(MyAppImporter.probeFormat(library) == .library)
        #expect(MyAppImporter.probeFormat(Data("nonsense".utf8)) == .unknown)
    }

    @Test("Library round-trip imports every app with re-materialised memories")
    func libraryRoundTrip() throws {
        let mem = tempMemory()
        let app1 = fixtureApp()
        var app2 = fixtureApp()
        app2.name = "Demo Two"
        // Seed a skill into each app's scoped memory so we can prove per-app
        // re-materialisation on import.
        try mem.appScopedStore(forAppNamed: app1.name)
            .writeFile(path: "pupa/skills/one/SKILL.md", content: "---\ndescription: one\n---\nA.")
        try mem.appScopedStore(forAppNamed: app2.name)
            .writeFile(path: "pupa/skills/two/SKILL.md", content: "---\ndescription: two\n---\nB.")
        let store = MyAppStore(initial: ([], UUID()))

        let library = MyAppExporter.makeLibraryBundle(
            apps: [app1, app2], includeRecords: true, includeMemories: true, memory: mem)
        let result = try MyAppImporter.importLibrary(try library.encoded(), into: store, memory: mem)

        #expect(result.myAppIds.count == 2)
        #expect(store.myApps.count == 2)
        let names = Set(store.myApps.map(\.name))
        #expect(names.contains("Demo"))
        #expect(names.contains("Demo Two"))
        // Memories re-materialised under each imported app's own scope.
        let one = try #require(store.myApps.first { $0.name == "Demo" })
        let two = try #require(store.myApps.first { $0.name == "Demo Two" })
        #expect(mem.appScopedStore(forAppNamed: one.name).fileExists(at: "pupa/skills/one/SKILL.md"))
        #expect(mem.appScopedStore(forAppNamed: two.name).fileExists(at: "pupa/skills/two/SKILL.md"))
    }

    @Test("Library apps that collide are renamed uniquely, one per app")
    func libraryCollisionRenames() throws {
        let mem = tempMemory()
        let app = fixtureApp()            // both apps share the name "Demo"
        let store = MyAppStore(initial: ([], UUID()))
        let library = MyAppExporter.makeLibraryBundle(
            apps: [app, app], includeRecords: true, includeMemories: true, memory: mem)

        let result = try MyAppImporter.importLibrary(try library.encoded(), into: store, memory: mem)
        #expect(result.myAppIds.count == 2)
        #expect(Set(store.myApps.map(\.name)).count == store.myApps.count)   // all unique
    }

    @Test("A malformed app in a library is skipped best-effort; the rest import")
    func libraryBestEffortSkipsMalformed() throws {
        let mem = tempMemory()
        let good = MyAppExporter.makeBundle(app: fixtureApp(), options: allSelected(fixtureApp()), memory: mem)
        // Hand-build a bad inner bundle: an unknown typeId, rejected by the
        // per-app validator with `.unknownType`.
        let badApp = MyApp(
            name: "Broken", iconSystemName: "xmark", typeId: "bogus-type",
            components: [Component(id: "x-1", name: "X", iconSystemName: "xmark", body: .empty)])
        let bad = MyAppBundle(
            header: .init(appVersion: PupaAppVersion, includedRecords: true, includedMemories: true),
            app: badApp, memories: [])
        let library = MyAppLibraryBundle(
            header: .init(appVersion: PupaAppVersion, appCount: 2, includedRecords: true, includedMemories: true),
            apps: [good, bad])
        let store = MyAppStore(initial: ([], UUID()))

        let result = try MyAppImporter.importLibrary(try library.encoded(), into: store, memory: mem)
        #expect(result.myAppIds.count == 1)
        #expect(store.myApps.count == 1)
        #expect(result.warnings.contains { $0.contains("Skipped 'Broken'") })
    }

    @Test("Oversized library data is rejected before decode")
    func libraryOversizedRejected() {
        let store = MyAppStore(initial: ([], UUID()))
        let big = Data(count: MyAppImporter.maxLibraryBytes + 1)
        #expect(throws: MyAppImporter.ImportError.self) {
            try MyAppImporter.importLibrary(big, into: store, memory: tempMemory())
        }
    }

    @Test("A newer library formatVersion is hard-rejected")
    func libraryNewerFormatRejected() throws {
        let mem = tempMemory()
        let app = fixtureApp()
        let store = MyAppStore(initial: ([], UUID()))
        let data = try MyAppExporter.makeLibraryBundle(
            apps: [app], includeRecords: true, includeMemories: true, memory: mem).encoded()
        // Bump only the library header's formatVersion.
        var obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        var header = try #require(obj["header"] as? [String: Any])
        header["formatVersion"] = 999
        obj["header"] = header
        let bumped = try JSONSerialization.data(withJSONObject: obj)
        #expect(throws: MyAppImporter.ImportError.self) {
            try MyAppImporter.importLibrary(bumped, into: store, memory: mem)
        }
    }
}
