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
        let allowed = ChatViewModel.allowedToolNames(scope: .myApp(myApp.id), store: store, skillState: SkillState())

        // Base tools always visible.
        #expect(allowed.contains("addComponent"))
        #expect(allowed.contains("removeComponent"))
        #expect(allowed.contains("setActiveComponent"))
        #expect(allowed.contains("clearCanvas"))
        #expect(allowed.contains("getCanvasState"))
        #expect(allowed.contains("linkItem"))
        #expect(allowed.contains("unlinkItem"))

        // Notifications now behind get_skill_notifications (issue #220).
        #expect(allowed.contains("get_skill_notifications"))
        #expect(!allowed.contains("sendNotification"))
        #expect(!allowed.contains("cancelNotification"))

        // Memory is behind get_skill_memories; raw memory tool hidden.
        #expect(allowed.contains("get_skill_memories"))
        #expect(!allowed.contains("lsMemories"))

        // No kind tools and no kind gates (no components of those kinds).
        #expect(!allowed.contains("renderTracker"))
        #expect(!allowed.contains("addTrackerItems"))
        #expect(!allowed.contains("renderCalendar"))
        #expect(!allowed.contains("addCalendarEvent"))
        #expect(!allowed.contains("renderChecklist"))
        #expect(!allowed.contains("addChecklistItem"))
        #expect(!allowed.contains("get_skill_tracker"))
        #expect(!allowed.contains("get_skill_calendar"))
        #expect(!allowed.contains("get_skill_checklist"))
    }

    @Test("Tracker component present: get_skill_tracker gate appears; tracker tools hidden until activated")
    func trackerComponentShowsGateThenTools() {
        let (store, myApp) = freshStore()
        store.addComponent(kind: "tracker", name: "Books", iconSystemName: "book", myAppId: myApp.id)

        // Before activation: gate visible, kind tools hidden.
        let skillState = SkillState()
        let gated = ChatViewModel.allowedToolNames(scope: .myApp(myApp.id), store: store, skillState: skillState)
        #expect(gated.contains("get_skill_tracker"))
        #expect(!gated.contains("renderTracker"))
        #expect(!gated.contains("addTrackerItems"))
        // Calendar gate absent (no calendar component).
        #expect(!gated.contains("get_skill_calendar"))
        #expect(gated.contains("linkItem"))
        #expect(gated.contains("unlinkItem"))

        // After activation: kind tools appear, gate disappears.
        skillState.activate(kind: "tracker")
        let unlocked = ChatViewModel.allowedToolNames(scope: .myApp(myApp.id), store: store, skillState: skillState)
        #expect(unlocked.contains("renderTracker"))
        #expect(unlocked.contains("addTrackerItems"))
        #expect(!unlocked.contains("get_skill_tracker"))
        #expect(!unlocked.contains("renderCalendar"))
    }

    @Test("Calendar component present: get_skill_calendar gate appears; tracker tools hidden")
    func calendarComponentShowsGateThenTools() {
        let (store, myApp) = freshStore()
        store.addComponent(kind: "calendar", name: "Cal", iconSystemName: "calendar", myAppId: myApp.id)

        let skillState = SkillState()
        let gated = ChatViewModel.allowedToolNames(scope: .myApp(myApp.id), store: store, skillState: skillState)
        #expect(gated.contains("get_skill_calendar"))
        #expect(!gated.contains("renderCalendar"))
        #expect(!gated.contains("get_skill_tracker"))

        skillState.activate(kind: "calendar")
        let unlocked = ChatViewModel.allowedToolNames(scope: .myApp(myApp.id), store: store, skillState: skillState)
        #expect(unlocked.contains("renderCalendar"))
        #expect(unlocked.contains("addCalendarEvent"))
        #expect(!unlocked.contains("renderTracker"))
    }

    @Test("Checklist component present: gate then unlock exposes all checklist tools")
    func checklistComponentShowsGateThenTools() {
        let (store, myApp) = freshStore()
        store.addComponent(kind: "checklist", name: "Errands", iconSystemName: "checklist", myAppId: myApp.id)

        let skillState = SkillState()
        let gated = ChatViewModel.allowedToolNames(scope: .myApp(myApp.id), store: store, skillState: skillState)
        #expect(gated.contains("get_skill_checklist"))
        #expect(!gated.contains("renderChecklist"))

        skillState.activate(kind: "checklist")
        let unlocked = ChatViewModel.allowedToolNames(scope: .myApp(myApp.id), store: store, skillState: skillState)
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

    @Test("Universal link tools are always advertised regardless of kinds present")
    func universalLinkToolsAlwaysOn() {
        let (store, myApp) = freshStore()
        let beforeAny = ChatViewModel.allowedToolNames(scope: .myApp(myApp.id), store: store, skillState: SkillState())
        #expect(beforeAny.contains("linkItem"))
        #expect(beforeAny.contains("unlinkItem"))

        store.addComponent(kind: "tracker", name: "Books", iconSystemName: "book", myAppId: myApp.id)
        store.addComponent(kind: "calendar", name: "Cal", iconSystemName: "calendar", myAppId: myApp.id)
        store.addComponent(kind: "checklist", name: "Errands", iconSystemName: "checklist", myAppId: myApp.id)
        let withAll = ChatViewModel.allowedToolNames(scope: .myApp(myApp.id), store: store, skillState: SkillState())
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
    @Test("Mid-turn refresh: addComponent makes the skill gate appear in the next round's tool filter")
    func midTurnRefresh_snapshotBeforeAndAfterAddComponent() {
        let (store, myApp) = freshStore()
        let skillState = SkillState()
        let before = ChatViewModel.allowedToolNames(scope: .myApp(myApp.id), store: store, skillState: skillState)
        // No tracker component → gate not yet visible.
        #expect(!before.contains("get_skill_tracker"))
        #expect(!before.contains("renderTracker"))

        // Simulate the agent's first-round tool call landing.
        store.addComponent(kind: "tracker", name: "Books", iconSystemName: "book", myAppId: myApp.id)

        let after = ChatViewModel.allowedToolNames(scope: .myApp(myApp.id), store: store, skillState: skillState)
        // Gate now visible; kind tools still locked until activated.
        #expect(after.contains("get_skill_tracker"))
        #expect(!after.contains("renderTracker"))
        // Surface only widens — base tools present in `before` stay present.
        #expect(before.isSubset(of: after))
    }

    @Test("addComponent seeds a typed-empty body so the skill gate is visible to the next round's tool filter")
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
        let allowed = ChatViewModel.allowedToolNames(scope: .myApp(myApp.id), store: store, skillState: SkillState())
        #expect(allowed.contains("get_skill_calendar"))
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
        let allowed = ChatViewModel.allowedToolNames(scope: .memory, store: store, skillState: SkillState())
        // Orchestrator surface
        #expect(allowed.contains("listMyApps"))
        #expect(allowed.contains("createMyApp"))
        #expect(allowed.contains("invokeMyAppAgent"))
        // Memory FS — primary orchestrator surface, NOT gated.
        #expect(allowed.contains("lsMemories"))
        #expect(allowed.contains("readMemoryFile"))
        // Notifications gated (issue #220).
        #expect(allowed.contains("get_skill_notifications"))
        #expect(!allowed.contains("sendNotification"))
        // No myApp-scope tools leak in
        #expect(!allowed.contains("renderTracker"))
        #expect(!allowed.contains("addTrackerItems"))
        #expect(!allowed.contains("addComponent"))
    }
}
