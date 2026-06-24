import Foundation

/// What the sidebar currently has focus on. Picking a myApp rebinds the
/// visible chat overlay to that myApp's `ChatViewModel` (via
/// `ChatSessionCoordinator.session(for:)`) without cancelling any other
/// session; picking a memory file routes chat to the shared memory session
/// and updates its `memoryFocusedPath` for the next turn's context;
/// picking `orchestrator` routes chat to the same memory session but with
/// no focused file — the meta-agent that can call `listMyApps`,
/// `createMyApp`, and `invokeMyAppAgent` to drive other myApps.
public enum SidebarSelection: Hashable, Sendable {
    case orchestrator
    /// The landing-page overview for a myApp. Shown when the user clicks the
    /// myApp row label in the sidebar (distinct from the expansion chevron).
    /// Displays a summary of all components and the app's memories without
    /// navigating directly into a specific component canvas.
    case myAppHome(UUID)
    case myApp(UUID)
    /// One of a myApp's child components, addressed by `(myAppId, componentId)`.
    /// Sidebar DisclosureGroups produce this selection when the user picks a
    /// sub-row; `AppView` resolves it back to the same per-myApp chat session
    /// (components share the thread) and tells `CanvasView` which component
    /// to render.
    case myAppComponent(UUID, String)
    /// The agents overview page for a myApp — lists the main agent plus
    /// every Slack agent inside any Slack component. Reached by tapping
    /// the Agents panel on the landing page (no sidebar row).
    case myAppAgents(UUID)
    /// Details page for one specific agent inside a myApp. `agentId` is
    /// `"myapp-main"` for the MyApp's main agent and
    /// `"slack:<componentId>:<slackAgentId>"` for Slack personas — both
    /// resolved by `AgentRegistry.enumerateAgents`.
    case myAppAgentDetail(UUID, agentId: String)
    /// A memory file that belongs to a specific myApp's memory tree.
    /// Routes to the myApp's chat (not the orchestrator) while showing
    /// the file content in the detail pane.
    case myAppMemoryFile(UUID, String)
    /// The myApp's memory browse page — a folder tree of all its notes.
    /// Reached from the bottom bar's Memories button; files inside push
    /// `.myAppMemoryFile`.
    case myAppMemories(UUID)
    /// The myApp's change-history page — a newest-first list of `ItemEvent`s
    /// with per-row Undo. Pushed from the bottom bar's History button.
    case myAppHistory(UUID)
    /// The orchestrator's memory browse page — a folder tree of its shared
    /// notes. Mirror of `.myAppMemories` but orchestrator-scoped (reuses
    /// `MyAppMemoriesView`); files inside push `.memoryFile`.
    case orchestratorMemories
    /// A memory file in the orchestrator's tree. Routes to the memory/
    /// orchestrator chat and sets `memoryFocusedPath`.
    case memoryFile(String)
    /// Details page for the orchestrator (the cross-MyApp meta-agent). Mirror
    /// of `myAppAgentDetail` but unscoped — there's only one orchestrator.
    case orchestratorAgentDetail
    /// Live screen-share viewer. Doesn't route the chat overlay anywhere
    /// specific — it's a standalone panel that connects to the backend's
    /// screenshare broker and renders the incoming WebRTC video track.
    case screenShare

    /// Detail-pane root for an optional sidebar selection. `nil` falls back to
    /// the active MyApp's home — the iOS drawer clears `selection` after each
    /// tap (so re-tapping the same row re-fires `List.onChange`), and the home
    /// is where a tap lands, so the fallback matches with no visible flip.
    public static func detailRoot(for selection: SidebarSelection?, activeMyAppId: UUID) -> SidebarSelection {
        selection ?? .myAppHome(activeMyAppId)
    }

    /// The pushed detail stack that navigates to this selection on iOS, where
    /// the `NavigationStack` root resolves to the active MyApp home once
    /// `selection` clears to nil. The home / canvas resolves through
    /// `activeMyAppId`, so it needs no push (empty stack); **every other page**
    /// — a MyApp's agents / memories / component / history, the orchestrator,
    /// screen-share — must be pushed so it survives the clear-to-nil instead of
    /// bouncing straight back to the canvas. Pure so the routing rule is unit
    /// tested away from the view layer.
    public var iOSDetailStack: [SidebarSelection] {
        switch self {
        case .myAppHome, .myApp: return []
        default: return [self]
        }
    }

    /// The detail stack after the user picks `nav` from any source (bottom bar,
    /// sidebar, chat link) on iOS. The stack is **replaced wholesale** — picking
    /// a tab must never clear-to-empty then refill across two transactions, which
    /// blanks `NavigationStack` when the prior stack was non-empty. Pure so the
    /// "replace, don't clear-first" rule is unit tested away from the view.
    public static func detailStack(picking nav: SidebarSelection,
                                   from current: [SidebarSelection]) -> [SidebarSelection] {
        nav.iOSDetailStack
    }

    /// MyApp id the selection belongs to, if any.
    public var myAppId: UUID? {
        switch self {
        case .myAppHome(let id), .myApp(let id), .myAppComponent(let id, _),
             .myAppMemoryFile(let id, _), .myAppMemories(let id),
             .myAppHistory(let id),
             .myAppAgents(let id), .myAppAgentDetail(let id, _): return id
        default: return nil
        }
    }
}
