import Foundation
import AGUIKit

extension AppTools {
    // Chart component frontend tools. Relocated from the AppTools
    // monolith into the Chart folder (issue #162). Zero logic change.
    @MainActor
    static func registerChartTools(
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
                        "componentId": componentIdSchema(kind: "chart"),
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
                let componentIdArg = args["componentId"]?.stringValue
                let series = parseChartSeries(from: args["series"])
                return await MainActor.run {
                    let resolvedId: String
                    switch store.resolveRenderTarget(kind: "chart", componentId: componentIdArg, myAppId: myAppId) {
                    case .failure(let msg):
                        return .object(["ok": .bool(false), "error": .string(msg)])
                    case .resolved(let id):
                        resolvedId = id
                    }
                    store.setChart(title: title, kind: kind, series: series, myAppId: myAppId, componentId: resolvedId)
                    return chartEcho(store: store, myAppId: myAppId, componentId: resolvedId)
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
                        "componentId": componentIdSchema(kind: "chart"),
                        "title": ["type": "string"],
                        "kind": ["type": "string", "enum": ["pie", "bar", "line"]],
                        "series": ["type": "array", "items": chartSeriesSchema()],
                    ],
                ]
            ),
            handler: { args in
                let componentIdArg = args["componentId"]?.stringValue
                var patch = MyAppStore.ChartPatch()
                if let t = args["title"]?.stringValue { patch.title = t }
                if let k = args["kind"]?.stringValue, let kind = ChartKind(rawValue: k) { patch.kind = kind }
                if args["series"] != nil { patch.series = parseChartSeries(from: args["series"]) }
                return await MainActor.run {
                    let resolvedId: String
                    switch store.resolveWriteTarget(kind: "chart", componentId: componentIdArg, myAppId: myAppId) {
                    case .failure(let msg):
                        return .object(["ok": .bool(false), "error": .string(msg)])
                    case .resolved(let id):
                        resolvedId = id
                    }
                    guard store.patchChart(patch: patch, myAppId: myAppId, componentId: resolvedId) else {
                        return .object([
                            "ok": .bool(false),
                            "error": "no chart component in this MyApp — call addComponent(kind:\"chart\", …) or renderChart first",
                        ])
                    }
                    return chartEcho(store: store, myAppId: myAppId, componentId: resolvedId)
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
                    "properties": [
                        "series": ["type": "array", "items": chartSeriesSchema()],
                        "componentId": componentIdSchema(kind: "chart"),
                    ],
                    "required": ["series"],
                ]
            ),
            handler: { args in
                let componentIdArg = args["componentId"]?.stringValue
                let specs = parseChartSeries(from: args["series"])
                return await MainActor.run {
                    let resolvedId: String
                    switch store.resolveWriteTarget(kind: "chart", componentId: componentIdArg, myAppId: myAppId) {
                    case .failure(let msg):
                        return .object(["ok": .bool(false), "error": .string(msg)])
                    case .resolved(let id):
                        resolvedId = id
                    }
                    guard store.addChartSeries(specs, myAppId: myAppId, componentId: resolvedId) != nil else {
                        return .object([
                            "ok": .bool(false),
                            "error": "no chart component in this MyApp — call addComponent(kind:\"chart\", …) or renderChart first",
                        ])
                    }
                    return chartEcho(store: store, myAppId: myAppId, componentId: resolvedId)
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
                    "properties": [
                        "index": ["type": "integer", "minimum": 0],
                        "componentId": componentIdSchema(kind: "chart"),
                    ],
                    "required": ["index"],
                ]
            ),
            handler: { args in
                guard let index = args["index"]?.intValue else {
                    return .object(["ok": .bool(false), "error": "removeChartSeries needs `index`."])
                }
                let componentIdArg = args["componentId"]?.stringValue
                return await MainActor.run {
                    let resolvedId: String
                    switch store.resolveWriteTarget(kind: "chart", componentId: componentIdArg, myAppId: myAppId) {
                    case .failure(let msg):
                        return .object(["ok": .bool(false), "error": .string(msg)])
                    case .resolved(let id):
                        resolvedId = id
                    }
                    guard store.removeChartSeries(index: index, myAppId: myAppId, componentId: resolvedId) else {
                        return .object([
                            "ok": .bool(false),
                            "error": "no chart series at that index (or no chart component).",
                        ])
                    }
                    return chartEcho(store: store, myAppId: myAppId, componentId: resolvedId)
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
                    "properties": [
                        "kind": ["type": "string", "enum": ["pie", "bar", "line"]],
                        "componentId": componentIdSchema(kind: "chart"),
                    ],
                    "required": ["kind"],
                ]
            ),
            handler: { args in
                guard let k = args["kind"]?.stringValue, let kind = ChartKind(rawValue: k) else {
                    return .object(["ok": .bool(false), "error": "setChartKind needs `kind` (pie|bar|line)."])
                }
                let componentIdArg = args["componentId"]?.stringValue
                return await MainActor.run {
                    let resolvedId: String
                    switch store.resolveWriteTarget(kind: "chart", componentId: componentIdArg, myAppId: myAppId) {
                    case .failure(let msg):
                        return .object(["ok": .bool(false), "error": .string(msg)])
                    case .resolved(let id):
                        resolvedId = id
                    }
                    store.setChartKind(kind, myAppId: myAppId, componentId: resolvedId)
                    return chartEcho(store: store, myAppId: myAppId, componentId: resolvedId)
                }
            }
        ))
    }
}
