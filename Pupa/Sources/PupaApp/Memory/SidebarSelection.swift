import Foundation

/// What the sidebar currently has focus on. Picking a miniApp rebinds the
/// visible chat overlay to that miniApp's `ChatViewModel` (via
/// `ChatSessionCoordinator.session(for:)`) without cancelling any other
/// session; picking a memory file routes chat to the shared memory session
/// and updates its `memoryFocusedPath` for the next turn's context;
/// picking `orchestrator` routes chat to the same memory session but with
/// no focused file — the meta-agent that can call `listMiniApps`,
/// `createMiniApp`, and `invokeMiniAppAgent` to drive other miniApps.
public enum SidebarSelection: Hashable, Sendable {
    case orchestrator
    /// The landing-page overview for a miniApp. Shown when the user clicks the
    /// miniApp row label in the sidebar (distinct from the expansion chevron).
    /// Displays a summary of all components and the app's memories without
    /// navigating directly into a specific component canvas.
    case miniAppHome(UUID)
    case miniApp(UUID)
    /// One of a miniApp's child components, addressed by `(miniAppId, componentId)`.
    /// Sidebar DisclosureGroups produce this selection when the user picks a
    /// sub-row; `AppView` resolves it back to the same per-miniApp chat session
    /// (components share the thread) and tells `CanvasView` which component
    /// to render.
    case miniAppComponent(UUID, String)
    /// The agents overview page for a miniApp — lists the main agent plus
    /// every Slack agent inside any Slack component. Reached by tapping
    /// the Agents panel on the landing page (no sidebar row).
    case miniAppAgents(UUID)
    /// Details page for one specific agent inside a miniApp. `agentId` is
    /// `"miniapp-main"` for the MiniApp's main agent and
    /// `"slack:<componentId>:<slackAgentId>"` for Slack personas — both
    /// resolved by `AgentRegistry.enumerateAgents`.
    case miniAppAgentDetail(UUID, agentId: String)
    /// A memory file that belongs to a specific miniApp's memory tree.
    /// Routes to the miniApp's chat (not the orchestrator) while showing
    /// the file in a sheet over whatever was on screen — see
    /// `MemoryFileRoute` and `AppView.presentOrPush`.
    case miniAppMemoryFile(UUID, String)
    /// The miniApp's memory browse page — a folder tree of all its notes.
    /// Reached from the bottom bar's Memories button; files inside present
    /// `.miniAppMemoryFile` as a sheet.
    case miniAppMemories(UUID)
    /// The miniApp's change-history page — a newest-first list of `ItemEvent`s
    /// with per-row Undo. Pushed from the bottom bar's History button.
    case miniAppHistory(UUID)
    /// The orchestrator's memory browse page — a folder tree of its shared
    /// notes. Mirror of `.miniAppMemories` but orchestrator-scoped (reuses
    /// `MiniAppMemoriesView`); files inside present `.memoryFile` as a sheet.
    case orchestratorMemories
    /// A memory file in the orchestrator's tree. Routes to the memory/
    /// orchestrator chat and sets `memoryFocusedPath`.
    case memoryFile(String)
    /// Details page for the orchestrator (the cross-MiniApp meta-agent). Mirror
    /// of `miniAppAgentDetail` but unscoped — there's only one orchestrator.
    case orchestratorAgentDetail
    /// Live screen-share viewer. Doesn't route the chat overlay anywhere
    /// specific — it's a standalone panel that connects to the backend's
    /// screenshare broker and renders the incoming WebRTC video track.
    case screenShare

    /// MiniApp id the selection belongs to, if any.
    public var miniAppId: UUID? {
        switch self {
        case .miniAppHome(let id), .miniApp(let id), .miniAppComponent(let id, _),
             .miniAppMemoryFile(let id, _), .miniAppMemories(let id),
             .miniAppHistory(let id),
             .miniAppAgents(let id), .miniAppAgentDetail(let id, _): return id
        default: return nil
        }
    }

    /// Rewrite a **scope-relative** memory selection (as `ChatLink` emits — the
    /// agent only sees paths relative to its own scope root) into a
    /// **global-root-relative** one, which is the space the shared UI
    /// `MemoryStore` reads from (matching browse + agent-prompt links). Prefixes
    /// the scope folder: a miniApp's id, or `orchestrator/`. Non-memory selections
    /// pass through.
    public func globalizedMemoryPath() -> SidebarSelection {
        switch self {
        case .miniAppMemoryFile(let id, let path):
            return .miniAppMemoryFile(id, MemoryStore.miniAppFolder(miniAppId: id) + "/" + path)
        case .memoryFile(let path):
            return .memoryFile(MemoryStore.orchestratorFolder() + "/" + path)
        default:
            return self
        }
    }
}

/// A memory file addressed for presentation as a sheet rather than a push.
/// `Identifiable` so `AppView` can drive `.sheet(item:)` with it.
///
/// Memory files are reference material read *while* talking to the agent — the
/// same argument that makes chat an overlay. Pushing one evicted the canvas;
/// a sheet keeps it behind the note and a swipe puts it back.
public struct MemoryFileRoute: Identifiable, Hashable, Sendable {
    /// The miniApp whose memory tree this file belongs to, or `nil` for the
    /// orchestrator's shared tree.
    public let miniAppId: UUID?
    /// Global-root-relative path, the space `MemoryStore` reads from.
    public let path: String
    /// Restored into the editor when a failed autosave re-presents the sheet,
    /// so the user's text survives the round trip. `nil` loads from disk.
    public let restoredBuffer: String?
    /// Why the autosave failed, shown inside the sheet. Carried here rather
    /// than raised as an alert: an alert and this sheet present from the same
    /// anchor, and asking for both in one update drops one of them.
    public let autosaveError: String?

    public var id: String { "\(miniAppId?.uuidString ?? "orchestrator"):\(path)" }

    public init(
        miniAppId: UUID?,
        path: String,
        restoredBuffer: String? = nil,
        autosaveError: String? = nil
    ) {
        self.miniAppId = miniAppId
        self.path = path
        self.restoredBuffer = restoredBuffer
        self.autosaveError = autosaveError
    }

    /// The memory-file selections, and only those. Everything else still
    /// navigates as a push.
    public init?(_ selection: SidebarSelection) {
        switch selection {
        case .miniAppMemoryFile(let id, let path):
            self.init(miniAppId: id, path: path)
        case .memoryFile(let path):
            self.init(miniAppId: nil, path: path)
        default:
            return nil
        }
    }

    /// Back to a selection, for the chat-scope routing that still keys off one.
    public var selection: SidebarSelection {
        if let miniAppId { return .miniAppMemoryFile(miniAppId, path) }
        return .memoryFile(path)
    }
}

/// What dismissing a memory-file sheet should do with the editor buffer.
///
/// Swipe-down saves rather than discards: a memory file is a document, not a
/// form, and these files are the agent's long-term context — silently losing an
/// edit is worse than silently keeping one. Two guards keep that honest: a file
/// that was only read is never rewritten (which would churn its mtime and the
/// change log for nothing), and a locked file is never written at all.
public enum MemoryFileDismiss {
    public static func shouldSave(
        readOnly: Bool,
        isEditing: Bool,
        buffer: String,
        loaded: String
    ) -> Bool {
        guard !readOnly, isEditing else { return false }
        return buffer != loaded
    }
}
