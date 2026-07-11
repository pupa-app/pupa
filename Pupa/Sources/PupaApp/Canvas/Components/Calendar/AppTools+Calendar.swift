import Foundation
import AGUIKit

extension AppTools {
    // Calendar component frontend tools. Relocated from the AppTools
    // monolith into the Calendar component folder (issue #162);
    // registerMyAppTools + CalendarModule.registerTools both call it.
    // Zero logic change.
    @MainActor
    static func registerCalendarTools(
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
                        "componentId": componentIdSchema(kind: "calendar"),
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
                let componentIdArg = args["componentId"]?.stringValue
                let hasSummary = summaryArg != nil
                let hasBodyArgs = titleArg != nil
                return await MainActor.run {
                    guard hasBodyArgs || hasSummary else {
                        return .object([
                            "ok": .bool(false),
                            "error": "renderCalendar called with no arguments. Pass `title` (with optional `events`) for a full render and/or `summary` to update your content summary.",
                        ])
                    }
                    let resolvedId: String
                    switch store.resolveRenderTarget(kind: "calendar", componentId: componentIdArg, myAppId: myAppId) {
                    case .failure(let msg):
                        return .object(["ok": .bool(false), "error": .string(msg)])
                    case .resolved(let id):
                        resolvedId = id
                    }
                    if let title = titleArg {
                        let events = parseEvents(from: args["events"])
                        store.setCalendar(title: title, events: events, myAppId: myAppId, componentId: resolvedId)
                    }
                    var summarySet = false
                    if hasSummary {
                        summarySet = store.setComponentSummary(
                            forKind: "calendar",
                            summary: summaryArg?.stringValue,
                            myAppId: myAppId,
                            componentId: resolvedId
                        )
                    }
                    let c = calendar(store, myAppId: myAppId, componentId: resolvedId)
                    var result: [String: AnyJSON] = ["ok": .bool(c != nil), "componentId": .string(resolvedId)]
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
                    "properties": [
                        "event": calendarEventSchema(),
                        "componentId": componentIdSchema(kind: "calendar"),
                    ],
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
                let componentIdArg = args["componentId"]?.stringValue
                let event = CalendarEvent(
                    title: title,
                    start: start,
                    end: obj["end"]?.stringValue,
                    location: obj["location"]?.stringValue,
                    notes: obj["notes"]?.stringValue,
                    linkedItems: parseLinkedItems(from: obj["linkedItems"])
                )
                return await MainActor.run {
                    let resolvedId: String
                    switch store.resolveWriteTarget(kind: "calendar", componentId: componentIdArg, myAppId: myAppId) {
                    case .failure(let msg):
                        return .object(["ok": .bool(false), "error": .string(msg)])
                    case .resolved(let id):
                        resolvedId = id
                    }
                    guard let id = store.addCalendarEvent(event, myAppId: myAppId, componentId: resolvedId, actor: .agent(toolName: "addCalendarEvent")) else {
                        return .object([
                            "ok": .bool(false),
                            "error": "no calendar component in this MyApp — call renderCalendar or addComponent first",
                        ])
                    }
                    let c = calendar(store, myAppId: myAppId, componentId: resolvedId)
                    return .object([
                        "ok": .bool(true),
                        "componentId": .string(resolvedId),
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
                    "properties": [
                        "id": ["type": "string"],
                        "componentId": componentIdSchema(kind: "calendar"),
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
                    switch store.resolveWriteTarget(kind: "calendar", componentId: componentIdArg, myAppId: myAppId) {
                    case .failure(let msg):
                        return .object(["ok": .bool(false), "error": .string(msg)])
                    case .resolved(let id):
                        resolvedId = id
                    }
                    guard let removed = store.removeCalendarEvent(id: uuid, myAppId: myAppId, componentId: resolvedId, actor: .agent(toolName: "removeCalendarEvent")) else {
                        return .object([
                            "ok": .bool(false),
                            "error": .string("no event with id \(idString)"),
                        ])
                    }
                    let c = calendar(store, myAppId: myAppId, componentId: resolvedId)
                    return .object([
                        "ok": .bool(true),
                        "componentId": .string(resolvedId),
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
                        "componentId": componentIdSchema(kind: "calendar"),
                    ],
                    "required": ["mode"],
                ]
            ),
            handler: { args in
                let raw = args["mode"]?.stringValue ?? ""
                let componentIdArg = args["componentId"]?.stringValue
                guard let mode = CalendarViewMode(rawValue: raw) else {
                    return .object([
                        "ok": .bool(false),
                        "error": .string("invalid mode '\(raw)' (expected 'list' or 'month')"),
                    ])
                }
                return await MainActor.run {
                    let resolvedId: String
                    switch store.resolveWriteTarget(kind: "calendar", componentId: componentIdArg, myAppId: myAppId) {
                    case .failure(let msg):
                        return .object(["ok": .bool(false), "error": .string(msg)])
                    case .resolved(let id):
                        resolvedId = id
                    }
                    guard let resolved = store.setCalendarViewMode(mode, myAppId: myAppId, componentId: resolvedId) else {
                        return .object([
                            "ok": .bool(false),
                            "error": .string("no calendar component in this MyApp"),
                        ])
                    }
                    return .object([
                        "ok": .bool(true),
                        "componentId": .string(resolvedId),
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
                        "componentId": componentIdSchema(kind: "calendar"),
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
                    let resolvedId: String
                    switch store.resolveWriteTarget(kind: "calendar", componentId: componentIdArg, myAppId: myAppId) {
                    case .failure(let msg):
                        return .object(["ok": .bool(false), "error": .string(msg)])
                    case .resolved(let id):
                        resolvedId = id
                    }
                    guard let after = store.patchCalendarEvent(id: uuid, patch: patch, myAppId: myAppId, componentId: resolvedId, actor: .agent(toolName: "patchCalendarEvent")) else {
                        return .object([
                            "ok": .bool(false),
                            "error": .string("no event with id \(idString)"),
                        ])
                    }
                    return .object([
                        "ok": .bool(true),
                        "componentId": .string(resolvedId),
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
            readOnly: true,
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
            readOnly: true,
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
}
