import Foundation
import AGUIKit

extension AppTools {
    // Calculator component frontend tools. Relocated from the AppTools
    // monolith into the Calculator folder (issue #162). Zero logic change.
    @MainActor
    static func registerCalculatorTools(
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
                        "componentId": componentIdSchema(kind: "calculator"),
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
                let componentIdArg = args["componentId"]?.stringValue
                let hasSummary = summaryArg != nil
                let hasBodyArgs = titleArg != nil
                return await MainActor.run {
                    guard hasBodyArgs || hasSummary else {
                        return .object([
                            "ok": .bool(false),
                            "error": "renderCalculator called with no arguments. Pass `title` (with optional `rows`) for a full render and/or `summary` to update your content summary.",
                        ])
                    }
                    let resolvedId: String
                    switch store.resolveRenderTarget(kind: "calculator", componentId: componentIdArg, myAppId: myAppId) {
                    case .failure(let msg):
                        return .object(["ok": .bool(false), "error": .string(msg)])
                    case .resolved(let id):
                        resolvedId = id
                    }
                    if let title = titleArg {
                        let rows = parseCalcRows(from: args["rows"])
                        store.setCalculator(title: title, rows: rows, myAppId: myAppId, componentId: resolvedId)
                    }
                    var summarySet = false
                    if hasSummary {
                        summarySet = store.setComponentSummary(
                            forKind: "calculator",
                            summary: summaryArg?.stringValue,
                            myAppId: myAppId,
                            componentId: resolvedId
                        )
                    }
                    guard let data = calculator(store, myAppId: myAppId, componentId: resolvedId) else {
                        return .object([
                            "ok": .bool(false),
                            "error": "no calculator component in this MyApp — call addComponent(kind:\"calculator\", …) first",
                        ])
                    }
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
                    "properties": [
                        "rows": ["type": "array", "items": calcRowSchema()],
                        "componentId": componentIdSchema(kind: "calculator"),
                    ],
                    "required": ["rows"],
                ]
            ),
            handler: { args in
                guard let entries = args["rows"]?.arrayValue, !entries.isEmpty else {
                    return .object(["ok": .bool(false), "error": "missing 'rows' array"])
                }
                let componentIdArg = args["componentId"]?.stringValue
                return await MainActor.run {
                    let resolvedId: String
                    switch store.resolveWriteTarget(kind: "calculator", componentId: componentIdArg, myAppId: myAppId) {
                    case .failure(let msg):
                        return .object(["ok": .bool(false), "error": .string(msg)])
                    case .resolved(let id):
                        resolvedId = id
                    }
                    var added: [AnyJSON] = []
                    for entry in entries {
                        guard let (key, name, unit, format, kind) = parseCalcRowParts(from: entry) else { continue }
                        if let resolvedKey = store.addCalcRow(
                            key: key, name: name, unit: unit, format: format, kind: kind,
                            myAppId: myAppId, componentId: resolvedId, actor: .agent(toolName: "addCalcRows")
                        ) {
                            added.append(.object(["key": .string(resolvedKey), "name": .string(name)]))
                        }
                    }
                    let data = calculator(store, myAppId: myAppId, componentId: resolvedId)
                    var result: [String: AnyJSON] = [
                        "ok": .bool(true),
                        "componentId": .string(resolvedId),
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
                        "componentId": componentIdSchema(kind: "calculator"),
                    ],
                    "required": ["patches"],
                ]
            ),
            handler: { args in
                guard let entries = args["patches"]?.arrayValue, !entries.isEmpty else {
                    return .object(["ok": .bool(false), "error": "missing 'patches' array"])
                }
                let componentIdArg = args["componentId"]?.stringValue
                return await MainActor.run {
                    let resolvedId: String
                    switch store.resolveWriteTarget(kind: "calculator", componentId: componentIdArg, myAppId: myAppId) {
                    case .failure(let msg):
                        return .object(["ok": .bool(false), "error": .string(msg)])
                    case .resolved(let id):
                        resolvedId = id
                    }
                    var patched: [AnyJSON] = []
                    for entry in entries {
                        guard let key = entry["key"]?.stringValue else { continue }
                        let patch = parseCalcRowPatch(from: entry["patch"])
                        if store.patchCalcRow(key: key, patch: patch, myAppId: myAppId, componentId: resolvedId, actor: .agent(toolName: "patchCalcRows")) {
                            patched.append(.string(key))
                        }
                    }
                    let data = calculator(store, myAppId: myAppId, componentId: resolvedId)
                    var result: [String: AnyJSON] = [
                        "ok": .bool(true),
                        "componentId": .string(resolvedId),
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
                    "properties": [
                        "keys": ["type": "array", "items": ["type": "string"]],
                        "componentId": componentIdSchema(kind: "calculator"),
                    ],
                    "required": ["keys"],
                ]
            ),
            handler: { args in
                guard let keys = args["keys"]?.arrayValue?.compactMap(\.stringValue), !keys.isEmpty else {
                    return .object(["ok": .bool(false), "error": "missing 'keys' array"])
                }
                let componentIdArg = args["componentId"]?.stringValue
                return await MainActor.run {
                    let resolvedId: String
                    switch store.resolveWriteTarget(kind: "calculator", componentId: componentIdArg, myAppId: myAppId) {
                    case .failure(let msg):
                        return .object(["ok": .bool(false), "error": .string(msg)])
                    case .resolved(let id):
                        resolvedId = id
                    }
                    var removed: [AnyJSON] = []
                    for key in keys {
                        if store.removeCalcRow(key: key, myAppId: myAppId, componentId: resolvedId, actor: .agent(toolName: "removeCalcRows")) {
                            removed.append(.string(key))
                        }
                    }
                    let data = calculator(store, myAppId: myAppId, componentId: resolvedId)
                    return .object([
                        "ok": .bool(true),
                        "componentId": .string(resolvedId),
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
                        "componentId": componentIdSchema(kind: "calculator"),
                    ],
                    "required": ["key"],
                ]
            ),
            handler: { args in
                guard let key = args["key"]?.stringValue else {
                    return .object(["ok": .bool(false), "error": "missing 'key'"])
                }
                let ref = parseRef(from: args["ref"])
                let componentIdArg = args["componentId"]?.stringValue
                return await MainActor.run {
                    let resolvedId: String
                    switch store.resolveWriteTarget(kind: "calculator", componentId: componentIdArg, myAppId: myAppId) {
                    case .failure(let msg):
                        return .object(["ok": .bool(false), "error": .string(msg)])
                    case .resolved(let id):
                        resolvedId = id
                    }
                    let ok = store.setCalcRowLinkedRef(
                        key: key,
                        ref: ref,
                        myAppId: myAppId,
                        componentId: resolvedId,
                        actor: .agent(toolName: "setCalcRowLink")
                    )
                    var result: [String: AnyJSON] = ["ok": .bool(ok), "componentId": .string(resolvedId), "key": .string(key)]
                    if let data = calculator(store, myAppId: myAppId, componentId: resolvedId) {
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
            readOnly: true,
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
            readOnly: true,
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
}
