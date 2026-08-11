import Foundation

/// Builds `[AgentDescriptor]` for a MyApp by walking its current state.
///
/// The MyApp main agent is always emitted; each `pupa/agents/<slug>/AGENTS.md`
/// subagent contributes one descriptor (discovered via `AgentStore`).
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

    /// Build the descriptor id for a subagent: `subagent:<myAppId>:<slug>`.
    /// `AgentDetailView` unwinds this to resolve the AGENTS.md to edit.
    public static func subagentId(myAppId: UUID, slug: String) -> String {
        "subagent:\(myAppId.uuidString):\(slug)"
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
        let appMemory = MemoryStore(rootOverride: MemoryStore.appRoot(myAppName: myApp.name))
        for subagent in AgentStore(memory: appMemory).agents {
            descriptors.append(buildSubagent(
                myApp: myApp,
                subagent: subagent,
                store: store,
                settings: settings,
                catalog: catalog
            ))
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
        let promptPath = "\(MemoryStore.pupaFolder(myAppName: myApp.name))/AGENTS.md"
        let memory = MemoryStore(rootOverride: MemoryStore.appRoot(myAppName: myApp.name))
        let promptOnDisk = memory.fileExists(at: MemoryStore.pupaAgentsPath)
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
        let currentSelection = store.myAppLLM(for: myApp.id)
        let disabled = store.myAppDisabledTools(for: myApp.id)

        var properties: [AgentProperty] = []
        properties.append(modelProperty(currentSelection: currentSelection, catalog: catalog))
        if let thinking = thinkingProperty(currentLevel: store.myAppThinking(for: myApp.id), catalog: catalog) {
            properties.append(thinking)
        }
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
            value: .toolToggles(
                summary: toolSummaryText(allowed: allowedTools.count, disabled: disabled.count),
                groups: toolGroups,
                disabled: disabled
            ),
            note: "Resolved from the MyApp type and the components currently on the canvas. Toggle a tool off to hide it from this agent (unioned with the global Settings → Tools set)."
        ))

        return AgentDescriptor(
            id: mainAgentId,
            name: myApp.name,
            kind: .myApp,
            iconSystemName: myApp.iconSystemName,
            myAppId: myApp.id,
            subtitle: "Main agent",
            modelSummary: modelSummaryText(currentSelection: currentSelection, catalog: catalog),
            toolSummary: toolSummaryText(allowed: allowedTools.count, disabled: disabled.count),
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
        let promptPath = "\(MemoryStore.orchestratorFolder())/\(MemoryStore.pupaAgentsPath)"
        let promptOnDisk = memory.fileExists(at: "\(MemoryStore.orchestratorFolder())/\(MemoryStore.pupaAgentsPath)")
        let allowedTools = ChatViewModel.allowedToolNames(
            scope: .memory,
            store: store,
            toolGateState: ToolGateState()
        )
        let toolGroups = groupToolNames(allowed: allowedTools, scope: .memory, store: store)
        let currentSelection = settings.orchestratorLLM()
        let disabled = settings.orchestratorDisabledTools

        var properties: [AgentProperty] = []
        properties.append(modelProperty(currentSelection: currentSelection, catalog: catalog))
        if let thinking = thinkingProperty(currentLevel: settings.orchestratorThinking, catalog: catalog) {
            properties.append(thinking)
        }
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
            value: .toolToggles(
                summary: toolSummaryText(allowed: allowedTools.count, disabled: disabled.count),
                groups: toolGroups,
                disabled: disabled
            ),
            note: "The set the orchestrator sees on every memory-mode turn. Toggle a tool off to hide it (unioned with the global Settings → Tools set)."
        ))

        return AgentDescriptor(
            id: orchestratorAgentId,
            name: "Orchestrator",
            kind: .orchestrator,
            iconSystemName: "square.stack.3d.up.fill",
            myAppId: nil,
            subtitle: "Cross-MyApp meta-agent",
            modelSummary: modelSummaryText(currentSelection: currentSelection, catalog: catalog),
            toolSummary: toolSummaryText(allowed: allowedTools.count, disabled: disabled.count),
            properties: properties
        )
    }

    // MARK: - Subagent

    @MainActor
    private static func buildSubagent(
        myApp: MyApp,
        subagent: Subagent,
        store: MyAppStore,
        settings: SettingsStore,
        catalog: ModelCatalogStore
    ) -> AgentDescriptor {
        let promptPath = "\(MemoryStore.pupaFolder(myAppName: myApp.name))/agents/\(subagent.name)/AGENTS.md"

        var properties: [AgentProperty] = []
        if !subagent.description.isEmpty {
            properties.append(AgentProperty(
                id: "role",
                label: "Description",
                value: .text(subagent.description),
                note: nil
            ))
        }
        let agentSelection = subagent.llmSelection
        // The subagent's advertised surface, narrowed by its frontmatter.
        let base = ChatViewModel.allowedToolNames(
            scope: .myApp(myApp.id),
            store: store,
            toolGateState: ToolGateState()
        )
        let allowedTools = SubagentPolicy.narrowedTools(base: base, subagent: subagent)
        let toolGroups = groupToolNames(allowed: allowedTools, scope: .myApp(myApp.id), store: store)
        let disabled = Set(subagent.disabledTools ?? [])

        properties.append(modelProperty(currentSelection: agentSelection, catalog: catalog))
        properties.append(permissionsProperty(settings: settings))
        properties.append(AgentProperty(
            id: "prompt",
            label: "Prompt",
            value: .link(
                label: promptPath,
                destination: .myAppMemoryFile(myApp.id, promptPath)
            ),
            note: "Edit this AGENTS.md to change the persona, tools (frontmatter `tools`), or model (`model`/`provider`)."
        ))
        properties.append(AgentProperty(
            id: "tools",
            label: "Tool surface",
            value: .toolToggles(
                summary: toolSummaryText(allowed: allowedTools.count, disabled: disabled.count),
                groups: toolGroups,
                disabled: disabled
            ),
            note: "Resolved from the subagent's frontmatter `tools`/`disabled_tools` over the parent MyApp surface. Toggle a tool off to add it to `disabled_tools`."
        ))

        return AgentDescriptor(
            id: subagentId(myAppId: myApp.id, slug: subagent.name),
            name: subagent.displayName ?? subagent.name,
            kind: .subagent,
            iconSystemName: "person.crop.circle",
            myAppId: myApp.id,
            subtitle: subagent.description.isEmpty ? nil : subagent.description,
            modelSummary: modelSummaryText(currentSelection: agentSelection, catalog: catalog),
            toolSummary: toolSummaryText(allowed: allowedTools.count, disabled: disabled.count),
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
            (label: "Skills", names: MyAppType.skillToolNames),
            (label: "Subagents", names: MyAppType.subagentToolNames),
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

    /// Build the extended-thinking picker row, or `nil` when the active harness
    /// advertises no thinking levels (`catalog.thinkingLevels` empty) — the row
    /// is hidden for harnesses without the capability (e.g. deepagents). An
    /// override not in the catalog falls back to the "Default" sentinel.
    @MainActor
    private static func thinkingProperty(
        currentLevel: String?,
        catalog: ModelCatalogStore
    ) -> AgentProperty? {
        guard !catalog.thinkingLevels.isEmpty else { return nil }
        let selected: String
        if let currentLevel, catalog.thinkingLevels.contains(where: { $0.level == currentLevel }) {
            selected = currentLevel
        } else {
            selected = KnownLLMModelCatalog.thinkingDefaultId
        }
        return AgentProperty(
            id: "thinking",
            label: "Thinking",
            value: .thinkingPicker(selectedLevel: selected, options: catalog.thinkingLevels),
            note: selected == KnownLLMModelCatalog.thinkingDefaultId
                ? "Inherits the backend's default extended-thinking setting."
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
            note: "Shell approval is resolved at the global scope. (Model and tool overrides are per-agent — see the rows above.)"
        )
    }

    /// Glanceable model label for the list row. Mirrors the picker's
    /// "Backend default" sentinel when no per-agent override resolves.
    @MainActor
    static func modelSummaryText(
        currentSelection: (provider: String, model: String)?,
        catalog: ModelCatalogStore
    ) -> String {
        if let (provider, model) = currentSelection,
           let known = catalog.model(provider: provider, modelId: model) {
            return known.label
        }
        return "Backend default"
    }

    /// Glanceable tool-count caption, e.g. "12 tools" or "12 tools · 2 off".
    static func toolSummaryText(allowed: Int, disabled: Int) -> String {
        let base = "\(allowed) tool\(allowed == 1 ? "" : "s")"
        return disabled > 0 ? "\(base) · \(disabled) off" : base
    }
}
