import Foundation

/// Builds `[AgentDescriptor]` for a MyApp by walking its current state.
///
/// The MyApp main agent is always emitted; each Slack component
/// contributes one descriptor per `SlackAgent` in `SlackData.agents`.
///
/// ## Extension point
/// Add a new attribute by appending one `AgentProperty` to the relevant
/// builder. The list/details views render whatever is in `properties` —
/// no UI changes required unless you also need a new `AgentPropertyValue`
/// rendering shape.
public enum AgentRegistry {

    /// Stable id for the MyApp's main agent (one per app).
    public static let mainAgentId = "myapp-main"

    /// Stable id for the orchestrator agent (the cross-MyApp meta-agent).
    /// There's only one — no scoping needed.
    public static let orchestratorAgentId = "orchestrator"

    /// Build the id used for a Slack agent inside a specific component.
    /// `componentId` keeps the id unique even if two components ever
    /// host agents with the same underlying `SlackAgent.id`.
    public static func slackAgentId(componentId: String, slackAgentId: String) -> String {
        "slack:\(componentId):\(slackAgentId)"
    }

    @MainActor
    public static func enumerateAgents(
        myApp: MyApp,
        store: MyAppStore,
        settings: SettingsStore,
        catalog: ModelCatalogStore
    ) -> [AgentDescriptor] {
        var descriptors: [AgentDescriptor] = []
        descriptors.append(buildMainAgent(myApp: myApp, store: store, settings: settings, catalog: catalog))
        for component in myApp.components {
            if case .slack(let data) = component.body {
                for agent in data.agents {
                    descriptors.append(buildSlackAgent(
                        myApp: myApp,
                        component: component,
                        agent: agent,
                        settings: settings,
                        catalog: catalog
                    ))
                }
            }
        }
        return descriptors
    }

    // MARK: - Main MyApp agent

    @MainActor
    private static func buildMainAgent(
        myApp: MyApp,
        store: MyAppStore,
        settings: SettingsStore,
        catalog: ModelCatalogStore
    ) -> AgentDescriptor {
        let promptPath = "\(MemoryStore.myAppFolder(myAppName: myApp.name))/AGENTS.md"
        let memory = MemoryStore(rootOverride: MemoryStore.appRoot(myAppName: myApp.name))
        let promptOnDisk = memory.fileExists(at: "AGENTS.md")
        let allowedTools = ChatViewModel.allowedToolNames(
            scope: .myApp(myApp.id),
            store: store,
            toolGateState: ToolGateState()
        )
        let toolGroups = groupToolNames(
            allowed: allowedTools,
            scope: .myApp(myApp.id),
            store: store
        )

        var properties: [AgentProperty] = []
        properties.append(modelProperty(currentSelection: store.myAppLLM(for: myApp.id), catalog: catalog))
        properties.append(permissionsProperty(settings: settings))
        properties.append(AgentProperty(
            id: "prompt",
            label: "Prompt",
            value: .link(
                label: promptPath,
                destination: .myAppMemoryFile(myApp.id, promptPath)
            ),
            note: promptOnDisk
                ? nil
                : "Falls back to the MyAppType fragment — no AGENTS.md on disk yet. Open the link to create one."
        ))
        properties.append(AgentProperty(
            id: "components",
            label: "Components",
            value: .list(myApp.components.map { "\($0.name) (\($0.kindString))" }),
            note: nil
        ))
        properties.append(AgentProperty(
            id: "tools",
            label: "Tool surface",
            value: .sections(
                summary: "\(allowedTools.count) tools currently exposed",
                groups: toolGroups
            ),
            note: "Resolved from the MyApp type and the components currently on the canvas. Expand to see the full list grouped like `/tools`."
        ))

        return AgentDescriptor(
            id: mainAgentId,
            name: myApp.name,
            kind: .myApp,
            iconSystemName: myApp.iconSystemName,
            myAppId: myApp.id,
            subtitle: "Main agent",
            properties: properties
        )
    }

    // MARK: - Orchestrator agent

    /// Build the orchestrator's `AgentDescriptor`. The orchestrator has no
    /// `myAppId` — it runs in the `.memory` scope and routes across every
    /// MyApp via `invokeMyAppAgent`. Tools are resolved the same way the
    /// chat surface does (`allowedToolNames(scope: .memory, …)`); the
    /// prompt link points at `memories/orchestrator/AGENTS.md`.
    @MainActor
    public static func buildOrchestratorAgent(
        store: MyAppStore,
        settings: SettingsStore,
        memory: MemoryStore,
        catalog: ModelCatalogStore
    ) -> AgentDescriptor {
        let promptPath = "\(MemoryStore.orchestratorFolder())/AGENTS.md"
        let promptOnDisk = memory.fileExists(at: "\(MemoryStore.orchestratorFolder())/AGENTS.md")
        let allowedTools = ChatViewModel.allowedToolNames(
            scope: .memory,
            store: store,
            toolGateState: ToolGateState()
        )

        var properties: [AgentProperty] = []
        properties.append(modelProperty(currentSelection: settings.orchestratorLLM(), catalog: catalog))
        properties.append(permissionsProperty(settings: settings))
        properties.append(AgentProperty(
            id: "prompt",
            label: "Prompt",
            value: .link(
                label: promptPath,
                destination: .memoryFile(promptPath)
            ),
            note: promptOnDisk
                ? nil
                : "Falls back to the hardcoded orchestrator prompt — no AGENTS.md on disk yet. Open the link to create one."
        ))
        properties.append(AgentProperty(
            id: "tools",
            label: "Tool surface",
            value: .list(allowedTools.sorted()),
            note: "Resolved from `ChatViewModel.allowedToolNames(scope: .memory, …)` — the same set the orchestrator sees on every memory-mode turn."
        ))

        return AgentDescriptor(
            id: orchestratorAgentId,
            name: "Orchestrator",
            kind: .orchestrator,
            iconSystemName: "square.stack.3d.up.fill",
            myAppId: nil,
            subtitle: "Cross-MyApp meta-agent",
            properties: properties
        )
    }

    // MARK: - Slack agent

    @MainActor
    private static func buildSlackAgent(
        myApp: MyApp,
        component: Component,
        agent: SlackAgent,
        settings: SettingsStore,
        catalog: ModelCatalogStore
    ) -> AgentDescriptor {
        let promptPath = "\(MemoryStore.slackAgentFolder(myAppName: myApp.name, agentName: agent.name))/AGENTS.md"

        var properties: [AgentProperty] = []
        properties.append(AgentProperty(
            id: "role",
            label: "Role",
            value: .text(agent.role.isEmpty ? "—" : agent.role),
            note: nil
        ))
        let agentSelection: (provider: String, model: String)?
        if let provider = agent.llmProvider, let model = agent.llmModel {
            agentSelection = (provider, model)
        } else {
            agentSelection = nil
        }
        properties.append(modelProperty(currentSelection: agentSelection, catalog: catalog))
        properties.append(permissionsProperty(settings: settings))
        properties.append(AgentProperty(
            id: "prompt",
            label: "Prompt",
            value: .link(
                label: promptPath,
                destination: .myAppMemoryFile(myApp.id, promptPath)
            ),
            note: nil
        ))
        properties.append(AgentProperty(
            id: "persona",
            label: "Persona addition",
            value: .text(agent.systemPromptAddition.isEmpty
                ? "(none)"
                : agent.systemPromptAddition),
            note: "Appended to the parent MyApp's system prompt for each invocation."
        ))
        properties.append(AgentProperty(
            id: "component",
            label: "Component",
            value: .list(["\(component.name) (\(component.kindString))"]),
            note: nil
        ))

        return AgentDescriptor(
            id: slackAgentId(componentId: component.id, slackAgentId: agent.id),
            name: agent.name,
            kind: .slack,
            iconSystemName: "person.crop.circle",
            myAppId: myApp.id,
            subtitle: agent.role.isEmpty ? nil : agent.role,
            properties: properties
        )
    }

    // MARK: - Tool grouping

    /// Group `allowed` tool names by the same buckets `/tools` uses —
    /// Canvas → kind groups → Tool Gates → Memory → Notifications →
    /// Orchestrator → Human-in-the-loop → Other. Mirrors the bucketing
    /// in `ChatViewModel.groupFrontendTools` but operates on names only
    /// (no `ToolDescriptor` dependency) since the agents page does not
    /// need parameter schemas. Keep both in sync when new groups are
    /// added.
    @MainActor
    private static func groupToolNames(
        allowed: Set<String>,
        scope: ChatScope,
        store: MyAppStore
    ) -> [AgentPropertySection] {
        var canvasNames: Set<String> = []
        var kindGroups: [(label: String, names: Set<String>)] = []
        var toolGateNames: Set<String> = []
        if case .myApp(let id) = scope,
           let myApp = store.myApps.first(where: { $0.id == id }),
           let type = MyAppTypeRegistry.shared.resolve(id: myApp.typeId) {
            canvasNames = type.baseToolNames
            let kindOrder = ["tracker", "calendar", "checklist"]
            for kind in kindOrder {
                if let names = type.toolNamesByKind[kind], !names.isEmpty {
                    kindGroups.append((label: kind.capitalized, names: names))
                    toolGateNames.insert("get_tools_\(kind)")
                }
            }
            for kind in type.toolNamesByKind.keys.sorted() where !kindOrder.contains(kind) {
                if let names = type.toolNamesByKind[kind], !names.isEmpty {
                    kindGroups.append((label: kind.capitalized, names: names))
                    toolGateNames.insert("get_tools_\(kind)")
                }
            }
            toolGateNames.insert("get_tools_memories")
        }
        toolGateNames.insert("get_tools_notifications")

        let definitions: [(label: String, names: Set<String>)] = [
            (label: "Canvas", names: canvasNames),
        ] + kindGroups + [
            (label: "Tool Gates", names: toolGateNames),
            (label: "Memory", names: MyAppType.memoryToolNames),
            (label: "Notifications", names: MyAppType.notificationToolNames),
            (label: "Orchestrator", names: MyAppType.orchestratorToolNames),
            (label: "Human-in-the-loop", names: MyAppType.humanInTheLoopToolNames),
        ]

        var assigned: Set<String> = []
        var result: [AgentPropertySection] = []
        for def in definitions {
            let bucket = def.names.intersection(allowed).subtracting(assigned)
            if bucket.isEmpty { continue }
            assigned.formUnion(bucket)
            result.append(AgentPropertySection(label: def.label, items: bucket.sorted()))
        }
        let leftovers = allowed.subtracting(assigned)
        if !leftovers.isEmpty {
            result.append(AgentPropertySection(label: "Other", items: leftovers.sorted()))
        }
        return result
    }

    // MARK: - Shared property builders

    @MainActor
    private static func modelProperty(
        currentSelection: (provider: String, model: String)?,
        catalog: ModelCatalogStore
    ) -> AgentProperty {
        // Resolve the current selection against the dynamic catalog so the
        // picker shows the matching entry as selected. An override that isn't
        // in the catalog (e.g. one persisted by an older app build) falls back
        // to the "Backend default" sentinel — the user can pick a known model
        // to overwrite it.
        let selectedId: String
        if let (provider, model) = currentSelection,
           let known = catalog.model(provider: provider, modelId: model) {
            selectedId = known.id
        } else {
            selectedId = KnownLLMModelCatalog.backendDefaultId
        }
        return AgentProperty(
            id: "model",
            label: "Model",
            value: .modelPicker(selectedId: selectedId, options: catalog.models),
            note: selectedId == KnownLLMModelCatalog.backendDefaultId
                ? "Inherits the model the backend was started with (LLM_PROVIDER env var)."
                : nil
        )
    }

    @MainActor
    private static func permissionsProperty(settings: SettingsStore) -> AgentProperty {
        let shell = settings.shellApprovalDisabled
            ? "Shell approval: bypassed"
            : "Shell approval: required"
        return AgentProperty(
            id: "permissions",
            label: "Permissions",
            value: .list([shell]),
            note: "Resolved at the global scope today. Per-agent overrides are planned (TODO) — the `SettingsScope.component(myAppId:componentId:)` stub in EffectiveSettings.swift is the future hook point."
        )
    }
}
