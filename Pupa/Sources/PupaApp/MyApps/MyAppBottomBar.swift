import SwiftUI

/// Persistent bottom bar for a myApp or the orchestrator — the per-subject
/// "tab bar". Always visible (mounted via `.safeAreaInset`) on a myApp's home /
/// component / memories pages and on the orchestrator's home / memories pages.
///
///   myApp:        Home · Agents · Memories · History · Pupa(chat) · ⋯(components)
///   orchestrator: Home · Agents · Memories ·           Pupa(chat) · ⋯(jump to myapps)
///
/// (The orchestrator has no canvas change-log, so it omits History.) Icons are
/// tinted in the subject's color; the pupa keeps its own look.
public struct MyAppBottomBar: View {
    /// Which page the bar should mark as active.
    public enum Page: Equatable {
        case home
        case component(String)
        /// The memory browse page or any memory file within it.
        case memories
        /// The agents overview or any agent detail page.
        case agents
        /// The change-history page.
        case history
    }

    let store: MyAppStore
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
    /// orchestrator hides the History button.
    let onShowHistory: (UUID) -> Void
    let onToggleChat: () -> Void

    /// Row height for each bar button.
    static let rowHeight: CGFloat = 30
    /// Vertical padding above/below the row.
    static let verticalPadding: CGFloat = 4

    public init(
        store: MyAppStore,
        subject: MyAppHomeView.Subject,
        currentPage: Page,
        appColor: Color,
        chatStatus: ChatActivityStatus,
        chatOpen: Bool,
        onSelect: @escaping (SidebarSelection) -> Void,
        onShowHistory: @escaping (UUID) -> Void,
        onToggleChat: @escaping () -> Void
    ) {
        self.store = store
        self.subject = subject
        self.currentPage = currentPage
        self.appColor = appColor
        self.chatStatus = chatStatus
        self.chatOpen = chatOpen
        self.onSelect = onSelect
        self.onShowHistory = onShowHistory
        self.onToggleChat = onToggleChat
    }

    private var myAppId: UUID? {
        if case .myApp(let id) = subject { return id }
        return nil
    }

    private var app: MyApp? {
        guard let id = myAppId else { return nil }
        return store.myApps.first { $0.id == id }
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
            barButton(system: "person.2", active: currentPage == .agents, help: "Agents",
                      highlight: .bottomBarAgents) {
                onSelect(agentsSelection)
            }
            if let id = myAppId {
                barButton(system: "clock", active: currentPage == .history, help: "History",
                          highlight: .bottomBarHistory) {
                    onShowHistory(id)
                }
            }
            pupaButton
            ellipsisMenu
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
        .accessibilityValue(chatStatus.accessibilityDescription ?? "")
        .tourAnchor(.bottomBarChat)
    }

    /// `⋯` jump menu: a myApp lists its components; the orchestrator lists the
    /// myapps it can drive.
    private var ellipsisMenu: some View {
        Menu {
            if let app {
                if app.components.isEmpty {
                    Text("No components yet")
                } else {
                    ForEach(app.components) { component in
                        Button {
                            onSelect(.myAppComponent(app.id, component.id))
                        } label: {
                            Label(component.name, systemImage: component.iconSystemName)
                        }
                    }
                }
            } else {
                if store.myApps.isEmpty {
                    Text("No myapps yet")
                } else {
                    ForEach(store.myApps) { myApp in
                        Button {
                            onSelect(.myAppHome(myApp.id))
                        } label: {
                            Label(myApp.name, systemImage: myApp.iconSystemName)
                        }
                    }
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(appColor.opacity(0.7))
                .frame(maxWidth: .infinity)
                .frame(height: Self.rowHeight)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        // Claim an equal slot like the other bar buttons: on macOS the
        // borderless menu collapses to its label's intrinsic width otherwise,
        // shoving `⋯` against the trailing edge.
        .frame(maxWidth: .infinity)
        .help(myAppId == nil ? "Myapps" : "Components")
        .accessibilityLabel(myAppId == nil ? "Myapps" : "Components")
    }
}
