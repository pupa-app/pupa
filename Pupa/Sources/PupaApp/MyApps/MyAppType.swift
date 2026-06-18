import Foundation

/// A registered template for a kind of myApp. Declares the agent's surface
/// area for the type and slices it by component kind so a MyApp instance only
/// sees the tools (and prompt prose) for components that actually exist on
/// its canvas.
///
/// Resolution happens per-turn via `resolvedToolNames(kindsPresent:)` and
/// `resolvedSystemPromptFragment(kindsPresent:)` — `ChatViewModel` and
/// `ChatSessionCoordinator` recompute the active set from the live
/// `MyApp.components` on every agent round, so the surface grows mid-turn
/// the instant a component is added and shrinks the instant the last one of
/// a kind is removed.
public struct MyAppType: Sendable, Hashable, Identifiable {
    public let id: String
    public let displayName: String
    public let defaultName: String
    public let iconSystemName: String

    /// Always-on framing — sent to the model regardless of which components
    /// exist. Keep this short; per-kind detail belongs in
    /// `promptFragmentsByKind`.
    public let baseSystemPromptFragment: String
    /// Tools always advertised to this MyApp's agent — component lifecycle
    /// and anything kind-agnostic (`getCanvasState`, `clearCanvas`).
    public let baseToolNames: Set<String>
    /// Tools advertised only when at least one component of the matching
    /// kind exists in the MyApp's `components` array. Keys are kind strings
    /// (`"tracker"`, `"calendar"`) matching `CanvasApp.kindString`.
    public let toolNamesByKind: [String: Set<String>]
    /// Prompt prose appended to `baseSystemPromptFragment` when a component
    /// of the matching kind exists. Fragments are joined with a blank line.
    public let promptFragmentsByKind: [String: String]
    /// Co-presence requirements for individual tools. Tool name → the set of
    /// **additional** kinds that must also be present alongside the tool's
    /// own kind for it to be advertised. Used for tools that cross kinds
    /// (e.g. `linkTrackerItem` mutates a calendar event but references a
    /// tracker — only meaningful when both kinds exist).
    public let coPresenceGates: [String: Set<String>]
    /// Component kinds this MyAppType may host on its canvas. Used by the
    /// `addComponent` tool to validate which kinds the agent is allowed to
    /// add. The default tracker type supports both `"tracker"` and
    /// `"calendar"` so a single MyApp can mix the two.
    public let supportedComponentKinds: Set<String>

    public init(
        id: String,
        displayName: String,
        defaultName: String,
        iconSystemName: String,
        baseSystemPromptFragment: String,
        baseToolNames: Set<String>,
        toolNamesByKind: [String: Set<String>] = [:],
        promptFragmentsByKind: [String: String] = [:],
        coPresenceGates: [String: Set<String>] = [:],
        supportedComponentKinds: Set<String>
    ) {
        self.id = id
        self.displayName = displayName
        self.defaultName = defaultName
        self.iconSystemName = iconSystemName
        self.baseSystemPromptFragment = baseSystemPromptFragment
        self.baseToolNames = baseToolNames
        self.toolNamesByKind = toolNamesByKind
        self.promptFragmentsByKind = promptFragmentsByKind
        self.coPresenceGates = coPresenceGates
        self.supportedComponentKinds = supportedComponentKinds
    }

    /// Resolve the tools advertised to a MyApp's agent given the kinds of
    /// components currently on its canvas. Union of `baseToolNames` and
    /// each `toolNamesByKind[kind]` for `kind in kindsPresent`, then a
    /// co-presence filter pass drops any tool whose `coPresenceGates`
    /// requirements aren't met.
    public func resolvedToolNames(kindsPresent: Set<String>) -> Set<String> {
        var result = baseToolNames
        for kind in kindsPresent {
            if let kindTools = toolNamesByKind[kind] {
                result.formUnion(kindTools)
            }
        }
        if !coPresenceGates.isEmpty {
            result = result.filter { name in
                guard let required = coPresenceGates[name] else { return true }
                return required.isSubset(of: kindsPresent)
            }
        }
        return result
    }

    /// Build the prompt fragment forwarded to the agent. `baseSystemPromptFragment`
    /// is always included; per-kind fragments are appended for each kind in
    /// `kindsPresent`, in sorted order so the prose is deterministic across
    /// turns. Fragments are joined by a blank line.
    public func resolvedSystemPromptFragment(kindsPresent: Set<String>) -> String {
        var parts: [String] = []
        if !baseSystemPromptFragment.isEmpty {
            parts.append(baseSystemPromptFragment)
        }
        for kind in kindsPresent.sorted() {
            if let fragment = promptFragmentsByKind[kind], !fragment.isEmpty {
                parts.append(fragment)
            }
        }
        return parts.joined(separator: "\n\n")
    }

    /// User-level long-term memory filesystem tools. Always advertised to
    /// the .memory orchestrator scope; gated behind `get_tools_memories` in
    /// .myApp scope (the memories surface is not myApp-scoped, but per-myApp
    /// turns rarely need it — keeping the descriptions out of the per-turn
    /// payload until first use saves ~560 tokens; see issue #220).
    public static let memoryToolNames: Set<String> = [
        "lsMemories",
        "readMemoryFile",
        "writeMemoryFile",
        "appendMemoryFile",
        "editMemoryFile",
        "grepMemories",
        "moveMemoryFile",
        "deleteMemoryFile",
        "createMemoryFolder",
    ]

    /// Local notification scheduling. Always advertised to every scope so
    /// either a myApp agent or the orchestrator can post banners.
    public static let notificationToolNames: Set<String> = [
        "sendNotification",
        "cancelNotification",
    ]

    /// Human-in-the-loop frontend tools — currently just
    /// `ask_user_questions`, which routes through `CopilotKitMiddlewareWithFrontendInterrupt`
    /// on the backend and `HumanInTheLoopBridge` on iOS to pause the
    /// agent until the user fills in a panel of clarifying questions.
    public static let humanInTheLoopToolNames: Set<String> = [
        "ask_user_questions",
    ]

    /// Tools the **orchestrator** (memory-scope) chat can call. Lets the
    /// memory-mode agent see and create myApps and delegate a one-shot
    /// prompt to any existing myApp's agent — sub-runs use a fresh
    /// `threadId` against the target myApp's normal tool surface (canvas
    /// mutators + memories), so they can mutate that myApp's canvas the same
    /// way the user's own chat would. Not exposed inside any myApp's own
    /// scope; only registered on the `.memory` session.
    public static let orchestratorToolNames: Set<String> = [
        "listMyApps",
        "createMyApp",
        "renameMyApp",
        "invokeMyAppAgent",
    ]

    /// The built-in tracker myApp type. Drives the existing tracker UI and
    /// also hosts calendar components — a single MyApp can mix kinds.
    public static let tracker = MyAppType(
        id: "tracker",
        displayName: "Tracker",
        defaultName: "New Tracker",
        iconSystemName: "list.bullet.rectangle",
        baseSystemPromptFragment: """
        Canvas hosts COMPONENTS (sub-canvases, ids like "tracker-1") — pass \
        `componentId` to target one; single-component myApps may omit it. \
        Per-kind tools unlock only after `addComponent` introduces that kind.

        LINKING — linkItem / unlinkItem attach refs between any two items \
        (any kinds, any direction, same-component allowed for parent / subtask).
        """,
        baseToolNames: [
            "addComponent",
            "removeComponent",
            "setActiveComponent",
            "setComponentMeta",
            "clearCanvas",
            "getCanvasState",
            "linkItem",
            "unlinkItem",
        ],
        toolNamesByKind: [
            "tracker": [
                "renderTracker",
                "addTrackerItems",
                "removeTrackerItems",
                "patchTrackerItems",
                "setTrackerFilter",
                "setTrackerViewMode",
                "addFieldOption",
                "removeFieldOption",
                "addTrackerField",
                "renameTrackerField",
                "reorderTrackerFields",
                "hideTrackerField",
                "showTrackerField",
                "listTrackerItems",
                "searchTrackerItems",
                "getTrackerItem",
            ],
            "calendar": [
                "renderCalendar",
                "addCalendarEvent",
                "removeCalendarEvent",
                "patchCalendarEvent",
                "setCalendarViewMode",
                "listCalendarEvents",
                "getCalendarEvent",
            ],
            "checklist": [
                "renderChecklist",
                "addChecklistItem",
                "toggleChecklistItem",
                "patchChecklistItem",
                "removeChecklistItem",
                "listChecklistItems",
                "getChecklistItem",
            ],
            "slack": [
                "slackListAgents",
                "slackListChannels",
                "slackReadChannelHistory",
                "slackPostMessage",
                "slackCreateAgent",
                "slackCreateChannels",
                "slackAddAgentsToChannel",
            ],
            "calculator": [
                "renderCalculator",
                "addCalcRows",
                "patchCalcRows",
                "removeCalcRows",
                "setCalcRowLink",
                "listCalcRows",
                "getCalcRow",
                "embedComponent",
            ],
            "chart": [
                "renderChart",
                "patchChart",
                "setChartKind",
                "addChartSeries",
                "removeChartSeries",
                "embedComponent",
            ],
        ],
        promptFragmentsByKind: [
            "tracker": """
            TRACKER — multi-field rows (form + filter + card/kanban). Pick \
            TRACKER when rows carry multiple fields (status, category, image); \
            CHECKLIST otherwise. Explore via list/search/getTrackerItem; \
            `summary` slot — set via renderTracker(summary:).
            """,
            "calendar": """
            CALENDAR — time-indexed events (list or month grid). Pick when \
            date is the primary axis. Explore via list/getCalendarEvent; \
            `summary` slot — set via renderCalendar(summary:).
            """,
            "checklist": """
            CHECKLIST — done/not-done rows, no per-row metadata. Switch to \
            TRACKER once rows need multiple fields. Explore via \
            list/getChecklistItem; `summary` slot — set via renderChecklist(summary:).
            """,
            "slack": """
            SLACK — multi-agent rooms. Setup: slackCreateAgent (persona), \
            slackCreateChannels (seed + members). After seed, user @-mentions \
            invoke agents in transient sessions with private memory at \
            `memories/agents/{agentId}/`. Sub-agent: slackPostMessage to \
            speak; @-mention another agent to fan out (reentrancy + depth caps \
            return `{outcome: 'reentrant' | 'max_depth_exceeded'}` in `fanOut`). \
            Admin tools (create / add) refuse for sub-agents.
            """,
            "calculator": """
            CALCULATOR — live numeric model. Rows: tunable inputs (VARIABLE), \
            formulas over other rows by key (FORMULA), tracker aggregates \
            (AGGREGATE), one field off a linked tracker item (LINKED_FIELD — \
            swap the item with setCalcRowLink to re-run the model), array \
            output for charts (LIST, incl. linkedCompare to compare a set of \
            linked items on a target row), section labels (HEADER). Use when \
            user wants a model to tune in real time. Explore via \
            list/getCalcRow; `summary` slot — set via renderCalculator(summary:).
            """,
            "chart": """
            CHART — pie/bar/line with overlaid series. Sources: tracker (group \
            by field), calculator rows (by key), calculator list row \
            (sweep/column), or inline points. Multi-series over a shared x \
            axis = line chart with multiple CALCULATOR_LIST or TRACKER series. \
            Pairs naturally with a calculator LIST row. To show the user a chart \
            inline in the conversation, embedComponent(hostKind:"chat").
            """,
        ],
        // No cross-kind gates as of project `0.0.41`. The generic
        // `linkItem` / `unlinkItem` pair lives in `baseToolNames` and
        // validates source / target at call time, so we no longer need
        // to hide kind-specific link tools behind co-presence
        // requirements. Per-kind tools that don't depend on another
        // kind sit in `toolNamesByKind[kind]` alone.
        coPresenceGates: [:],
        supportedComponentKinds: ["tracker", "calendar", "checklist", "slack", "calculator", "chart"]
    )
}
