import Foundation
import Testing
import AGUIKit
@testable import PupaApp

/// Tests for kind-gated tool / prompt disclosure on a MyApp. The contract:
/// a tool listed under `MyAppType.toolNamesByKind[kind]` is advertised only
/// when at least one `Component` of that kind exists in the MyApp; tools in
/// `coPresenceGates` additionally require every listed kind to be present.
/// Same gating applies to per-kind prompt fragments. See
/// [docs/architecture.md → Tool surface (per-MyApp, per-round)].
@MainActor
@Suite("Tool gating on component presence")
struct ToolGatingTests {

    private func freshStore(typeId: String = "tracker") -> (MyAppStore, MyApp) {
        MyAppTypeRegistry.shared.registerBuiltins()
        let myApp = MyApp(
            name: "T",
            iconSystemName: "list.bullet.rectangle",
            typeId: typeId
        )
        let store = MyAppStore(initial: ([myApp], myApp.id))
        return (store, myApp)
    }

    @Test("Fresh MyApp: base tools advertised; kind tools, memory, notifications behind gates")
    func freshMyAppExposesOnlyBaseSurface() {
        let (store, myApp) = freshStore()
        let allowed = ChatViewModel.allowedToolNames(scope: .myApp(myApp.id), store: store, toolGateState: ToolGateState())

        // Base tools always visible.
        #expect(allowed.contains("addComponent"))
        #expect(allowed.contains("removeComponent"))
        #expect(allowed.contains("setActiveComponent"))
        #expect(allowed.contains("clearCanvas"))
        #expect(allowed.contains("getCanvasState"))
        #expect(allowed.contains("linkItem"))
        #expect(allowed.contains("unlinkItem"))

        // Notifications now behind get_tools_notifications (issue #220).
        #expect(allowed.contains("get_tools_notifications"))
        #expect(!allowed.contains("sendNotification"))
        #expect(!allowed.contains("cancelNotification"))

        // Memory is behind get_tools_memories; raw memory tool hidden.
        #expect(allowed.contains("get_tools_memories"))
        #expect(!allowed.contains("lsMemories"))

        // No kind tools and no kind gates (no components of those kinds).
        #expect(!allowed.contains("renderTracker"))
        #expect(!allowed.contains("addTrackerItems"))
        #expect(!allowed.contains("renderCalendar"))
        #expect(!allowed.contains("addCalendarEvent"))
        #expect(!allowed.contains("renderChecklist"))
        #expect(!allowed.contains("addChecklistItem"))
        #expect(!allowed.contains("get_tools_tracker"))
        #expect(!allowed.contains("get_tools_calendar"))
        #expect(!allowed.contains("get_tools_checklist"))
    }

    @Test("Tracker component present: get_tools_tracker gate appears; tracker tools hidden until activated")
    func trackerComponentShowsGateThenTools() {
        let (store, myApp) = freshStore()
        store.addComponent(kind: "tracker", name: "Books", iconSystemName: "book", myAppId: myApp.id)

        // Before activation: gate visible, kind tools hidden.
        let toolGateState = ToolGateState()
        let gated = ChatViewModel.allowedToolNames(scope: .myApp(myApp.id), store: store, toolGateState: toolGateState)
        #expect(gated.contains("get_tools_tracker"))
        #expect(!gated.contains("renderTracker"))
        #expect(!gated.contains("addTrackerItems"))
        // Calendar gate absent (no calendar component).
        #expect(!gated.contains("get_tools_calendar"))
        #expect(gated.contains("linkItem"))
        #expect(gated.contains("unlinkItem"))

        // After activation: kind tools appear, gate disappears.
        toolGateState.activate(kind: "tracker")
        let unlocked = ChatViewModel.allowedToolNames(scope: .myApp(myApp.id), store: store, toolGateState: toolGateState)
        #expect(unlocked.contains("renderTracker"))
        #expect(unlocked.contains("addTrackerItems"))
        #expect(!unlocked.contains("get_tools_tracker"))
        #expect(!unlocked.contains("renderCalendar"))
    }

    @Test("Calendar component present: get_tools_calendar gate appears; tracker tools hidden")
    func calendarComponentShowsGateThenTools() {
        let (store, myApp) = freshStore()
        store.addComponent(kind: "calendar", name: "Cal", iconSystemName: "calendar", myAppId: myApp.id)

        let toolGateState = ToolGateState()
        let gated = ChatViewModel.allowedToolNames(scope: .myApp(myApp.id), store: store, toolGateState: toolGateState)
        #expect(gated.contains("get_tools_calendar"))
        #expect(!gated.contains("renderCalendar"))
        #expect(!gated.contains("get_tools_tracker"))

        toolGateState.activate(kind: "calendar")
        let unlocked = ChatViewModel.allowedToolNames(scope: .myApp(myApp.id), store: store, toolGateState: toolGateState)
        #expect(unlocked.contains("renderCalendar"))
        #expect(unlocked.contains("addCalendarEvent"))
        #expect(!unlocked.contains("renderTracker"))
    }

    @Test("Checklist component present: gate then unlock exposes all checklist tools")
    func checklistComponentShowsGateThenTools() {
        let (store, myApp) = freshStore()
        store.addComponent(kind: "checklist", name: "Errands", iconSystemName: "checklist", myAppId: myApp.id)

        let toolGateState = ToolGateState()
        let gated = ChatViewModel.allowedToolNames(scope: .myApp(myApp.id), store: store, toolGateState: toolGateState)
        #expect(gated.contains("get_tools_checklist"))
        #expect(!gated.contains("renderChecklist"))

        toolGateState.activate(kind: "checklist")
        let unlocked = ChatViewModel.allowedToolNames(scope: .myApp(myApp.id), store: store, toolGateState: toolGateState)
        #expect(unlocked.contains("renderChecklist"))
        #expect(unlocked.contains("addChecklistItem"))
        #expect(unlocked.contains("toggleChecklistItem"))
        #expect(unlocked.contains("patchChecklistItem"))
        #expect(unlocked.contains("removeChecklistItem"))
        #expect(unlocked.contains("linkItem"))
        #expect(unlocked.contains("unlinkItem"))
        #expect(!unlocked.contains("renderTracker"))
        #expect(!unlocked.contains("renderCalendar"))
    }

    @Test("Calculator component present: gate then unlock exposes all calculator tools including embedComponent")
    func calculatorComponentShowsGateThenTools() {
        let (store, myApp) = freshStore()
        store.addComponent(kind: "calculator", name: "Calc", iconSystemName: "function", myAppId: myApp.id)

        let toolGateState = ToolGateState()
        let gated = ChatViewModel.allowedToolNames(scope: .myApp(myApp.id), store: store, toolGateState: toolGateState)
        #expect(gated.contains("get_tools_calculator"))
        #expect(!gated.contains("renderCalculator"))
        #expect(!gated.contains("embedComponent"))

        toolGateState.activate(kind: "calculator")
        let unlocked = ChatViewModel.allowedToolNames(scope: .myApp(myApp.id), store: store, toolGateState: toolGateState)
        #expect(unlocked.contains("renderCalculator"))
        #expect(unlocked.contains("addCalcRows"))
        #expect(unlocked.contains("patchCalcRows"))
        #expect(unlocked.contains("removeCalcRows"))
        #expect(unlocked.contains("listCalcRows"))
        #expect(unlocked.contains("getCalcRow"))
        #expect(unlocked.contains("embedComponent"))
        #expect(!unlocked.contains("renderTracker"))
        #expect(!unlocked.contains("renderChecklist"))
    }

    @Test("embedComponent sets and clears the calculator's inlineChart")
    func embedComponentSetsAndClearsInlineChart() {
        let (store, myApp) = freshStore()
        store.addComponent(kind: "calculator", name: "Calc", iconSystemName: "function", myAppId: myApp.id)
        store.setCalculator(title: "Mortgage", rows: [], myAppId: myApp.id)

        let chart = ChartData(
            title: "Payment curve",
            kind: .line,
            series: [ChartSeriesSpec(source: .inline(points: [ChartPoint(label: "A", y: 1)]))]
        )
        let set = store.setCalculatorInlineChart(chart, myAppId: myApp.id)
        #expect(set)
        let body = store.myApps.first!.components.first(where: { $0.kindString == "calculator" })?.body
        if case .calculator(let data) = body {
            #expect(data.inlineChart?.title == "Payment curve")
        } else {
            Issue.record("Expected calculator body")
        }

        let cleared = store.setCalculatorInlineChart(nil, myAppId: myApp.id)
        #expect(cleared)
        let body2 = store.myApps.first!.components.first(where: { $0.kindString == "calculator" })?.body
        if case .calculator(let data) = body2 {
            #expect(data.inlineChart == nil)
        } else {
            Issue.record("Expected calculator body after clear")
        }
    }

    @Test("embedComponent advertised under chart kind (chat embedding) — hidden with no chart/calculator")
    func embedComponentGating() {
        let (store, myApp) = freshStore()

        // No chart / calculator present → embedComponent not advertised.
        let bare = ToolGateState()
        #expect(!ChatViewModel.allowedToolNames(scope: .myApp(myApp.id), store: store, toolGateState: bare).contains("embedComponent"))

        // Chart present + chart tool active → embedComponent shows (it can
        // snapshot the chart into chat via hostKind "chat").
        store.addComponent(kind: "chart", name: "Chart", iconSystemName: "chart.pie", myAppId: myApp.id)
        let toolGateState = ToolGateState()
        toolGateState.activate(kind: "chart")
        let allowed = ChatViewModel.allowedToolNames(scope: .myApp(myApp.id), store: store, toolGateState: toolGateState)
        #expect(allowed.contains("embedComponent"))
    }

    @Test("Chart component present: gate then unlock exposes all chart tools")
    func chartComponentShowsGateThenTools() {
        let (store, myApp) = freshStore()
        store.addComponent(kind: "chart", name: "Chart", iconSystemName: "chart.pie", myAppId: myApp.id)

        let toolGateState = ToolGateState()
        let gated = ChatViewModel.allowedToolNames(scope: .myApp(myApp.id), store: store, toolGateState: toolGateState)
        #expect(gated.contains("get_tools_chart"))
        #expect(!gated.contains("renderChart"))

        toolGateState.activate(kind: "chart")
        let unlocked = ChatViewModel.allowedToolNames(scope: .myApp(myApp.id), store: store, toolGateState: toolGateState)
        #expect(unlocked.contains("renderChart"))
        #expect(unlocked.contains("patchChart"))
        #expect(unlocked.contains("setChartKind"))
        #expect(unlocked.contains("addChartSeries"))
        #expect(unlocked.contains("removeChartSeries"))
        #expect(!unlocked.contains("renderCalculator"))
    }

    @Test("addComponent supports the calculator kind and seeds a typed-empty body")
    func addComponentCalculator() {
        let (store, myApp) = freshStore()
        let id = store.addComponent(
            kind: "calculator",
            name: "Calc",
            iconSystemName: "function",
            myAppId: myApp.id
        )
        let added = store.myApps.first!.components.first(where: { $0.id == id })
        #expect(added?.kindString == "calculator")
    }

    @Test("Universal link tools are always advertised regardless of kinds present")
    func universalLinkToolsAlwaysOn() {
        let (store, myApp) = freshStore()
        let beforeAny = ChatViewModel.allowedToolNames(scope: .myApp(myApp.id), store: store, toolGateState: ToolGateState())
        #expect(beforeAny.contains("linkItem"))
        #expect(beforeAny.contains("unlinkItem"))

        store.addComponent(kind: "tracker", name: "Books", iconSystemName: "book", myAppId: myApp.id)
        store.addComponent(kind: "calendar", name: "Cal", iconSystemName: "calendar", myAppId: myApp.id)
        store.addComponent(kind: "checklist", name: "Errands", iconSystemName: "checklist", myAppId: myApp.id)
        let withAll = ChatViewModel.allowedToolNames(scope: .myApp(myApp.id), store: store, toolGateState: ToolGateState())
        #expect(withAll.contains("linkItem"))
        #expect(withAll.contains("unlinkItem"))

        // The four old per-kind link tools are gone for good.
        #expect(!withAll.contains("linkTrackerItem"))
        #expect(!withAll.contains("unlinkTrackerItem"))
        #expect(!withAll.contains("linkChecklistItem"))
        #expect(!withAll.contains("unlinkChecklistItem"))
    }

    @Test("addComponent schema enum + description derive from supportedComponentKinds (no hardcoded drift)")
    func addComponentSchemaMatchesSupportedKinds() {
        let (store, myApp) = freshStore()
        let registry = ToolRegistry()
        AppTools.registerMyAppTools(on: registry, store: store, myAppId: myApp.id)

        guard let tool = registry.resolve("addComponent") else {
            Issue.record("addComponent tool not registered")
            return
        }
        // Drill into parameters.properties.kind.enum
        let props = tool.descriptor.parameters
            .objectValue?["properties"]?.objectValue
        let kindEnumArray = props?["kind"]?.objectValue?["enum"]?.arrayValue ?? []
        let kindEnum = kindEnumArray.compactMap { $0.stringValue }
        let expected = MyAppType.tracker.supportedComponentKinds.sorted()
        #expect(Set(kindEnum) == Set(expected))
        #expect(kindEnum.contains("slack"))
        #expect(kindEnum.contains("calculator"))
        // Description should mention every supported kind so the agent
        // doesn't drift from the schema.
        for kind in expected {
            #expect(
                tool.descriptor.description.contains("\"\(kind)\""),
                "description missing kind '\(kind)'"
            )
        }
    }

    @Test("addComponent collapses the empty placeholder into the new typed component")
    func addComponentReplacesEmptyPlaceholder() {
        let (store, myApp) = freshStore()
        #expect(store.myApps.first!.components.count == 1)
        #expect(store.myApps.first!.components[0].kindString == "empty")

        let newId = store.addComponent(
            kind: "tracker",
            name: "Books",
            iconSystemName: "book",
            myAppId: myApp.id
        )

        // Placeholder gone; only the new typed component remains.
        let after = store.myApps.first!.components
        #expect(after.count == 1)
        #expect(after[0].id == newId)
        #expect(after[0].kindString == "tracker")
    }

    @Test("addComponent on a populated MyApp appends without dropping existing components")
    func addComponentAppendsAlongsideTypedComponents() {
        let (store, myApp) = freshStore()
        store.addComponent(kind: "tracker", name: "Books", iconSystemName: "book", myAppId: myApp.id)
        store.addComponent(kind: "calendar", name: "Cal", iconSystemName: "calendar", myAppId: myApp.id)

        let after = store.myApps.first!.components
        #expect(after.count == 2)
        #expect(after.contains { $0.kindString == "tracker" })
        #expect(after.contains { $0.kindString == "calendar" })
    }

    /// Round-1-vs-round-2 snapshot: the per-round `toolFilter` closure
    /// installed by `ChatViewModel.send` reads `allowedToolNames` on every
    /// round. If round 1's tool dispatch is `addComponent(kind:"tracker")`,
    /// round 2's filter must include the tracker surface — this asserts
    /// the resolver contract that makes mid-turn refresh useful. The
    /// matching AGUIKit test `toolFilter_recomputesPerRound` pins the
    /// other half (`runLoop` actually re-invokes the closure per round).
    @Test("Mid-turn refresh: addComponent makes the tool gate appear in the next round's tool filter")
    func midTurnRefresh_snapshotBeforeAndAfterAddComponent() {
        let (store, myApp) = freshStore()
        let toolGateState = ToolGateState()
        let before = ChatViewModel.allowedToolNames(scope: .myApp(myApp.id), store: store, toolGateState: toolGateState)
        // No tracker component → gate not yet visible.
        #expect(!before.contains("get_tools_tracker"))
        #expect(!before.contains("renderTracker"))

        // Simulate the agent's first-round tool call landing.
        store.addComponent(kind: "tracker", name: "Books", iconSystemName: "book", myAppId: myApp.id)

        let after = ChatViewModel.allowedToolNames(scope: .myApp(myApp.id), store: store, toolGateState: toolGateState)
        // Gate now visible; kind tools still locked until activated.
        #expect(after.contains("get_tools_tracker"))
        #expect(!after.contains("renderTracker"))
        // Surface only widens — base tools present in `before` stay present.
        #expect(before.isSubset(of: after))
    }

    @Test("addComponent seeds a typed-empty body so the tool gate is visible to the next round's tool filter")
    func addComponentSetsKindEagerly() {
        let (store, myApp) = freshStore()
        let id = store.addComponent(
            kind: "calendar",
            name: "Cal",
            iconSystemName: "calendar",
            myAppId: myApp.id
        )
        let added = store.myApps.first!.components.first(where: { $0.id == id })
        #expect(added?.kindString == "calendar")

        // Gate appears immediately; kind tools are unlocked only after activation.
        let allowed = ChatViewModel.allowedToolNames(scope: .myApp(myApp.id), store: store, toolGateState: ToolGateState())
        #expect(allowed.contains("get_tools_calendar"))
        #expect(!allowed.contains("renderCalendar"))
        #expect(!allowed.contains("addCalendarEvent"))
    }

    @Test("MyApp.init seeds a kindless empty placeholder, NOT a typed component")
    func defaultComponentIsEmpty() {
        let myApp = MyApp(name: "T", iconSystemName: "list.bullet.rectangle", typeId: "tracker")
        #expect(myApp.components.count == 1)
        #expect(myApp.components[0].kindString == "empty")
    }

    @Test("activeSystemPromptFragment composes base + per-kind prose by present kinds")
    func promptFragmentGating() {
        let (store, myApp) = freshStore()
        let type = MyAppTypeRegistry.shared.resolve(id: "tracker")!

        // Empty placeholder only → base prose (incl. LINKING framing),
        // no per-kind sections.
        let baseOnly = ChatViewModel.activeSystemPromptFragment(
            myApp: store.myApps.first!,
            type: type
        )
        #expect(baseOnly.contains("LINKING"),
                "the base fragment always includes the linking framing")
        #expect(!baseOnly.contains("TRACKER —"))
        #expect(!baseOnly.contains("CALENDAR —"))
        #expect(!baseOnly.contains("CHECKLIST —"))

        // The kind catalog menu is always present — even with no component of
        // a kind yet, the agent sees a one-line capability blurb per supported
        // kind so it knows it can `addComponent(kind:…)` to grow into one.
        #expect(baseOnly.contains("COMPONENT KINDS you can"))
        for kind in type.supportedComponentKinds {
            #expect(baseOnly.contains("\(kind) — "),
                    "catalog must list supported kind \(kind) before it is present")
        }

        // Each catalog blurb comes from its kind's dedicated
        // `ComponentKindSpec.catalogBlurb` (one definition site per kind), kept
        // separate from the full `promptFragment` so the menu is one clean line.
        let calcSpec = type.kinds["calculator"]
        #expect(calcSpec?.catalogBlurb == "live numeric model with tunable inputs + formula rows")
        #expect(baseOnly.contains("calculator — live numeric model with tunable inputs + formula rows"))

        // Add a tracker → tracker prose appears.
        store.addComponent(kind: "tracker", name: "Books", iconSystemName: "book", myAppId: myApp.id)
        let trackerOnly = ChatViewModel.activeSystemPromptFragment(
            myApp: store.myApps.first!,
            type: type
        )
        #expect(trackerOnly.contains("TRACKER —"))
        #expect(!trackerOnly.contains("CALENDAR —"))
        #expect(!trackerOnly.contains("CHECKLIST —"))

        // Add a calendar → calendar prose.
        store.addComponent(kind: "calendar", name: "Cal", iconSystemName: "calendar", myAppId: myApp.id)
        let both = ChatViewModel.activeSystemPromptFragment(
            myApp: store.myApps.first!,
            type: type
        )
        #expect(both.contains("TRACKER —"))
        #expect(both.contains("CALENDAR —"))
        #expect(!both.contains("CHECKLIST —"))

        store.addComponent(kind: "checklist", name: "Errands", iconSystemName: "checklist", myAppId: myApp.id)
        let allKinds = ChatViewModel.activeSystemPromptFragment(
            myApp: store.myApps.first!,
            type: type
        )
        #expect(allKinds.contains("CHECKLIST —"))
    }

    @Test("addComponent supports the checklist kind and seeds a typed-empty body")
    func addComponentChecklist() {
        let (store, myApp) = freshStore()
        let id = store.addComponent(
            kind: "checklist",
            name: "Errands",
            iconSystemName: "checklist",
            myAppId: myApp.id
        )
        let added = store.myApps.first!.components.first(where: { $0.id == id })
        #expect(added?.kindString == "checklist")
    }

    @Test("Memory scope surfaces orchestrator + memory FS; notifications gated")
    func memoryScopeSurface() {
        let (store, _) = freshStore()
        let allowed = ChatViewModel.allowedToolNames(scope: .memory, store: store, toolGateState: ToolGateState())
        // Orchestrator surface
        #expect(allowed.contains("listMyApps"))
        #expect(allowed.contains("createMyApp"))
        #expect(allowed.contains("invokeMyAppAgent"))
        // Memory FS — primary orchestrator surface, NOT gated.
        #expect(allowed.contains("lsMemories"))
        #expect(allowed.contains("readMemoryFile"))
        // Notifications gated (issue #220).
        #expect(allowed.contains("get_tools_notifications"))
        #expect(!allowed.contains("sendNotification"))
        // No myApp-scope tools leak in
        #expect(!allowed.contains("renderTracker"))
        #expect(!allowed.contains("addTrackerItems"))
        #expect(!allowed.contains("addComponent"))
    }
}
