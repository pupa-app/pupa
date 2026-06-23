import SwiftUI

/// Persistent bottom bar for a myApp — the per-app "tab bar". Always visible
/// (mounted via `.safeAreaInset` so page content insets above it) on a myApp's
/// home / component / memories pages. Fixed destinations on the left, the chat
/// launcher in the middle-right, and a `⋯` menu that jumps to any component:
///
///   Home · Memories · History · Pupa(chat) · ⋯(components)
///
/// Icons are tinted in the app's color; the pupa keeps its own look. Hidden on
/// non-myApp pages (orchestrator, agents, screen share) — there the
/// `ChatOverlay`'s own floating launcher takes over.
public struct MyAppBottomBar: View {
    /// Which page the bar should mark as active.
    public enum Page: Equatable {
        case home
        case component(String)
        /// The memory browse page or any memory file within it.
        case memories
    }

    let store: MyAppStore
    let myAppId: UUID
    let currentPage: Page
    let appColor: Color
    /// Folded chat status for the scope — surfaces a background run on the
    /// pupa button while chat is closed.
    let chatStatus: ChatActivityStatus
    /// Whether the chat card is currently open (drives the pupa button's label).
    let chatOpen: Bool
    let onSelect: (SidebarSelection) -> Void
    let onShowHistory: () -> Void
    let onToggleChat: () -> Void

    public init(
        store: MyAppStore,
        myAppId: UUID,
        currentPage: Page,
        appColor: Color,
        chatStatus: ChatActivityStatus,
        chatOpen: Bool,
        onSelect: @escaping (SidebarSelection) -> Void,
        onShowHistory: @escaping () -> Void,
        onToggleChat: @escaping () -> Void
    ) {
        self.store = store
        self.myAppId = myAppId
        self.currentPage = currentPage
        self.appColor = appColor
        self.chatStatus = chatStatus
        self.chatOpen = chatOpen
        self.onSelect = onSelect
        self.onShowHistory = onShowHistory
        self.onToggleChat = onToggleChat
    }

    private var app: MyApp? { store.myApps.first { $0.id == myAppId } }

    public var body: some View {
        HStack(spacing: 0) {
            barButton(system: "house", active: currentPage == .home, help: "Home") {
                onSelect(.myAppHome(myAppId))
            }
            barButton(system: "brain", active: currentPage == .memories, help: "Memories") {
                onSelect(.myAppMemories(myAppId))
            }
            barButton(system: "clock", active: false, help: "History", action: onShowHistory)
            pupaButton
            componentsMenu
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

    /// Jump-to-component menu — the component navigator that used to be the
    /// dock's icon row.
    private var componentsMenu: some View {
        Menu {
            let components = app?.components ?? []
            if components.isEmpty {
                Text("No components yet")
            } else {
                ForEach(components) { component in
                    Button {
                        onSelect(.myAppComponent(myAppId, component.id))
                    } label: {
                        Label(component.name, systemImage: component.iconSystemName)
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
        .help("Components")
        .accessibilityLabel("Components")
    }
}
