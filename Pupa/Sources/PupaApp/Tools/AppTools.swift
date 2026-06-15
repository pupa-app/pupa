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
        registry.register(ClientTool(
            descriptor: ToolDescriptor(
                name: "renderTracker",
                description: """
                Render a tracker and/or set its `summary`. \
                `title` + `fields` = DESTRUCTIVE full render (RESETS items) — \
                only for fresh starts; for schema edits on a populated tracker \
                use add/rename/reorder/hideTrackerField. Field types: \
                text/number/select (options for known enums)/image (URL or \
                emoji → card hero)/link (clickable pill). \
                `summary` alone = update content note without re-render. \
                Result: {fields, totalItems, summarySet?}.
                """,
                parameters: trackerSchema()
            ),
            handler: { args in
                let titleArg = args["title"]?.stringValue
                let fieldsArg = args["fields"]
                let summaryArg = args["summary"]
                let hasSummary = summaryArg != nil
                let hasBodyArgs = titleArg != nil || fieldsArg != nil
                return await MainActor.run {
                    if hasBodyArgs {
                        guard let title = titleArg, fieldsArg != nil else {
                            return .object([
                                "ok": .bool(false),
                                "error": "renderTracker requires BOTH `title` and `fields` for a full render. Pass only `summary` to update your content summary without re-rendering.",
                            ])
                        }
                        let fields = parseFields(from: fieldsArg)
                        store.setTracker(title: title, fields: fields, myAppId: myAppId)
                    }
                    var summarySet = false
                    if hasSummary {
                        summarySet = store.setComponentSummary(
                            forKind: "tracker",
                            summary: summaryArg?.stringValue,
                            myAppId: myAppId
                        )
                    }
                    guard hasBodyArgs || hasSummary else {
                        return .object([
                            "ok": .bool(false),
                            "error": "renderTracker called with no arguments. Pass `title` + `fields` for a full render and/or `summary` to update your content summary.",
                        ])
                    }
                    let t = tracker(store, myAppId: myAppId)
                    var result: [String: AnyJSON] = ["ok": .bool(true)]
                    if let t {
                        result["fields"] = .array(t.fields.map { .string($0.name) })
                        result["totalItems"] = .int(t.items.count)
                    }
                    if hasSummary {
                        result["summarySet"] = .bool(summarySet)
                    }
                    return .object(result)
                }
            }
        ))

        registry.register(ClientTool(
            descriptor: ToolDescriptor(
                name: "addTrackerItems",
                description: """
                Append one or more items to the current tracker. Always pass \
                an `items` array — wrap a single item as `[{ ... }]`. Keys \
                in each item must match field names. Result echoes \
                {ids, added, totalItems}; `ids` are in the same order as \
                `items` and are stable UUIDs to pass to `patchTrackerItems` \
                / `removeTrackerItems` later.
                """,
                parameters: [
                    "type": "object",
                    "properties": [
                        "items": [
                            "type": "array",
                            "items": ["type": "object"],
                        ],
                    ],
                    "required": ["items"],
                ]
            ),
            handler: { args in
                guard let itemsArray = args["items"]?.arrayValue else {
                    return .object(["ok": .bool(false), "error": "missing 'items' array"])
                }
                return await MainActor.run {
                    var ids: [AnyJSON] = []
                    var added: [AnyJSON] = []
                    for entry in itemsArray {
                        let values = (entry.objectValue ?? [:]).mapValues { stringify($0) }
                        let id = store.addItem(values, myAppId: myAppId, actor: .agent(toolName: "addTrackerItems"))
                        ids.append(id.map { .string($0.uuidString) } ?? .null)
                        added.append(valuesAsAnyJSON(values))
                    }
                    return .object([
                        "ok": .bool(true),
                        "ids": .array(ids),
                        "added": .array(added),
                        "totalItems": .int(tracker(store, myAppId: myAppId)?.items.count ?? 0),
                    ])
                }
            }
        ))

        registry.register(ClientTool(
            descriptor: ToolDescriptor(
                name: "patchTrackerItems",
                description: """
                Edit fields on one or more items. Always pass a `patches` \
                array — wrap a single edit as `[{ ... }]`. Each entry \
                identifies its target with `id` (preferred — stable UUID) \
                or `index` (0-based; indices shift under filter / reorder, \
                so id is safer for bulk edits). `patch` is merged into the \
                item. Per-entry failures don't abort the batch; result \
                echoes {results: [{id, item, ok, error?}, ...], totalItems} \
                in the same order as `patches`. Overall `ok` is true only \
                if every entry succeeded.
                """,
                parameters: [
                    "type": "object",
                    "properties": [
                        "patches": [
                            "type": "array",
                            "items": [
                                "type": "object",
                                "properties": [
                                    "id": ["type": "string"],
                                    "index": ["type": "integer", "minimum": 0],
                                    "patch": ["type": "object"],
                                ],
                                "required": ["patch"],
                            ],
                        ],
                    ],
                    "required": ["patches"],
                ]
            ),
            handler: { args in
                guard let patchArray = args["patches"]?.arrayValue else {
                    return .object(["ok": .bool(false), "error": "missing 'patches' array"])
                }
                return await MainActor.run {
                    var results: [AnyJSON] = []
                    var allOk = true
                    for entry in patchArray {
                        let obj = entry.objectValue ?? [:]
                        guard let patchObj = obj["patch"]?.objectValue else {
                            results.append(.object([
                                "ok": .bool(false),
                                "error": .string("missing 'patch'"),
                            ]))
                            allOk = false
                            continue
                        }
                        let patch = patchObj.mapValues { stringify($0) }
                        let idString = obj["id"]?.stringValue
                        let idx = obj["index"]?.intValue
                        guard let t = tracker(store, myAppId: myAppId) else {
                            results.append(.object([
                                "ok": .bool(false),
                                "error": .string("canvas is not a tracker"),
                            ]))
                            allOk = false
                            continue
                        }
                        if let idString,
                           let uuid = UUID(uuidString: idString),
                           t.items.contains(where: { $0.id == uuid }) {
                            _ = store.patchItem(id: uuid, with: patch, myAppId: myAppId, actor: .agent(toolName: "patchTrackerItems"))
                            let after = tracker(store, myAppId: myAppId)?
                                .items.first(where: { $0.id == uuid })?.values ?? [:]
                            results.append(.object([
                                "ok": .bool(true),
                                "id": .string(uuid.uuidString),
                                "item": valuesAsAnyJSON(after),
                            ]))
                            continue
                        }
                        if let idx, t.items.indices.contains(idx) {
                            let item = t.items[idx]
                            store.patchItem(at: idx, with: patch, myAppId: myAppId, actor: .agent(toolName: "patchTrackerItems"))
                            let after = tracker(store, myAppId: myAppId)?
                                .items.first(where: { $0.id == item.id })?.values ?? [:]
                            results.append(.object([
                                "ok": .bool(true),
                                "id": .string(item.id.uuidString),
                                "item": valuesAsAnyJSON(after),
                            ]))
                            continue
                        }
                        results.append(.object([
                            "ok": .bool(false),
                            "error": .string(idString != nil ? "no item with id" : "missing id or valid index"),
                        ]))
                        allOk = false
                    }
                    return .object([
                        "ok": .bool(allOk),
                        "results": .array(results),
                        "totalItems": .int(tracker(store, myAppId: myAppId)?.items.count ?? 0),
                    ])
                }
            }
        ))

        registry.register(ClientTool(
            descriptor: ToolDescriptor(
                name: "removeTrackerItems",
                description: """
                Remove one or more items. Always pass a `targets` array — \
                wrap a single removal as `[{ ... }]`. Each target identifies \
                its row with `id` (preferred — stable UUID) or `index` \
                (0-based). Indices are resolved to UUIDs BEFORE any removal \
                so caller-supplied indices don't shift mid-batch. \
                Per-target failures don't abort; result echoes \
                {results: [{id, removed, ok, error?}, ...], totalItems} in \
                the same order as `targets`. Overall `ok` is true only if \
                every target was removed.
                """,
                parameters: [
                    "type": "object",
                    "properties": [
                        "targets": [
                            "type": "array",
                            "items": [
                                "type": "object",
                                "properties": [
                                    "id": ["type": "string"],
                                    "index": ["type": "integer", "minimum": 0],
                                ],
                            ],
                        ],
                    ],
                    "required": ["targets"],
                ]
            ),
            handler: { args in
                guard let targetArray = args["targets"]?.arrayValue else {
                    return .object(["ok": .bool(false), "error": "missing 'targets' array"])
                }
                return await MainActor.run {
                    guard let t = tracker(store, myAppId: myAppId) else {
                        return .object(["ok": .bool(false), "error": "canvas is not a tracker"])
                    }
                    // Resolve every target to a UUID + cached values BEFORE
                    // any remove, so caller-supplied indices don't shift
                    // under earlier removals in the same batch.
                    enum Resolved { case ok(UUID, [String: String]); case fail(String) }
                    let resolved: [Resolved] = targetArray.map { entry in
                        let obj = entry.objectValue ?? [:]
                        if let idString = obj["id"]?.stringValue,
                           let uuid = UUID(uuidString: idString),
                           let item = t.items.first(where: { $0.id == uuid }) {
                            return .ok(uuid, item.values)
                        }
                        if let idx = obj["index"]?.intValue,
                           t.items.indices.contains(idx) {
                            let item = t.items[idx]
                            return .ok(item.id, item.values)
                        }
                        return .fail(obj["id"]?.stringValue != nil ? "no item with id" : "missing id or valid index")
                    }

                    var results: [AnyJSON] = []
                    var allOk = true
                    for r in resolved {
                        switch r {
                        case .ok(let uuid, let values):
                            let ok = store.removeItem(id: uuid, myAppId: myAppId, actor: .agent(toolName: "removeTrackerItems"))
                            if ok {
                                results.append(.object([
                                    "ok": .bool(true),
                                    "id": .string(uuid.uuidString),
                                    "removed": valuesAsAnyJSON(values),
                                ]))
                            } else {
                                results.append(.object([
                                    "ok": .bool(false),
                                    "id": .string(uuid.uuidString),
                                    "error": .string("remove failed"),
                                ]))
                                allOk = false
                            }
                        case .fail(let msg):
                            results.append(.object([
                                "ok": .bool(false),
                                "error": .string(msg),
                            ]))
                            allOk = false
                        }
                    }
                    return .object([
                        "ok": .bool(allOk),
                        "results": .array(results),
                        "totalItems": .int(tracker(store, myAppId: myAppId)?.items.count ?? 0),
                    ])
                }
            }
        ))

        registry.register(ClientTool(
            descriptor: ToolDescriptor(
                name: "setTrackerFilter",
                description: """
                Set or clear a select-field filter. Empty value clears that field's \
                filter. Result echoes {filter, visibleCount, totalItems}.
                """,
                parameters: [
                    "type": "object",
                    "properties": [
                        "field": ["type": "string"],
                        "value": ["type": "string"],
                    ],
                    "required": ["field", "value"],
                ]
            ),
            handler: { args in
                let field = args["field"]?.stringValue ?? ""
                let value = args["value"]?.stringValue ?? ""
                return await MainActor.run {
                    store.setFilter(field: field, value: value, myAppId: myAppId)
                    let t = tracker(store, myAppId: myAppId)
                    return .object([
                        "ok": .bool(true),
                        "filter": .object((t?.filter ?? [:]).mapValues { .string($0) }),
                        "visibleCount": .int(visibleCount(t)),
                        "totalItems": .int(t?.items.count ?? 0),
                    ])
                }
            }
        ))

        registry.register(ClientTool(
            descriptor: ToolDescriptor(
                name: "setTrackerViewMode",
                description: """
                Switch the tracker's rendering between 'grid' (adaptive card \
                grid) and 'kanban' (Jira-style swimlanes). Same data — only \
                the view changes. Kanban groups items into columns by one \
                select field's options; pass `columnField` to choose which \
                one, or omit to keep the existing choice / auto-pick the \
                first usable select field. Use this when the user asks to \
                see progress / status / board / kanban / columns / by \
                <select-field>. Result echoes {mode, columnField, totalItems}. \
                If `columnField` resolves to null (no select fields exist) \
                the kanban renders an empty-state hint — adding a select \
                field via renderTracker + addFieldOption then switching \
                mode again will populate the columns.
                """,
                parameters: [
                    "type": "object",
                    "properties": [
                        "mode": ["type": "string", "enum": ["grid", "kanban"]],
                        "columnField": ["type": "string"],
                    ],
                    "required": ["mode"],
                ]
            ),
            handler: { args in
                let modeRaw = args["mode"]?.stringValue ?? ""
                let requestedColumn = args["columnField"]?.stringValue
                guard let mode = TrackerViewMode(rawValue: modeRaw) else {
                    return .object([
                        "ok": .bool(false),
                        "error": .string("invalid mode '\(modeRaw)' (expected 'grid' or 'kanban')"),
                    ])
                }
                return await MainActor.run {
                    guard let resolved = store.setTrackerViewMode(
                        mode,
                        columnField: requestedColumn,
                        myAppId: myAppId
                    ) else {
                        return .object([
                            "ok": .bool(false),
                            "error": .string("canvas is not a tracker"),
                        ])
                    }
                    let t = tracker(store, myAppId: myAppId)
                    return .object([
                        "ok": .bool(true),
                        "mode": .string(resolved.mode.rawValue),
                        "columnField": resolved.columnField.map { .string($0) } ?? .null,
                        "totalItems": .int(t?.items.count ?? 0),
                    ])
                }
            }
        ))

        registry.register(ClientTool(
            descriptor: ToolDescriptor(
                name: "addFieldOption",
                description: """
                Add a new option to a select-type field's options array. Result echoes \
                {fieldName, options}.
                """,
                parameters: [
                    "type": "object",
                    "properties": [
                        "fieldName": ["type": "string"],
                        "option": ["type": "string"],
                    ],
                    "required": ["fieldName", "option"],
                ]
            ),
            handler: { args in
                let field = args["fieldName"]?.stringValue ?? ""
                let opt = args["option"]?.stringValue ?? ""
                return await MainActor.run {
                    let ok = store.addFieldOption(fieldName: field, option: opt, myAppId: myAppId)
                    let t = tracker(store, myAppId: myAppId)
                    let opts = t?.fields.first(where: { $0.name == field })?.options ?? []
                    return .object([
                        "ok": .bool(ok),
                        "fieldName": .string(field),
                        "options": .array(opts.map { .string($0) }),
                    ])
                }
            }
        ))

        registry.register(ClientTool(
            descriptor: ToolDescriptor(
                name: "removeFieldOption",
                description: """
                Remove an option from a select-type field's options array. Result \
                echoes {fieldName, options}.
                """,
                parameters: [
                    "type": "object",
                    "properties": [
                        "fieldName": ["type": "string"],
                        "option": ["type": "string"],
                    ],
                    "required": ["fieldName", "option"],
                ]
            ),
            handler: { args in
                let field = args["fieldName"]?.stringValue ?? ""
                let opt = args["option"]?.stringValue ?? ""
                return await MainActor.run {
                    let ok = store.removeFieldOption(fieldName: field, option: opt, myAppId: myAppId)
                    let t = tracker(store, myAppId: myAppId)
                    let opts = t?.fields.first(where: { $0.name == field })?.options ?? []
                    return .object([
                        "ok": .bool(ok),
                        "fieldName": .string(field),
                        "options": .array(opts.map { .string($0) }),
                    ])
                }
            }
        ))

        registry.register(ClientTool(
            descriptor: ToolDescriptor(
                name: "addTrackerField",
                description: """
                Append a new field to the current tracker — non-destructive, every \
                existing item keeps its data. Existing items render the new column \
                as empty until you patch them. Use this for any "add a category / \
                price / status / link / image column" request on a tracker that \
                already has items; do NOT call renderTracker for that, since it \
                wipes items. Reject if `name` already exists on another field. \
                Result echoes {field, fieldsCount, totalItems}.
                """,
                parameters: [
                    "type": "object",
                    "properties": [
                        "name": ["type": "string"],
                        "label": ["type": "string"],
                        "type": ["type": "string", "enum": ["text", "number", "select", "image", "link"]],
                        "options": ["type": "array", "items": ["type": "string"]],
                    ],
                    "required": ["name", "type"],
                ]
            ),
            handler: { args in
                guard let name = args["name"]?.stringValue,
                      let typeRaw = args["type"]?.stringValue,
                      let type = FieldType(rawValue: typeRaw) else {
                    return .object(["ok": .bool(false), "error": "missing 'name' or invalid 'type'"])
                }
                let field = FieldDef(
                    name: name,
                    label: args["label"]?.stringValue,
                    type: type,
                    options: args["options"]?.arrayValue?.compactMap(\.stringValue)
                )
                return await MainActor.run {
                    if let err = store.addField(field, myAppId: myAppId) {
                        return .object([
                            "ok": .bool(false),
                            "error": .string(err.rawValue),
                        ])
                    }
                    let t = tracker(store, myAppId: myAppId)
                    return .object([
                        "ok": .bool(true),
                        "field": fieldAsAnyJSON(field),
                        "fieldsCount": .int(t?.fields.count ?? 0),
                        "totalItems": .int(t?.items.count ?? 0),
                    ])
                }
            }
        ))

        registry.register(ClientTool(
            descriptor: ToolDescriptor(
                name: "renameTrackerField",
                description: """
                Atomically rename a field. Every existing item's value for `from` \
                is re-keyed under `to` so no data is orphaned; the matching entry \
                in `filter` is remapped, and `columnField` is remapped if it \
                pointed at the renamed field. Rejects if `to` already exists on \
                another field. Result echoes {from, to, migratedItems, \
                remappedFilter, remappedColumnField, fields: [name]}.
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
                    switch store.renameField(from: from, to: to, myAppId: myAppId) {
                    case .failure(let err):
                        return .object([
                            "ok": .bool(false),
                            "error": .string(err.rawValue),
                        ])
                    case .success(let result):
                        let t = tracker(store, myAppId: myAppId)
                        return .object([
                            "ok": .bool(true),
                            "from": .string(from),
                            "to": .string(to),
                            "migratedItems": .int(result.migratedItems),
                            "remappedFilter": .bool(result.remappedFilter),
                            "remappedColumnField": .bool(result.remappedColumnField),
                            "fields": .array((t?.fields ?? []).map { .string($0.name) }),
                        ])
                    }
                }
            }
        ))

        registry.register(ClientTool(
            descriptor: ToolDescriptor(
                name: "reorderTrackerFields",
                description: """
                Reorder the tracker's fields. `order` must be a permutation of \
                the current field names (same set, same length, no duplicates). \
                Items are not touched. Result echoes {order: [name]}.
                """,
                parameters: [
                    "type": "object",
                    "properties": [
                        "order": ["type": "array", "items": ["type": "string"]],
                    ],
                    "required": ["order"],
                ]
            ),
            handler: { args in
                let order = args["order"]?.arrayValue?.compactMap(\.stringValue) ?? []
                return await MainActor.run {
                    if let err = store.reorderFields(order, myAppId: myAppId) {
                        return .object([
                            "ok": .bool(false),
                            "error": .string(err.rawValue),
                        ])
                    }
                    let t = tracker(store, myAppId: myAppId)
                    return .object([
                        "ok": .bool(true),
                        "order": .array((t?.fields ?? []).map { .string($0.name) }),
                    ])
                }
            }
        ))

        registry.register(ClientTool(
            descriptor: ToolDescriptor(
                name: "hideTrackerField",
                description: """
                Soft-hide a field. The column disappears from the form / cards / \
                filter / kanban group-by, but each item's value for that field \
                stays on disk — so calling showTrackerField later restores the \
                view with all data intact. This is the ONLY removal verb on a \
                tracker field — there is no hard-delete. If the field had an \
                active filter entry it is dropped (a hidden filter would silently \
                hide items). Result echoes {name, hidden:true, \
                droppedFilterValue?}.
                """,
                parameters: [
                    "type": "object",
                    "properties": ["name": ["type": "string"]],
                    "required": ["name"],
                ]
            ),
            handler: { args in
                let name = args["name"]?.stringValue ?? ""
                return await MainActor.run {
                    switch store.setFieldHidden(name: name, hidden: true, myAppId: myAppId) {
                    case .failure(let err):
                        return .object([
                            "ok": .bool(false),
                            "error": .string(err.rawValue),
                        ])
                    case .success(let result):
                        var payload: [String: AnyJSON] = [
                            "ok": .bool(true),
                            "name": .string(name),
                            "hidden": .bool(result.hidden),
                        ]
                        if let dropped = result.droppedFilterValue {
                            payload["droppedFilterValue"] = .string(dropped)
                        }
                        return .object(payload)
                    }
                }
            }
        ))

        registry.register(ClientTool(
            descriptor: ToolDescriptor(
                name: "showTrackerField",
                description: """
                Un-hide a previously hidden field. Item values for that field are \
                preserved across hide / show, so the column reappears with the \
                same data it had before hiding. Result echoes {name, hidden:false}.
                """,
                parameters: [
                    "type": "object",
                    "properties": ["name": ["type": "string"]],
                    "required": ["name"],
                ]
            ),
            handler: { args in
                let name = args["name"]?.stringValue ?? ""
                return await MainActor.run {
                    switch store.setFieldHidden(name: name, hidden: false, myAppId: myAppId) {
                    case .failure(let err):
                        return .object([
                            "ok": .bool(false),
                            "error": .string(err.rawValue),
                        ])
                    case .success(let result):
                        return .object([
                            "ok": .bool(true),
                            "name": .string(name),
                            "hidden": .bool(result.hidden),
                        ])
                    }
                }
            }
        ))

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
                Each entry includes: id, kind (added/patched/removed/linked/unlinked), \
                actor ({kind: user|agent, toolName?}), summary (human-readable one-liner), \
                reversible (bool — true if undo is currently possible), reason (why not \
                reversible, if applicable), undone (bool), isUndo (bool), timestamp (ISO-8601). \
                Supports pagination via offset + limit (default 20, max 100). \
                Use before calling undoChanges to identify event ids.
                """,
                parameters: [
                    "type": "object",
                    "properties": [
                        "offset": ["type": "integer", "description": "Skip the first N events (default 0)."],
                        "limit": ["type": "integer", "description": "Max events to return (default 20, max 100)."]
                    ]
                ]
            ),
            handler: { args in
                let offset = max(0, args["offset"]?.intValue ?? 0)
                let limit = min(100, max(1, args["limit"]?.intValue ?? 20))
                let result: AnyJSON = await MainActor.run {
                    let all = store.itemEventLog.events(forMyApp: myAppId)
                    let reversed = Array(all.reversed())
                    let total = reversed.count
                    let slice = Array(reversed.dropFirst(offset).prefix(limit))
                    let changes: [AnyJSON] = slice.map { event in
                        let inv = event.inverse()
                        let reversible = inv != nil && !event.undone && !event.isUndo
                        let actorObj: AnyJSON
                        switch event.actor {
                        case .user:
                            actorObj = .object(["kind": .string("user")])
                        case .agent(let toolName):
                            actorObj = .object(["kind": .string("agent"), "toolName": .string(toolName)])
                        }
                        var entry: [String: AnyJSON] = [
                            "id": .string(event.id.uuidString),
                            "kind": .string(event.kind.rawValue),
                            "actor": actorObj,
                            "summary": .string(store.changeSummary(for: event)),
                            "reversible": .bool(reversible),
                            "undone": .bool(event.undone),
                            "isUndo": .bool(event.isUndo),
                            "timestamp": .string(ISO8601DateFormatter().string(from: event.timestamp))
                        ]
                        if !reversible, event.undone {
                            entry["reason"] = .string("Already undone.")
                        } else if !reversible, event.isUndo {
                            entry["reason"] = .string("Undo events cannot themselves be undone.")
                        } else if !reversible, inv == nil {
                            entry["reason"] = .string("No recorded inverse (legacy event).")
                        }
                        return .object(entry)
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

        registry.register(ClientTool(
            descriptor: ToolDescriptor(
                name: "undoChanges",
                description: """
                Reverse one or more item/component mutations by event id or by undoing the N \
                most-recent reversible events. Provide EITHER eventIds OR count — not both. \
                Returns a per-entry result array; partial success is possible. \
                Error codes: event_not_found, already_undone, not_reversible, \
                item_no_longer_exists, component_no_longer_exists, inconsistent_state. \
                Call listChanges first to identify reversible event ids.
                """,
                parameters: [
                    "type": "object",
                    "properties": [
                        "eventIds": [
                            "type": "array",
                            "items": ["type": "string"],
                            "description": "UUIDs of specific events to undo (newest-first recommended)."
                        ],
                        "count": [
                            "type": "integer",
                            "description": "Undo the N most-recent reversible events instead of named ids."
                        ]
                    ]
                ]
            ),
            handler: { args in
                let result: AnyJSON = await MainActor.run {
                    let targetIds: [UUID]
                    if let idsArg = args["eventIds"]?.arrayValue {
                        targetIds = idsArg.compactMap { $0.stringValue.flatMap(UUID.init) }
                    } else if let count = args["count"]?.intValue, count > 0 {
                        let reversible = store.itemEventLog.events(forMyApp: myAppId)
                            .reversed()
                            .filter { !$0.undone && !$0.isUndo && $0.inverse() != nil }
                            .prefix(count)
                        targetIds = reversible.map(\.id)
                    } else {
                        return .object(["ok": .bool(false), "error": .string("Provide eventIds or count.")])
                    }
                    let results: [AnyJSON] = targetIds.map { eventId in
                        let undoResult = store.undo(eventId: eventId)
                        switch undoResult {
                        case .success:
                            return .object(["eventId": .string(eventId.uuidString), "ok": .bool(true)])
                        case .failure(let err):
                            return .object([
                                "eventId": .string(eventId.uuidString),
                                "ok": .bool(false),
                                "error": .string(err.stableCode)
                            ])
                        }
                    }
                    let allOk = results.allSatisfy {
                        if case .object(let d) = $0, case .bool(let b) = d["ok"] { return b }
                        return false
                    }
                    return .object([
                        "ok": .bool(allOk),
                        "results": .array(results)
                    ])
                }
                return result
            }
        ))
    }

    // MARK: - Tracker discovery tools

    @MainActor
    private static func registerTrackerDiscoveryTools(
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

    @MainActor
    private static func resolveTracker(
        store: MyAppStore,
        myAppId: UUID,
        componentId: String?
    ) -> (TrackerData, String)? {
        guard let myApp = store.myApps.first(where: { $0.id == myAppId }) else { return nil }
        if let componentId {
            guard let component = myApp.components.first(where: { $0.id == componentId }),
                  case .tracker(let t) = component.body else { return nil }
            return (t, componentId)
        }
        let activeIdx = myApp.activeComponentId.flatMap { id in
            myApp.components.firstIndex(where: { $0.id == id })
        }
        if let activeIdx, case .tracker(let t) = myApp.components[activeIdx].body {
            return (t, myApp.components[activeIdx].id)
        }
        for component in myApp.components {
            if case .tracker(let t) = component.body { return (t, component.id) }
        }
        return nil
    }

    @MainActor
    private static func resolveCalendar(
        store: MyAppStore,
        myAppId: UUID,
        componentId: String?
    ) -> (CalendarData, String)? {
        guard let myApp = store.myApps.first(where: { $0.id == myAppId }) else { return nil }
        if let componentId {
            guard let component = myApp.components.first(where: { $0.id == componentId }),
                  case .calendar(let c) = component.body else { return nil }
            return (c, componentId)
        }
        let activeIdx = myApp.activeComponentId.flatMap { id in
            myApp.components.firstIndex(where: { $0.id == id })
        }
        if let activeIdx, case .calendar(let c) = myApp.components[activeIdx].body {
            return (c, myApp.components[activeIdx].id)
        }
        for component in myApp.components {
            if case .calendar(let c) = component.body { return (c, component.id) }
        }
        return nil
    }

    @MainActor
    private static func resolveChecklist(
        store: MyAppStore,
        myAppId: UUID,
        componentId: String?
    ) -> (ChecklistData, String)? {
        guard let myApp = store.myApps.first(where: { $0.id == myAppId }) else { return nil }
        if let componentId {
            guard let component = myApp.components.first(where: { $0.id == componentId }),
                  case .checklist(let cl) = component.body else { return nil }
            return (cl, componentId)
        }
        let activeIdx = myApp.activeComponentId.flatMap { id in
            myApp.components.firstIndex(where: { $0.id == id })
        }
        if let activeIdx, case .checklist(let cl) = myApp.components[activeIdx].body {
            return (cl, myApp.components[activeIdx].id)
        }
        for component in myApp.components {
            if case .checklist(let cl) = component.body { return (cl, component.id) }
        }
        return nil
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
                `slackCreateAgents` and `slackCreateChannels` to set up the \
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
                    let icon = explicitIcon ?? defaultIcon(forKind: kind)
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
                Focus a component — drives the canvas view and which component \
                kind-targeted tools fall back to when called without a \
                componentId. Use this after addComponent to focus the freshly \
                created component, or when the user asks to "open" / "show" / \
                "switch to" a specific component. Result echoes \
                {componentId, activeComponentId}.
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
    }

    // MARK: - Calendar tools

    @MainActor
    private static func registerCalendarTools(
        on registry: ToolRegistry,
        store: MyAppStore,
        myAppId: UUID
    ) {
        registry.register(ClientTool(
            descriptor: ToolDescriptor(
                name: "renderCalendar",
                description: """
                Render a calendar on the first calendar component in this MyApp \
                (or the active component if it's a calendar) and/or set the \
                calendar's LLM-authored content `summary`. Passing `title` is a \
                DESTRUCTIVE full render — replaces the existing event list. For \
                incremental changes use addCalendarEvent / patchCalendarEvent / \
                removeCalendarEvent. `events` is optional; pass [] to start \
                empty. Each event needs {title, start (ISO-8601), end? \
                (ISO-8601), location?, notes?}. If no calendar component exists \
                yet, call `addComponent(kind:"calendar", name:…)` first. \
                Pass `summary` alone (no `title`) to update your content \
                summary without re-rendering — round-trips back in every \
                turn's canvas state. Result echoes {title, eventCount, \
                summarySet?}.
                """,
                parameters: [
                    "type": "object",
                    "properties": [
                        "title": ["type": "string"],
                        "events": [
                            "type": "array",
                            "items": calendarEventSchema(),
                        ],
                        "summary": [
                            "type": "string",
                            "description": "Your content summary for this calendar — what its events represent, recurring intent, who attends. Pass alone (without `title`) to update without re-rendering. Round-trips back in canvas state every turn.",
                        ],
                    ],
                ]
            ),
            handler: { args in
                let titleArg = args["title"]?.stringValue
                let summaryArg = args["summary"]
                let hasSummary = summaryArg != nil
                let hasBodyArgs = titleArg != nil
                return await MainActor.run {
                    if let title = titleArg {
                        let events = parseEvents(from: args["events"])
                        store.setCalendar(title: title, events: events, myAppId: myAppId)
                    }
                    var summarySet = false
                    if hasSummary {
                        summarySet = store.setComponentSummary(
                            forKind: "calendar",
                            summary: summaryArg?.stringValue,
                            myAppId: myAppId
                        )
                    }
                    guard hasBodyArgs || hasSummary else {
                        return .object([
                            "ok": .bool(false),
                            "error": "renderCalendar called with no arguments. Pass `title` (with optional `events`) for a full render and/or `summary` to update your content summary.",
                        ])
                    }
                    let c = calendar(store, myAppId: myAppId)
                    var result: [String: AnyJSON] = ["ok": .bool(c != nil)]
                    if let title = titleArg { result["title"] = .string(title) }
                    result["eventCount"] = .int(c?.events.count ?? 0)
                    if hasSummary {
                        result["summarySet"] = .bool(summarySet)
                    }
                    return .object(result)
                }
            }
        ))

        registry.register(ClientTool(
            descriptor: ToolDescriptor(
                name: "addCalendarEvent",
                description: """
                Append one event to the calendar. `start` (and optional `end`) \
                are ISO-8601 strings (e.g. "2026-05-14T10:00:00Z"). Resolve \
                relative user phrases ("tomorrow 3pm") against today's date \
                before calling. `linkedItems` optionally attaches one or \
                more tracker rows to the event — each rendered as an inline \
                chain-link pill under the title and kept live (edits to the \
                tracker row update the pill). To show a tracker on a \
                calendar, prefer ONE addCalendarEvent per intent with \
                `linkedItems` populated over creating separate ad-hoc + \
                linked events. Result echoes {id, eventCount}. Use the \
                returned `id` to refer to the event in subsequent \
                patchCalendarEvent / removeCalendarEvent / linkItem calls.
                """,
                parameters: [
                    "type": "object",
                    "properties": ["event": calendarEventSchema()],
                    "required": ["event"],
                ]
            ),
            handler: { args in
                guard let obj = args["event"]?.objectValue,
                      let title = obj["title"]?.stringValue,
                      let start = obj["start"]?.stringValue else {
                    return .object([
                        "ok": .bool(false),
                        "error": "missing 'event.title' or 'event.start'",
                    ])
                }
                let event = CalendarEvent(
                    title: title,
                    start: start,
                    end: obj["end"]?.stringValue,
                    location: obj["location"]?.stringValue,
                    notes: obj["notes"]?.stringValue,
                    linkedItems: parseLinkedItems(from: obj["linkedItems"])
                )
                return await MainActor.run {
                    guard let id = store.addCalendarEvent(event, myAppId: myAppId, actor: .agent(toolName: "addCalendarEvent")) else {
                        return .object([
                            "ok": .bool(false),
                            "error": "no calendar component in this MyApp — call renderCalendar or addComponent first",
                        ])
                    }
                    let c = calendar(store, myAppId: myAppId)
                    return .object([
                        "ok": .bool(true),
                        "id": .string(id.uuidString),
                        "eventCount": .int(c?.events.count ?? 0),
                        "linkCount": .int(event.linkedItems.count),
                    ])
                }
            }
        ))

        registry.register(ClientTool(
            descriptor: ToolDescriptor(
                name: "removeCalendarEvent",
                description: """
                Remove a calendar event by `id` (the stable UUID returned by \
                addCalendarEvent / getCanvasState). Result echoes \
                {removed, id, eventCount}.
                """,
                parameters: [
                    "type": "object",
                    "properties": ["id": ["type": "string"]],
                    "required": ["id"],
                ]
            ),
            handler: { args in
                let idString = args["id"]?.stringValue ?? ""
                guard let uuid = UUID(uuidString: idString) else {
                    return .object([
                        "ok": .bool(false),
                        "error": .string("invalid id '\(idString)' (expected a UUID)"),
                    ])
                }
                return await MainActor.run {
                    guard let removed = store.removeCalendarEvent(id: uuid, myAppId: myAppId, actor: .agent(toolName: "removeCalendarEvent")) else {
                        return .object([
                            "ok": .bool(false),
                            "error": .string("no event with id \(idString)"),
                        ])
                    }
                    let c = calendar(store, myAppId: myAppId)
                    return .object([
                        "ok": .bool(true),
                        "id": .string(idString),
                        "removed": .object([
                            "title": .string(removed.title),
                            "start": .string(removed.start),
                        ]),
                        "eventCount": .int(c?.events.count ?? 0),
                    ])
                }
            }
        ))

        registry.register(ClientTool(
            descriptor: ToolDescriptor(
                name: "setCalendarViewMode",
                description: """
                Switch the calendar's rendering between 'list' (upcoming \
                events grouped by day) and 'month' (7-column grid with the \
                selected day's events expanded below). Same data — only the \
                view changes. Use this when the user asks to "show as month" \
                / "switch to month view" / "go back to list". Result echoes \
                {mode}.
                """,
                parameters: [
                    "type": "object",
                    "properties": [
                        "mode": ["type": "string", "enum": ["list", "month"]],
                    ],
                    "required": ["mode"],
                ]
            ),
            handler: { args in
                let raw = args["mode"]?.stringValue ?? ""
                guard let mode = CalendarViewMode(rawValue: raw) else {
                    return .object([
                        "ok": .bool(false),
                        "error": .string("invalid mode '\(raw)' (expected 'list' or 'month')"),
                    ])
                }
                return await MainActor.run {
                    guard let resolved = store.setCalendarViewMode(mode, myAppId: myAppId) else {
                        return .object([
                            "ok": .bool(false),
                            "error": .string("no calendar component in this MyApp"),
                        ])
                    }
                    return .object([
                        "ok": .bool(true),
                        "mode": .string(resolved.rawValue),
                    ])
                }
            }
        ))

        registry.register(ClientTool(
            descriptor: ToolDescriptor(
                name: "patchCalendarEvent",
                description: """
                Edit one calendar event by `id`. Only fields included in the \
                `patch` object are changed. To clear an optional field, pass \
                an empty string. `start` and `end` are ISO-8601 strings. \
                `linkedItems` in the patch REPLACES the full list of refs \
                (use linkItem / unlinkItem for fine-grained edits). Result \
                echoes {event, id}.
                """,
                parameters: [
                    "type": "object",
                    "properties": [
                        "id": ["type": "string"],
                        "patch": [
                            "type": "object",
                            "properties": [
                                "title": ["type": "string"],
                                "start": ["type": "string"],
                                "end": ["type": "string"],
                                "location": ["type": "string"],
                                "notes": ["type": "string"],
                                "linkedItems": [
                                    "type": "array",
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
                        ],
                    ],
                    "required": ["id", "patch"],
                ]
            ),
            handler: { args in
                let idString = args["id"]?.stringValue ?? ""
                guard let uuid = UUID(uuidString: idString) else {
                    return .object([
                        "ok": .bool(false),
                        "error": .string("invalid id '\(idString)' (expected a UUID)"),
                    ])
                }
                let patchObj = args["patch"]?.objectValue ?? [:]
                var patch = MyAppStore.CalendarEventPatch()
                if let v = patchObj["title"]?.stringValue { patch.title = v }
                if let v = patchObj["start"]?.stringValue { patch.start = v }
                if let v = patchObj["end"]?.stringValue {
                    patch.end = .some(v.isEmpty ? nil : v)
                }
                if let v = patchObj["location"]?.stringValue {
                    patch.location = .some(v.isEmpty ? nil : v)
                }
                if let v = patchObj["notes"]?.stringValue {
                    patch.notes = .some(v.isEmpty ? nil : v)
                }
                if patchObj["linkedItems"] != nil {
                    patch.linkedItems = parseLinkedItems(from: patchObj["linkedItems"])
                }
                return await MainActor.run {
                    guard let after = store.patchCalendarEvent(id: uuid, patch: patch, myAppId: myAppId, actor: .agent(toolName: "patchCalendarEvent")) else {
                        return .object([
                            "ok": .bool(false),
                            "error": .string("no event with id \(idString)"),
                        ])
                    }
                    return .object([
                        "ok": .bool(true),
                        "id": .string(idString),
                        "event": eventAsAnyJSON(after),
                    ])
                }
            }
        ))

        registry.register(ClientTool(
            descriptor: ToolDescriptor(
                name: "listCalendarEvents",
                description: """
                Paginated read of a calendar's events as one-line previews \
                (`title @ start — location?` with long values cut by \
                ` [PREVIEW END]`). Use this — not `getCanvasState` — to \
                drill into a calendar beyond the 2-event sticky preview \
                in the stable canvas summary. Events are pre-sorted \
                ascending by `start`. Optional `dateRange: {from, to}` \
                (ISO-8601 strings, both inclusive) bounds which events \
                are paginated; either bound is itself optional. `offset` \
                (default 0) and `limit` (default 20, max 100) slice the \
                filtered list. `componentId` optional — resolves to the \
                active / first calendar. Result: {ok, componentId, \
                totalEvents, offset, limit, items: [{id, preview}]}.
                """,
                parameters: [
                    "type": "object",
                    "properties": [
                        "componentId": ["type": "string"],
                        "offset": ["type": "integer", "minimum": 0],
                        "limit": ["type": "integer", "minimum": 1, "maximum": 100],
                        "dateRange": [
                            "type": "object",
                            "properties": [
                                "from": ["type": "string", "description": "ISO-8601 inclusive lower bound on event.start"],
                                "to": ["type": "string", "description": "ISO-8601 inclusive upper bound on event.start"],
                            ],
                        ],
                    ],
                ]
            ),
            handler: { args in
                let componentId = args["componentId"]?.stringValue
                let offset = max(0, args["offset"]?.intValue ?? 0)
                let limit = min(100, max(1, args["limit"]?.intValue ?? 20))
                let from = args["dateRange"]?["from"]?.stringValue
                let to = args["dateRange"]?["to"]?.stringValue
                return await MainActor.run {
                    guard let resolved = resolveCalendar(store: store, myAppId: myAppId, componentId: componentId) else {
                        return .object([
                            "ok": .bool(false),
                            "error": "no calendar component matches that componentId (or this myApp has no calendar).",
                        ])
                    }
                    let (cal, resolvedId) = resolved
                    let filtered = cal.sortedEvents.filter { event in
                        if let from, event.start < from { return false }
                        if let to, event.start > to { return false }
                        return true
                    }
                    let total = filtered.count
                    let slice = offset >= total ? [] : Array(filtered[offset..<min(offset + limit, total)])
                    let items: [AnyJSON] = slice.map { event in
                        .object([
                            "id": .string(event.id.uuidString),
                            "preview": .string(CanvasPreview.calendarEvent(event)),
                        ])
                    }
                    return .object([
                        "ok": .bool(true),
                        "componentId": .string(resolvedId),
                        "totalEvents": .int(total),
                        "offset": .int(offset),
                        "limit": .int(limit),
                        "items": .array(items),
                    ])
                }
            }
        ))

        registry.register(ClientTool(
            descriptor: ToolDescriptor(
                name: "getCalendarEvent",
                description: """
                Full read of one calendar event — title, start, end?, \
                location?, notes?, linkedItems. No truncation. \
                `componentId` optional — resolves to the active / first \
                calendar. `eventId` is the stable UUID returned by \
                addCalendarEvent / listCalendarEvents. Result: {ok, \
                componentId, event: {id, title, start, end?, location?, \
                notes?, linkedItems: [{componentId, itemId}]}}.
                """,
                parameters: [
                    "type": "object",
                    "properties": [
                        "componentId": ["type": "string"],
                        "eventId": ["type": "string"],
                    ],
                    "required": ["eventId"],
                ]
            ),
            handler: { args in
                let componentId = args["componentId"]?.stringValue
                guard let eventIdString = args["eventId"]?.stringValue,
                      let eventId = UUID(uuidString: eventIdString) else {
                    return .object([
                        "ok": .bool(false),
                        "error": "missing or malformed `eventId` (expected UUID).",
                    ])
                }
                return await MainActor.run {
                    guard let resolved = resolveCalendar(store: store, myAppId: myAppId, componentId: componentId) else {
                        return .object([
                            "ok": .bool(false),
                            "error": "no calendar component matches that componentId (or this myApp has no calendar).",
                        ])
                    }
                    let (cal, resolvedId) = resolved
                    guard let event = cal.events.first(where: { $0.id == eventId }) else {
                        return .object([
                            "ok": .bool(false),
                            "error": .string("no event with id '\(eventIdString)' in calendar '\(resolvedId)'."),
                        ])
                    }
                    return .object([
                        "ok": .bool(true),
                        "componentId": .string(resolvedId),
                        "event": eventAsAnyJSON(event),
                    ])
                }
            }
        ))
    }

    // MARK: - Checklist tools

    @MainActor
    private static func registerChecklistTools(
        on registry: ToolRegistry,
        store: MyAppStore,
        myAppId: UUID
    ) {
        registry.register(ClientTool(
            descriptor: ToolDescriptor(
                name: "renderChecklist",
                description: """
                Render a checklist on the first checklist component in this \
                MyApp (or the active component if it's a checklist) and/or set \
                the checklist's LLM-authored content `summary`. Passing `title` \
                is a DESTRUCTIVE full render — replaces the existing item \
                list. For incremental changes use addChecklistItem / \
                patchChecklistItem / removeChecklistItem / \
                toggleChecklistItem. `items` is optional; pass [] to start \
                empty. Each item needs {text, done? (default false)}. If no \
                checklist component exists yet, call \
                `addComponent(kind:"checklist", name:…)` first. \
                Pass `summary` alone (no `title`) to update your content \
                summary without re-rendering — round-trips back in every \
                turn's canvas state. Result echoes {title, itemCount, \
                summarySet?}.
                """,
                parameters: [
                    "type": "object",
                    "properties": [
                        "title": ["type": "string"],
                        "items": [
                            "type": "array",
                            "items": checklistItemSchema(),
                        ],
                        "summary": [
                            "type": "string",
                            "description": "Your content summary for this checklist — what its rows represent, the user's intent, current state. Pass alone (without `title`) to update without re-rendering. Round-trips back in canvas state every turn.",
                        ],
                    ],
                ]
            ),
            handler: { args in
                let titleArg = args["title"]?.stringValue
                let summaryArg = args["summary"]
                let hasSummary = summaryArg != nil
                let hasBodyArgs = titleArg != nil
                return await MainActor.run {
                    if let title = titleArg {
                        let items = parseChecklistItems(from: args["items"])
                        store.setChecklist(title: title, items: items, myAppId: myAppId)
                    }
                    var summarySet = false
                    if hasSummary {
                        summarySet = store.setComponentSummary(
                            forKind: "checklist",
                            summary: summaryArg?.stringValue,
                            myAppId: myAppId
                        )
                    }
                    guard hasBodyArgs || hasSummary else {
                        return .object([
                            "ok": .bool(false),
                            "error": "renderChecklist called with no arguments. Pass `title` (with optional `items`) for a full render and/or `summary` to update your content summary.",
                        ])
                    }
                    let cl = checklist(store, myAppId: myAppId)
                    var result: [String: AnyJSON] = ["ok": .bool(cl != nil)]
                    if let title = titleArg { result["title"] = .string(title) }
                    result["itemCount"] = .int(cl?.items.count ?? 0)
                    if hasSummary {
                        result["summarySet"] = .bool(summarySet)
                    }
                    return .object(result)
                }
            }
        ))

        registry.register(ClientTool(
            descriptor: ToolDescriptor(
                name: "addChecklistItem",
                description: """
                Append one row to the checklist. `text` is the displayed \
                line; `done` defaults to false. Result echoes {id, \
                itemCount}. Use the returned `id` to refer to the row in \
                subsequent toggleChecklistItem / patchChecklistItem / \
                removeChecklistItem / linkItem calls.
                """,
                parameters: [
                    "type": "object",
                    "properties": [
                        "text": ["type": "string"],
                        "done": ["type": "boolean"],
                    ],
                    "required": ["text"],
                ]
            ),
            handler: { args in
                let text = args["text"]?.stringValue ?? ""
                let done = args["done"]?.boolValue ?? false
                return await MainActor.run {
                    guard let id = store.addChecklistItem(text: text, done: done, myAppId: myAppId, actor: .agent(toolName: "addChecklistItem")) else {
                        return .object([
                            "ok": .bool(false),
                            "error": "no checklist component in this MyApp — call renderChecklist or addComponent first",
                        ])
                    }
                    let cl = checklist(store, myAppId: myAppId)
                    return .object([
                        "ok": .bool(true),
                        "id": .string(id.uuidString),
                        "itemCount": .int(cl?.items.count ?? 0),
                    ])
                }
            }
        ))

        registry.register(ClientTool(
            descriptor: ToolDescriptor(
                name: "toggleChecklistItem",
                description: """
                Flip a checklist row's `done` flag (true → false, false → \
                true). Identify the row with its stable UUID `id`. Use \
                patchChecklistItem when you want to set `done` to a specific \
                value rather than flip it. Result echoes {id, done, \
                itemCount}.
                """,
                parameters: [
                    "type": "object",
                    "properties": ["id": ["type": "string"]],
                    "required": ["id"],
                ]
            ),
            handler: { args in
                let idString = args["id"]?.stringValue ?? ""
                guard let uuid = UUID(uuidString: idString) else {
                    return .object([
                        "ok": .bool(false),
                        "error": .string("invalid id '\(idString)' (expected a UUID)"),
                    ])
                }
                return await MainActor.run {
                    guard let newValue = store.toggleChecklistItem(id: uuid, myAppId: myAppId, actor: .agent(toolName: "toggleChecklistItem")) else {
                        return .object([
                            "ok": .bool(false),
                            "error": .string("no checklist item with id \(idString)"),
                        ])
                    }
                    let cl = checklist(store, myAppId: myAppId)
                    return .object([
                        "ok": .bool(true),
                        "id": .string(idString),
                        "done": .bool(newValue),
                        "itemCount": .int(cl?.items.count ?? 0),
                    ])
                }
            }
        ))

        registry.register(ClientTool(
            descriptor: ToolDescriptor(
                name: "patchChecklistItem",
                description: """
                Edit one checklist row by `id`. Only fields included in the \
                `patch` object are changed. `linkedItems` in the patch \
                REPLACES the full list of refs (use linkItem / unlinkItem \
                for fine-grained edits). Result echoes {id, item}.
                """,
                parameters: [
                    "type": "object",
                    "properties": [
                        "id": ["type": "string"],
                        "patch": [
                            "type": "object",
                            "properties": [
                                "text": ["type": "string"],
                                "done": ["type": "boolean"],
                                "linkedItems": [
                                    "type": "array",
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
                        ],
                    ],
                    "required": ["id", "patch"],
                ]
            ),
            handler: { args in
                let idString = args["id"]?.stringValue ?? ""
                guard let uuid = UUID(uuidString: idString) else {
                    return .object([
                        "ok": .bool(false),
                        "error": .string("invalid id '\(idString)' (expected a UUID)"),
                    ])
                }
                let patchObj = args["patch"]?.objectValue ?? [:]
                var patch = MyAppStore.ChecklistItemPatch()
                if let v = patchObj["text"]?.stringValue { patch.text = v }
                if let v = patchObj["done"]?.boolValue { patch.done = v }
                if patchObj["linkedItems"] != nil {
                    patch.linkedItems = parseLinkedItems(from: patchObj["linkedItems"])
                }
                return await MainActor.run {
                    guard let after = store.patchChecklistItem(id: uuid, patch: patch, myAppId: myAppId, actor: .agent(toolName: "patchChecklistItem")) else {
                        return .object([
                            "ok": .bool(false),
                            "error": .string("no checklist item with id \(idString)"),
                        ])
                    }
                    return .object([
                        "ok": .bool(true),
                        "id": .string(idString),
                        "item": checklistItemAsAnyJSON(after),
                    ])
                }
            }
        ))

        registry.register(ClientTool(
            descriptor: ToolDescriptor(
                name: "removeChecklistItem",
                description: """
                Remove a checklist row by `id` (the stable UUID returned by \
                addChecklistItem / getCanvasState). Result echoes \
                {removed, id, itemCount}.
                """,
                parameters: [
                    "type": "object",
                    "properties": ["id": ["type": "string"]],
                    "required": ["id"],
                ]
            ),
            handler: { args in
                let idString = args["id"]?.stringValue ?? ""
                guard let uuid = UUID(uuidString: idString) else {
                    return .object([
                        "ok": .bool(false),
                        "error": .string("invalid id '\(idString)' (expected a UUID)"),
                    ])
                }
                return await MainActor.run {
                    guard let removed = store.removeChecklistItem(id: uuid, myAppId: myAppId, actor: .agent(toolName: "removeChecklistItem")) else {
                        return .object([
                            "ok": .bool(false),
                            "error": .string("no checklist item with id \(idString)"),
                        ])
                    }
                    let cl = checklist(store, myAppId: myAppId)
                    return .object([
                        "ok": .bool(true),
                        "id": .string(idString),
                        "removed": .object([
                            "text": .string(removed.text),
                            "done": .bool(removed.done),
                        ]),
                        "itemCount": .int(cl?.items.count ?? 0),
                    ])
                }
            }
        ))

        registry.register(ClientTool(
            descriptor: ToolDescriptor(
                name: "listChecklistItems",
                description: """
                Paginated read of a checklist's rows as one-line previews \
                (`[x] text` / `[ ] text` with long text cut by \
                ` [PREVIEW END]`). Use this — not `getCanvasState` — to \
                drill into a checklist beyond the 2-row sticky preview in \
                the stable canvas summary. `status` filters: \"open\" \
                (done=false), \"done\" (done=true), or \"all\" (default). \
                `offset` (default 0) and `limit` (default 20, max 100) \
                slice the filtered list (preserves insertion order). \
                `componentId` optional — resolves to the active / first \
                checklist. Result: {ok, componentId, totalItems, offset, \
                limit, items: [{id, preview, done}]}.
                """,
                parameters: [
                    "type": "object",
                    "properties": [
                        "componentId": ["type": "string"],
                        "offset": ["type": "integer", "minimum": 0],
                        "limit": ["type": "integer", "minimum": 1, "maximum": 100],
                        "status": ["type": "string", "enum": ["open", "done", "all"]],
                    ],
                ]
            ),
            handler: { args in
                let componentId = args["componentId"]?.stringValue
                let offset = max(0, args["offset"]?.intValue ?? 0)
                let limit = min(100, max(1, args["limit"]?.intValue ?? 20))
                let status = args["status"]?.stringValue ?? "all"
                return await MainActor.run {
                    guard let resolved = resolveChecklist(store: store, myAppId: myAppId, componentId: componentId) else {
                        return .object([
                            "ok": .bool(false),
                            "error": "no checklist component matches that componentId (or this myApp has no checklist).",
                        ])
                    }
                    let (cl, resolvedId) = resolved
                    let filtered: [ChecklistItem] = {
                        switch status {
                        case "open": return cl.items.filter { !$0.done }
                        case "done": return cl.items.filter { $0.done }
                        default: return cl.items
                        }
                    }()
                    let total = filtered.count
                    let slice = offset >= total ? [] : Array(filtered[offset..<min(offset + limit, total)])
                    let items: [AnyJSON] = slice.map { item in
                        .object([
                            "id": .string(item.id.uuidString),
                            "preview": .string(CanvasPreview.checklistItem(item)),
                            "done": .bool(item.done),
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
                name: "getChecklistItem",
                description: """
                Full read of one checklist row — text, done, linkedItems. \
                No truncation. `componentId` optional — resolves to the \
                active / first checklist. `itemId` is the stable UUID \
                returned by addChecklistItem / listChecklistItems. \
                Result: {ok, componentId, item: {id, text, done, \
                linkedItems: [{componentId, itemId}]}}.
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
                    guard let resolved = resolveChecklist(store: store, myAppId: myAppId, componentId: componentId) else {
                        return .object([
                            "ok": .bool(false),
                            "error": "no checklist component matches that componentId (or this myApp has no checklist).",
                        ])
                    }
                    let (cl, resolvedId) = resolved
                    guard let item = cl.items.first(where: { $0.id == itemId }) else {
                        return .object([
                            "ok": .bool(false),
                            "error": .string("no item with id '\(itemIdString)' in checklist '\(resolvedId)'."),
                        ])
                    }
                    return .object([
                        "ok": .bool(true),
                        "componentId": .string(resolvedId),
                        "item": checklistItemAsAnyJSON(item),
                    ])
                }
            }
        ))
    }

    // MARK: - Calculator tools

    @MainActor
    private static func registerCalculatorTools(
        on registry: ToolRegistry,
        store: MyAppStore,
        myAppId: UUID
    ) {
        registry.register(ClientTool(
            descriptor: ToolDescriptor(
                name: "renderCalculator",
                description: """
                Render a calculator and/or set its `summary`. `title` = \
                DESTRUCTIVE full render — replaces all rows; for incremental \
                use addCalcRows / patchCalcRows / removeCalcRows. `summary` \
                alone = update without re-render. Row shapes: see `rows` \
                schema (variable / aggregate / formula / list / header). \
                Result: {rowCount, results:[{key, value, status}], summarySet?}.
                """,
                parameters: [
                    "type": "object",
                    "properties": [
                        "title": ["type": "string"],
                        "rows": ["type": "array", "items": calcRowSchema()],
                        "summary": [
                            "type": "string",
                            "description": "Your content summary for this calculator — what it models, which rows are the tunable inputs, what the key outputs mean. Pass alone (without `title`) to update without re-rendering. Round-trips back in canvas state every turn.",
                        ],
                    ],
                ]
            ),
            handler: { args in
                let titleArg = args["title"]?.stringValue
                let summaryArg = args["summary"]
                let hasSummary = summaryArg != nil
                let hasBodyArgs = titleArg != nil
                return await MainActor.run {
                    if let title = titleArg {
                        let rows = parseCalcRows(from: args["rows"])
                        store.setCalculator(title: title, rows: rows, myAppId: myAppId)
                    }
                    var summarySet = false
                    if hasSummary {
                        summarySet = store.setComponentSummary(
                            forKind: "calculator",
                            summary: summaryArg?.stringValue,
                            myAppId: myAppId
                        )
                    }
                    guard hasBodyArgs || hasSummary else {
                        return .object([
                            "ok": .bool(false),
                            "error": "renderCalculator called with no arguments. Pass `title` (with optional `rows`) for a full render and/or `summary` to update your content summary.",
                        ])
                    }
                    guard let resolved = resolveCalculator(store: store, myAppId: myAppId, componentId: nil) else {
                        return .object([
                            "ok": .bool(false),
                            "error": "no calculator component in this MyApp — call addComponent(kind:\"calculator\", …) first",
                        ])
                    }
                    let (data, resolvedId) = resolved
                    var result: [String: AnyJSON] = ["ok": .bool(true), "componentId": .string(resolvedId)]
                    if let title = titleArg { result["title"] = .string(title) }
                    result["rowCount"] = .int(data.rows.count)
                    result["results"] = calcResults(store: store, myAppId: myAppId, data: data)
                    if hasSummary { result["summarySet"] = .bool(summarySet) }
                    return .object(result)
                }
            }
        ))

        registry.register(ClientTool(
            descriptor: ToolDescriptor(
                name: "addCalcRows",
                description: """
                Append one or more rows to the calculator. Always pass a \
                `rows` array — wrap a single row as `[{ ... }]`. Each row is \
                {key?, name, unit?, format?, kind} (see renderCalculator for \
                the kind shapes). `key` is the stable slug formulas reference; \
                omit it to derive one from `name`. Duplicate keys are \
                de-duplicated (`spend`, `spend_2`, …) — the resolved keys are \
                returned. Result echoes {added:[{key,name}], rowCount, \
                results}.
                """,
                parameters: [
                    "type": "object",
                    "properties": ["rows": ["type": "array", "items": calcRowSchema()]],
                    "required": ["rows"],
                ]
            ),
            handler: { args in
                guard let entries = args["rows"]?.arrayValue, !entries.isEmpty else {
                    return .object(["ok": .bool(false), "error": "missing 'rows' array"])
                }
                return await MainActor.run {
                    guard store.calculatorComponentId(myAppId: myAppId) != nil else {
                        return .object([
                            "ok": .bool(false),
                            "error": "no calculator component in this MyApp — call addComponent(kind:\"calculator\", …) or renderCalculator first",
                        ])
                    }
                    var added: [AnyJSON] = []
                    for entry in entries {
                        guard let (key, name, unit, format, kind) = parseCalcRowParts(from: entry) else { continue }
                        if let resolvedKey = store.addCalcRow(
                            key: key, name: name, unit: unit, format: format, kind: kind,
                            myAppId: myAppId, actor: .agent(toolName: "addCalcRows")
                        ) {
                            added.append(.object(["key": .string(resolvedKey), "name": .string(name)]))
                        }
                    }
                    let data = calculator(store, myAppId: myAppId)
                    var result: [String: AnyJSON] = [
                        "ok": .bool(true),
                        "added": .array(added),
                        "rowCount": .int(data?.rows.count ?? 0),
                    ]
                    if let data { result["results"] = calcResults(store: store, myAppId: myAppId, data: data) }
                    return .object(result)
                }
            }
        ))

        registry.register(ClientTool(
            descriptor: ToolDescriptor(
                name: "patchCalcRows",
                description: """
                Edit one or more rows by `key`. Always pass a `patches` array \
                — wrap a single edit as `[{ ... }]`. Each entry is {key, \
                patch} where `patch` may contain {name?, unit?, format?, \
                kind?}. `key` itself is immutable (so formulas never break); \
                `kind` replaces the whole row behaviour. Result echoes \
                {patched:[keys], rowCount, results}.
                """,
                parameters: [
                    "type": "object",
                    "properties": [
                        "patches": [
                            "type": "array",
                            "items": [
                                "type": "object",
                                "properties": [
                                    "key": ["type": "string"],
                                    "patch": calcRowPatchSchema(),
                                ],
                                "required": ["key", "patch"],
                            ],
                        ],
                    ],
                    "required": ["patches"],
                ]
            ),
            handler: { args in
                guard let entries = args["patches"]?.arrayValue, !entries.isEmpty else {
                    return .object(["ok": .bool(false), "error": "missing 'patches' array"])
                }
                return await MainActor.run {
                    var patched: [AnyJSON] = []
                    for entry in entries {
                        guard let key = entry["key"]?.stringValue else { continue }
                        let patch = parseCalcRowPatch(from: entry["patch"])
                        if store.patchCalcRow(key: key, patch: patch, myAppId: myAppId, actor: .agent(toolName: "patchCalcRows")) {
                            patched.append(.string(key))
                        }
                    }
                    let data = calculator(store, myAppId: myAppId)
                    var result: [String: AnyJSON] = [
                        "ok": .bool(true),
                        "patched": .array(patched),
                        "rowCount": .int(data?.rows.count ?? 0),
                    ]
                    if let data { result["results"] = calcResults(store: store, myAppId: myAppId, data: data) }
                    return .object(result)
                }
            }
        ))

        registry.register(ClientTool(
            descriptor: ToolDescriptor(
                name: "removeCalcRows",
                description: """
                Remove one or more rows by `key`. Always pass a `keys` array \
                — wrap a single key as `["..."]`. Formulas that referenced a \
                removed key then resolve to a `brokenRef` status (handled \
                live; other rows are not rewritten). Result echoes \
                {removed:[keys], rowCount}.
                """,
                parameters: [
                    "type": "object",
                    "properties": ["keys": ["type": "array", "items": ["type": "string"]]],
                    "required": ["keys"],
                ]
            ),
            handler: { args in
                guard let keys = args["keys"]?.arrayValue?.compactMap(\.stringValue), !keys.isEmpty else {
                    return .object(["ok": .bool(false), "error": "missing 'keys' array"])
                }
                return await MainActor.run {
                    var removed: [AnyJSON] = []
                    for key in keys {
                        if store.removeCalcRow(key: key, myAppId: myAppId, actor: .agent(toolName: "removeCalcRows")) {
                            removed.append(.string(key))
                        }
                    }
                    let data = calculator(store, myAppId: myAppId)
                    return .object([
                        "ok": .bool(true),
                        "removed": .array(removed),
                        "rowCount": .int(data?.rows.count ?? 0),
                    ])
                }
            }
        ))

        registry.register(ClientTool(
            descriptor: ToolDescriptor(
                name: "setCalcRowLink",
                description: """
                Point a `linkedField` row at a tracker item (the "pick a \
                house" swap) — every formula above re-runs against the new \
                item's fields. `key` is the linkedField row. `ref` is \
                {componentId, itemId}; pass null to clear the link. Result \
                echoes {ok, key, results}.
                """,
                parameters: [
                    "type": "object",
                    "properties": [
                        "key": ["type": "string"],
                        "ref": [
                            "type": "object",
                            "properties": [
                                "componentId": ["type": "string"],
                                "itemId": ["type": "string"],
                            ],
                            "required": ["componentId", "itemId"],
                        ],
                        "componentId": ["type": "string", "description": "Optional calculator id; defaults to the active / first calculator."],
                    ],
                    "required": ["key"],
                ]
            ),
            handler: { args in
                guard let key = args["key"]?.stringValue else {
                    return .object(["ok": .bool(false), "error": "missing 'key'"])
                }
                let ref = parseRef(from: args["ref"])
                let componentId = args["componentId"]?.stringValue
                return await MainActor.run {
                    let ok = store.setCalcRowLinkedRef(
                        key: key,
                        ref: ref,
                        myAppId: myAppId,
                        componentId: componentId,
                        actor: .agent(toolName: "setCalcRowLink")
                    )
                    var result: [String: AnyJSON] = ["ok": .bool(ok), "key": .string(key)]
                    if let data = calculator(store, myAppId: myAppId) {
                        result["results"] = calcResults(store: store, myAppId: myAppId, data: data)
                    }
                    return .object(result)
                }
            }
        ))

        registry.register(ClientTool(
            descriptor: ToolDescriptor(
                name: "listCalcRows",
                description: """
                Read a calculator's rows with their live-resolved values. \
                `componentId` optional — resolves to the active / first \
                calculator. `offset` (default 0) and `limit` (default 50, max \
                100) slice the row list in order. Result: {ok, componentId, \
                title, totalRows, offset, limit, rows:[{key, name, kind, \
                value, status}]}.
                """,
                parameters: [
                    "type": "object",
                    "properties": [
                        "componentId": ["type": "string"],
                        "offset": ["type": "integer", "minimum": 0],
                        "limit": ["type": "integer", "minimum": 1, "maximum": 100],
                    ],
                ]
            ),
            handler: { args in
                let componentId = args["componentId"]?.stringValue
                let offset = max(0, args["offset"]?.intValue ?? 0)
                let limit = min(100, max(1, args["limit"]?.intValue ?? 50))
                return await MainActor.run {
                    guard let resolved = resolveCalculator(store: store, myAppId: myAppId, componentId: componentId) else {
                        return .object([
                            "ok": .bool(false),
                            "error": "no calculator component matches that componentId (or this myApp has no calculator).",
                        ])
                    }
                    let (data, resolvedId) = resolved
                    let results = CalculatorResolver.resolve(data, components: siblingComponents(store: store, myAppId: myAppId))
                    let total = data.rows.count
                    let slice = offset >= total ? [] : Array(data.rows[offset..<min(offset + limit, total)])
                    let rows: [AnyJSON] = slice.map { calcRowAsAnyJSON($0, result: results.result(forKey: $0.key), full: false) }
                    return .object([
                        "ok": .bool(true),
                        "componentId": .string(resolvedId),
                        "title": .string(data.title),
                        "totalRows": .int(total),
                        "offset": .int(offset),
                        "limit": .int(limit),
                        "rows": .array(rows),
                    ])
                }
            }
        ))

        registry.register(ClientTool(
            descriptor: ToolDescriptor(
                name: "getCalcRow",
                description: """
                Full read of one calculator row by `key` — name, unit, \
                format, the complete kind spec (variable value/control, \
                aggregate source/field/reduce/filter, or formula expression), \
                plus the live-resolved {value, status}. `componentId` optional \
                — resolves to the active / first calculator. Result: {ok, \
                componentId, row}.
                """,
                parameters: [
                    "type": "object",
                    "properties": [
                        "componentId": ["type": "string"],
                        "key": ["type": "string"],
                    ],
                    "required": ["key"],
                ]
            ),
            handler: { args in
                let componentId = args["componentId"]?.stringValue
                guard let key = args["key"]?.stringValue else {
                    return .object(["ok": .bool(false), "error": "missing `key`."])
                }
                return await MainActor.run {
                    guard let resolved = resolveCalculator(store: store, myAppId: myAppId, componentId: componentId) else {
                        return .object([
                            "ok": .bool(false),
                            "error": "no calculator component matches that componentId (or this myApp has no calculator).",
                        ])
                    }
                    let (data, resolvedId) = resolved
                    guard let row = data.rows.first(where: { $0.key == key }) else {
                        return .object([
                            "ok": .bool(false),
                            "error": .string("no row with key '\(key)' in calculator '\(resolvedId)'."),
                        ])
                    }
                    let results = CalculatorResolver.resolve(data, components: siblingComponents(store: store, myAppId: myAppId))
                    return .object([
                        "ok": .bool(true),
                        "componentId": .string(resolvedId),
                        "row": calcRowAsAnyJSON(row, result: results.result(forKey: key), full: true),
                    ])
                }
            }
        ))
    }

    // MARK: - Chart tools

    @MainActor
    private static func registerChartTools(
        on registry: ToolRegistry,
        store: MyAppStore,
        myAppId: UUID
    ) {
        registry.register(ClientTool(
            descriptor: ToolDescriptor(
                name: "renderChart",
                description: """
                Render a chart on the first chart component in this MyApp (or \
                the active component if it's a chart). DESTRUCTIVE — overwrites \
                title / kind / series. `kind` is one of pie | bar | line. \
                `series` is an ARRAY of overlaid series (line/bar overlay with \
                a colour each + legend; pie uses series[0] only). Each series \
                is {name?, colorHex?, source} where `source` is one of: \
                {type:"tracker", componentId, groupBy, valueField, \
                reduce:"sum|avg|min|max|count", filter?, xIsNumericOrDate?}; \
                {type:"calculatorRows", componentId, keys:[...]}; \
                {type:"calculatorList", componentId, key} — plot one \
                calculator `.list` row (a sweep / column array); or \
                {type:"inline", points:[{label, x?, y}]}. If no chart \
                component exists yet, call addComponent(kind:"chart", name:…) \
                first. Result echoes {ok, componentId, title, kind, \
                seriesCount, pointCount}.
                """,
                parameters: [
                    "type": "object",
                    "properties": [
                        "title": ["type": "string"],
                        "kind": ["type": "string", "enum": ["pie", "bar", "line"]],
                        "series": ["type": "array", "items": chartSeriesSchema()],
                    ],
                    "required": ["title", "kind", "series"],
                ]
            ),
            handler: { args in
                guard let title = args["title"]?.stringValue,
                      let kindRaw = args["kind"]?.stringValue,
                      let kind = ChartKind(rawValue: kindRaw) else {
                    return .object(["ok": .bool(false), "error": "renderChart needs `title`, `kind` (pie|bar|line), and `series`."])
                }
                let series = parseChartSeries(from: args["series"])
                return await MainActor.run {
                    guard store.chartComponentId(myAppId: myAppId) != nil else {
                        return .object([
                            "ok": .bool(false),
                            "error": "no chart component in this MyApp — call addComponent(kind:\"chart\", …) first",
                        ])
                    }
                    store.setChart(title: title, kind: kind, series: series, myAppId: myAppId)
                    return chartEcho(store: store, myAppId: myAppId)
                }
            }
        ))

        registry.register(ClientTool(
            descriptor: ToolDescriptor(
                name: "patchChart",
                description: """
                Edit the chart in place — only the fields you pass change. \
                {title?, kind?, series?} (same shapes as renderChart; `series` \
                replaces the whole list — use addChartSeries / \
                removeChartSeries for incremental). Result echoes {ok, \
                componentId, title, kind, seriesCount, pointCount}.
                """,
                parameters: [
                    "type": "object",
                    "properties": [
                        "title": ["type": "string"],
                        "kind": ["type": "string", "enum": ["pie", "bar", "line"]],
                        "series": ["type": "array", "items": chartSeriesSchema()],
                    ],
                ]
            ),
            handler: { args in
                var patch = MyAppStore.ChartPatch()
                if let t = args["title"]?.stringValue { patch.title = t }
                if let k = args["kind"]?.stringValue, let kind = ChartKind(rawValue: k) { patch.kind = kind }
                if args["series"] != nil { patch.series = parseChartSeries(from: args["series"]) }
                return await MainActor.run {
                    guard store.patchChart(patch: patch, myAppId: myAppId) else {
                        return .object([
                            "ok": .bool(false),
                            "error": "no chart component in this MyApp — call addComponent(kind:\"chart\", …) or renderChart first",
                        ])
                    }
                    return chartEcho(store: store, myAppId: myAppId)
                }
            }
        ))

        registry.register(ClientTool(
            descriptor: ToolDescriptor(
                name: "addChartSeries",
                description: """
                Append one or more series to the chart (each gets its own \
                colour + legend entry). Pass `series` (array of {name?, \
                colorHex?, source}; see renderChart). Result echoes {ok, \
                componentId, title, kind, seriesCount, pointCount}.
                """,
                parameters: [
                    "type": "object",
                    "properties": ["series": ["type": "array", "items": chartSeriesSchema()]],
                    "required": ["series"],
                ]
            ),
            handler: { args in
                let specs = parseChartSeries(from: args["series"])
                return await MainActor.run {
                    guard store.addChartSeries(specs, myAppId: myAppId) != nil else {
                        return .object([
                            "ok": .bool(false),
                            "error": "no chart component in this MyApp — call addComponent(kind:\"chart\", …) or renderChart first",
                        ])
                    }
                    return chartEcho(store: store, myAppId: myAppId)
                }
            }
        ))

        registry.register(ClientTool(
            descriptor: ToolDescriptor(
                name: "removeChartSeries",
                description: """
                Remove the series at 0-based `index`. Result echoes {ok, \
                componentId, title, kind, seriesCount, pointCount}.
                """,
                parameters: [
                    "type": "object",
                    "properties": ["index": ["type": "integer", "minimum": 0]],
                    "required": ["index"],
                ]
            ),
            handler: { args in
                guard let index = args["index"]?.intValue else {
                    return .object(["ok": .bool(false), "error": "removeChartSeries needs `index`."])
                }
                return await MainActor.run {
                    guard store.removeChartSeries(index: index, myAppId: myAppId) else {
                        return .object([
                            "ok": .bool(false),
                            "error": "no chart series at that index (or no chart component).",
                        ])
                    }
                    return chartEcho(store: store, myAppId: myAppId)
                }
            }
        ))

        registry.register(ClientTool(
            descriptor: ToolDescriptor(
                name: "setChartKind",
                description: """
                Flip the chart's kind (pie | bar | line) without touching its \
                series. Result echoes {ok, componentId, title, kind, \
                seriesCount, pointCount}.
                """,
                parameters: [
                    "type": "object",
                    "properties": ["kind": ["type": "string", "enum": ["pie", "bar", "line"]]],
                    "required": ["kind"],
                ]
            ),
            handler: { args in
                guard let k = args["kind"]?.stringValue, let kind = ChartKind(rawValue: k) else {
                    return .object(["ok": .bool(false), "error": "setChartKind needs `kind` (pie|bar|line)."])
                }
                return await MainActor.run {
                    guard store.chartComponentId(myAppId: myAppId) != nil else {
                        return .object([
                            "ok": .bool(false),
                            "error": "no chart component in this MyApp — call addComponent(kind:\"chart\", …) or renderChart first",
                        ])
                    }
                    store.setChartKind(kind, myAppId: myAppId)
                    return chartEcho(store: store, myAppId: myAppId)
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
            handler: { _ in
                return await MainActor.run {
                    let entries: [AnyJSON] = store.myApps.map { myApp in
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

    // MARK: - Slack tools

    /// Tools that drive a Slack canvas component. Three flavours:
    ///
    /// - **Discovery** (any caller): `slackListAgents`,
    ///   `slackListChannels`, `slackReadChannelHistory`.
    /// - **Posting** (sub-agents only): `slackPostMessage`.
    ///   Authors a message as the current sub-agent and fans out
    ///   to any `@mentioned` agents through the same
    ///   `invokeSlackAgent` path the user composer uses — so the
    ///   `SlackInvoker` reentrancy + max-depth guard applies to
    ///   agent-triggered chains too. Multiple calls in one turn
    ///   are allowed; auto-post of the agent's final assistant
    ///   text is suppressed when this tool has been used.
    /// - **Admin** (main chat panel only): `slackCreateAgent`,
    ///   `slackCreateChannels`, `slackAddAgentsToChannel`. Refuse
    ///   when `context.currentAgentId` is non-nil so sub-agents
    ///   can't spawn more agents / channels in v1.
    @MainActor
    public static func registerSlackTools(
        on registry: ToolRegistry,
        store: MyAppStore,
        myAppId: UUID,
        memory: MemoryStore? = nil,
        context: SlackToolContext
    ) {
        // --- Discovery -----------------------------------------

        registry.register(ClientTool(
            descriptor: ToolDescriptor(
                name: "slackListAgents",
                description: """
                List every agent in this MyApp's Slack canvas. \
                Result echoes \
                {agents: [{id, name, role}]}.
                """,
                parameters: ["type": "object", "properties": [:]]
            ),
            handler: { _ in
                return await MainActor.run {
                    guard let s = slackData(store, myAppId: myAppId) else {
                        return .object(["ok": .bool(false), "error": "no slack component"])
                    }
                    let entries: [AnyJSON] = s.agents.map { a in
                        .object([
                            "id": .string(a.id),
                            "name": .string(a.name),
                            "role": .string(a.role),
                        ])
                    }
                    return .object([
                        "ok": .bool(true),
                        "agents": .array(entries),
                    ])
                }
            }
        ))

        registry.register(ClientTool(
            descriptor: ToolDescriptor(
                name: "slackListChannels",
                description: """
                List every channel / group-DM / DM in this MyApp's \
                Slack canvas. Result echoes \
                {channels: [{id, name, type, memberAgentIds}]}.
                """,
                parameters: ["type": "object", "properties": [:]]
            ),
            handler: { _ in
                return await MainActor.run {
                    guard let s = slackData(store, myAppId: myAppId) else {
                        return .object(["ok": .bool(false), "error": "no slack component"])
                    }
                    let entries: [AnyJSON] = s.channels.map { c in
                        .object([
                            "id": .string(c.id),
                            "name": .string(c.name),
                            "type": .string(c.type.rawValue),
                            "memberAgentIds": .array(c.memberAgentIds.map { .string($0) }),
                        ])
                    }
                    return .object([
                        "ok": .bool(true),
                        "channels": .array(entries),
                    ])
                }
            }
        ))

        registry.register(ClientTool(
            descriptor: ToolDescriptor(
                name: "slackReadChannelHistory",
                description: """
                Read messages from a Slack channel. `channelId` is \
                required; `limit` (optional, default 50) caps the \
                number of messages returned. By default returns the \
                most-recent messages. Pass `before` (a message id) \
                to fetch the page strictly older than that message — \
                use the `id` of the oldest message from a previous \
                call to walk back through history. Invocation prompts \
                only include the most recent slice of a channel, so \
                use this tool when older context matters. Result \
                echoes {messages: [{id, channelId, authorKind, \
                authorId, text, timestamp}], totalMessages, hasMore}; \
                `hasMore: true` means older messages exist beyond \
                the returned page.
                """,
                parameters: [
                    "type": "object",
                    "properties": [
                        "channelId": ["type": "string"],
                        "limit": ["type": "integer"],
                        "before": ["type": "string"],
                    ],
                    "required": ["channelId"],
                ]
            ),
            handler: { args in
                let channelId = args["channelId"]?.stringValue ?? ""
                let limit = args["limit"]?.intValue ?? 50
                let before = args["before"]?.stringValue
                return await MainActor.run {
                    guard let s = slackData(store, myAppId: myAppId) else {
                        return .object(["ok": .bool(false), "error": "no slack component"])
                    }
                    let all = (s.messagesByChannel[channelId] ?? [])
                        .sorted { $0.timestamp < $1.timestamp }
                    let pool: [SlackMessage]
                    if let before, !before.isEmpty,
                       let cursorIdx = all.firstIndex(where: { $0.id == before }) {
                        pool = Array(all.prefix(cursorIdx))
                    } else {
                        pool = all
                    }
                    let cap = max(0, limit)
                    let trimmed = Array(pool.suffix(cap))
                    let hasMore = pool.count > trimmed.count
                    let formatter = ISO8601DateFormatter()
                    let entries: [AnyJSON] = trimmed.map { m in
                        .object([
                            "id": .string(m.id),
                            "channelId": .string(m.channelId),
                            "authorKind": .string(m.authorKind.rawValue),
                            "authorId": .string(m.authorId),
                            "text": .string(m.text),
                            "timestamp": .string(formatter.string(from: m.timestamp)),
                        ])
                    }
                    return .object([
                        "ok": .bool(true),
                        "messages": .array(entries),
                        "totalMessages": .int(all.count),
                        "hasMore": .bool(hasMore),
                    ])
                }
            }
        ))

        // --- Posting (sub-agents only) -------------------------

        registry.register(ClientTool(
            descriptor: ToolDescriptor(
                name: "slackPostMessage",
                description: """
                Post a message into a Slack channel as the running \
                agent. Use this when you want to say more than one \
                thing in a turn (e.g. "looking…" → run a tool → \
                "here it is"). If you don't call this and end your \
                turn with a normal assistant message, your final \
                reply is auto-posted for you, so simple Q&A \
                doesn't need this tool. Any `@mentions` in `text` \
                fan out — each mentioned agent is invoked \
                synchronously on the same channel, returning their \
                final reply through this tool result. Reentrancy + \
                a chain-depth cap prevent infinite call loops. \
                Result echoes \
                {messageId, channelId, fanOut: [{agentId, outcome, text?, error?}]}.
                """,
                parameters: [
                    "type": "object",
                    "properties": [
                        "channelId": ["type": "string"],
                        "text": ["type": "string"],
                    ],
                    "required": ["channelId", "text"],
                ]
            ),
            handler: { args in
                let channelId = args["channelId"]?.stringValue ?? ""
                let text = args["text"]?.stringValue ?? ""
                guard let currentAgentId = context.currentAgentId else {
                    return .object([
                        "ok": .bool(false),
                        "error": .string("slackPostMessage requires a sub-agent context — only invoked agents can post."),
                    ])
                }
                let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmedText.isEmpty else {
                    return .object([
                        "ok": .bool(false),
                        "error": .string("text must be non-empty"),
                    ])
                }
                // Snapshot @mentions BEFORE posting — we want the
                // text the agent actually wrote, not whatever the
                // store coerces.
                let agentsSnapshot = await MainActor.run {
                    slackData(store, myAppId: myAppId)?.agents ?? []
                }
                let mentions = SlackView.parseMentions(text: trimmedText, agents: agentsSnapshot)
                // Resolve componentId for the store mutator.
                let componentId = await MainActor.run {
                    store.slackComponentId(myAppId: myAppId)
                }
                guard let componentId else {
                    return .object([
                        "ok": .bool(false),
                        "error": .string("no slack component"),
                    ])
                }
                let messageId = await MainActor.run {
                    store.slackPostMessage(
                        channelId: channelId,
                        authorKind: .agent,
                        authorId: currentAgentId,
                        text: trimmedText,
                        mentionedAgentIds: mentions,
                        myAppId: myAppId,
                        componentId: componentId
                    )
                }
                guard let messageId else {
                    return .object([
                        "ok": .bool(false),
                        "error": .string("could not post — channel not found"),
                    ])
                }
                await context.markMessagePosted(currentAgentId)
                // Fan out to each @mention sequentially. Sequential
                // (not parallel) so the invocation stack grows
                // predictably and the chain-depth guard sees one
                // nested level at a time.
                var fanOut: [AnyJSON] = []
                for targetId in mentions {
                    let outcome = await context.invoke(targetId, channelId)
                    fanOut.append(Self.encodeFanOutOutcome(agentId: targetId, outcome: outcome))
                }
                return .object([
                    "ok": .bool(true),
                    "messageId": .string(messageId),
                    "channelId": .string(channelId),
                    "fanOut": .array(fanOut),
                ])
            }
        ))

        // --- Admin (main chat only) ----------------------------

        registry.register(ClientTool(
            descriptor: ToolDescriptor(
                name: "slackCreateAgent",
                description: """
                Create a new agent in this MyApp's Slack canvas. \
                `name` is the @-mentionable handle (one token, no \
                spaces). `role` is a short label ("marketing", \
                "engineering"). `systemPromptAddition` is the \
                persona text appended to the base system prompt \
                for every invocation of this agent — keep it \
                focused on behaviour, not facts. Refused if the \
                caller is itself a Slack agent (only the main \
                chat agent can create agents in v1). \
                Result echoes {agentId, name, role}.
                """,
                parameters: [
                    "type": "object",
                    "properties": [
                        "name": ["type": "string"],
                        "role": ["type": "string"],
                        "systemPromptAddition": ["type": "string"],
                    ],
                    "required": ["name", "role"],
                ]
            ),
            handler: { args in
                if context.currentAgentId != nil {
                    return Self.adminForbiddenResult()
                }
                let name = args["name"]?.stringValue ?? ""
                let role = args["role"]?.stringValue ?? ""
                let prompt = args["systemPromptAddition"]?.stringValue ?? ""
                if let mem = memory {
                    let (folderPath, exists) = await MainActor.run {
                        // mem is app-scoped, so use the app-relative subfolder path
                        let path = MemoryStore.slackAgentSubfolder(agentName: name)
                        return (path, mem.folderExists(at: path))
                    }
                    if exists {
                        return .object([
                            "ok": .bool(false),
                            "error": .string(
                                "A memory folder already exists at '\(folderPath)'. " +
                                "Choose a different agent name or delete the folder first."
                            ),
                        ])
                    }
                }
                return await MainActor.run {
                    guard let agentId = store.slackAddAgent(
                        name: name,
                        role: role,
                        systemPromptAddition: prompt,
                        myAppId: myAppId
                    ) else {
                        return .object([
                            "ok": .bool(false),
                            "error": .string("could not add agent — name empty or no slack component"),
                        ])
                    }
                    // Auto-write AGENTS.md into the agent's memory subfolder
                    // so its role and persona are persisted and visible in
                    // the sidebar from the moment it's created.
                    if let mem = memory {
                        let subfolder = MemoryStore.slackAgentSubfolder(agentName: name)
                        let agentsContent = """
                            # \(name)

                            **Role:** \(role)

                            ## Persona
                            \(prompt.isEmpty ? "_No persona set._" : prompt)
                            """
                        _ = try? mem.writeFile(
                            path: "\(subfolder)/AGENTS.md",
                            content: agentsContent
                        )
                    }
                    return .object([
                        "ok": .bool(true),
                        "agentId": .string(agentId),
                        "name": .string(name),
                        "role": .string(role),
                    ])
                }
            }
        ))

        registry.register(ClientTool(
            descriptor: ToolDescriptor(
                name: "slackCreateChannels",
                description: """
                Create one or more channels / group DMs / 1-on-1 DMs \
                in this MyApp's Slack canvas. Always pass a `channels` \
                array — wrap a single channel as `[{ ... }]`. Each entry \
                is `{name, type, memberAgentIds?}`. `type` is one of \
                "channel", "groupDM", "dm". Unknown agent ids in \
                `memberAgentIds` are silently dropped (call \
                slackListAgents first to resolve names). Refused \
                if the caller is itself a Slack agent — only the \
                main chat agent can manage channels in v1. Result \
                echoes {created: [{channelId, name, type}]}.
                """,
                parameters: [
                    "type": "object",
                    "properties": [
                        "channels": [
                            "type": "array",
                            "items": [
                                "type": "object",
                                "properties": [
                                    "name": ["type": "string"],
                                    "type": ["type": "string", "enum": ["channel", "groupDM", "dm"]],
                                    "memberAgentIds": [
                                        "type": "array",
                                        "items": ["type": "string"],
                                    ],
                                ],
                                "required": ["name", "type"],
                            ],
                        ],
                    ],
                    "required": ["channels"],
                ]
            ),
            handler: { args in
                if context.currentAgentId != nil {
                    return Self.adminForbiddenResult()
                }
                let entries = args["channels"]?.arrayValue ?? []
                var created: [AnyJSON] = []
                await MainActor.run {
                    for entry in entries {
                        let obj = entry.objectValue ?? [:]
                        let name = obj["name"]?.stringValue ?? ""
                        let typeStr = obj["type"]?.stringValue ?? ""
                        let memberIds = (obj["memberAgentIds"]?.arrayValue ?? [])
                            .compactMap { $0.stringValue }
                        guard let type = SlackChannelType(rawValue: typeStr) else { continue }
                        if let id = store.slackAddChannel(
                            name: name,
                            type: type,
                            memberAgentIds: memberIds,
                            myAppId: myAppId
                        ) {
                            created.append(.object([
                                "channelId": .string(id),
                                "name": .string(name),
                                "type": .string(typeStr),
                            ]))
                        }
                    }
                }
                return .object([
                    "ok": .bool(true),
                    "created": .array(created),
                ])
            }
        ))

        registry.register(ClientTool(
            descriptor: ToolDescriptor(
                name: "slackAddAgentsToChannel",
                description: """
                Add one or more agents to a channel's member \
                roster. `channelId` + `agentIds` (array; pass `[id]` \
                for a single agent). Idempotent — already-present \
                ids are skipped. Refused for sub-agent callers. \
                Result echoes {channelId, added}.
                """,
                parameters: [
                    "type": "object",
                    "properties": [
                        "channelId": ["type": "string"],
                        "agentIds": [
                            "type": "array",
                            "items": ["type": "string"],
                        ],
                    ],
                    "required": ["channelId", "agentIds"],
                ]
            ),
            handler: { args in
                if context.currentAgentId != nil {
                    return Self.adminForbiddenResult()
                }
                let channelId = args["channelId"]?.stringValue ?? ""
                let agentIds = (args["agentIds"]?.arrayValue ?? [])
                    .compactMap { $0.stringValue }
                return await MainActor.run {
                    let changed = store.slackAddAgentsToChannel(
                        channelId: channelId,
                        agentIds: agentIds,
                        myAppId: myAppId
                    )
                    return .object([
                        "ok": .bool(true),
                        "channelId": .string(channelId),
                        "added": .bool(changed),
                    ])
                }
            }
        ))
    }

    /// Resolve the first `SlackData` body within the MyApp,
    /// preferring the active component if it's a Slack one.
    /// Mirrors `tracker(_:myAppId:)` etc.
    @MainActor
    private static func slackData(_ store: MyAppStore, myAppId: UUID) -> SlackData? {
        guard let myApp = store.myApps.first(where: { $0.id == myAppId }) else { return nil }
        if let activeId = myApp.activeComponentId,
           let comp = myApp.components.first(where: { $0.id == activeId }),
           case .slack(let s) = comp.body { return s }
        for comp in myApp.components {
            if case .slack(let s) = comp.body { return s }
        }
        return nil
    }

    /// JSON-encode one fan-out outcome for inclusion in the
    /// `slackPostMessage` tool result. Reentrancy / busy /
    /// max-depth all surface as `{ok: false, error}` rows so the
    /// invoking agent can react without parsing free-form text.
    ///
    /// TODO(#193 follow-up): bring this echo to parity with
    /// `invokeMyAppAgent`'s `agent_unavailable` payload — surface
    /// `target` (as `AgentInvocationKey.wireValue`), `callPath`, and
    /// `treeRootedAt` so a Slack agent can reason about the forest
    /// programmatically instead of only reading the human-readable
    /// `error` string. Requires plumbing the rejection's structured
    /// fields through `SlackInvoker.InvocationOutcome`, which today
    /// only carries `targetName` + `depth`.
    private static func encodeFanOutOutcome(
        agentId: String,
        outcome: SlackInvoker.InvocationOutcome
    ) -> AnyJSON {
        switch outcome {
        case .completed(let text, let messageId):
            return .object([
                "agentId": .string(agentId),
                "outcome": .string("completed"),
                "text": .string(text),
                "messageId": messageId.map { AnyJSON.string($0) } ?? .null,
            ])
        case .reentrant(let name):
            return .object([
                "agentId": .string(agentId),
                "outcome": .string("reentrant"),
                "error": .string("@\(name) invoked you earlier — they're waiting on your reply. Finish your turn before calling them again."),
            ])
        case .busy(let name):
            return .object([
                "agentId": .string(agentId),
                "outcome": .string("busy"),
                "error": .string("@\(name) is already replying in a parallel turn — try again once they finish."),
            ])
        case .maxDepthExceeded(let name, let depth):
            return .object([
                "agentId": .string(agentId),
                "outcome": .string("max_depth_exceeded"),
                "error": .string("Cannot invoke @\(name): agent chain already \(depth) deep. Reply directly instead of asking another agent."),
            ])
        case .budgetExhausted(let name, let n):
            return .object([
                "agentId": .string(agentId),
                "outcome": .string("budget_exhausted"),
                "error": .string("Turn budget with @\(name) exhausted after \(n) turns. Start a new conversation to re-engage."),
            ])
        case .failed(let error):
            return .object([
                "agentId": .string(agentId),
                "outcome": .string("failed"),
                "error": .string(error),
            ])
        }
    }

    private static func adminForbiddenResult() -> AnyJSON {
        .object([
            "ok": .bool(false),
            "error": .string("Only the main chat agent can manage Slack agents and channels. Ask the user to create what you need."),
        ])
    }

    @MainActor
    public static func registerMemoryTools(on registry: ToolRegistry, memory: MemoryStore) {
        registry.register(ClientTool(
            descriptor: ToolDescriptor(
                name: "lsMemories",
                description: """
                List entries at a memory path. `path` is relative to the memories \
                root (use "" for the root). With `recursive=true`, returns the full \
                subtree (paths flattened). Result echoes \
                {entries: [{path, name, kind: "file"|"folder", sizeBytes?, modifiedAt?}]}.
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

    private static func trackerSchema() -> AnyJSON {
        [
            "type": "object",
            "properties": [
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

    private static func calendarEventSchema() -> AnyJSON {
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

    private static func parseEvents(from json: AnyJSON?) -> [CalendarEvent] {
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
    private static func parseLinkedItems(from json: AnyJSON?) -> [ComponentItemRef] {
        guard let arr = json?.arrayValue else { return [] }
        return arr.compactMap { entry in
            guard let componentId = entry["componentId"]?.stringValue,
                  let idString = entry["itemId"]?.stringValue,
                  let uuid = UUID(uuidString: idString) else { return nil }
            return ComponentItemRef(componentId: componentId, itemId: uuid)
        }
    }

    private static func checklistItemSchema() -> AnyJSON {
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

    private static func parseChecklistItems(from json: AnyJSON?) -> [ChecklistItem] {
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

    private static func checklistItemAsAnyJSON(_ item: ChecklistItem) -> AnyJSON {
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

    private static func eventAsAnyJSON(_ event: CalendarEvent) -> AnyJSON {
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
        default: return "square.dashed"
        }
    }

    private static func parseFields(from json: AnyJSON?) -> [FieldDef] {
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
    private static func stringify(_ v: AnyJSON) -> String {
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
    /// component if it's a tracker, otherwise returns the first tracker in
    /// component order. Returns nil if the MyApp has no tracker. Symmetric
    /// with how `MyAppStore.mutate(kind: "tracker", …)` resolves its target.
    @MainActor
    private static func tracker(_ store: MyAppStore, myAppId: UUID) -> TrackerData? {
        guard let myApp = store.myApps.first(where: { $0.id == myAppId }) else { return nil }
        if let active = myApp.activeComponent, case .tracker(let t) = active.body { return t }
        for c in myApp.components {
            if case .tracker(let t) = c.body { return t }
        }
        return nil
    }

    @MainActor
    private static func calendar(_ store: MyAppStore, myAppId: UUID) -> CalendarData? {
        guard let myApp = store.myApps.first(where: { $0.id == myAppId }) else { return nil }
        if let active = myApp.activeComponent, case .calendar(let c) = active.body { return c }
        for c in myApp.components {
            if case .calendar(let cd) = c.body { return cd }
        }
        return nil
    }

    @MainActor
    private static func checklist(_ store: MyAppStore, myAppId: UUID) -> ChecklistData? {
        guard let myApp = store.myApps.first(where: { $0.id == myAppId }) else { return nil }
        if let active = myApp.activeComponent, case .checklist(let cl) = active.body { return cl }
        for c in myApp.components {
            if case .checklist(let cl) = c.body { return cl }
        }
        return nil
    }

    // MARK: - Calculator helpers

    @MainActor
    private static func calculator(_ store: MyAppStore, myAppId: UUID) -> CalculatorData? {
        guard let myApp = store.myApps.first(where: { $0.id == myAppId }) else { return nil }
        if let active = myApp.activeComponent, case .calculator(let c) = active.body { return c }
        for c in myApp.components {
            if case .calculator(let cd) = c.body { return cd }
        }
        return nil
    }

    @MainActor
    private static func resolveCalculator(
        store: MyAppStore,
        myAppId: UUID,
        componentId: String?
    ) -> (CalculatorData, String)? {
        guard let myApp = store.myApps.first(where: { $0.id == myAppId }) else { return nil }
        if let componentId {
            guard let component = myApp.components.first(where: { $0.id == componentId }),
                  case .calculator(let c) = component.body else { return nil }
            return (c, componentId)
        }
        let activeIdx = myApp.activeComponentId.flatMap { id in
            myApp.components.firstIndex(where: { $0.id == id })
        }
        if let activeIdx, case .calculator(let c) = myApp.components[activeIdx].body {
            return (c, myApp.components[activeIdx].id)
        }
        for component in myApp.components {
            if case .calculator(let c) = component.body { return (c, component.id) }
        }
        return nil
    }

    /// Sibling components of `myAppId` — the pool calculator aggregate rows
    /// resolve their source trackers from.
    @MainActor
    private static func siblingComponents(store: MyAppStore, myAppId: UUID) -> [Component] {
        store.myApps.first(where: { $0.id == myAppId })?.components ?? []
    }

    /// `[{key, value?, status}]` for every row, resolved live. Echoed by the
    /// mutating calculator tools so the agent sees computed values mid-turn.
    @MainActor
    private static func calcResults(store: MyAppStore, myAppId: UUID, data: CalculatorData) -> AnyJSON {
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

    private static func calcRowSchema() -> AnyJSON {
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

    private static func calcRowPatchSchema() -> AnyJSON {
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
    private static func parseRef(from json: AnyJSON?) -> ComponentItemRef? {
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
    private static func parseCalcRowParts(
        from entry: AnyJSON
    ) -> (key: String?, name: String, unit: String?, format: String?, kind: CalcRowKind)? {
        guard let kind = parseCalcRowKind(from: entry) else { return nil }
        let key = entry["key"]?.stringValue
        let name = entry["name"]?.stringValue ?? key ?? ""
        return (key, name, entry["unit"]?.stringValue, entry["format"]?.stringValue, kind)
    }

    /// Parse a full `rows` array for `renderCalculator`, slug-deduping keys
    /// up front so the destructive render lands with unique handles.
    private static func parseCalcRows(from json: AnyJSON?) -> [CalcRow] {
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

    private static func parseCalcRowPatch(from json: AnyJSON?) -> MyAppStore.CalcRowPatch {
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
    private static func calcRowAsAnyJSON(
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
        guard let myApp = store.myApps.first(where: { $0.id == myAppId }) else { return nil }
        if let active = myApp.activeComponent, case .chart(let c) = active.body { return (c, active.id) }
        for c in myApp.components {
            if case .chart(let cd) = c.body { return (cd, c.id) }
        }
        return nil
    }

    /// `{ok, componentId, title, kind, seriesCount, pointCount}` for the
    /// resolved chart. Shared by every chart mutating tool.
    @MainActor
    private static func chartEcho(store: MyAppStore, myAppId: UUID) -> AnyJSON {
        guard let (data, id) = chartData(store, myAppId: myAppId) else {
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

    private static func chartSeriesSchema() -> AnyJSON {
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
    private static func parseChartSeries(from json: AnyJSON?) -> [ChartSeriesSpec] {
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

    private static func valuesAsAnyJSON(_ values: [String: String]) -> AnyJSON {
        .object(values.mapValues { .string($0) })
    }

    private static func fieldAsAnyJSON(_ field: FieldDef) -> AnyJSON {
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

    private static func visibleCount(_ tracker: TrackerData?) -> Int {
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
