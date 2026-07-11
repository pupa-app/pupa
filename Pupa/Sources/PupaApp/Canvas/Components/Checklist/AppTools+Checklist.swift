import Foundation
import AGUIKit

extension AppTools {
    // Checklist component frontend tools. Relocated from the AppTools
    // monolith into the Checklist folder (issue #162). Zero logic change.
    @MainActor
    static func registerChecklistTools(
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
                        "componentId": componentIdSchema(kind: "checklist"),
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
                let componentIdArg = args["componentId"]?.stringValue
                let hasSummary = summaryArg != nil
                let hasBodyArgs = titleArg != nil
                return await MainActor.run {
                    guard hasBodyArgs || hasSummary else {
                        return .object([
                            "ok": .bool(false),
                            "error": "renderChecklist called with no arguments. Pass `title` (with optional `items`) for a full render and/or `summary` to update your content summary.",
                        ])
                    }
                    let resolvedId: String
                    switch store.resolveRenderTarget(kind: "checklist", componentId: componentIdArg, myAppId: myAppId) {
                    case .failure(let msg):
                        return .object(["ok": .bool(false), "error": .string(msg)])
                    case .resolved(let id):
                        resolvedId = id
                    }
                    if let title = titleArg {
                        let items = parseChecklistItems(from: args["items"])
                        store.setChecklist(title: title, items: items, myAppId: myAppId, componentId: resolvedId)
                    }
                    var summarySet = false
                    if hasSummary {
                        summarySet = store.setComponentSummary(
                            forKind: "checklist",
                            summary: summaryArg?.stringValue,
                            myAppId: myAppId,
                            componentId: resolvedId
                        )
                    }
                    let cl = checklist(store, myAppId: myAppId, componentId: resolvedId)
                    var result: [String: AnyJSON] = ["ok": .bool(cl != nil), "componentId": .string(resolvedId)]
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
                        "componentId": componentIdSchema(kind: "checklist"),
                    ],
                    "required": ["text"],
                ]
            ),
            handler: { args in
                let text = args["text"]?.stringValue ?? ""
                let done = args["done"]?.boolValue ?? false
                let componentIdArg = args["componentId"]?.stringValue
                return await MainActor.run {
                    let resolvedId: String
                    switch store.resolveWriteTarget(kind: "checklist", componentId: componentIdArg, myAppId: myAppId) {
                    case .failure(let msg):
                        return .object(["ok": .bool(false), "error": .string(msg)])
                    case .resolved(let id):
                        resolvedId = id
                    }
                    guard let id = store.addChecklistItem(text: text, done: done, myAppId: myAppId, componentId: resolvedId, actor: .agent(toolName: "addChecklistItem")) else {
                        return .object([
                            "ok": .bool(false),
                            "error": "no checklist component in this MyApp — call renderChecklist or addComponent first",
                        ])
                    }
                    let cl = checklist(store, myAppId: myAppId, componentId: resolvedId)
                    return .object([
                        "ok": .bool(true),
                        "componentId": .string(resolvedId),
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
                    "properties": [
                        "id": ["type": "string"],
                        "componentId": componentIdSchema(kind: "checklist"),
                    ],
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
                let componentIdArg = args["componentId"]?.stringValue
                return await MainActor.run {
                    let resolvedId: String
                    switch store.resolveWriteTarget(kind: "checklist", componentId: componentIdArg, myAppId: myAppId) {
                    case .failure(let msg):
                        return .object(["ok": .bool(false), "error": .string(msg)])
                    case .resolved(let id):
                        resolvedId = id
                    }
                    guard let newValue = store.toggleChecklistItem(id: uuid, myAppId: myAppId, componentId: resolvedId, actor: .agent(toolName: "toggleChecklistItem")) else {
                        return .object([
                            "ok": .bool(false),
                            "error": .string("no checklist item with id \(idString)"),
                        ])
                    }
                    let cl = checklist(store, myAppId: myAppId, componentId: resolvedId)
                    return .object([
                        "ok": .bool(true),
                        "componentId": .string(resolvedId),
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
                        "componentId": componentIdSchema(kind: "checklist"),
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
                let componentIdArg = args["componentId"]?.stringValue
                let patchObj = args["patch"]?.objectValue ?? [:]
                var patch = MyAppStore.ChecklistItemPatch()
                if let v = patchObj["text"]?.stringValue { patch.text = v }
                if let v = patchObj["done"]?.boolValue { patch.done = v }
                if patchObj["linkedItems"] != nil {
                    patch.linkedItems = parseLinkedItems(from: patchObj["linkedItems"])
                }
                return await MainActor.run {
                    let resolvedId: String
                    switch store.resolveWriteTarget(kind: "checklist", componentId: componentIdArg, myAppId: myAppId) {
                    case .failure(let msg):
                        return .object(["ok": .bool(false), "error": .string(msg)])
                    case .resolved(let id):
                        resolvedId = id
                    }
                    guard let after = store.patchChecklistItem(id: uuid, patch: patch, myAppId: myAppId, componentId: resolvedId, actor: .agent(toolName: "patchChecklistItem")) else {
                        return .object([
                            "ok": .bool(false),
                            "error": .string("no checklist item with id \(idString)"),
                        ])
                    }
                    return .object([
                        "ok": .bool(true),
                        "componentId": .string(resolvedId),
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
                    "properties": [
                        "id": ["type": "string"],
                        "componentId": componentIdSchema(kind: "checklist"),
                    ],
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
                let componentIdArg = args["componentId"]?.stringValue
                return await MainActor.run {
                    let resolvedId: String
                    switch store.resolveWriteTarget(kind: "checklist", componentId: componentIdArg, myAppId: myAppId) {
                    case .failure(let msg):
                        return .object(["ok": .bool(false), "error": .string(msg)])
                    case .resolved(let id):
                        resolvedId = id
                    }
                    guard let removed = store.removeChecklistItem(id: uuid, myAppId: myAppId, componentId: resolvedId, actor: .agent(toolName: "removeChecklistItem")) else {
                        return .object([
                            "ok": .bool(false),
                            "error": .string("no checklist item with id \(idString)"),
                        ])
                    }
                    let cl = checklist(store, myAppId: myAppId, componentId: resolvedId)
                    return .object([
                        "ok": .bool(true),
                        "componentId": .string(resolvedId),
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
            readOnly: true,
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
}
