import Foundation
import Testing
import AGUIKit
@testable import PupaApp

/// Pins the `/tools` slash-command rendering: descriptors are bucketed by
/// component (`Canvas`, `Tracker`, `Calendar`, `Checklist`, `Memory`,
/// `Notifications`, `Orchestrator`) instead of dumped as one flat list.
/// Groups are derived from `MyAppType` so the wiring stays a derived view
/// of the same sets `allowedToolNames` reads — no parallel tool-name list.
@MainActor
@Suite("Slash `/tools` grouped rendering")
struct SlashToolsRenderingTests {

    private static func descriptor(_ name: String, description: String = "") -> ToolDescriptor {
        ToolDescriptor(name: name, description: description, parameters: .object([:]))
    }

    private static func descriptors(_ names: [String]) -> [ToolDescriptor] {
        names.sorted().map { descriptor($0) }
    }

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

    // MARK: - groupFrontendTools

    @Test("Memory scope: Memory + Tool Gates (notifications) + Orchestrator + HITL populated")
    func memoryScopeGroups() {
        let (store, _) = freshStore()
        let allowed = ChatViewModel.allowedToolNames(scope: .memory, store: store, toolGateState: ToolGateState())
        let descs = Self.descriptors(Array(allowed))
        let groups = ChatViewModel.groupFrontendTools(
            descriptors: descs,
            scope: .memory,
            store: store
        )
        let labels = groups.map(\.label)
        #expect(labels == ["Tool Gates", "Memory", "Orchestrator", "Human-in-the-loop"])

        let memoryNames = groups.first(where: { $0.label == "Memory" })!.tools.map(\.name)
        #expect(Set(memoryNames) == MyAppType.memoryToolNames)
        let gateNames = Set(groups.first(where: { $0.label == "Tool Gates" })!.tools.map(\.name))
        #expect(gateNames == ["get_tools_notifications"])
        let orchNames = groups.first(where: { $0.label == "Orchestrator" })!.tools.map(\.name)
        #expect(Set(orchNames) == MyAppType.orchestratorToolNames)
    }

    @Test("MyApp scope (empty placeholder): Canvas + Tool Gates (memory + notifications), no kind groups")
    func myAppScopeEmptyCanvasGroups() {
        let (store, myApp) = freshStore()
        let allowed = ChatViewModel.allowedToolNames(scope: .myApp(myApp.id), store: store, toolGateState: ToolGateState())
        let groups = ChatViewModel.groupFrontendTools(
            descriptors: Self.descriptors(Array(allowed)),
            scope: .myApp(myApp.id),
            store: store
        )
        // No components → no kind gates; memories + notifications gates advertised.
        #expect(groups.map(\.label) == ["Canvas", "Tool Gates", "Human-in-the-loop"])
        let canvasNames = Set(groups.first(where: { $0.label == "Canvas" })!.tools.map(\.name))
        #expect(canvasNames == MyAppType.tracker.baseToolNames)
        let gateNames = Set(groups.first(where: { $0.label == "Tool Gates" })!.tools.map(\.name))
        #expect(gateNames == ["get_tools_memories", "get_tools_notifications"])
    }

    @Test("MyApp scope (all kinds, no tools activated): Canvas + Tool Gates, kind tools hidden")
    func myAppScopeAllKindsGated() {
        let (store, myApp) = freshStore()
        store.addComponent(kind: "tracker", name: "Books", iconSystemName: "book", myAppId: myApp.id)
        store.addComponent(kind: "calendar", name: "Cal", iconSystemName: "calendar", myAppId: myApp.id)
        store.addComponent(kind: "checklist", name: "Errands", iconSystemName: "checklist", myAppId: myApp.id)
        let allowed = ChatViewModel.allowedToolNames(scope: .myApp(myApp.id), store: store, toolGateState: ToolGateState())
        let groups = ChatViewModel.groupFrontendTools(
            descriptors: Self.descriptors(Array(allowed)),
            scope: .myApp(myApp.id),
            store: store
        )
        // Kind tools are hidden until a gate is called; only gate tool names appear.
        #expect(groups.map(\.label) == ["Canvas", "Tool Gates", "Human-in-the-loop"])
        let gateNames = Set(groups.first(where: { $0.label == "Tool Gates" })!.tools.map(\.name))
        #expect(gateNames == [
            "get_tools_tracker", "get_tools_calendar", "get_tools_checklist",
            "get_tools_memories", "get_tools_notifications",
        ])
    }

    @Test("MyApp scope (all tools activated): Canvas + kind groups + Memory + Notifications visible")
    func myAppScopeAllKindsUnlocked() {
        let (store, myApp) = freshStore()
        store.addComponent(kind: "tracker", name: "Books", iconSystemName: "book", myAppId: myApp.id)
        store.addComponent(kind: "calendar", name: "Cal", iconSystemName: "calendar", myAppId: myApp.id)
        store.addComponent(kind: "checklist", name: "Errands", iconSystemName: "checklist", myAppId: myApp.id)
        let toolGateState = ToolGateState()
        toolGateState.activate(kind: "tracker")
        toolGateState.activate(kind: "calendar")
        toolGateState.activate(kind: "checklist")
        toolGateState.activateMemories()
        toolGateState.activateNotifications()
        let allowed = ChatViewModel.allowedToolNames(scope: .myApp(myApp.id), store: store, toolGateState: toolGateState)
        let groups = ChatViewModel.groupFrontendTools(
            descriptors: Self.descriptors(Array(allowed)),
            scope: .myApp(myApp.id),
            store: store
        )
        #expect(groups.map(\.label) == [
            "Canvas", "Tracker", "Calendar", "Checklist", "Memory", "Notifications", "Human-in-the-loop",
        ])
        let trackerNames = Set(groups.first(where: { $0.label == "Tracker" })!.tools.map(\.name))
        #expect(trackerNames == MyAppType.tracker.toolNamesByKind["tracker"])
        let calendarNames = Set(groups.first(where: { $0.label == "Calendar" })!.tools.map(\.name))
        #expect(calendarNames == MyAppType.tracker.toolNamesByKind["calendar"])
        let checklistNames = Set(groups.first(where: { $0.label == "Checklist" })!.tools.map(\.name))
        #expect(checklistNames == MyAppType.tracker.toolNamesByKind["checklist"])
    }

    @Test("Descriptors not in any known group fall into `Other`")
    func unknownToolFallsIntoOther() {
        let (store, _) = freshStore()
        let descs = [Self.descriptor("definitelyNotARealTool")]
        let groups = ChatViewModel.groupFrontendTools(
            descriptors: descs,
            scope: .memory,
            store: store
        )
        #expect(groups.last?.label == "Other")
        #expect(groups.last?.tools.map(\.name) == ["definitelyNotARealTool"])
    }

    // MARK: - renderToolsBody

    @Test("Body renders indented section headers with bullets under each group")
    func bodyRendersGroupedHeaders() {
        let groups: [ChatViewModel.ToolGroup] = [
            .init(label: "Canvas", tools: [Self.descriptor("addComponent"), Self.descriptor("clearCanvas")]),
            .init(label: "Memory", tools: [Self.descriptor("lsMemories")]),
        ]
        let body = ChatViewModel.renderToolsBody(
            agentName: "TestAgent",
            frontendGroups: groups,
            frontendIsEmpty: false,
            backend: [],
            disabledByUser: [],
            verbose: false
        )
        #expect(body.contains("Agent: TestAgent"))
        #expect(body.contains("Frontend tools (advertised to the model this turn):"))
        #expect(body.contains("  Canvas:\n    • addComponent\n    • clearCanvas"))
        #expect(body.contains("  Memory:\n    • lsMemories"))
        // A blank line separates adjacent groups so the listing breathes.
        #expect(body.contains("    • clearCanvas\n\n  Memory:"))
    }

    @Test("Verbose mode appends ' — <description>' after each tool name")
    func bodyVerboseAppendsDescriptions() {
        let groups: [ChatViewModel.ToolGroup] = [
            .init(label: "Canvas", tools: [Self.descriptor("addComponent", description: "Add a component.")]),
        ]
        let body = ChatViewModel.renderToolsBody(
            agentName: "TestAgent",
            frontendGroups: groups,
            frontendIsEmpty: false,
            backend: [],
            disabledByUser: [],
            verbose: true
        )
        #expect(body.contains("    • addComponent — Add a component."))
    }

    @Test("Empty frontend renders `(none)` placeholder")
    func bodyEmptyFrontendFallback() {
        let body = ChatViewModel.renderToolsBody(
            agentName: "TestAgent",
            frontendGroups: [],
            frontendIsEmpty: true,
            backend: [],
            disabledByUser: [],
            verbose: false
        )
        #expect(body.contains("Frontend tools (advertised to the model this turn):\n  (none)"))
    }
}
