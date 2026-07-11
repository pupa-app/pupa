import Foundation
import AGUIKit

extension AppTools {
    /// Register the tracker component's frontend tools (render / add / patch /
    /// remove items, field-schema mutators, filter + view mode). Extracted from
    /// the `registerMyAppTools` monolith into the Tracker component folder
    /// (issue #162); `TrackerModule.registerTools` forwards here. Discovery tools
    /// (list/search/get) still register separately. Zero logic change.
    @MainActor
    static func registerTrackerTools(
        on registry: ToolRegistry,
        store: MyAppStore,
        myAppId: UUID
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
                let componentIdArg = args["componentId"]?.stringValue
                let hasSummary = summaryArg != nil
                let hasBodyArgs = titleArg != nil || fieldsArg != nil
                return await MainActor.run {
                    guard hasBodyArgs || hasSummary else {
                        return .object([
                            "ok": .bool(false),
                            "error": "renderTracker called with no arguments. Pass `title` + `fields` for a full render and/or `summary` to update your content summary.",
                        ])
                    }
                    // Resolve the target deterministically (never via the
                    // active/view component). Surface ambiguity to the agent.
                    let resolvedId: String
                    switch store.resolveTrackerRenderTarget(componentId: componentIdArg, myAppId: myAppId) {
                    case .failure(let msg):
                        return .object(["ok": .bool(false), "error": .string(msg)])
                    case .resolved(let id):
                        resolvedId = id
                    }
                    if hasBodyArgs {
                        guard let title = titleArg, fieldsArg != nil else {
                            return .object([
                                "ok": .bool(false),
                                "error": "renderTracker requires BOTH `title` and `fields` for a full render. Pass only `summary` to update your content summary without re-rendering.",
                            ])
                        }
                        let fields = parseFields(from: fieldsArg)
                        store.setTracker(title: title, fields: fields, myAppId: myAppId, componentId: resolvedId)
                    }
                    var summarySet = false
                    if hasSummary {
                        summarySet = store.setComponentSummary(
                            forKind: "tracker",
                            summary: summaryArg?.stringValue,
                            myAppId: myAppId,
                            componentId: resolvedId
                        )
                    }
                    let t = tracker(store, myAppId: myAppId, componentId: resolvedId)
                    var result: [String: AnyJSON] = ["ok": .bool(true), "componentId": .string(resolvedId)]
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
                Append one or more items to a tracker. Pass `componentId` to \
                choose which tracker (required only when the myApp has more \
                than one; otherwise the single tracker is used — the active/ \
                viewed component is never assumed). Always pass an `items` \
                array — wrap a single item as `[{ ... }]`. Keys in each item \
                must match field names. Result echoes \
                {componentId, ids, added, totalItems}; `ids` are in the same \
                order as `items` and are stable UUIDs to pass to \
                `patchTrackerItems` / `removeTrackerItems` later.
                """,
                parameters: [
                    "type": "object",
                    "properties": [
                        "items": [
                            "type": "array",
                            "items": ["type": "object"],
                        ],
                        "componentId": componentIdSchema(),
                    ],
                    "required": ["items"],
                ]
            ),
            handler: { args in
                guard let itemsArray = args["items"]?.arrayValue else {
                    return .object(["ok": .bool(false), "error": "missing 'items' array"])
                }
                let componentIdArg = args["componentId"]?.stringValue
                return await MainActor.run {
                    let resolvedId: String
                    switch store.resolveTrackerWriteTarget(componentId: componentIdArg, myAppId: myAppId) {
                    case .failure(let msg):
                        return .object(["ok": .bool(false), "error": .string(msg)])
                    case .resolved(let id):
                        resolvedId = id
                    }
                    var ids: [AnyJSON] = []
                    var added: [AnyJSON] = []
                    for entry in itemsArray {
                        let values = (entry.objectValue ?? [:]).mapValues { stringify($0) }
                        let id = store.addItem(values, myAppId: myAppId, componentId: resolvedId, actor: .agent(toolName: "addTrackerItems"))
                        ids.append(id.map { .string($0.uuidString) } ?? .null)
                        added.append(valuesAsAnyJSON(values))
                    }
                    return .object([
                        "ok": .bool(true),
                        "componentId": .string(resolvedId),
                        "ids": .array(ids),
                        "added": .array(added),
                        "totalItems": .int(tracker(store, myAppId: myAppId, componentId: resolvedId)?.items.count ?? 0),
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
                        "componentId": componentIdSchema(),
                    ],
                    "required": ["patches"],
                ]
            ),
            handler: { args in
                guard let patchArray = args["patches"]?.arrayValue else {
                    return .object(["ok": .bool(false), "error": "missing 'patches' array"])
                }
                let componentIdArg = args["componentId"]?.stringValue
                return await MainActor.run {
                    let resolvedId: String
                    switch store.resolveTrackerWriteTarget(componentId: componentIdArg, myAppId: myAppId) {
                    case .failure(let msg):
                        return .object(["ok": .bool(false), "error": .string(msg)])
                    case .resolved(let id):
                        resolvedId = id
                    }
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
                        guard let t = tracker(store, myAppId: myAppId, componentId: resolvedId) else {
                            results.append(.object([
                                "ok": .bool(false),
                                "error": .string("canvas is not a tracker"),
                            ]))
                            allOk = false
                            continue
                        }
                        // Resolve the target row to a stable UUID up front so
                        // both the id and index paths write to the SAME
                        // component via the id-addressed patch.
                        let targetUUID: UUID?
                        if let idString, let uuid = UUID(uuidString: idString),
                           t.items.contains(where: { $0.id == uuid }) {
                            targetUUID = uuid
                        } else if let idx, t.items.indices.contains(idx) {
                            targetUUID = t.items[idx].id
                        } else {
                            targetUUID = nil
                        }
                        guard let uuid = targetUUID else {
                            results.append(.object([
                                "ok": .bool(false),
                                "error": .string(idString != nil ? "no item with id" : "missing id or valid index"),
                            ]))
                            allOk = false
                            continue
                        }
                        _ = store.patchItem(id: uuid, with: patch, myAppId: myAppId, componentId: resolvedId, actor: .agent(toolName: "patchTrackerItems"))
                        let after = tracker(store, myAppId: myAppId, componentId: resolvedId)?
                            .items.first(where: { $0.id == uuid })?.values ?? [:]
                        results.append(.object([
                            "ok": .bool(true),
                            "id": .string(uuid.uuidString),
                            "item": valuesAsAnyJSON(after),
                        ]))
                    }
                    return .object([
                        "ok": .bool(allOk),
                        "componentId": .string(resolvedId),
                        "results": .array(results),
                        "totalItems": .int(tracker(store, myAppId: myAppId, componentId: resolvedId)?.items.count ?? 0),
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
                        "componentId": componentIdSchema(),
                    ],
                    "required": ["targets"],
                ]
            ),
            handler: { args in
                guard let targetArray = args["targets"]?.arrayValue else {
                    return .object(["ok": .bool(false), "error": "missing 'targets' array"])
                }
                let componentIdArg = args["componentId"]?.stringValue
                return await MainActor.run {
                    let resolvedId: String
                    switch store.resolveTrackerWriteTarget(componentId: componentIdArg, myAppId: myAppId) {
                    case .failure(let msg):
                        return .object(["ok": .bool(false), "error": .string(msg)])
                    case .resolved(let id):
                        resolvedId = id
                    }
                    guard let t = tracker(store, myAppId: myAppId, componentId: resolvedId) else {
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
                            let ok = store.removeItem(id: uuid, myAppId: myAppId, componentId: resolvedId, actor: .agent(toolName: "removeTrackerItems"))
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
                        "componentId": .string(resolvedId),
                        "results": .array(results),
                        "totalItems": .int(tracker(store, myAppId: myAppId, componentId: resolvedId)?.items.count ?? 0),
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
                        "componentId": componentIdSchema(),
                    ],
                    "required": ["field", "value"],
                ]
            ),
            handler: { args in
                let field = args["field"]?.stringValue ?? ""
                let value = args["value"]?.stringValue ?? ""
                let componentIdArg = args["componentId"]?.stringValue
                return await MainActor.run {
                    let resolvedId: String
                    switch store.resolveWriteTarget(kind: "tracker", componentId: componentIdArg, myAppId: myAppId) {
                    case .failure(let msg):
                        return .object(["ok": .bool(false), "error": .string(msg)])
                    case .resolved(let id):
                        resolvedId = id
                    }
                    store.setFilter(field: field, value: value, myAppId: myAppId, componentId: resolvedId)
                    let t = tracker(store, myAppId: myAppId, componentId: resolvedId)
                    return .object([
                        "ok": .bool(true),
                        "componentId": .string(resolvedId),
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
                        "componentId": componentIdSchema(),
                    ],
                    "required": ["mode"],
                ]
            ),
            handler: { args in
                let modeRaw = args["mode"]?.stringValue ?? ""
                let requestedColumn = args["columnField"]?.stringValue
                let componentIdArg = args["componentId"]?.stringValue
                guard let mode = TrackerViewMode(rawValue: modeRaw) else {
                    return .object([
                        "ok": .bool(false),
                        "error": .string("invalid mode '\(modeRaw)' (expected 'grid' or 'kanban')"),
                    ])
                }
                return await MainActor.run {
                    let resolvedId: String
                    switch store.resolveWriteTarget(kind: "tracker", componentId: componentIdArg, myAppId: myAppId) {
                    case .failure(let msg):
                        return .object(["ok": .bool(false), "error": .string(msg)])
                    case .resolved(let id):
                        resolvedId = id
                    }
                    guard let resolved = store.setTrackerViewMode(
                        mode,
                        columnField: requestedColumn,
                        myAppId: myAppId,
                        componentId: resolvedId
                    ) else {
                        return .object([
                            "ok": .bool(false),
                            "error": .string("canvas is not a tracker"),
                        ])
                    }
                    let t = tracker(store, myAppId: myAppId, componentId: resolvedId)
                    return .object([
                        "ok": .bool(true),
                        "componentId": .string(resolvedId),
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
                        "componentId": componentIdSchema(),
                    ],
                    "required": ["fieldName", "option"],
                ]
            ),
            handler: { args in
                let field = args["fieldName"]?.stringValue ?? ""
                let opt = args["option"]?.stringValue ?? ""
                let componentIdArg = args["componentId"]?.stringValue
                return await MainActor.run {
                    let resolvedId: String
                    switch store.resolveWriteTarget(kind: "tracker", componentId: componentIdArg, myAppId: myAppId) {
                    case .failure(let msg):
                        return .object(["ok": .bool(false), "error": .string(msg)])
                    case .resolved(let id):
                        resolvedId = id
                    }
                    let ok = store.addFieldOption(fieldName: field, option: opt, myAppId: myAppId, componentId: resolvedId)
                    let t = tracker(store, myAppId: myAppId, componentId: resolvedId)
                    let opts = t?.fields.first(where: { $0.name == field })?.options ?? []
                    return .object([
                        "ok": .bool(ok),
                        "componentId": .string(resolvedId),
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
                        "componentId": componentIdSchema(),
                    ],
                    "required": ["fieldName", "option"],
                ]
            ),
            handler: { args in
                let field = args["fieldName"]?.stringValue ?? ""
                let opt = args["option"]?.stringValue ?? ""
                let componentIdArg = args["componentId"]?.stringValue
                return await MainActor.run {
                    let resolvedId: String
                    switch store.resolveWriteTarget(kind: "tracker", componentId: componentIdArg, myAppId: myAppId) {
                    case .failure(let msg):
                        return .object(["ok": .bool(false), "error": .string(msg)])
                    case .resolved(let id):
                        resolvedId = id
                    }
                    let ok = store.removeFieldOption(fieldName: field, option: opt, myAppId: myAppId, componentId: resolvedId)
                    let t = tracker(store, myAppId: myAppId, componentId: resolvedId)
                    let opts = t?.fields.first(where: { $0.name == field })?.options ?? []
                    return .object([
                        "ok": .bool(ok),
                        "componentId": .string(resolvedId),
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
                        "componentId": componentIdSchema(),
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
                let componentIdArg = args["componentId"]?.stringValue
                let field = FieldDef(
                    name: name,
                    label: args["label"]?.stringValue,
                    type: type,
                    options: args["options"]?.arrayValue?.compactMap(\.stringValue)
                )
                return await MainActor.run {
                    let resolvedId: String
                    switch store.resolveWriteTarget(kind: "tracker", componentId: componentIdArg, myAppId: myAppId) {
                    case .failure(let msg):
                        return .object(["ok": .bool(false), "error": .string(msg)])
                    case .resolved(let id):
                        resolvedId = id
                    }
                    if let err = store.addField(field, myAppId: myAppId, componentId: resolvedId) {
                        return .object([
                            "ok": .bool(false),
                            "error": .string(err.rawValue),
                        ])
                    }
                    let t = tracker(store, myAppId: myAppId, componentId: resolvedId)
                    return .object([
                        "ok": .bool(true),
                        "componentId": .string(resolvedId),
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
                        "componentId": componentIdSchema(),
                    ],
                    "required": ["from", "to"],
                ]
            ),
            handler: { args in
                let from = args["from"]?.stringValue ?? ""
                let to = args["to"]?.stringValue ?? ""
                let componentIdArg = args["componentId"]?.stringValue
                return await MainActor.run {
                    let resolvedId: String
                    switch store.resolveWriteTarget(kind: "tracker", componentId: componentIdArg, myAppId: myAppId) {
                    case .failure(let msg):
                        return .object(["ok": .bool(false), "error": .string(msg)])
                    case .resolved(let id):
                        resolvedId = id
                    }
                    switch store.renameField(from: from, to: to, myAppId: myAppId, componentId: resolvedId) {
                    case .failure(let err):
                        return .object([
                            "ok": .bool(false),
                            "error": .string(err.rawValue),
                        ])
                    case .success(let result):
                        let t = tracker(store, myAppId: myAppId, componentId: resolvedId)
                        return .object([
                            "ok": .bool(true),
                            "componentId": .string(resolvedId),
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
                        "componentId": componentIdSchema(),
                    ],
                    "required": ["order"],
                ]
            ),
            handler: { args in
                let order = args["order"]?.arrayValue?.compactMap(\.stringValue) ?? []
                let componentIdArg = args["componentId"]?.stringValue
                return await MainActor.run {
                    let resolvedId: String
                    switch store.resolveWriteTarget(kind: "tracker", componentId: componentIdArg, myAppId: myAppId) {
                    case .failure(let msg):
                        return .object(["ok": .bool(false), "error": .string(msg)])
                    case .resolved(let id):
                        resolvedId = id
                    }
                    if let err = store.reorderFields(order, myAppId: myAppId, componentId: resolvedId) {
                        return .object([
                            "ok": .bool(false),
                            "error": .string(err.rawValue),
                        ])
                    }
                    let t = tracker(store, myAppId: myAppId, componentId: resolvedId)
                    return .object([
                        "ok": .bool(true),
                        "componentId": .string(resolvedId),
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
                    "properties": [
                        "name": ["type": "string"],
                        "componentId": componentIdSchema(),
                    ],
                    "required": ["name"],
                ]
            ),
            handler: { args in
                let name = args["name"]?.stringValue ?? ""
                let componentIdArg = args["componentId"]?.stringValue
                return await MainActor.run {
                    let resolvedId: String
                    switch store.resolveWriteTarget(kind: "tracker", componentId: componentIdArg, myAppId: myAppId) {
                    case .failure(let msg):
                        return .object(["ok": .bool(false), "error": .string(msg)])
                    case .resolved(let id):
                        resolvedId = id
                    }
                    switch store.setFieldHidden(name: name, hidden: true, myAppId: myAppId, componentId: resolvedId) {
                    case .failure(let err):
                        return .object([
                            "ok": .bool(false),
                            "error": .string(err.rawValue),
                        ])
                    case .success(let result):
                        var payload: [String: AnyJSON] = [
                            "ok": .bool(true),
                            "componentId": .string(resolvedId),
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
                    "properties": [
                        "name": ["type": "string"],
                        "componentId": componentIdSchema(),
                    ],
                    "required": ["name"],
                ]
            ),
            handler: { args in
                let name = args["name"]?.stringValue ?? ""
                let componentIdArg = args["componentId"]?.stringValue
                return await MainActor.run {
                    let resolvedId: String
                    switch store.resolveWriteTarget(kind: "tracker", componentId: componentIdArg, myAppId: myAppId) {
                    case .failure(let msg):
                        return .object(["ok": .bool(false), "error": .string(msg)])
                    case .resolved(let id):
                        resolvedId = id
                    }
                    switch store.setFieldHidden(name: name, hidden: false, myAppId: myAppId, componentId: resolvedId) {
                    case .failure(let err):
                        return .object([
                            "ok": .bool(false),
                            "error": .string(err.rawValue),
                        ])
                    case .success(let result):
                        return .object([
                            "ok": .bool(true),
                            "componentId": .string(resolvedId),
                            "name": .string(name),
                            "hidden": .bool(result.hidden),
                        ])
                    }
                }
            }
        ))
    }
}
