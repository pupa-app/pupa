import SwiftUI

/// Persistent bottom bar for a myApp or the orchestrator — the per-subject
/// "tab bar". Always visible (mounted via `.safeAreaInset`) on a myApp's home /
/// component / memories pages and on the orchestrator's home / memories pages.
///
///   myApp:        Home · Memories · History · Pupa(chat) · ⋯(components)
///   orchestrator: Home · Memories ·           Pupa(chat) · ⋯(jump to myapps)
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

    public var body: some View {
        HStack(spacing: 0) {
            barButton(system: "house", active: currentPage == .home, help: "Home") {
                onSelect(homeSelection)
            }
            barButton(system: "brain", active: currentPage == .memories, help: "Memories") {
                onSelect(memoriesSelection)
            }
            if let id = myAppId {
                barButton(system: "clock", active: false, help: "History") {
                    onShowHistory(id)
                }
            }
            pupaButton
            ellipsisMenu
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .background(.regularMaterial)
        .overlay(alignment: .top) { Divider() }
    }

    private func barButton(
        system: String,
        active: Bool,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(active ? appColor : appColor.opacity(0.55))
                .frame(maxWidth: .infinity)
                .frame(height: 34)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
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
            .frame(width: 36, height: 36)
            .shadow(color: .black.opacity(0.2), radius: 4, y: 1)
            .overlay(alignment: .topTrailing) {
                if chatStatus != .idle {
                    StatusBadge(status: chatStatus, size: 12)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 34)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(chatOpen ? "Close chat" : "Open chat")
        .accessibilityValue(chatStatus.accessibilityDescription ?? "")
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
                .frame(height: 34)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .help(myAppId == nil ? "Myapps" : "Components")
        .accessibilityLabel(myAppId == nil ? "Myapps" : "Components")
    }
}
