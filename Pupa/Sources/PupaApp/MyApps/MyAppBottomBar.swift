import SwiftUI

/// Persistent bottom bar for a myApp or the orchestrator — the per-subject
/// "tab bar". Always visible (mounted via `.safeAreaInset`) on a myApp's home /
/// component / memories pages and on the orchestrator's home / memories pages.
///
///   Home · Memories · Pupa(chat) · More
///
/// The app's only bar: the sidebar has no footer, so More carries what used to
/// be split between the two — Agents and History (the low-traffic per-subject
/// pages) plus the global Screen share and Settings. The orchestrator has no
/// canvas change-log, so its More omits History. Icons are tinted in the
/// subject's color; the pupa keeps its own look.
public struct MyAppBottomBar: View {
    /// Which page the bar should mark as active.
    public enum Page: Equatable {
        case home
        case component(String)
        /// The memory browse page or any memory file within it.
        case memories
        /// The agents overview or any agent detail page. Reached from More, so
        /// it lights More rather than a slot of its own.
        case agents
        /// The change-history page. Also reached from More.
        case history
    }

    let subject: MyAppHomeView.Subject
    let currentPage: Page
    let appColor: Color
    /// Folded chat status for the scope — surfaces a background run on the pupa
    /// button while chat is closed.
    let chatStatus: ChatActivityStatus
    /// Whether the chat card is currently open (drives the pupa button's label).
    let chatOpen: Bool
    let onSelect: (SidebarSelection) -> Void
    /// Open the Change History sheet for a myApp. Only wired for `.myApp`; the
    /// orchestrator hides the History item.
    let onShowHistory: (UUID) -> Void
    let onToggleChat: () -> Void
    /// Present the Settings sheet. Owned by `AppView` — the bar is the only
    /// surface that reaches Settings now that the sidebar footer is gone.
    let onOpenSettings: () -> Void

    /// Row height for each bar button.
    static let rowHeight: CGFloat = 30
    /// Vertical padding above/below the row.
    static let verticalPadding: CGFloat = 4

    public init(
        subject: MyAppHomeView.Subject,
        currentPage: Page,
        appColor: Color,
        chatStatus: ChatActivityStatus,
        chatOpen: Bool,
        onSelect: @escaping (SidebarSelection) -> Void,
        onShowHistory: @escaping (UUID) -> Void,
        onToggleChat: @escaping () -> Void,
        onOpenSettings: @escaping () -> Void
    ) {
        self.subject = subject
        self.currentPage = currentPage
        self.appColor = appColor
        self.chatStatus = chatStatus
        self.chatOpen = chatOpen
        self.onSelect = onSelect
        self.onShowHistory = onShowHistory
        self.onToggleChat = onToggleChat
        self.onOpenSettings = onOpenSettings
    }

    private var myAppId: UUID? {
        if case .myApp(let id) = subject { return id }
        return nil
    }

    private var homeSelection: SidebarSelection {
        myAppId.map { .myAppHome($0) } ?? .orchestrator
    }

    private var memoriesSelection: SidebarSelection {
        myAppId.map { .myAppMemories($0) } ?? .orchestratorMemories
    }

    private var agentsSelection: SidebarSelection {
        myAppId.map { .myAppAgents($0) } ?? .orchestratorAgentDetail
    }

    public var body: some View {
        HStack(spacing: 0) {
            barButton(system: "house", active: currentPage == .home, help: "Home",
                      highlight: .bottomBarHome) {
                onSelect(homeSelection)
            }
            barButton(system: "brain", active: currentPage == .memories, help: "Memories",
                      highlight: .bottomBarMemories) {
                onSelect(memoriesSelection)
            }
            pupaButton
            moreMenu
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Self.verticalPadding)
        // macOS: keep the end controls (Home, ⋯) off the window edge — the
        // borderless menu otherwise sits flush against the trailing border.
        #if os(macOS)
        .padding(.horizontal, 8)
        #endif
        .background(.regularMaterial)
        .overlay(alignment: .top) { Divider() }
    }

    private func barButton(
        system: String,
        active: Bool,
        help: String,
        highlight: TourHighlight? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 18, weight: active ? .semibold : .regular))
                .foregroundStyle(active ? appColor : appColor.opacity(0.4))
                .frame(height: Self.rowHeight)
                .padding(.horizontal, 14)
                .background(
                    Capsule().fill(active ? appColor.opacity(0.16) : .clear)
                )
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
        .tourAnchorIfPresent(highlight)
    }

    /// Chat launcher. Keeps the pupa's current look (app-icon image on the
    /// accent circle) and carries the scope's activity badge.
    private var pupaButton: some View {
        Button(action: onToggleChat) {
            ZStack {
                Circle().fill(Color.accentColor)
                if let icon = AppIcon.swiftUIImage {
                    icon
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fill)
                        .clipShape(Circle())
                } else {
                    Image(systemName: "message.fill")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
            .frame(width: 30, height: 30)
            .shadow(color: .black.opacity(0.1), radius: 2, y: 0.5)
            .overlay(alignment: .topTrailing) {
                if chatStatus != .idle {
                    StatusBadge(status: chatStatus, size: 12)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: Self.rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(chatOpen ? "Close chat" : "Open chat")
        .accessibilityIdentifier(PupaID.chatToggle)
        .accessibilityValue(chatStatus.accessibilityDescription ?? "")
        .tourAnchor(.bottomBarChat)
    }

    /// True while a page reached through More is showing, so the button reads
    /// as the active slot the way a real tab would.
    private var moreActive: Bool {
        currentPage == .agents || currentPage == .history
    }

    /// `⋯` overflow: the per-subject pages that don't earn a slot (Agents, and
    /// History for a myApp) above the app-wide ones (Screen share, Settings).
    /// Components are deliberately absent — Home already grids them, one tap
    /// away, and this is the only `⋯` in the app now.
    private var moreMenu: some View {
        Menu {
            Button {
                onSelect(agentsSelection)
            } label: {
                Label("Agents", systemImage: "person.2")
            }
            if let id = myAppId {
                Button {
                    onShowHistory(id)
                } label: {
                    Label("History", systemImage: "clock")
                }
            }
            Divider()
            Button {
                onSelect(.screenShare)
            } label: {
                Label("Screen share", systemImage: "rectangle.on.rectangle")
            }
            Button(action: onOpenSettings) {
                Label("Settings", systemImage: "gearshape")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 18, weight: moreActive ? .semibold : .medium))
                .foregroundStyle(moreActive ? appColor : appColor.opacity(0.7))
                .frame(height: Self.rowHeight)
                .padding(.horizontal, 14)
                .background(
                    Capsule().fill(moreActive ? appColor.opacity(0.16) : .clear)
                )
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        // Claim an equal slot like the other bar buttons: on macOS the
        // borderless menu collapses to its label's intrinsic width otherwise,
        // shoving `⋯` against the trailing edge.
        .frame(maxWidth: .infinity)
        .help("More")
        .accessibilityLabel("More")
        .tourAnchor(.bottomBarMore)
    }
}
