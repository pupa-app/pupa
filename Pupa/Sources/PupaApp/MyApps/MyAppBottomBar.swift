import SwiftUI

/// Persistent bottom bar for a myApp or the orchestrator — the per-subject
/// "tab bar". Always visible (mounted via `.safeAreaInset`) on a myApp's home /
/// component / memories pages and on the orchestrator's home / memories pages.
///
///   Home · Memories · Pupa(chat) · Menu
///
/// The app's only bar: the sidebar has no footer, so the menu carries what used to
/// be split between the two — Agents and History (the low-traffic per-subject
/// pages) plus the global Screen share and Settings. The orchestrator has no
/// canvas change-log, so its the menu omits History. Icons are tinted in the
/// subject's color; the pupa keeps its own look.
public struct MyAppBottomBar: View {
    /// Which page the bar should mark as active.
    public enum Page: Equatable {
        case home
        case component(String)
        /// The memory browse page or any memory file within it.
        case memories
        /// The agents overview or any agent detail page. Reached from the menu, so
        /// it lights the menu rather than a slot of its own.
        case agents
        /// The change-history page. Also reached from the menu.
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
    /// Present the MyApps sheet. The bar is the only way there now that the
    /// top-left hamburger is gone. `nil` on macOS, where the sidebar column is
    /// always on screen and a row that opens it would be redundant.
    let onOpenMyApps: (() -> Void)?
    /// Open the screen-share viewer. Separate from `onSelect` because it must
    /// **push**: it is the one page the bar does not appear on, so a root swap
    /// there would leave no bar, no Back button, and no way out.
    let onOpenScreenShare: () -> Void

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
        onOpenSettings: @escaping () -> Void,
        onOpenMyApps: (() -> Void)? = nil,
        onOpenScreenShare: @escaping () -> Void
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
        self.onOpenMyApps = onOpenMyApps
        self.onOpenScreenShare = onOpenScreenShare
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
        // macOS: keep the end controls (Home, menu) off the window edge — the
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

    /// True while a page reached through the menu is showing, so the button reads
    /// as the active slot the way a real tab would.
    private var moreActive: Bool {
        currentPage == .agents || currentPage == .history
    }

    /// The app's menu, grouped one axis per section — this scope's pages
    /// (Agents, History), which scope you're in (MyApps, Orchestrator), then
    /// app-wide (Screen share, Settings). Mixing those in one flat list put
    /// History next to Settings, two rows that don't even apply to the same
    /// thing; MyApps is a single row onto its own surface instead.
    ///
    /// iOS flips a bottom-anchored menu, so the first group declared lands
    /// nearest the thumb.
    ///
    /// Components are deliberately absent — Home already grids them. The
    /// orchestrator's bar omits the Orchestrator row, the same way it omits
    /// History: you're already there.
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
            // The scope group is empty on the macOS orchestrator bar — no
            // MyApps row (the column is always up) and no Orchestrator row
            // (you're on it) — so skip it rather than colliding two dividers.
            if onOpenMyApps != nil || myAppId != nil {
                if let onOpenMyApps {
                    Button(action: onOpenMyApps) {
                        Label("MyApps", systemImage: "square.grid.2x2")
                    }
                }
                if myAppId != nil {
                    Button {
                        onSelect(.orchestrator)
                    } label: {
                        Label("Orchestrator", systemImage: "square.stack.3d.up.fill")
                    }
                }
                Divider()
            }
            Button(action: onOpenScreenShare) {
                Label("Screen share", systemImage: "rectangle.on.rectangle")
            }
            Button(action: onOpenSettings) {
                Label("Settings", systemImage: "gearshape")
            }
        } label: {
            // Heavier and a touch larger than the other slots: three thin rules
            // at the shared 18pt/medium did not read as a hamburger.
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 21, weight: moreActive ? .bold : .semibold))
                .foregroundStyle(moreActive ? appColor : appColor.opacity(0.7))
                .frame(height: Self.rowHeight)
                .padding(.horizontal, 14)
                // Built only when active. A `.fill(.clear)` capsule is still a
                // shape layer the bar re-rasterizes on every nav, and the bar
                // re-lays out on every one — measured ~5ms of frame time on an
                // app switch, which is most of this button's cost.
                .background {
                    if moreActive { Capsule().fill(appColor.opacity(0.16)) }
                }
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        // Claim an equal slot like the other bar buttons: on macOS the
        // borderless menu collapses to its label's intrinsic width otherwise,
        // shoving the menu against the trailing edge.
        .frame(maxWidth: .infinity)
        .help("Menu")
        .accessibilityLabel("Menu")
        .tourAnchor(.bottomBarMore)
    }
}
