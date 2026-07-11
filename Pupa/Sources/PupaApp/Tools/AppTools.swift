import Foundation
import AGUIKit

/// Registers every frontend tool the agent can call.
///
/// **Tool-name ↔ MyAppType coupling.** Each `MyAppType` declares its agent
/// surface as `baseToolNames` (always-on for the type) plus
/// `toolNamesByKind[kind]` (advertised only when a component of `kind`
/// exists on the MyApp's canvas) — see `MyAppType.tracker`. Those strings
/// must match the `ToolDescriptor.name` values registered here. There is no
/// compile-time check — keep them in sync by convention. When you add a tool
/// for a tracker myApp, drop its name into the appropriate kind bucket on
/// `MyAppType.tracker.toolNamesByKind` (or `baseToolNames` if it should
/// always be available). When you add a new myApp type, add its tool
/// registration as a sibling and reference its names from the new
/// `MyAppType`.
public enum AppTools {
    /// Register every tool a myApp-bound session needs: the tracker tools
    /// (pinned to `myAppId` — no `activeMyAppId` reads) plus the
    /// myApp-agnostic memory tools. Called once per `ChatViewModel` at
    /// construction so concurrent streams in different myApps never race on
    /// the active selection.
    /// Context handed to `registerSlackTools` so the runtime
    /// gating + agent fan-out can wire into the live coordinator.
    /// Passing `nil` for the `slack` parameter on
    /// `registerMyAppTools` disables Slack-tool registration —
    /// used by call sites that don't host a Slack-capable session
    /// (e.g. CLI-style harnesses or future read-only previews).
    public struct SlackToolContext: Sendable {
        /// Agent id whose run owns this session, or `nil` for the
        /// main chat panel. Admin tools (`slackCreateAgent`,
        /// `slackCreateChannels`, `slackAddAgentsToChannel`)
        /// refuse when this is non-nil — sub-agents cannot spawn
        /// more agents / channels in v1. `slackPostMessage`
        /// requires it to be non-nil — only sub-agents post.
        public let currentAgentId: String?
        /// Invoke another Slack agent on a channel. Used by
        /// `slackPostMessage` to fan out the agents @-mentioned
        /// in the freshly-posted message. The closure routes
        /// through `ChatSessionCoordinator.invokeSlackAgent`, so
        /// the same `SlackInvoker` state (reentrancy stack +
        /// max-depth cap + tool-call tracking) drives both
        /// user-triggered and agent-triggered runs.
        public let invoke: @Sendable (String, String) async -> SlackInvoker.InvocationOutcome
        /// Lookup table from agent name → agent id, captured at
        /// registration time. Used by `slackPostMessage` to
        /// resolve `@mentions` parsed out of the agent's text
        /// before fan-out.
        public let resolveAgentId: @Sendable (String) async -> String?
        /// Notify the invoker that the running agent posted a
        /// message explicitly. Coordinator reads the resulting
        /// counter at run-end to skip auto-posting the agent's
        /// final assistantMessageEnd text (avoiding a duplicate
        /// reply when the agent already spoke via the tool).
        public let markMessagePosted: @Sendable (String) async -> Void

        public init(
            currentAgentId: String?,
            invoke: @escaping @Sendable (String, String) async -> SlackInvoker.InvocationOutcome,
            resolveAgentId: @escaping @Sendable (String) async -> String?,
            markMessagePosted: @escaping @Sendable (String) async -> Void
        ) {
            self.currentAgentId = currentAgentId
            self.invoke = invoke
            self.resolveAgentId = resolveAgentId
            self.markMessagePosted = markMessagePosted
        }
    }

    @MainActor
    public static func registerMyAppTools(
        on registry: ToolRegistry,
        store: MyAppStore,
        myAppId: UUID,
        memory: MemoryStore? = nil,
        slack: SlackToolContext? = nil
    ) {
        registerTrackerTools(on: registry, store: store, myAppId: myAppId)

        registry.register(ClientTool(
            descriptor: ToolDescriptor(
                name: "clearCanvas",
                description: "Reset the canvas to the empty state. Result echoes {kind:'empty'}.",
                parameters: ["type": "object", "properties": [:]]
            ),
            handler: { _ in
                return await MainActor.run {
                    store.reset(myAppId: myAppId)
                    return .object(["ok": .bool(true), "kind": .string("empty")])
                }
            }
        ))

        registry.register(ClientTool(
            descriptor: ToolDescriptor(
                name: "getCanvasState",
                description: """
                Full canvas dump — heavy ESCAPE HATCH. Shape: {components: \
                [{id, name, iconSystemName, body: {kind, data}}], activeComponentId}. \
                Prefer per-kind list/search/get tools for paginated reads. \
                Use this only when you need everything at once (post-mutation \
                audit, cross-component reasoning) or to refresh after mid-turn \
                mutations desync the canvas summary.
                """,
                parameters: ["type": "object", "properties": [:]]
            ),
            readOnly: true,
            handler: { _ in
                return await MainActor.run {
                    .object([
                        "ok": .bool(true),
                        "canvas": canvasAsAnyJSON(store, myAppId: myAppId),
                    ])
                }
            }
        ))

        registerTrackerDiscoveryTools(on: registry, store: store, myAppId: myAppId)
        registerComponentLifecycleTools(on: registry, store: store, myAppId: myAppId)
        registerCalendarTools(on: registry, store: store, myAppId: myAppId)
        registerChecklistTools(on: registry, store: store, myAppId: myAppId)
        registerCalculatorTools(on: registry, store: store, myAppId: myAppId)
        registerChartTools(on: registry, store: store, myAppId: myAppId)
        registerEmbedTools(on: registry, store: store, myAppId: myAppId)
        registerLinkTools(on: registry, store: store, myAppId: myAppId)
        registerHistoryTools(on: registry, store: store, myAppId: myAppId)
        if let slack {
            registerSlackTools(on: registry, store: store, myAppId: myAppId, memory: memory, context: slack)
        }

        registry.register(ClientTool(
            descriptor: ToolDescriptor(
                name: "setComponentLocked",
                description: """
                Lock or unlock a canvas component. A locked component refuses all \
                mutating tools until unlocked (reads still work). Use to honor a \
                user's request to protect a component, or to unlock one they ask you \
                to edit. Result: {ok, componentId, locked}.
                """,
                parameters: [
                    "type": "object",
                    "properties": [
                        "componentId": ["type": "string", "description": "Component to lock/unlock. Required — name the component explicitly (see the canvas summary); there is no active/view fallback."],
                        "locked": ["type": "boolean", "description": "true to lock, false to unlock."],
                    ],
                    "required": ["locked", "componentId"],
                ]
            ),
            handler: { args in
                await MainActor.run {
                    guard let locked = args["locked"]?.boolValue else {
                        return .object(["ok": .bool(false), "error": .string("missing 'locked' boolean")])
                    }
                    guard let cid = args["componentId"]?.stringValue, !cid.isEmpty else {
                        return .object(["ok": .bool(false), "error": .string("missing 'componentId' — name the component to lock/unlock")])
                    }
                    store.setComponentLocked(componentId: cid, locked: locked, myAppId: myAppId)
                    return .object([
                        "ok": .bool(true),
                        "componentId": .string(cid),
                        "locked": .bool(locked),
                    ])
                }
            }
        ))

        // Gate every mutating tool: refuse when its target canvas component is
        // locked, surfacing a clear "locked" result to the agent. Read-only
        // tools are exempt. Applied last so it wraps every tool above.
        registry.transformAll { tool in
            guard !tool.readOnly else { return tool }
            let inner = tool.handler
            return ClientTool(
                descriptor: tool.descriptor,
                parallelSafe: tool.parallelSafe,
                readOnly: false
            ) { args in
                await MainActor.run { store.resetLockFlag() }
                let result = try await inner(args)
                let blocked = await MainActor.run { store.lastWriteBlockedByLock }
                guard blocked else { return result }
                return .object([
                    "ok": .bool(false),
                    "locked": .bool(true),
                    "error": .string("That component is locked by the user. Ask them to unlock it before making changes."),
                ])
            }
        }
    }

    // MARK: - History tools

    @MainActor
    private static func registerHistoryTools(
        on registry: ToolRegistry,
        store: MyAppStore,
        myAppId: UUID
    ) {
        registry.register(ClientTool(
            descriptor: ToolDescriptor(
                name: "listChanges",
                description: """
                List recent item and component mutations for this MyApp, newest-first. \
                Each entry: id, kind (added/patched/removed/linked/unlinked/restored), \
                actor ({kind: user|agent, toolName?}), summary (human-readable one-liner), \
                timestamp (ISO-8601). Supports pagination via offset + limit (default 20, \
                max 100). This is a read-only change feed; to revert state the user restores \
                a snapshot from the History page.
                """,
                parameters: [
                    "type": "object",
                    "properties": [
                        "offset": ["type": "integer", "description": "Skip the first N events (default 0)."],
                        "limit": ["type": "integer", "description": "Max events to return (default 20, max 100)."]
                    ]
                ]
            ),
            readOnly: true,
            handler: { args in
                let offset = max(0, args["offset"]?.intValue ?? 0)
                let limit = min(100, max(1, args["limit"]?.intValue ?? 20))
                let result: AnyJSON = await MainActor.run {
                    let all = store.itemEventLog.events(forMyApp: myAppId)
                    let reversed = Array(all.reversed())
                    let total = reversed.count
                    let slice = Array(reversed.dropFirst(offset).prefix(limit))
                    let changes: [AnyJSON] = slice.map { event in
                        let actorObj: AnyJSON
                        switch event.actor {
                        case .user:
                            actorObj = .object(["kind": .string("user")])
                        case .agent(let toolName):
                            actorObj = .object(["kind": .string("agent"), "toolName": .string(toolName)])
                        }
                        return .object([
                            "id": .string(event.id.uuidString),
                            "kind": .string(event.kind.rawValue),
                            "actor": actorObj,
                            "summary": .string(store.changeSummary(for: event)),
                            "timestamp": .string(ISO8601DateFormatter().string(from: event.timestamp))
                        ])
                    }
                    return .object([
                        "ok": .bool(true),
                        "totalItems": .int(total),
                        "offset": .int(offset),
                        "limit": .int(limit),
                        "changes": .array(changes)
                    ])
                }
                return result
            }
        ))
    }

    // MARK: - Tracker discovery tools

    @MainActor
    static func registerTrackerDiscoveryTools(
        on registry: ToolRegistry,
        store: MyAppStore,
        myAppId: UUID
    ) {
        registry.register(ClientTool(
            descriptor: ToolDescriptor(
                name: "listTrackerItems",
                description: """
                Paginated read of a tracker's items, returning one-line \
                previews instead of the full row payload. Use this — not \
                `getCanvasState` — to drill into a tracker beyond the \
                2-item sticky preview shown in the stable canvas summary. \
                `offset` (default 0) and `limit` (default 20, max 100) \
                slice the items in insertion order. `componentId` optional \
                — omitted resolves to the active tracker (or first tracker \
                if active isn't one). `fields` optional — when set, \
                `preview` renders only those field values (in that order); \
                otherwise every visible field with a non-empty value is \
                shown. Long values are cut with ` [PREVIEW END]`. Result: \
                {ok, componentId, totalItems, offset, limit, items: \
                [{id, preview}]}.
                """,
                parameters: [
                    "type": "object",
                    "properties": [
                        "componentId": ["type": "string"],
                        "offset": ["type": "integer", "minimum": 0],
                        "limit": ["type": "integer", "minimum": 1, "maximum": 100],
                        "fields": ["type": "array", "items": ["type": "string"]],
                    ],
                ]
            ),
            readOnly: true,
            handler: { args in
                let componentId = args["componentId"]?.stringValue
                let offset = max(0, args["offset"]?.intValue ?? 0)
                let limit = min(100, max(1, args["limit"]?.intValue ?? 20))
                let fieldNames = args["fields"]?.arrayValue?.compactMap { $0.stringValue }
                return await MainActor.run {
                    guard let resolved = resolveTracker(store: store, myAppId: myAppId, componentId: componentId) else {
                        return .object([
                            "ok": .bool(false),
                            "error": "no tracker component matches that componentId (or this myApp has no tracker).",
                        ])
                    }
                    let (t, resolvedId) = resolved
                    let total = t.items.count
                    let slice = offset >= total ? [] : Array(t.items[offset..<min(offset + limit, total)])
                    let items: [AnyJSON] = slice.map { item in
                        .object([
                            "id": .string(item.id.uuidString),
                            "preview": .string(CanvasPreview.trackerItem(item, fields: t.fields, fieldNames: fieldNames)),
                        ])
                    }
                    return .object([
                        "ok": .bool(true),
                        "componentId": .string(resolvedId),
                        "totalItems": .int(total),
                        "offset": .int(offset),
                        "limit": .int(limit),
                        "items": .array(items),
                    ])
                }
            }
        ))

        registry.register(ClientTool(
            descriptor: ToolDescriptor(
                name: "searchTrackerItems",
                description: """
                Case-insensitive substring search across all field values \
                of a tracker. Returns one-line previews of matching rows \
                (same `preview` shape as `listTrackerItems`), plus the \
                first field whose value matched. `componentId` optional \
                — resolves to the active / first tracker if omitted. \
                `limit` (default 20, max 100) caps results; `totalMatches` \
                always reflects the full match count. Pivot to \
                `getTrackerItem(componentId, itemId)` for the full row. \
                Result: {ok, componentId, totalMatches, items: \
                [{id, preview, matchedField}]}.
                """,
                parameters: [
                    "type": "object",
                    "properties": [
                        "componentId": ["type": "string"],
                        "query": ["type": "string"],
                        "limit": ["type": "integer", "minimum": 1, "maximum": 100],
                    ],
                    "required": ["query"],
                ]
            ),
            readOnly: true,
            handler: { args in
                let componentId = args["componentId"]?.stringValue
                guard let query = args["query"]?.stringValue, !query.isEmpty else {
                    return .object([
                        "ok": .bool(false),
                        "error": "missing required `query`.",
                    ])
                }
                let limit = min(100, max(1, args["limit"]?.intValue ?? 20))
                let needle = query.lowercased()
                return await MainActor.run {
                    guard let resolved = resolveTracker(store: store, myAppId: myAppId, componentId: componentId) else {
                        return .object([
                            "ok": .bool(false),
                            "error": "no tracker component matches that componentId (or this myApp has no tracker).",
                        ])
                    }
                    let (t, resolvedId) = resolved
                    var matched: [(TrackerItem, String)] = []
                    for item in t.items {
                        for field in t.fields {
                            guard let raw = item.values[field.name], !raw.isEmpty else { continue }
                            if raw.lowercased().contains(needle) {
                                matched.append((item, field.name))
                                break
                            }
                        }
                    }
                    let slice = Array(matched.prefix(limit))
                    let items: [AnyJSON] = slice.map { (item, matchedField) in
                        .object([
                            "id": .string(item.id.uuidString),
                            "preview": .string(CanvasPreview.trackerItem(item, fields: t.fields)),
                            "matchedField": .string(matchedField),
                        ])
                    }
                    return .object([
                        "ok": .bool(true),
                        "componentId": .string(resolvedId),
                        "totalMatches": .int(matched.count),
                        "items": .array(items),
                    ])
                }
            }
        ))

        registry.register(ClientTool(
            descriptor: ToolDescriptor(
                name: "getTrackerItem",
                description: """
                Full read of one tracker row — every field value plus \
                `linkedItems`. No truncation. `componentId` optional — \
                resolves to the active / first tracker if omitted. \
                `itemId` is the stable UUID returned by addTrackerItems / \
                listTrackerItems / searchTrackerItems. Use this after \
                `listTrackerItems` / `searchTrackerItems` narrows down a \
                row — much cheaper than `getCanvasState`. Result: {ok, \
                componentId, id, values: {fieldName: value}, linkedItems: \
                [{componentId, itemId}]}.
                """,
                parameters: [
                    "type": "object",
                    "properties": [
                        "componentId": ["type": "string"],
                        "itemId": ["type": "string"],
                    ],
                    "required": ["itemId"],
                ]
            ),
            readOnly: true,
            handler: { args in
                let componentId = args["componentId"]?.stringValue
                guard let itemIdString = args["itemId"]?.stringValue,
                      let itemId = UUID(uuidString: itemIdString) else {
                    return .object([
                        "ok": .bool(false),
                        "error": "missing or malformed `itemId` (expected UUID).",
                    ])
                }
                return await MainActor.run {
                    guard let resolved = resolveTracker(store: store, myAppId: myAppId, componentId: componentId) else {
                        return .object([
                            "ok": .bool(false),
                            "error": "no tracker component matches that componentId (or this myApp has no tracker).",
                        ])
                    }
                    let (t, resolvedId) = resolved
                    guard let item = t.items.first(where: { $0.id == itemId }) else {
                        return .object([
                            "ok": .bool(false),
                            "error": .string("no item with id '\(itemIdString)' in tracker '\(resolvedId)'."),
                        ])
                    }
                    let links: [AnyJSON] = item.linkedItems.map { ref in
                        .object([
                            "componentId": .string(ref.componentId),
                            "itemId": .string(ref.itemId.uuidString),
                        ])
                    }
                    return .object([
                        "ok": .bool(true),
                        "componentId": .string(resolvedId),
                        "id": .string(item.id.uuidString),
                        "values": valuesAsAnyJSON(item.values),
                        "linkedItems": .array(links),
                    ])
                }
            }
        ))
    }

    // The read resolvers below resolve their target the same way writes do
    // (`MyAppStore.resolveWriteTarget`): an explicit id is honoured or
    // rejected; an omitted id resolves only when exactly one component of
    // that kind exists. The active/view component is never consulted — the
    // agent doesn't reliably know it (it's no longer in the prompt), so a
    // read must not silently depend on it. Ambiguity returns nil, which the
    // calling tool surfaces as an error.

    @MainActor
    private static func resolveTracker(
        store: MyAppStore,
        myAppId: UUID,
        componentId: String?
    ) -> (TrackerData, String)? {
        guard case .resolved(let id) = store.resolveWriteTarget(kind: "tracker", componentId: componentId, myAppId: myAppId),
              let myApp = store.myApps.first(where: { $0.id == myAppId }),
              let comp = myApp.components.first(where: { $0.id == id }),
              case .tracker(let t) = comp.body else { return nil }
        return (t, id)
    }

    @MainActor
    static func resolveCalendar(
        store: MyAppStore,
        myAppId: UUID,
        componentId: String?
    ) -> (CalendarData, String)? {
        guard case .resolved(let id) = store.resolveWriteTarget(kind: "calendar", componentId: componentId, myAppId: myAppId),
              let myApp = store.myApps.first(where: { $0.id == myAppId }),
              let comp = myApp.components.first(where: { $0.id == id }),
              case .calendar(let c) = comp.body else { return nil }
        return (c, id)
    }

    @MainActor
    static func resolveChecklist(
        store: MyAppStore,
        myAppId: UUID,
        componentId: String?
    ) -> (ChecklistData, String)? {
        guard case .resolved(let id) = store.resolveWriteTarget(kind: "checklist", componentId: componentId, myAppId: myAppId),
              let myApp = store.myApps.first(where: { $0.id == myAppId }),
              let comp = myApp.components.first(where: { $0.id == id }),
              case .checklist(let cl) = comp.body else { return nil }
        return (cl, id)
    }

    // MARK: - Component lifecycle tools

    @MainActor
    private static func registerComponentLifecycleTools(
        on registry: ToolRegistry,
        store: MyAppStore,
        myAppId: UUID
    ) {
        // Resolve the MyApp's actual supported kinds at registration time
        // so the schema enum + description never drift from
        // `MyAppType.supportedComponentKinds`. Stable alphabetical order
        // for a deterministic agent-facing surface.
        let supportedKinds: [String] = {
            guard let myApp = store.myApps.first(where: { $0.id == myAppId }),
                  let type = MyAppTypeRegistry.shared.resolve(id: myApp.typeId)
            else { return [] }
            return type.supportedComponentKinds.sorted()
        }()
        let kindsListing = supportedKinds.map { "\"\($0)\"" }.joined(separator: ", ")
        registry.register(ClientTool(
            descriptor: ToolDescriptor(
                name: "addComponent",
                description: """
                Append a new component to this MyApp. `kind` must be one of \
                the MyApp's supported kinds: \(kindsListing). `name` is the \
                sidebar label (e.g. "Books", "Appointments", "Packing list", \
                "Team chat"). Optional `iconSystemName` is an SF Symbol; \
                defaults to a kind-appropriate icon. The component starts \
                empty — for trackers / calendars / checklists, call the \
                kind's render tool next to populate it; for slack, call \
                `slackCreateAgent` and `slackCreateChannels` to set up the \
                room. The new component becomes the active one. Result \
                echoes {componentId, kind, name, totalComponents}.
                """,
                parameters: [
                    "type": "object",
                    "properties": [
                        "kind": ["type": "string", "enum": .array(supportedKinds.map { .string($0) })],
                        "name": ["type": "string"],
                        "iconSystemName": ["type": "string"],
                    ],
                    "required": ["kind", "name"],
                ]
            ),
            handler: { args in
                let kind = args["kind"]?.stringValue ?? ""
                let name = args["name"]?.stringValue ?? ""
                let explicitIcon = args["iconSystemName"]?.stringValue
                return await MainActor.run {
                    guard let myApp = store.myApps.first(where: { $0.id == myAppId }) else {
                        return .object(["ok": .bool(false), "error": "no myApp"])
                    }
                    let type = MyAppTypeRegistry.shared.resolve(id: myApp.typeId)
                    guard type?.supportedComponentKinds.contains(kind) ?? false else {
                        return .object([
                            "ok": .bool(false),
                            "error": .string("kind '\(kind)' not supported by this MyApp"),
                        ])
                    }
                    // Registered kinds seed their icon from the module (issue
                    // #162); unmigrated kinds fall back to the legacy switch.
                    let icon = explicitIcon
                        ?? ComponentRegistry.shared.module(forKind: kind)?.defaultIcon
                        ?? defaultIcon(forKind: kind)
                    guard let id = store.addComponent(
                        kind: kind, name: name, iconSystemName: icon, myAppId: myAppId
                    ) else {
                        return .object(["ok": .bool(false), "error": "could not add component"])
                    }
                    let total = store.myApps.first(where: { $0.id == myAppId })?.components.count ?? 0
                    return .object([
                        "ok": .bool(true),
                        "componentId": .string(id),
                        "kind": .string(kind),
                        "name": .string(name),
                        "totalComponents": .int(total),
                    ])
                }
            }
        ))

        registry.register(ClientTool(
            descriptor: ToolDescriptor(
                name: "removeComponent",
                description: """
                Remove a component from this MyApp. Refuses if it would leave \
                the MyApp with zero components — every MyApp must keep at \
                least one. Result echoes {componentId, totalComponents}.
                """,
                parameters: [
                    "type": "object",
                    "properties": ["componentId": ["type": "string"]],
                    "required": ["componentId"],
                ]
            ),
            handler: { args in
                let id = args["componentId"]?.stringValue ?? ""
                return await MainActor.run {
                    let ok = store.removeComponent(componentId: id, myAppId: myAppId)
                    let total = store.myApps.first(where: { $0.id == myAppId })?.components.count ?? 0
                    return .object([
                        "ok": .bool(ok),
                        "componentId": .string(id),
                        "totalComponents": .int(total),
                    ])
                }
            }
        ))

        registry.register(ClientTool(
            descriptor: ToolDescriptor(
                name: "setActiveComponent",
                description: """
                Focus a component — drives ONLY the canvas view (which \
                component is on screen for the user). It does NOT change where \
                tools write: tools target a component by explicit `componentId`, \
                never the active one. Use when the user asks to "open" / "show" \
                / "switch to" a component, or to reveal one you just created. \
                Result echoes {componentId, activeComponentId}.
                """,
                parameters: [
                    "type": "object",
                    "properties": ["componentId": ["type": "string"]],
                    "required": ["componentId"],
                ]
            ),
            handler: { args in
                let id = args["componentId"]?.stringValue ?? ""
                return await MainActor.run {
                    let ok = store.setActiveComponent(componentId: id, myAppId: myAppId)
                    let active = store.myApps.first(where: { $0.id == myAppId })?.activeComponentId
                    return .object([
                        "ok": .bool(ok),
                        "componentId": .string(id),
                        "activeComponentId": active.map { .string($0) } ?? .null,
                    ])
                }
            }
        ))

        registry.register(ClientTool(
            descriptor: ToolDescriptor(
                name: "getActiveComponent",
                description: """
                Read which component the user is currently viewing (the \
                "active" component). This is a pure VIEW pointer — it is \
                deliberately NOT in the per-turn canvas summary, so fetch it \
                here when the user says "this" / "the one I'm looking at" and \
                you need to resolve it to a concrete `componentId` to pass to \
                another tool. Result: {ok, activeComponentId, name, kind} \
                (fields null when nothing is focused).
                """,
                parameters: ["type": "object", "properties": [:]]
            ),
            readOnly: true,
            handler: { _ in
                await MainActor.run {
                    guard let myApp = store.myApps.first(where: { $0.id == myAppId }),
                          let id = myApp.activeComponentId,
                          let comp = myApp.components.first(where: { $0.id == id }) else {
                        return .object([
                            "ok": .bool(true),
                            "activeComponentId": .null,
                            "name": .null,
                            "kind": .null,
                        ])
                    }
                    return .object([
                        "ok": .bool(true),
                        "activeComponentId": .string(id),
                        "name": .string(comp.name),
                        "kind": .string(comp.kindString),
                    ])
                }
            }
        ))

        registry.register(ClientTool(
            descriptor: ToolDescriptor(
                name: "setComponentMeta",
                description: """
                Edit a component's metadata IN PLACE — its `name` (sidebar / \
                dock label), `iconSystemName` (SF Symbol), and/or `summary` \
                (your short "what this is for" description, surfaced in the \
                canvas-state context every turn). The component's `id` and its \
                data are untouched. Pass only the fields you want to change; \
                an empty `summary` clears it. Result echoes {componentId, changed}.
                """,
                parameters: [
                    "type": "object",
                    "properties": [
                        "componentId": ["type": "string"],
                        "name": ["type": "string"],
                        "iconSystemName": ["type": "string"],
                        "summary": ["type": "string"],
                    ],
                    "required": ["componentId"],
                ]
            ),
            handler: { args in
                let id = args["componentId"]?.stringValue ?? ""
                let name = args["name"]?.stringValue
                let icon = args["iconSystemName"]?.stringValue
                let summary = args["summary"]?.stringValue
                return await MainActor.run {
                    let changed = store.updateComponentMeta(
                        componentId: id,
                        name: name,
                        iconSystemName: icon,
                        summary: summary,
                        myAppId: myAppId
                    )
                    return .object([
                        "ok": .bool(true),
                        "componentId": .string(id),
                        "changed": .bool(changed),
                    ])
                }
            }
        ))
    }

    // MARK: - Embed tools

    /// Register `embedComponent` / `clearEmbeddedComponent`. Gated by the
    /// host component kind (calculator for now); future hosts add their own
    /// kind entry in `MyAppType.toolNamesByKind` and handle their guest in
    /// the switch below.
    @MainActor
    private static func registerEmbedTools(
        on registry: ToolRegistry,
        store: MyAppStore,
        myAppId: UUID
    ) {
        registry.register(ClientTool(
            descriptor: ToolDescriptor(
                name: "embedComponent",
                description: """
                Embed a guest component inside a host. Supported: \
                hostKind "calculator" + guestKind "chart" — pins a live chart \
                below the calculator rows (resolves against the sibling pool; \
                pass `chart`={title,kind,series} to set/replace, omit/null to \
                clear). hostKind "chat" + guestKind "chart" — resolves `chart` \
                NOW and drops a frozen snapshot into the conversation as its \
                own assistant message (reproducible; never re-resolves). Use \
                "chat" to show the user a chart inline without a canvas \
                component. `chart` shape matches renderChart (title, kind, \
                series). Result echoes {ok, guestKind, embedded, pointCount?}.
                """,
                parameters: [
                    "type": "object",
                    "properties": [
                        "hostKind": ["type": "string", "enum": ["calculator", "chat"], "description": "Kind of the host: \"calculator\" pins a live embed; \"chat\" posts a frozen snapshot into the conversation."],
                        "guestKind": ["type": "string", "enum": ["chart"], "description": "Kind of the component to embed."],
                        "chart": [
                            "type": "object",
                            "description": "ChartData when guestKind is \"chart\". Omit or null to clear.",
                            "properties": [
                                "title": ["type": "string"],
                                "kind": ["type": "string", "enum": ["pie", "bar", "line"]],
                                "series": ["type": "array", "items": chartSeriesSchema()],
                            ],
                            "required": ["title", "kind", "series"],
                        ],
                    ],
                    "required": ["hostKind", "guestKind"],
                ]
            ),
            handler: { args in
                guard let hostKind = args["hostKind"]?.stringValue,
                      let guestKind = args["guestKind"]?.stringValue else {
                    return .object(["ok": .bool(false), "error": "embedComponent needs hostKind and guestKind."])
                }
                return await MainActor.run {
                    switch (hostKind, guestKind) {
                    case ("chat", "chart"):
                        guard let chart = parseChartData(from: args["chart"]) else {
                            return .object(["ok": .bool(false), "error": "embedComponent hostKind \"chat\" needs a `chart` ({title, kind, series})."])
                        }
                        let series = ChartResolver.resolve(chart, components: siblingComponents(store: store, myAppId: myAppId))
                        guard !series.isEmpty else {
                            return .object(["ok": .bool(false), "error": "chart resolved to no points — check the series sources before embedding in chat."])
                        }
                        let snapshot = ChatChartSnapshot(title: chart.title, kind: chart.kind, series: series)
                        return .object([
                            "ok": .bool(true),
                            "guestKind": .string("chart"),
                            "embedded": .bool(true),
                            "pointCount": .int(series.reduce(0) { $0 + $1.points.count }),
                            "chartSnapshot": encodableAsAnyJSON(snapshot),
                        ])
                    case ("calculator", "chart"):
                        let chart = parseChartData(from: args["chart"])
                        guard let id = store.calculatorComponentId(myAppId: myAppId) else {
                            return .object([
                                "ok": .bool(false),
                                "error": "no calculator component — call addComponent(kind:\"calculator\", …) or renderCalculator first",
                            ])
                        }
                        store.setCalculatorInlineChart(chart, myAppId: myAppId)
                        return .object([
                            "ok": .bool(true),
                            "hostComponentId": .string(id),
                            "guestKind": .string("chart"),
                            "embedded": .bool(chart != nil),
                        ])
                    default:
                        return .object([
                            "ok": .bool(false),
                            "error": .string("unsupported embed: hostKind \"\(hostKind)\" + guestKind \"\(guestKind)\""),
                        ])
                    }
                }
            }
        ))
    }

    // MARK: - Universal linking tools

    /// Register the generic `linkItem` / `unlinkItem` tool pair. Always
    /// advertised on a myApp scope (added to `MyAppType.baseToolNames`)
    /// since any two items in the MyApp may want to reference each
    /// other regardless of which kinds happen to be present. Source and
    /// target can be any link-bearing kind (tracker row, calendar event,
    /// checklist row), in any direction, including the same component
    /// (e.g. checklist row → another row in the same checklist for
    /// parent / subtask relationships). Only the literal self-ref
    /// where `source == target` is rejected; the store mutator returns
    /// a `LinkMutationError` the handler maps to a structured echo so
    /// the agent can correct its call.
    @MainActor
    public static func registerLinkTools(
        on registry: ToolRegistry,
        store: MyAppStore,
        myAppId: UUID
    ) {
        registry.register(ClientTool(
            descriptor: ToolDescriptor(
                name: "linkItem",
                description: """
                Attach an inline ref from one item to another. Any kind ↔ any \
                kind, any direction, same-component allowed (parent/subtask); \
                only literal self-ref (source==target) rejected. Renders as a \
                live chain-link pill on the source. Idempotent. \
                Identify via componentId (e.g. "tracker-1") + itemId (UUID). \
                Result: {sourceComponentId, sourceItemId, targetComponentId, \
                targetItemId, linkCount} or {ok:false, error}.
                """,
                parameters: [
                    "type": "object",
                    "properties": [
                        "sourceComponentId": ["type": "string"],
                        "sourceItemId": ["type": "string"],
                        "targetComponentId": ["type": "string"],
                        "targetItemId": ["type": "string"],
                    ],
                    "required": ["sourceComponentId", "sourceItemId", "targetComponentId", "targetItemId"],
                ]
            ),
            handler: { args in
                let sourceCompId = args["sourceComponentId"]?.stringValue ?? ""
                let targetCompId = args["targetComponentId"]?.stringValue ?? ""
                let sourceItemStr = args["sourceItemId"]?.stringValue ?? ""
                let targetItemStr = args["targetItemId"]?.stringValue ?? ""
                guard let sourceUUID = UUID(uuidString: sourceItemStr),
                      let targetUUID = UUID(uuidString: targetItemStr) else {
                    return .object([
                        "ok": .bool(false),
                        "error": .string("invalid sourceItemId or targetItemId (expected UUIDs)"),
                    ])
                }
                return await MainActor.run {
                    let outcome = store.linkItems(
                        sourceComponentId: sourceCompId,
                        sourceItemId: sourceUUID,
                        targetComponentId: targetCompId,
                        targetItemId: targetUUID,
                        myAppId: myAppId
                    )
                    switch outcome {
                    case .success(let count):
                        return .object([
                            "ok": .bool(true),
                            "sourceComponentId": .string(sourceCompId),
                            "sourceItemId": .string(sourceItemStr),
                            "targetComponentId": .string(targetCompId),
                            "targetItemId": .string(targetItemStr),
                            "linkCount": .int(count),
                        ])
                    case .failure(let err):
                        return .object([
                            "ok": .bool(false),
                            "error": .string(err.rawValue),
                            "sourceComponentId": .string(sourceCompId),
                            "sourceItemId": .string(sourceItemStr),
                            "targetComponentId": .string(targetCompId),
                            "targetItemId": .string(targetItemStr),
                        ])
                    }
                }
            }
        ))

        registry.register(ClientTool(
            descriptor: ToolDescriptor(
                name: "unlinkItem",
                description: """
                Remove a previously-attached reference from one item to \
                another (the inline pill disappears; both items' own \
                fields are unaffected). Mirror of `linkItem`. Idempotent \
                — removing a ref that wasn't present succeeds with the \
                unchanged count. Result echoes \
                {sourceComponentId, sourceItemId, targetComponentId, \
                targetItemId, linkCount}.
                """,
                parameters: [
                    "type": "object",
                    "properties": [
                        "sourceComponentId": ["type": "string"],
                        "sourceItemId": ["type": "string"],
                        "targetComponentId": ["type": "string"],
                        "targetItemId": ["type": "string"],
                    ],
                    "required": ["sourceComponentId", "sourceItemId", "targetComponentId", "targetItemId"],
                ]
            ),
            handler: { args in
                let sourceCompId = args["sourceComponentId"]?.stringValue ?? ""
                let targetCompId = args["targetComponentId"]?.stringValue ?? ""
                let sourceItemStr = args["sourceItemId"]?.stringValue ?? ""
                let targetItemStr = args["targetItemId"]?.stringValue ?? ""
                guard let sourceUUID = UUID(uuidString: sourceItemStr),
                      let targetUUID = UUID(uuidString: targetItemStr) else {
                    return .object([
                        "ok": .bool(false),
                        "error": .string("invalid sourceItemId or targetItemId (expected UUIDs)"),
                    ])
                }
                return await MainActor.run {
                    let outcome = store.unlinkItems(
                        sourceComponentId: sourceCompId,
                        sourceItemId: sourceUUID,
                        targetComponentId: targetCompId,
                        targetItemId: targetUUID,
                        myAppId: myAppId
                    )
                    switch outcome {
                    case .success(let count):
                        return .object([
                            "ok": .bool(true),
                            "sourceComponentId": .string(sourceCompId),
                            "sourceItemId": .string(sourceItemStr),
                            "targetComponentId": .string(targetCompId),
                            "targetItemId": .string(targetItemStr),
                            "linkCount": .int(count),
                        ])
                    case .failure(let err):
                        return .object([
                            "ok": .bool(false),
                            "error": .string(err.rawValue),
                            "sourceComponentId": .string(sourceCompId),
                            "sourceItemId": .string(sourceItemStr),
                            "targetComponentId": .string(targetCompId),
                            "targetItemId": .string(targetItemStr),
                        ])
                    }
                }
            }
        ))
    }

    /// Register the orchestrator tool surface — only installed on the
    /// memory-mode session (`ChatScope.memory`). Lets the memory-mode agent
    /// list and create myApps and delegate a one-shot prompt to any existing
    /// myApp's agent.
    ///
    /// `invokeMyAppAgent` is the heavy one. The handler asks the caller-
    /// supplied `runOneShot` closure to spin up a transient sub-session
    /// against the target `myAppId` with a fresh `threadId` and the target
    /// myApp's normal tool surface (canvas mutators + memories). The
    /// sub-session runs to completion (its own multi-round loop, including
    /// any frontend-tool dispatch it needs to mutate the canvas) and the
    /// final assistant text is returned to the orchestrator as the tool
    /// result. Sub-runs do *not* land on the target myApp's persistent
    /// thread — they're ephemeral so the user opening that myApp afterwards
    /// still sees their own conversation history.
    ///
    /// The descriptor is marked `parallelSafe: true` so the orchestrator can
    /// fan out to multiple myApps in one assistant turn and AGUIKit
    /// dispatches the handlers concurrently. Each sub-session has its own
    /// `AgentSession` and `threadId`; concurrent mutations against
    /// `MyAppStore` serialise on its `@MainActor` isolation.
    @MainActor
    public static func registerOrchestratorTools(
        on registry: ToolRegistry,
        store: MyAppStore,
        runOneShot: @escaping @Sendable (UUID, String) async throws -> String,
        onMyAppCreated: (@Sendable (MyApp) -> Void)? = nil
    ) {
        registry.register(ClientTool(
            descriptor: ToolDescriptor(
                name: "listMyApps",
                description: """
                List every myApp in the sidebar. Returns \
                {myApps: [{id, typeId, name, iconSystemName}]}. Use this to \
                resolve a user-mentioned name (e.g. "Garden") to a `myAppId` \
                before calling invokeMyAppAgent.
                """,
                parameters: ["type": "object", "properties": [:]]
            ),
            readOnly: true,
            handler: { _ in
                return await MainActor.run {
                    // Archived apps are agent-off — excluded from the list the
                    // orchestrator resolves names against.
                    let entries: [AnyJSON] = store.visibleMyApps.map { myApp in
                        .object([
                            "id": .string(myApp.id.uuidString),
                            "typeId": .string(myApp.typeId),
                            "name": .string(myApp.name),
                            "iconSystemName": .string(myApp.iconSystemName),
                        ])
                    }
                    return .object([
                        "ok": .bool(true),
                        "myApps": .array(entries),
                    ])
                }
            }
        ))

        registry.register(ClientTool(
            descriptor: ToolDescriptor(
                name: "createMyApp",
                description: """
                Create a new myApp in the sidebar and return its id. \
                `typeId` selects the kind of canvas (today only "tracker"). \
                `iconSystemName` is an SF Symbol name (e.g. \
                "list.bullet.rectangle", "leaf", "book"). Result echoes \
                {id, typeId, name, iconSystemName}.
                """,
                parameters: [
                    "type": "object",
                    "properties": [
                        "typeId": ["type": "string"],
                        "name": ["type": "string"],
                        "iconSystemName": ["type": "string"],
                    ],
                    "required": ["typeId", "name"],
                ]
            ),
            handler: { args in
                let typeId = args["typeId"]?.stringValue ?? ""
                let name = args["name"]?.stringValue ?? ""
                let explicitIcon = args["iconSystemName"]?.stringValue
                return await MainActor.run {
                    guard let type = MyAppTypeRegistry.shared.resolve(id: typeId) else {
                        return .object([
                            "ok": .bool(false),
                            "error": .string("unknown typeId '\(typeId)'"),
                        ])
                    }
                    let icon = explicitIcon ?? type.iconSystemName
                    let id = store.addMyApp(typeId: typeId, name: name, iconSystemName: icon)
                    if let created = store.myApps.first(where: { $0.id == id }) {
                        onMyAppCreated?(created)
                    }
                    return .object([
                        "ok": .bool(true),
                        "id": .string(id.uuidString),
                        "typeId": .string(typeId),
                        "name": .string(name),
                        "iconSystemName": .string(icon),
                    ])
                }
            }
        ))

        registry.register(ClientTool(
            descriptor: ToolDescriptor(
                name: "renameMyApp",
                description: """
                Rename an existing myApp in the sidebar. Resolve `myAppId` via \
                listMyApps first. `name` is trimmed and must be non-empty. \
                Updates the same name shown to the user in the sidebar (the \
                user-facing Rename sheet calls the same mutator). Returns \
                {ok, id, name, previousName} on success, or \
                {ok:false, error} if `myAppId` is malformed/unknown, the \
                trimmed name is empty, or the new name equals the current one.
                """,
                parameters: [
                    "type": "object",
                    "properties": [
                        "myAppId": ["type": "string"],
                        "name": ["type": "string"],
                    ],
                    "required": ["myAppId", "name"],
                ]
            ),
            handler: { args in
                let myAppIdString = args["myAppId"]?.stringValue ?? ""
                let rawName = args["name"]?.stringValue ?? ""
                guard let myAppId = UUID(uuidString: myAppIdString) else {
                    return .object([
                        "ok": .bool(false),
                        "error": .string("invalid myAppId '\(myAppIdString)' (expected a UUID)"),
                    ])
                }
                let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else {
                    return .object([
                        "ok": .bool(false),
                        "error": .string("name must be non-empty after trimming whitespace"),
                    ])
                }
                return await MainActor.run {
                    guard let oldName = store.myApps.first(where: { $0.id == myAppId })?.name else {
                        return .object([
                            "ok": .bool(false),
                            "error": .string("no myApp with id \(myAppIdString)"),
                        ])
                    }
                    guard oldName != trimmed else {
                        return .object([
                            "ok": .bool(false),
                            "error": .string("name unchanged ('\(trimmed)')"),
                        ])
                    }
                    store.renameMyApp(myAppId, to: trimmed)
                    return .object([
                        "ok": .bool(true),
                        "id": .string(myAppIdString),
                        "name": .string(trimmed),
                        "previousName": .string(oldName),
                    ])
                }
            }
        ))

        registry.register(ClientTool(
            descriptor: ToolDescriptor(
                name: "invokeMyAppAgent",
                description: """
                Delegate a single-round prompt to an existing myApp's agent. \
                The sub-run runs on a fresh thread (NOT the target myApp's \
                persistent thread) with that myApp's normal tool surface — \
                canvas mutators + memories — so it CAN mutate the target \
                canvas the same way the user's own chat would. Returns \
                {ok, myAppId, text} where `text` is the sub-agent's final \
                assistant message. Resolve `myAppId` via listMyApps first. \
                Emit multiple `invokeMyAppAgent` tool_calls in one turn to \
                fan out to several myApps in parallel.
                """,
                parameters: [
                    "type": "object",
                    "properties": [
                        "myAppId": ["type": "string"],
                        "prompt": ["type": "string"],
                    ],
                    "required": ["myAppId", "prompt"],
                ]
            ),
            parallelSafe: true,
            handler: { args in
                let myAppIdString = args["myAppId"]?.stringValue ?? ""
                let prompt = args["prompt"]?.stringValue ?? ""
                guard let myAppId = UUID(uuidString: myAppIdString) else {
                    return .object([
                        "ok": .bool(false),
                        "error": .string("invalid myAppId '\(myAppIdString)' (expected a UUID)"),
                    ])
                }
                let exists = await MainActor.run {
                    store.myApps.contains(where: { $0.id == myAppId })
                }
                guard exists else {
                    return .object([
                        "ok": .bool(false),
                        "error": .string("no myApp with id \(myAppIdString)"),
                    ])
                }
                do {
                    let text = try await runOneShot(myAppId, prompt)
                    return .object([
                        "ok": .bool(true),
                        "myAppId": .string(myAppIdString),
                        "text": .string(text),
                    ])
                } catch let rejection as AgentInvocationRejection {
                    var payload: [String: AnyJSON] = [
                        "reason": .string(rejection.reason.rawValue),
                        "target": .string(rejection.target.wireValue),
                        "callPath": .array(rejection.callPath.map { .string($0.wireValue) }),
                    ]
                    if let depth = rejection.depth {
                        payload["depth"] = .int(depth)
                    }
                    if let rootKey = rejection.treeRootKey {
                        payload["treeRootedAt"] = .string(rootKey.wireValue)
                    }
                    if let n = rejection.exhaustedAfter {
                        payload["exhaustedAfter"] = .int(n)
                    }
                    return .object([
                        "ok": .bool(false),
                        "myAppId": .string(myAppIdString),
                        "agent_unavailable": .object(payload),
                    ])
                } catch {
                    return .object([
                        "ok": .bool(false),
                        "myAppId": .string(myAppIdString),
                        "error": .string(String(describing: error)),
                    ])
                }
            }
        ))
    }

    // MARK: - Subagent tools

    /// Generic subagent invocation. `invoke_agent(name, prompt)` spins a
    /// transient sub-session against a `pupa/agents/<slug>/AGENTS.md` subagent
    /// scoped to the current MyApp and returns its final assistant text.
    /// Advertised to the main agent AND to subagents (A2A); the invocation
    /// gate bounds chain depth and rejects reentrancy with a structured
    /// `agent_unavailable` echo (same shape as `invokeMyAppAgent`).
    @MainActor
    public static func registerSubagentTools(
        on registry: ToolRegistry,
        run: @escaping @Sendable (_ agentName: String, _ prompt: String) async throws -> String
    ) {
        registry.register(ClientTool(
            descriptor: ToolDescriptor(
                name: "invoke_agent",
                description: """
                Delegate a task to a subagent defined at \
                `pupa/agents/<name>/AGENTS.md`. Runs it in a transient \
                sub-session scoped to this myApp (its own canvas + memory \
                surface, narrowed to the subagent's frontmatter `tools`) and \
                returns {ok, name, text} with the subagent's final reply. \
                `name` is the subagent's folder slug — see the `agents` list in \
                context. Emit multiple `invoke_agent` calls in one turn to fan \
                out in parallel.
                """,
                parameters: [
                    "type": "object",
                    "properties": [
                        "name": ["type": "string"],
                        "prompt": ["type": "string"],
                    ],
                    "required": ["name", "prompt"],
                ]
            ),
            parallelSafe: true,
            handler: { args in
                let name = args["name"]?.stringValue ?? ""
                let prompt = args["prompt"]?.stringValue ?? ""
                guard !name.isEmpty else {
                    return .object(["ok": .bool(false), "error": .string("name is required")])
                }
                do {
                    let text = try await run(name, prompt)
                    return .object([
                        "ok": .bool(true),
                        "name": .string(name),
                        "text": .string(text),
                    ])
                } catch let rejection as AgentInvocationRejection {
                    var payload: [String: AnyJSON] = [
                        "reason": .string(rejection.reason.rawValue),
                        "target": .string(rejection.target.wireValue),
                        "callPath": .array(rejection.callPath.map { .string($0.wireValue) }),
                    ]
                    if let depth = rejection.depth { payload["depth"] = .int(depth) }
                    if let rootKey = rejection.treeRootKey { payload["treeRootedAt"] = .string(rootKey.wireValue) }
                    if let n = rejection.exhaustedAfter { payload["exhaustedAfter"] = .int(n) }
                    return .object([
                        "ok": .bool(false),
                        "name": .string(name),
                        "agent_unavailable": .object(payload),
                    ])
                } catch {
                    return .object([
                        "ok": .bool(false),
                        "name": .string(name),
                        "error": .string(String(describing: error)),
                    ])
                }
            }
        ))
    }

    @MainActor
    /// Register the frontend skills tool. `app_skill_view` loads a skill's
    /// full instructions by name (its `pupa/skills/<name>/SKILL.md` body) so the
    /// model can follow them on demand — the skills list it sees in context
    /// carries only name + when_to_use (progressive disclosure).
    public static func registerSkillTools(on registry: ToolRegistry, memory: MemoryStore) {
        registry.register(ClientTool(
            descriptor: ToolDescriptor(
                name: "app_skill_view",
                description: """
                Load a skill's full instructions by name and follow them. `name` \
                is the skill's directory name (the same token as its /command). \
                Use when a listed skill matches the task. Result echoes \
                {ok, name, body} or {ok:false, error}.
                """,
                parameters: [
                    "type": "object",
                    "properties": [
                        "name": ["type": "string"],
                    ],
                    "required": ["name"],
                ]
            ),
            handler: { args in
                let name = args["name"]?.stringValue ?? ""
                return await MainActor.run {
                    let skills = SkillStore(memory: memory)
                    guard let skill = skills.skill(named: name) else {
                        return .object([
                            "ok": .bool(false),
                            "error": .string("No skill named '\(name)'. See the skills list in context."),
                        ])
                    }
                    return .object([
                        "ok": .bool(true),
                        "name": .string(skill.name),
                        "body": .string(skill.body),
                    ])
                }
            }
        ))
    }

    public static func registerMemoryTools(on registry: ToolRegistry, memory: MemoryStore) {
        registry.register(ClientTool(
            descriptor: ToolDescriptor(
                name: "lsMemories",
                description: """
                List entries at a memory path. `path` is relative to the memories \
                root (use "" for the root). With `recursive=true`, returns the full \
                subtree (paths flattened). Result echoes \
                {entries: [{path, name, kind: "file"|"folder", sizeBytes?, modifiedAt?}]}. \
                To surface a note in chat as a tappable link, write the markdown \
                `[title](pupa://memory/<path>)` using a returned `path`.
                """,
                parameters: [
                    "type": "object",
                    "properties": [
                        "path": ["type": "string"],
                        "recursive": ["type": "boolean"],
                    ],
                ]
            ),
            handler: { args in
                let path = args["path"]?.stringValue ?? ""
                let recursive = args["recursive"]?.boolValue ?? false
                return await MainActor.run {
                    do {
                        let entries = try memory.ls(path: path, recursive: recursive)
                        return .object([
                            "ok": .bool(true),
                            "entries": .array(entries.map(entryAsAnyJSON)),
                        ])
                    } catch {
                        return .object(["ok": .bool(false), "error": .string(error.localizedDescription)])
                    }
                }
            }
        ))

        registry.register(ClientTool(
            descriptor: ToolDescriptor(
                name: "readMemoryFile",
                description: """
                Read a markdown file from the user's memories. Optional `offset` \
                (0-based) and `limit` slice by lines, useful for big files. Result \
                echoes {path, content, totalLines, offset, returnedLines}.
                """,
                parameters: [
                    "type": "object",
                    "properties": [
                        "path": ["type": "string"],
                        "offset": ["type": "integer", "minimum": 0],
                        "limit": ["type": "integer", "minimum": 1],
                    ],
                    "required": ["path"],
                ]
            ),
            handler: { args in
                let path = args["path"]?.stringValue ?? ""
                let offset = args["offset"]?.intValue
                let limit = args["limit"]?.intValue
                return await MainActor.run {
                    do {
                        let r = try memory.readFile(path: path, offset: offset, limit: limit)
                        return .object([
                            "ok": .bool(true),
                            "path": .string(path),
                            "content": .string(r.content),
                            "totalLines": .int(r.totalLines),
                            "offset": .int(r.offset),
                            "returnedLines": .int(r.returnedLines),
                        ])
                    } catch {
                        return .object(["ok": .bool(false), "error": .string(error.localizedDescription)])
                    }
                }
            }
        ))

        registry.register(ClientTool(
            descriptor: ToolDescriptor(
                name: "writeMemoryFile",
                description: """
                Create or overwrite a markdown file. `path` must end in .md and be \
                relative to the memories root (e.g. "notes/diet.md"). Parent folders \
                are created as needed. Result echoes {path, sizeBytes}.
                """,
                parameters: [
                    "type": "object",
                    "properties": [
                        "path": ["type": "string"],
                        "content": ["type": "string"],
                    ],
                    "required": ["path", "content"],
                ]
            ),
            handler: { args in
                let path = args["path"]?.stringValue ?? ""
                let content = args["content"]?.stringValue ?? ""
                return await MainActor.run {
                    do {
                        let size = try memory.writeFile(path: path, content: content)
                        return .object([
                            "ok": .bool(true),
                            "path": .string(path),
                            "sizeBytes": .int(size),
                        ])
                    } catch {
                        return .object(["ok": .bool(false), "error": .string(error.localizedDescription)])
                    }
                }
            }
        ))

        registry.register(ClientTool(
            descriptor: ToolDescriptor(
                name: "appendMemoryFile",
                description: """
                Append text to a markdown file (creates the file if missing). \
                Result echoes {path, sizeBytes}.
                """,
                parameters: [
                    "type": "object",
                    "properties": [
                        "path": ["type": "string"],
                        "content": ["type": "string"],
                    ],
                    "required": ["path", "content"],
                ]
            ),
            handler: { args in
                let path = args["path"]?.stringValue ?? ""
                let content = args["content"]?.stringValue ?? ""
                return await MainActor.run {
                    do {
                        let size = try memory.appendFile(path: path, content: content)
                        return .object([
                            "ok": .bool(true),
                            "path": .string(path),
                            "sizeBytes": .int(size),
                        ])
                    } catch {
                        return .object(["ok": .bool(false), "error": .string(error.localizedDescription)])
                    }
                }
            }
        ))

        registry.register(ClientTool(
            descriptor: ToolDescriptor(
                name: "editMemoryFile",
                description: """
                Surgically edit a file by replacing `oldString` with `newString`. \
                `oldString` must occur exactly ONCE unless `replaceAll=true`. Provide \
                enough surrounding context to make `oldString` unique. Errors with \
                'editNotUnique' if it isn't and `replaceAll` is false. Result echoes \
                {path, replacements}.
                """,
                parameters: [
                    "type": "object",
                    "properties": [
                        "path": ["type": "string"],
                        "oldString": ["type": "string"],
                        "newString": ["type": "string"],
                        "replaceAll": ["type": "boolean"],
                    ],
                    "required": ["path", "oldString", "newString"],
                ]
            ),
            handler: { args in
                let path = args["path"]?.stringValue ?? ""
                let old = args["oldString"]?.stringValue ?? ""
                let new = args["newString"]?.stringValue ?? ""
                let all = args["replaceAll"]?.boolValue ?? false
                return await MainActor.run {
                    do {
                        let n = try memory.editFile(path: path, oldString: old, newString: new, replaceAll: all)
                        return .object([
                            "ok": .bool(true),
                            "path": .string(path),
                            "replacements": .int(n),
                        ])
                    } catch {
                        return .object(["ok": .bool(false), "error": .string(error.localizedDescription)])
                    }
                }
            }
        ))

        registry.register(ClientTool(
            descriptor: ToolDescriptor(
                name: "grepMemories",
                description: """
                Search markdown files for a regex pattern. Scoped by optional `path` \
                (root by default) and `glob` (e.g. "**/*.md", "notes/*.md"). Returns \
                up to 50 hits as {matches: [{path, line, text}]}.
                """,
                parameters: [
                    "type": "object",
                    "properties": [
                        "pattern": ["type": "string"],
                        "path": ["type": "string"],
                        "glob": ["type": "string"],
                        "ignoreCase": ["type": "boolean"],
                        "contextLines": ["type": "integer", "minimum": 0],
                    ],
                    "required": ["pattern"],
                ]
            ),
            handler: { args in
                let pattern = args["pattern"]?.stringValue ?? ""
                let path = args["path"]?.stringValue ?? ""
                let glob = args["glob"]?.stringValue
                let ignoreCase = args["ignoreCase"]?.boolValue ?? false
                let ctx = args["contextLines"]?.intValue ?? 0
                return await MainActor.run {
                    do {
                        let hits = try memory.grep(
                            pattern: pattern, path: path, glob: glob,
                            ignoreCase: ignoreCase, contextLines: ctx
                        )
                        return .object([
                            "ok": .bool(true),
                            "matches": .array(hits.map { hit in
                                .object([
                                    "path": .string(hit.path),
                                    "line": .int(hit.line),
                                    "text": .string(hit.text),
                                ])
                            }),
                        ])
                    } catch {
                        return .object(["ok": .bool(false), "error": .string(error.localizedDescription)])
                    }
                }
            }
        ))

        registry.register(ClientTool(
            descriptor: ToolDescriptor(
                name: "moveMemoryFile",
                description: """
                Rename or move a file or folder. Creates intermediate folders for \
                `to`. Result echoes {from, to}.
                """,
                parameters: [
                    "type": "object",
                    "properties": [
                        "from": ["type": "string"],
                        "to": ["type": "string"],
                    ],
                    "required": ["from", "to"],
                ]
            ),
            handler: { args in
                let from = args["from"]?.stringValue ?? ""
                let to = args["to"]?.stringValue ?? ""
                return await MainActor.run {
                    do {
                        try memory.move(from: from, to: to)
                        return .object([
                            "ok": .bool(true),
                            "from": .string(from),
                            "to": .string(to),
                        ])
                    } catch {
                        return .object(["ok": .bool(false), "error": .string(error.localizedDescription)])
                    }
                }
            }
        ))

        registry.register(ClientTool(
            descriptor: ToolDescriptor(
                name: "deleteMemoryFile",
                description: """
                Remove a file or empty folder. Pass `recursive=true` to remove a \
                non-empty folder. Result echoes {deleted: true}.
                """,
                parameters: [
                    "type": "object",
                    "properties": [
                        "path": ["type": "string"],
                        "recursive": ["type": "boolean"],
                    ],
                    "required": ["path"],
                ]
            ),
            handler: { args in
                let path = args["path"]?.stringValue ?? ""
                let recursive = args["recursive"]?.boolValue ?? false
                return await MainActor.run {
                    do {
                        try memory.delete(path: path, recursive: recursive)
                        return .object(["ok": .bool(true), "deleted": .bool(true)])
                    } catch {
                        return .object(["ok": .bool(false), "error": .string(error.localizedDescription)])
                    }
                }
            }
        ))

        registry.register(ClientTool(
            descriptor: ToolDescriptor(
                name: "createMemoryFolder",
                description: "Create an empty folder (and any intermediate folders). Result echoes {path}.",
                parameters: [
                    "type": "object",
                    "properties": ["path": ["type": "string"]],
                    "required": ["path"],
                ]
            ),
            handler: { args in
                let path = args["path"]?.stringValue ?? ""
                return await MainActor.run {
                    do {
                        try memory.createFolder(path: path)
                        return .object(["ok": .bool(true), "path": .string(path)])
                    } catch {
                        return .object(["ok": .bool(false), "error": .string(error.localizedDescription)])
                    }
                }
            }
        ))
    }

    /// Register `ask_user_questions` as a frontend tool. The handler
    /// renders a question panel through the supplied
    /// [HumanInTheLoopBridge](HumanInTheLoopBridge.swift), awaits the
    /// user's submission, and returns the answers as a JSON array of
    /// strings. Pairs with the backend's
    /// [CopilotKitMiddlewareWithFrontendInterrupt](../../../../backend/frontend_interrupt.py):
    /// when the model emits this call, the middleware pauses the graph,
    /// AGUIKit dispatches the handler locally, this method suspends on
    /// the bridge, the user submits, the handler returns, and AGUIKit
    /// POSTs the resume with the answers as the tool result content —
    /// the model never speaks past the call without seeing the reply.
    @MainActor
    public static func registerHumanInTheLoopTools(
        on registry: ToolRegistry,
        bridge: HumanInTheLoopBridge
    ) {
        registry.register(ClientTool(
            descriptor: ToolDescriptor(
                name: "ask_user_questions",
                description: """
                Ask the user clarifying questions when you genuinely \
                cannot proceed — ambiguous references the canvas / \
                memories context can't disambiguate, missing required \
                parameters you can't infer, or confirmation before a \
                destructive change. Do NOT use for anything the \
                context, memories, another tool, or your own reasoning \
                can answer. Batch every clarification into one call \
                rather than asking sequentially. Returns a JSON array \
                of answer strings, one per question, in input order.
                """,
                parameters: [
                    "type": "object",
                    "properties": [
                        "questions": [
                            "type": "array",
                            "items": [
                                "type": "object",
                                "properties": [
                                    "question": [
                                        "type": "string",
                                        "description": "One focused sentence, no preamble.",
                                    ],
                                    "options": [
                                        "type": "array",
                                        "items": ["type": "string"],
                                        "description": "Up to ~4 short suggested answers (optional).",
                                    ],
                                ],
                                "required": ["question"],
                            ],
                        ],
                    ],
                    "required": ["questions"],
                ]
            ),
            handler: { [weak bridge] args in
                guard let bridge else {
                    return .object([
                        "ok": .bool(false),
                        "error": .string("HumanInTheLoopBridge unavailable"),
                    ])
                }
                let rows: [HumanQuestionRow]
                if case .array(let arr) = args["questions"] ?? .null {
                    rows = arr.compactMap { entry -> HumanQuestionRow? in
                        guard case .object(let fields) = entry,
                              case .string(let question) = fields["question"] else {
                            return nil
                        }
                        let options: [String]
                        if case .array(let opts) = fields["options"] ?? .null {
                            options = opts.compactMap { $0.stringValue }
                        } else {
                            options = []
                        }
                        return HumanQuestionRow(question: question, options: options)
                    }
                } else {
                    rows = []
                }
                guard !rows.isEmpty else {
                    return .object([
                        "ok": .bool(false),
                        "error": .string("ask_user_questions requires a non-empty `questions` list"),
                    ])
                }
                let answers = await bridge.askQuestions(rows)
                // Pad to match the requested question count so the model
                // can index by position without bookkeeping. Returning a
                // JSON array (not a wrapping object) matches what the
                // old backend tool returned when it stringified its
                // `list[str]` result — keeps the model's mental model
                // stable.
                let padded: [String] = (0..<rows.count).map { i in
                    i < answers.count ? answers[i] : ""
                }
                return .array(padded.map { .string($0) })
            }
        ))

        registry.register(ClientTool(
            descriptor: ToolDescriptor(
                name: "request_shell_approval",
                description: """
                Request the user's approval before running a shell command on \
                the backend host. Called automatically by the backend's \
                ShellApprovalMiddleware — never call this yourself. Returns \
                {"approved": bool, "remember": bool}.
                """,
                parameters: [
                    "type": "object",
                    "properties": [
                        "command": [
                            "type": "string",
                            "description": "The shell command string about to be executed.",
                        ],
                    ],
                    "required": ["command"],
                ]
            ),
            handler: { [weak bridge] args in
                guard let bridge else {
                    return .object([
                        "approved": .bool(false),
                        "remember": .bool(false),
                        "error": .string("HumanInTheLoopBridge unavailable"),
                    ])
                }
                let command: String
                if case .string(let cmd) = args["command"] ?? .null {
                    command = cmd
                } else {
                    command = ""
                }
                let result = await bridge.requestShellApproval(command: command)
                return .object([
                    "approved": .bool(result.approved),
                    "remember": .bool(result.remember),
                ])
            }
        ))
    }

    /// Register the local-notification tools (`sendNotification` +
    /// `cancelNotification`) plus the `get_tools_notifications` gate.
    /// Notifications are app-global — not bound to a MyApp — so the tool
    /// names live in `MyAppType.notificationToolNames`. The tool gate
    /// keeps the (heavy) descriptions out of the per-turn payload until the
    /// agent first opts in via `get_tools_notifications` (issue #220).
    @MainActor
    public static func registerNotificationTools(
        on registry: ToolRegistry,
        coordinator: NotificationCenterCoordinator,
        toolGateState: ToolGateState
    ) {
        registry.register(ClientTool(
            descriptor: ToolDescriptor(
                name: "get_tools_notifications",
                description: "Activate the notifications tools. Call once to unlock sendNotification + cancelNotification from the next agent round onward.",
                parameters: ["type": "object", "properties": [:]]
            ),
            readOnly: true,
            handler: { [weak toolGateState] _ in
                guard let toolGateState else {
                    return .object(["ok": .bool(false), "error": .string("tool gate state unavailable")])
                }
                await MainActor.run { toolGateState.activateNotifications() }
                return .object([
                    "ok": .bool(true),
                    "activated": .string("notifications"),
                    "toolsUnlocked": .int(MyAppType.notificationToolNames.count),
                ])
            }
        ))

        registry.register(ClientTool(
            descriptor: ToolDescriptor(
                name: "sendNotification",
                description: """
                Schedule a local notification banner on the user's device. Use \
                when the user asks to be reminded after a delay, at a specific \
                wall-clock time, or wants to be pinged when a long task you're \
                running completes (call with `trigger.kind=now` at the moment \
                the work finishes — the OS will surface the banner even if the \
                user has backgrounded the app). `trigger` is a discriminated \
                union: {kind:"now"} | {kind:"after", seconds:N} | \
                {kind:"atDate", iso8601:"<ISO-8601>"}. `seconds` ranges 1..\
                31536000. `atDate` must be in the future. Supply `target` to \
                deep-link the tap: `{myAppId:"<UUID>"}` opens that myApp, \
                add `componentId:"tracker-1"` to jump straight to a component. \
                Without a target, tapping just foregrounds the app. Permission \
                is requested lazily on first call; if denied the tool returns \
                {ok:false, error:"notifications-not-authorized"} so you can \
                tell the user. Result echoes {id, deliveryAt, trigger} — save \
                the `id` if you might want to cancel it.
                """,
                parameters: [
                    "type": "object",
                    "properties": [
                        "title": [
                            "type": "string",
                            "description": "Banner title (≤64 chars).",
                        ],
                        "body": [
                            "type": "string",
                            "description": "Banner body (≤256 chars).",
                        ],
                        "trigger": [
                            "type": "object",
                            "description": "When to fire. Discriminated by `kind`.",
                            "properties": [
                                "kind": [
                                    "type": "string",
                                    "enum": ["now", "after", "atDate"],
                                ],
                                "seconds": [
                                    "type": "integer",
                                    "minimum": 1,
                                    "maximum": 31_536_000,
                                    "description": "Required when kind=after.",
                                ],
                                "iso8601": [
                                    "type": "string",
                                    "description": "Required when kind=atDate. ISO-8601, e.g. 2026-05-14T15:00:00Z.",
                                ],
                            ],
                            "required": ["kind"],
                        ],
                        "target": [
                            "type": "object",
                            "description": "Optional deep-link: where to navigate when the user taps the banner.",
                            "properties": [
                                "myAppId": [
                                    "type": "string",
                                    "description": "UUID of the myApp to open.",
                                ],
                                "componentId": [
                                    "type": "string",
                                    "description": "Component to focus, e.g. \"tracker-1\". Omit to open the myApp home.",
                                ],
                            ],
                            "required": ["myAppId"],
                        ],
                    ],
                    "required": ["title", "body", "trigger"],
                ]
            ),
            handler: { args in
                let request: NotificationRequest
                do {
                    request = try NotificationRequest(fromToolArgs: args)
                } catch {
                    return .object([
                        "ok": .bool(false),
                        "error": .string(String(describing: error)),
                    ])
                }
                do {
                    let scheduled = try await coordinator.schedule(request)
                    return .object([
                        "ok": .bool(true),
                        "id": .string(scheduled.id),
                        "deliveryAt": .string(NotificationRequest.formatISO8601(scheduled.deliveryAt)),
                        "trigger": request.triggerEcho(),
                    ])
                } catch NotificationCenterCoordinator.ScheduleError.notAuthorised {
                    return .object([
                        "ok": .bool(false),
                        "error": .string("notifications-not-authorized"),
                        "permissionState": .string("denied"),
                    ])
                } catch NotificationCenterCoordinator.ScheduleError.unsupportedHost {
                    // Unsigned `swift run PupaDemo` macOS binary (no
                    // bundle identifier) — touching UNUserNotificationCenter
                    // would raise. Tell the agent so it can route the user to
                    // a signed build.
                    return .object([
                        "ok": .bool(false),
                        "error": .string("notifications-unsupported-host"),
                    ])
                } catch {
                    return .object([
                        "ok": .bool(false),
                        "error": .string(error.localizedDescription),
                    ])
                }
            }
        ))

        registry.register(ClientTool(
            descriptor: ToolDescriptor(
                name: "cancelNotification",
                description: """
                Cancel a pending local notification by its `id` (the value \
                returned in `sendNotification`'s echo). Idempotent — returns \
                ok:true even when the id is unknown or the notification has \
                already been delivered; check `wasPending` to know if a real \
                cancellation happened.
                """,
                parameters: [
                    "type": "object",
                    "properties": [
                        "id": [
                            "type": "string",
                            "description": "Identifier from sendNotification's echo.",
                        ],
                    ],
                    "required": ["id"],
                ]
            ),
            handler: { args in
                guard let id = args["id"]?.stringValue, !id.isEmpty else {
                    return .object([
                        "ok": .bool(false),
                        "error": .string("missing 'id'"),
                    ])
                }
                let wasPending = await coordinator.cancel(id: id)
                return .object([
                    "ok": .bool(true),
                    "id": .string(id),
                    "wasPending": .bool(wasPending),
                ])
            }
        ))
    }

    private static func entryAsAnyJSON(_ entry: Entry) -> AnyJSON {
        var obj: [String: AnyJSON] = [
            "path": .string(entry.path),
            "name": .string(entry.name),
            "kind": .string(entry.kind.rawValue),
        ]
        if let size = entry.sizeBytes { obj["sizeBytes"] = .int(size) }
        if let mtime = entry.modifiedAt {
            obj["modifiedAt"] = .string(ISO8601DateFormatter().string(from: mtime))
        }
        return .object(obj)
    }

    // MARK: - Helpers

    /// Shared `componentId` parameter schema for a kind's write tools. The
    /// target is resolved deterministically and never from the active/view
    /// component: required only when the myApp holds more than one component
    /// of `kind`.
    static func componentIdSchema(kind: String = "tracker") -> AnyJSON {
        [
            "type": "string",
            "description": .string("Which \(kind) to write to (e.g. \"\(kind)-1\"). Optional when the myApp has exactly one \(kind); REQUIRED when it has several — otherwise the call errors and lists the candidates. Writes never fall back to the active/viewed component."),
        ]
    }

    static func trackerSchema() -> AnyJSON {
        [
            "type": "object",
            "properties": [
                "componentId": componentIdSchema(),
                "title": ["type": "string"],
                "fields": [
                    "type": "array",
                    "minItems": 1,
                    "maxItems": 8,
                    "items": [
                        "type": "object",
                        "properties": [
                            "name": ["type": "string"],
                            "label": ["type": "string"],
                            "type": ["type": "string", "enum": ["text", "number", "select", "image", "link"]],
                            "options": ["type": "array", "items": ["type": "string"]],
                        ],
                        "required": ["name", "type"],
                    ],
                ],
                "summary": [
                    "type": "string",
                    "description": "Your content summary for this tracker — what its rows represent, field names worth remembering, status of the data. Round-trips back to you in the canvas state every turn (so future-you can read what past-you wrote). Pass `summary` alone (without `title` / `fields`) to update the note without re-rendering the body. Update it whenever the meaning or state of the data shifts.",
                ],
            ],
        ]
    }

    static func calendarEventSchema() -> AnyJSON {
        [
            "type": "object",
            "properties": [
                "title": ["type": "string"],
                "start": ["type": "string", "description": "ISO-8601 datetime, e.g. 2026-05-14T10:00:00Z"],
                "end": ["type": "string", "description": "ISO-8601 datetime, optional"],
                "location": ["type": "string"],
                "notes": ["type": "string"],
                "linkedItems": [
                    "type": "array",
                    "description": "Tracker items to attach as inline references (rendered as chain-link pills below the title). Each entry is {componentId, itemId}.",
                    "items": [
                        "type": "object",
                        "properties": [
                            "componentId": ["type": "string"],
                            "itemId": ["type": "string"],
                        ],
                        "required": ["componentId", "itemId"],
                    ],
                ],
            ],
            "required": ["title", "start"],
        ]
    }

    static func parseEvents(from json: AnyJSON?) -> [CalendarEvent] {
        guard let arr = json?.arrayValue else { return [] }
        return arr.compactMap { entry in
            guard let title = entry["title"]?.stringValue,
                  let start = entry["start"]?.stringValue else { return nil }
            return CalendarEvent(
                title: title,
                start: start,
                end: entry["end"]?.stringValue,
                location: entry["location"]?.stringValue,
                notes: entry["notes"]?.stringValue,
                linkedItems: parseLinkedItems(from: entry["linkedItems"])
            )
        }
    }

    /// Parse the `linkedItems` JSON shape `[{componentId, itemId}]` into
    /// strongly-typed refs. Entries with a malformed `itemId` (not a
    /// UUID) are silently dropped — better than erroring the whole tool
    /// call over one bad ref.
    static func parseLinkedItems(from json: AnyJSON?) -> [ComponentItemRef] {
        guard let arr = json?.arrayValue else { return [] }
        return arr.compactMap { entry in
            guard let componentId = entry["componentId"]?.stringValue,
                  let idString = entry["itemId"]?.stringValue,
                  let uuid = UUID(uuidString: idString) else { return nil }
            return ComponentItemRef(componentId: componentId, itemId: uuid)
        }
    }

    static func checklistItemSchema() -> AnyJSON {
        [
            "type": "object",
            "properties": [
                "text": ["type": "string"],
                "done": ["type": "boolean"],
                "linkedItems": [
                    "type": "array",
                    "description": "Items in other components to attach as inline references (rendered as chain-link pills under the row text). Each entry is {componentId, itemId}; componentId may point at a tracker or calendar component.",
                    "items": [
                        "type": "object",
                        "properties": [
                            "componentId": ["type": "string"],
                            "itemId": ["type": "string"],
                        ],
                        "required": ["componentId", "itemId"],
                    ],
                ],
            ],
            "required": ["text"],
        ]
    }

    static func parseChecklistItems(from json: AnyJSON?) -> [ChecklistItem] {
        guard let arr = json?.arrayValue else { return [] }
        return arr.compactMap { entry in
            guard let text = entry["text"]?.stringValue else { return nil }
            return ChecklistItem(
                text: text,
                done: entry["done"]?.boolValue ?? false,
                linkedItems: parseLinkedItems(from: entry["linkedItems"])
            )
        }
    }

    static func checklistItemAsAnyJSON(_ item: ChecklistItem) -> AnyJSON {
        var obj: [String: AnyJSON] = [
            "id": .string(item.id.uuidString),
            "text": .string(item.text),
            "done": .bool(item.done),
        ]
        if !item.linkedItems.isEmpty {
            obj["linkedItems"] = .array(item.linkedItems.map {
                .object([
                    "componentId": .string($0.componentId),
                    "itemId": .string($0.itemId.uuidString),
                ])
            })
        }
        return .object(obj)
    }

    static func eventAsAnyJSON(_ event: CalendarEvent) -> AnyJSON {
        var obj: [String: AnyJSON] = [
            "id": .string(event.id.uuidString),
            "title": .string(event.title),
            "start": .string(event.start),
        ]
        if let v = event.end { obj["end"] = .string(v) }
        if let v = event.location { obj["location"] = .string(v) }
        if let v = event.notes { obj["notes"] = .string(v) }
        if !event.linkedItems.isEmpty {
            obj["linkedItems"] = .array(event.linkedItems.map {
                .object([
                    "componentId": .string($0.componentId),
                    "itemId": .string($0.itemId.uuidString),
                ])
            })
        }
        return .object(obj)
    }

    private static func defaultIcon(forKind kind: String) -> String {
        switch kind {
        case "tracker": return "list.bullet.rectangle"
        case "calendar": return "calendar"
        case "checklist": return "checklist"
        case "calculator": return "function"
        case "chart": return "chart.pie"
        case "slack": return "bubble.left.and.bubble.right"
        default: return "square.dashed"
        }
    }

    static func parseFields(from json: AnyJSON?) -> [FieldDef] {
        guard let arr = json?.arrayValue else { return [] }
        return arr.compactMap { entry in
            guard let name = entry["name"]?.stringValue,
                  let typeRaw = entry["type"]?.stringValue,
                  let type = FieldType(rawValue: typeRaw) else { return nil }
            return FieldDef(
                name: name,
                label: entry["label"]?.stringValue,
                type: type,
                options: entry["options"]?.arrayValue?.compactMap(\.stringValue)
            )
        }
    }

    /// Coerce an arbitrary JSON value into the string we store in `TrackerData.items`.
    static func stringify(_ v: AnyJSON) -> String {
        switch v {
        case .null: return ""
        case .bool(let b): return String(b)
        case .int(let i): return String(i)
        case .double(let d): return String(d)
        case .string(let s): return s
        case .array, .object:
            if let data = try? JSONEncoder().encode(v),
               let s = String(data: data, encoding: .utf8) { return s }
            return ""
        }
    }

    /// Find the tracker component in `myAppId`. Prefers the active
    /// the MyApp's tracker when it holds exactly one — else nil. The
    /// active/view component is never consulted (it's no longer agent-facing
    /// and a read must not silently depend on it). Callers that know the id
    /// should use the `componentId:` overload.
    @MainActor
    static func tracker(_ store: MyAppStore, myAppId: UUID) -> TrackerData? {
        guard case .resolved(let id) = store.resolveWriteTarget(kind: "tracker", componentId: nil, myAppId: myAppId) else { return nil }
        return tracker(store, myAppId: myAppId, componentId: id)
    }

    /// Read a specific tracker by id (used to echo the correct component's
    /// state after a write that named its target). Falls back to the
    /// view-independent lookup when `componentId` is nil.
    @MainActor
    static func tracker(_ store: MyAppStore, myAppId: UUID, componentId: String?) -> TrackerData? {
        guard let componentId else { return tracker(store, myAppId: myAppId) }
        guard let myApp = store.myApps.first(where: { $0.id == myAppId }),
              let comp = myApp.components.first(where: { $0.id == componentId }),
              case .tracker(let t) = comp.body else { return nil }
        return t
    }

    @MainActor
    static func calendar(_ store: MyAppStore, myAppId: UUID) -> CalendarData? {
        guard case .resolved(let id) = store.resolveWriteTarget(kind: "calendar", componentId: nil, myAppId: myAppId) else { return nil }
        return calendar(store, myAppId: myAppId, componentId: id)
    }

    /// Read a specific calendar by id (to echo the correct component's
    /// state after a targeted write). Falls back to the view-independent
    /// lookup when `componentId` is nil.
    @MainActor
    static func calendar(_ store: MyAppStore, myAppId: UUID, componentId: String?) -> CalendarData? {
        guard let componentId else { return calendar(store, myAppId: myAppId) }
        guard let myApp = store.myApps.first(where: { $0.id == myAppId }),
              let comp = myApp.components.first(where: { $0.id == componentId }),
              case .calendar(let c) = comp.body else { return nil }
        return c
    }

    @MainActor
    static func checklist(_ store: MyAppStore, myAppId: UUID) -> ChecklistData? {
        guard case .resolved(let id) = store.resolveWriteTarget(kind: "checklist", componentId: nil, myAppId: myAppId) else { return nil }
        return checklist(store, myAppId: myAppId, componentId: id)
    }

    /// Read a specific checklist by id (to echo the correct component's
    /// state after a targeted write). Falls back to the view-independent
    /// lookup when `componentId` is nil.
    @MainActor
    static func checklist(_ store: MyAppStore, myAppId: UUID, componentId: String?) -> ChecklistData? {
        guard let componentId else { return checklist(store, myAppId: myAppId) }
        guard let myApp = store.myApps.first(where: { $0.id == myAppId }),
              let comp = myApp.components.first(where: { $0.id == componentId }),
              case .checklist(let cl) = comp.body else { return nil }
        return cl
    }

    // MARK: - Calculator helpers

    @MainActor
    static func calculator(_ store: MyAppStore, myAppId: UUID) -> CalculatorData? {
        guard case .resolved(let id) = store.resolveWriteTarget(kind: "calculator", componentId: nil, myAppId: myAppId) else { return nil }
        return calculator(store, myAppId: myAppId, componentId: id)
    }

    /// Read a specific calculator by id (to echo the correct component's
    /// state after a targeted write). Falls back to the view-independent
    /// lookup when `componentId` is nil.
    @MainActor
    static func calculator(_ store: MyAppStore, myAppId: UUID, componentId: String?) -> CalculatorData? {
        guard let componentId else { return calculator(store, myAppId: myAppId) }
        guard let myApp = store.myApps.first(where: { $0.id == myAppId }),
              let comp = myApp.components.first(where: { $0.id == componentId }),
              case .calculator(let c) = comp.body else { return nil }
        return c
    }

    @MainActor
    static func resolveCalculator(
        store: MyAppStore,
        myAppId: UUID,
        componentId: String?
    ) -> (CalculatorData, String)? {
        guard case .resolved(let id) = store.resolveWriteTarget(kind: "calculator", componentId: componentId, myAppId: myAppId),
              let myApp = store.myApps.first(where: { $0.id == myAppId }),
              let comp = myApp.components.first(where: { $0.id == id }),
              case .calculator(let c) = comp.body else { return nil }
        return (c, id)
    }

    /// Sibling components of `myAppId` — the pool calculator aggregate rows
    /// resolve their source trackers from.
    @MainActor
    static func siblingComponents(store: MyAppStore, myAppId: UUID) -> [Component] {
        store.myApps.first(where: { $0.id == myAppId })?.components ?? []
    }

    /// `[{key, value?, status}]` for every row, resolved live. Echoed by the
    /// mutating calculator tools so the agent sees computed values mid-turn.
    @MainActor
    static func calcResults(store: MyAppStore, myAppId: UUID, data: CalculatorData) -> AnyJSON {
        let resolved = CalculatorResolver.resolve(data, components: siblingComponents(store: store, myAppId: myAppId))
        return .array(data.rows.map { row in
            let r = resolved.result(forKey: row.key)
            var obj: [String: AnyJSON] = [
                "key": .string(row.key),
                "status": .string(r?.status.rawValue ?? "ok"),
            ]
            if let v = r?.value { obj["value"] = .double(v) }
            return .object(obj)
        })
    }

    static func calcRowSchema() -> AnyJSON {
        [
            "type": "object",
            "properties": [
                "key": ["type": "string", "description": "Stable slug formulas reference. Omit to derive from name."],
                "name": ["type": "string"],
                "unit": ["type": "string", "description": "Display unit, e.g. \"$\", \"%\", \"yr\"."],
                "format": ["type": "string", "description": "Optional printf hint, e.g. \"%.2f\"."],
                "kind": ["type": "string", "enum": ["variable", "aggregate", "formula", "list", "linkedField", "header"], "description": "linkedField: one numeric field off a single linked tracker item (swap the link to re-run the model). header: section label — rows below collapse/expand as a group until the next header; `name` is the heading text."],
                "value": ["type": "number", "description": "variable: the input value."],
                "control": [
                    "type": "object",
                    "description": "variable: tuning control.",
                    "properties": [
                        "type": ["type": "string", "enum": ["plain", "stepper", "slider"]],
                        "min": ["type": "number"],
                        "max": ["type": "number"],
                        "step": ["type": "number"],
                    ],
                ],
                "list": [
                    "type": "object",
                    "description": "list: an ARRAY output for charts. Kinds: sweep (one curve), trackerColumn (raw column), linkedCompare (one point per linked ref → bars), linkedSweep (one CURVE per linked ref → multi-line; linkedCompare with a swept y).",
                    "properties": [
                        "type": ["type": "string", "enum": ["sweep", "trackerColumn", "linkedCompare", "linkedSweep"]],
                        "variableKey": ["type": "string", "description": "sweep / linkedSweep: the variable row key to vary."],
                        "from": ["type": "number", "description": "sweep / linkedSweep: range start."],
                        "to": ["type": "number", "description": "sweep / linkedSweep: range end (inclusive)."],
                        "step": ["type": "number", "description": "sweep / linkedSweep: increment (> 0)."],
                        "targetKey": ["type": "string", "description": "sweep / linkedSweep / linkedCompare: the row key read for each point (y)."],
                        "sourceComponentId": ["type": "string", "description": "trackerColumn: source tracker id."],
                        "valueField": ["type": "string", "description": "trackerColumn: numeric field → y."],
                        "labelField": ["type": "string", "description": "trackerColumn: optional field → point label."],
                        "filter": ["type": "object", "description": "trackerColumn: equality filter."],
                        "refs": ["type": "array", "description": "linkedCompare / linkedSweep: tracker items to compare (one point / one curve each).", "items": ["type": "object", "properties": ["componentId": ["type": "string"], "itemId": ["type": "string"]], "required": ["componentId", "itemId"]]],
                        "linkedRowKey": ["type": "string", "description": "linkedCompare / linkedSweep: anchor linkedField row key; every linkedField row sharing its ref is swapped to each compared item before reading targetKey (linkedSweep sweeps variableKey at each)."],
                    ],
                ],
                "linkedField": [
                    "type": "object",
                    "description": "linkedField: pull one numeric field off a single linked tracker item.",
                    "properties": [
                        "ref": ["type": "object", "description": "The linked tracker item. Omit to leave unlinked.", "properties": ["componentId": ["type": "string"], "itemId": ["type": "string"]], "required": ["componentId", "itemId"]],
                        "field": ["type": "string", "description": "Field name on the linked item to read and parse as a number."],
                    ],
                ],
                "aggregate": [
                    "type": "object",
                    "description": "aggregate: scalar reduce over a tracker field.",
                    "properties": [
                        "sourceComponentId": ["type": "string"],
                        "field": ["type": "string"],
                        "reduce": ["type": "string", "enum": ["sum", "avg", "min", "max", "count"]],
                        "filter": ["type": "object", "description": "Case-insensitive AND equality filter, e.g. {\"cuisine\":\"African\"}."],
                    ],
                ],
                "expression": ["type": "string", "description": "formula: arithmetic over other rows' keys (+ - * / % ^, fns min/max/abs/round/sqrt/log/exp/pow)."],
            ],
            "required": ["name", "kind"],
        ]
    }

    static func calcRowPatchSchema() -> AnyJSON {
        [
            "type": "object",
            "properties": [
                "name": ["type": "string"],
                "unit": ["type": "string"],
                "format": ["type": "string"],
                "kind": ["type": "string", "enum": ["variable", "aggregate", "formula", "list", "linkedField", "header"]],
                "value": ["type": "number"],
                "control": ["type": "object"],
                "aggregate": ["type": "object"],
                "expression": ["type": "string"],
                "list": ["type": "object"],
                "linkedField": ["type": "object"],
            ],
        ]
    }

    private static func parseCalcControl(from json: AnyJSON?) -> CalcControl {
        guard let obj = json?.objectValue, let type = obj["type"]?.stringValue else { return .plain }
        switch type {
        case "stepper":
            return .stepper(step: obj["step"]?.doubleValue ?? 1)
        case "slider":
            return .slider(
                min: obj["min"]?.doubleValue ?? 0,
                max: obj["max"]?.doubleValue ?? 100,
                step: obj["step"]?.doubleValue ?? 1
            )
        default:
            return .plain
        }
    }

    /// Parse the `kind` discriminator + its sibling fields off a row (or
    /// patch) object into a `CalcRowKind`. Returns nil when `kind` is
    /// missing / unknown or an aggregate lacks a `sourceComponentId`.
    private static func parseCalcRowKind(from entry: AnyJSON) -> CalcRowKind? {
        guard let kind = entry["kind"]?.stringValue else { return nil }
        switch kind {
        case "variable":
            return .variable(value: entry["value"]?.doubleValue ?? 0, control: parseCalcControl(from: entry["control"]))
        case "aggregate":
            let agg: AnyJSON = entry["aggregate"] ?? entry
            guard let source = agg["sourceComponentId"]?.stringValue else { return nil }
            let field = agg["field"]?.stringValue ?? agg["fieldName"]?.stringValue ?? ""
            let reduce = CalcReduce(rawValue: agg["reduce"]?.stringValue ?? "sum") ?? .sum
            var filter: [String: String] = [:]
            if let f = agg["filter"]?.objectValue { filter = f.compactMapValues(\.stringValue) }
            return .aggregate(AggregateSpec(sourceComponentId: source, fieldName: field, reduce: reduce, filter: filter))
        case "formula":
            return .formula(expression: entry["expression"]?.stringValue ?? "")
        case "list":
            guard let spec = parseCalcListSpec(from: entry["list"] ?? entry) else { return nil }
            return .list(spec)
        case "linkedField":
            let lf: AnyJSON = entry["linkedField"] ?? entry
            let field = lf["field"]?.stringValue ?? lf["fieldName"]?.stringValue ?? ""
            return .linkedField(LinkedFieldSpec(ref: parseRef(from: lf["ref"]), fieldName: field))
        case "header":
            return .header
        default:
            return nil
        }
    }

    /// Parse a single `{componentId, itemId}` ref. Returns nil when absent or
    /// malformed (so a linkedField can decode as "unlinked").
    static func parseRef(from json: AnyJSON?) -> ComponentItemRef? {
        guard let componentId = json?["componentId"]?.stringValue,
              let idString = json?["itemId"]?.stringValue,
              let uuid = UUID(uuidString: idString) else { return nil }
        return ComponentItemRef(componentId: componentId, itemId: uuid)
    }

    /// Parse a `list` row's spec — a sweep or a tracker column.
    private static func parseCalcListSpec(from json: AnyJSON?) -> CalcListSpec? {
        guard let obj = json?.objectValue else { return nil }
        switch obj["type"]?.stringValue {
        case "trackerColumn":
            var filter: [String: String] = [:]
            if let f = obj["filter"]?.objectValue { filter = f.compactMapValues(\.stringValue) }
            return .trackerColumn(
                sourceComponentId: obj["sourceComponentId"]?.stringValue ?? "",
                valueField: obj["valueField"]?.stringValue ?? "",
                labelField: obj["labelField"]?.stringValue,
                filter: filter
            )
        case "linkedCompare":
            return .linkedCompare(
                refs: parseLinkedItems(from: obj["refs"]),
                targetKey: obj["targetKey"]?.stringValue ?? "",
                linkedRowKey: obj["linkedRowKey"]?.stringValue ?? ""
            )
        case "linkedSweep":
            return .linkedSweep(
                refs: parseLinkedItems(from: obj["refs"]),
                linkedRowKey: obj["linkedRowKey"]?.stringValue ?? "",
                variableKey: obj["variableKey"]?.stringValue ?? "",
                from: obj["from"]?.doubleValue ?? 0,
                to: obj["to"]?.doubleValue ?? 0,
                step: obj["step"]?.doubleValue ?? 1,
                targetKey: obj["targetKey"]?.stringValue ?? ""
            )
        default: // "sweep"
            return .sweep(
                variableKey: obj["variableKey"]?.stringValue ?? "",
                from: obj["from"]?.doubleValue ?? 0,
                to: obj["to"]?.doubleValue ?? 0,
                step: obj["step"]?.doubleValue ?? 1,
                targetKey: obj["targetKey"]?.stringValue ?? ""
            )
        }
    }

    /// Parse the common row parts + kind off a row entry. Returns nil if the
    /// kind can't be parsed.
    static func parseCalcRowParts(
        from entry: AnyJSON
    ) -> (key: String?, name: String, unit: String?, format: String?, kind: CalcRowKind)? {
        guard let kind = parseCalcRowKind(from: entry) else { return nil }
        let key = entry["key"]?.stringValue
        let name = entry["name"]?.stringValue ?? key ?? ""
        return (key, name, entry["unit"]?.stringValue, entry["format"]?.stringValue, kind)
    }

    /// Parse a full `rows` array for `renderCalculator`, slug-deduping keys
    /// up front so the destructive render lands with unique handles.
    static func parseCalcRows(from json: AnyJSON?) -> [CalcRow] {
        guard let arr = json?.arrayValue else { return [] }
        var rows: [CalcRow] = []
        var keys = Set<String>()
        for entry in arr {
            guard let parts = parseCalcRowParts(from: entry) else { continue }
            let base = MyAppStore.slugify(parts.key?.nonEmpty ?? parts.name)
            let unique = MyAppStore.dedupeSlug(base, existing: keys)
            keys.insert(unique)
            rows.append(CalcRow(
                key: unique,
                name: parts.name.nonEmpty ?? unique,
                unit: parts.unit,
                format: parts.format,
                kind: parts.kind
            ))
        }
        return rows
    }

    static func parseCalcRowPatch(from json: AnyJSON?) -> MyAppStore.CalcRowPatch {
        var patch = MyAppStore.CalcRowPatch()
        guard let obj = json?.objectValue, let json else { return patch }
        if let v = obj["name"]?.stringValue { patch.name = v }
        // Double-optional: key present (even null) = set/clear; absent = unchanged.
        if obj["unit"] != nil { patch.unit = obj["unit"]?.stringValue }
        if obj["format"] != nil { patch.format = obj["format"]?.stringValue }
        if obj["kind"] != nil, let k = parseCalcRowKind(from: json) { patch.kind = k }
        return patch
    }

    private static func calcControlAsAnyJSON(_ control: CalcControl) -> AnyJSON {
        switch control {
        case .plain:
            return .object(["type": .string("plain")])
        case .stepper(let step):
            return .object(["type": .string("stepper"), "step": .double(step)])
        case .slider(let lo, let hi, let step):
            return .object([
                "type": .string("slider"),
                "min": .double(lo),
                "max": .double(hi),
                "step": .double(step),
            ])
        }
    }

    /// Serialise one calc row. `full` adds the complete kind spec (control /
    /// aggregate / expression); the list view omits it. The live-resolved
    /// `{value, status}` is always attached.
    static func calcRowAsAnyJSON(
        _ row: CalcRow,
        result: CalculatorResolver.RowResult?,
        full: Bool
    ) -> AnyJSON {
        var obj: [String: AnyJSON] = ["key": .string(row.key), "name": .string(row.name)]
        if let unit = row.unit { obj["unit"] = .string(unit) }
        if let format = row.format { obj["format"] = .string(format) }
        switch row.kind {
        case .variable(let value, let control):
            obj["kind"] = .string("variable")
            if full {
                obj["input"] = .double(value)
                obj["control"] = calcControlAsAnyJSON(control)
            }
        case .aggregate(let spec):
            obj["kind"] = .string("aggregate")
            if full {
                var agg: [String: AnyJSON] = [
                    "sourceComponentId": .string(spec.sourceComponentId),
                    "field": .string(spec.fieldName),
                    "reduce": .string(spec.reduce.rawValue),
                ]
                if !spec.filter.isEmpty { agg["filter"] = .object(spec.filter.mapValues { .string($0) }) }
                obj["aggregate"] = .object(agg)
            }
        case .formula(let expression):
            obj["kind"] = .string("formula")
            if full { obj["expression"] = .string(expression) }
        case .list(let spec):
            obj["kind"] = .string("list")
            if full { obj["list"] = calcListSpecAsAnyJSON(spec) }
        case .linkedField(let spec):
            obj["kind"] = .string("linkedField")
            if full {
                var lf: [String: AnyJSON] = ["field": .string(spec.fieldName)]
                if let ref = spec.ref { lf["ref"] = refAsAnyJSON(ref) }
                obj["linkedField"] = .object(lf)
            }
        case .header:
            obj["kind"] = .string("header")
        }
        if let result {
            obj["status"] = .string(result.status.rawValue)
            if let v = result.value { obj["value"] = .double(v) }
            // List rows carry no scalar value — echo the resolved point count.
            if let list = result.list { obj["listCount"] = .int(list.count) }
        }
        return .object(obj)
    }

    private static func calcListSpecAsAnyJSON(_ spec: CalcListSpec) -> AnyJSON {
        switch spec {
        case .sweep(let variableKey, let from, let to, let step, let targetKey):
            return .object([
                "type": .string("sweep"),
                "variableKey": .string(variableKey),
                "from": .double(from),
                "to": .double(to),
                "step": .double(step),
                "targetKey": .string(targetKey),
            ])
        case .trackerColumn(let sourceComponentId, let valueField, let labelField, let filter):
            var obj: [String: AnyJSON] = [
                "type": .string("trackerColumn"),
                "sourceComponentId": .string(sourceComponentId),
                "valueField": .string(valueField),
            ]
            if let labelField { obj["labelField"] = .string(labelField) }
            if !filter.isEmpty { obj["filter"] = .object(filter.mapValues { .string($0) }) }
            return .object(obj)
        case .linkedCompare(let refs, let targetKey, let linkedRowKey):
            return .object([
                "type": .string("linkedCompare"),
                "refs": .array(refs.map { refAsAnyJSON($0) }),
                "targetKey": .string(targetKey),
                "linkedRowKey": .string(linkedRowKey),
            ])
        case .linkedSweep(let refs, let linkedRowKey, let variableKey, let from, let to, let step, let targetKey):
            return .object([
                "type": .string("linkedSweep"),
                "refs": .array(refs.map { refAsAnyJSON($0) }),
                "linkedRowKey": .string(linkedRowKey),
                "variableKey": .string(variableKey),
                "from": .double(from),
                "to": .double(to),
                "step": .double(step),
                "targetKey": .string(targetKey),
            ])
        }
    }

    /// Serialise one `{componentId, itemId}` ref.
    private static func refAsAnyJSON(_ ref: ComponentItemRef) -> AnyJSON {
        .object(["componentId": .string(ref.componentId), "itemId": .string(ref.itemId.uuidString)])
    }

    // MARK: - Chart helpers

    @MainActor
    private static func chartData(_ store: MyAppStore, myAppId: UUID) -> (ChartData, String)? {
        guard case .resolved(let id) = store.resolveWriteTarget(kind: "chart", componentId: nil, myAppId: myAppId) else { return nil }
        return chartData(store, myAppId: myAppId, componentId: id)
    }

    /// Read a specific chart by id (to echo the correct component's state
    /// after a targeted write). Falls back to the view-independent lookup
    /// when `componentId` is nil.
    @MainActor
    private static func chartData(_ store: MyAppStore, myAppId: UUID, componentId: String?) -> (ChartData, String)? {
        guard let componentId else { return chartData(store, myAppId: myAppId) }
        guard let myApp = store.myApps.first(where: { $0.id == myAppId }),
              let comp = myApp.components.first(where: { $0.id == componentId }),
              case .chart(let cd) = comp.body else { return nil }
        return (cd, componentId)
    }

    /// `{ok, componentId, title, kind, seriesCount, pointCount}` for the
    /// resolved chart. Shared by every chart mutating tool.
    @MainActor
    static func chartEcho(store: MyAppStore, myAppId: UUID, componentId: String? = nil) -> AnyJSON {
        guard let (data, id) = chartData(store, myAppId: myAppId, componentId: componentId) else {
            return .object(["ok": .bool(false), "error": "no chart component"])
        }
        let count = ChartResolver.pointCount(data, components: siblingComponents(store: store, myAppId: myAppId))
        return .object([
            "ok": .bool(true),
            "componentId": .string(id),
            "title": .string(data.title),
            "kind": .string(data.kind.rawValue),
            "seriesCount": .int(data.series.count),
            "pointCount": .int(count),
        ])
    }

    static func chartSeriesSchema() -> AnyJSON {
        [
            "type": "object",
            "description": "One overlaid series: presentation + a data source.",
            "properties": [
                "name": ["type": "string", "description": "Legend label; defaults from the source."],
                "colorHex": ["type": "string", "description": "Override colour as #RRGGBB; omit to auto-assign a distinct colour."],
                "source": chartSourceSchema(),
            ],
            "required": ["source"],
        ]
    }

    private static func chartSourceSchema() -> AnyJSON {
        [
            "type": "object",
            "description": "One of tracker | calculatorRows | calculatorList | calculatorLinkedSweep | inline (see `type`).",
            "properties": [
                "type": ["type": "string", "enum": ["tracker", "calculatorRows", "calculatorList", "calculatorLinkedSweep", "inline"]],
                "componentId": ["type": "string", "description": "tracker / calculatorRows / calculatorList / calculatorLinkedSweep: source component id."],
                "groupBy": ["type": "string", "description": "tracker: field whose value buckets the points (sector / x tick)."],
                "valueField": ["type": "string", "description": "tracker: numeric field reduced per bucket."],
                "reduce": ["type": "string", "enum": ["sum", "avg", "min", "max", "count"]],
                "filter": ["type": "object", "description": "tracker: case-insensitive AND equality filter, e.g. {\"cuisine\":\"African\"}."],
                "xIsNumericOrDate": ["type": "boolean", "description": "tracker: treat the group value as a numeric/date x axis (ascending) for bar/line."],
                "keys": ["type": "array", "items": ["type": "string"], "description": "calculatorRows: calculator row keys to plot."],
                "key": ["type": "string", "description": "calculatorList: a `.list` row key (one series). calculatorLinkedSweep: a `.linkedSweep` row key (fans out to one line per linked ref)."],
                "points": [
                    "type": "array",
                    "description": "inline: literal points.",
                    "items": [
                        "type": "object",
                        "properties": [
                            "label": ["type": "string"],
                            "x": ["type": "number"],
                            "y": ["type": "number"],
                        ],
                        "required": ["label", "y"],
                    ],
                ],
            ],
            "required": ["type"],
        ]
    }

    /// Parse a `chart` argument ({title, kind, series}) into `ChartData`, or
    /// nil when it's absent / missing a title or a known kind. Shared by both
    /// embedComponent host branches.
    private static func parseChartData(from json: AnyJSON?) -> ChartData? {
        guard let json, case .object = json,
              let title = json["title"]?.stringValue,
              let kindRaw = json["kind"]?.stringValue,
              let kind = ChartKind(rawValue: kindRaw) else { return nil }
        return ChartData(title: title, kind: kind, series: parseChartSeries(from: json["series"]))
    }

    /// Round-trip any `Encodable` through JSON into an `AnyJSON` for tool
    /// results. Returns `.null` if encoding fails (never throws into a handler).
    private static func encodableAsAnyJSON(_ value: some Encodable) -> AnyJSON {
        guard let data = try? JSONEncoder().encode(value),
              let json = try? JSONDecoder().decode(AnyJSON.self, from: data) else { return .null }
        return json
    }

    /// Parse a `series` array into `[ChartSeriesSpec]`. Entries without a
    /// parseable source are skipped.
    static func parseChartSeries(from json: AnyJSON?) -> [ChartSeriesSpec] {
        guard let arr = json?.arrayValue else { return [] }
        return arr.map { entry in
            ChartSeriesSpec(
                name: entry["name"]?.stringValue,
                colorHex: entry["colorHex"]?.stringValue,
                source: parseChartSource(from: entry["source"] ?? entry)
            )
        }
    }

    /// Parse a chart `source` JSON object into a `ChartSeriesSource`. Unknown
    /// / missing `type` degrades to an empty inline source so the chart
    /// renders a placeholder rather than failing the tool call.
    private static func parseChartSource(from json: AnyJSON?) -> ChartSeriesSource {
        guard let obj = json?.objectValue, let type = obj["type"]?.stringValue else {
            return .inline(points: [])
        }
        switch type {
        case "tracker":
            var filter: [String: String] = [:]
            if let f = obj["filter"]?.objectValue { filter = f.compactMapValues(\.stringValue) }
            return .tracker(
                componentId: obj["componentId"]?.stringValue ?? "",
                groupBy: obj["groupBy"]?.stringValue ?? "",
                valueField: obj["valueField"]?.stringValue ?? obj["field"]?.stringValue ?? "",
                reduce: CalcReduce(rawValue: obj["reduce"]?.stringValue ?? "sum") ?? .sum,
                filter: filter,
                xIsNumericOrDate: obj["xIsNumericOrDate"]?.boolValue ?? false
            )
        case "calculatorRows":
            let keys = obj["keys"]?.arrayValue?.compactMap(\.stringValue) ?? []
            return .calculatorRows(componentId: obj["componentId"]?.stringValue ?? "", keys: keys)
        case "calculatorList":
            return .calculatorList(componentId: obj["componentId"]?.stringValue ?? "", key: obj["key"]?.stringValue ?? "")
        case "calculatorLinkedSweep":
            return .calculatorLinkedSweep(componentId: obj["componentId"]?.stringValue ?? "", key: obj["key"]?.stringValue ?? "")
        default: // "inline"
            let points: [ChartPoint] = (obj["points"]?.arrayValue ?? []).compactMap { p in
                guard let y = p["y"]?.doubleValue else { return nil }
                return ChartPoint(label: p["label"]?.stringValue ?? "", x: p["x"]?.doubleValue, y: y)
            }
            return .inline(points: points)
        }
    }

    static func valuesAsAnyJSON(_ values: [String: String]) -> AnyJSON {
        .object(values.mapValues { .string($0) })
    }

    static func fieldAsAnyJSON(_ field: FieldDef) -> AnyJSON {
        var obj: [String: AnyJSON] = [
            "name": .string(field.name),
            "type": .string(field.type.rawValue),
        ]
        if let label = field.label { obj["label"] = .string(label) }
        if let opts = field.options { obj["options"] = .array(opts.map { .string($0) }) }
        if let hidden = field.hidden, hidden { obj["hidden"] = .bool(true) }
        return .object(obj)
    }

    /// Serialise the multi-component canvas the agent sees. Shape is
    /// `{components: [{id, name, iconSystemName, body: {kind, data}}],
    /// activeComponentId}`. Round-tripped through Codable so the structure
    /// is identical to what `MyApp` persists and what `ChatViewModel`
    /// injects into "Live canvas state".
    @MainActor
    private static func canvasAsAnyJSON(_ store: MyAppStore, myAppId: UUID) -> AnyJSON {
        guard let myApp = store.myApps.first(where: { $0.id == myAppId }) else {
            return .object(["components": .array([]), "activeComponentId": .null])
        }
        struct CanvasSnapshot: Encodable {
            var components: [Component]
            var activeComponentId: String?
        }
        let snap = CanvasSnapshot(
            components: myApp.components,
            activeComponentId: myApp.activeComponentId
        )
        guard let data = try? JSONEncoder().encode(snap),
              let json = try? JSONDecoder().decode(AnyJSON.self, from: data) else {
            return .object(["components": .array([])])
        }
        return json
    }

    static func visibleCount(_ tracker: TrackerData?) -> Int {
        guard let t = tracker else { return 0 }
        if t.filter.isEmpty { return t.items.count }
        return t.items.filter { item in
            t.filter.allSatisfy { (k, v) in item.values[k] == v }
        }.count
    }

    // MARK: - Tool gate tools

    /// Register one `get_tools_<kind>` gateway tool per component kind declared
    /// by `myAppType`, plus a `get_tools_memories` gate for the memory
    /// filesystem. Called only for `.myApp` sessions.
    ///
    /// Before the agent activates a tool group, only the gate tool is advertised
    /// (via `ChatViewModel.allowedToolNames`). Calling the gate marks the tool group
    /// as active in `toolGateState`; on the next agent round the full tool set for
    /// that kind replaces the gate in the advertised surface.
    @MainActor
    public static func registerToolGates(
        on registry: ToolRegistry,
        myAppType: MyAppType,
        toolGateState: ToolGateState
    ) {
        for kind in myAppType.toolNamesByKind.keys.sorted() {
            let toolCount = myAppType.toolNamesByKind[kind]?.count ?? 0
            let toolList = myAppType.toolNamesByKind[kind]?.sorted().joined(separator: ", ") ?? ""
            let toolName = "get_tools_\(kind)"
            registry.register(ClientTool(
                descriptor: ToolDescriptor(
                    name: toolName,
                    description: "Activate the \(kind) tools. Call once to unlock \(toolCount) \(kind) tools (\(toolList)) from the next agent round onward.",
                    parameters: ["type": "object", "properties": [:]]
                ),
                handler: { [weak toolGateState] _ in
                    guard let toolGateState else {
                        return .object(["ok": .bool(false), "error": .string("tool gate state unavailable")])
                    }
                    await MainActor.run { toolGateState.activate(kind: kind) }
                    return .object([
                        "ok": .bool(true),
                        "activated": .string(kind),
                        "toolsUnlocked": .int(toolCount),
                    ])
                }
            ))
        }

        let memCount = MyAppType.memoryToolNames.count
        registry.register(ClientTool(
            descriptor: ToolDescriptor(
                name: "get_tools_memories",
                description: "Activate the memories tools. Call once to unlock \(memCount) memory filesystem tools (lsMemories, readMemoryFile, writeMemoryFile, …) from the next agent round onward.",
                parameters: ["type": "object", "properties": [:]]
            ),
            readOnly: true,
            handler: { [weak toolGateState] _ in
                guard let toolGateState else {
                    return .object(["ok": .bool(false), "error": .string("tool gate state unavailable")])
                }
                await MainActor.run { toolGateState.activateMemories() }
                return .object([
                    "ok": .bool(true),
                    "activated": .string("memories"),
                    "toolsUnlocked": .int(memCount),
                ])
            }
        ))
    }
}
