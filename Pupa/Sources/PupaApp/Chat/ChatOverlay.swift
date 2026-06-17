import SwiftUI

/// Floating chat overlay. Collapsed by default as a circular pupa
/// button bottom-trailing of the detail pane; tapping expands it into a
/// floating card (defaulting to roughly half the available space) that hosts
/// a `ConversationPager` — the `ChatPanel` for the active scope's current
/// conversation, with a header dropdown for switching threads. The card is
/// user-resizable via a grip on its top-leading corner. The chosen size
/// survives expand/collapse within a session but resets each launch.
struct ChatOverlay: View {
    let scope: ChatScope
    let coordinator: ChatSessionCoordinator
    let store: MyAppStore
    let agents: [AgentPickerEntry]
    let onSwitchAgent: (ChatScope) -> Void

    @State private var isExpanded: Bool = false
    @State private var isFullscreen: Bool = false
    /// Shared guided-tour store. The chat / slash-command steps raise
    /// `wantChatOpen` to expand this overlay so the coach card has the live
    /// composer to point at.
    @State private var tour = GuidedTourStore.shared
    @State private var userSize: CGSize? = nil
    @State private var dragStartSize: CGSize? = nil
    /// Height of the on-screen keyboard (0 when hidden). Drives manual
    /// keyboard avoidance: the card is bottom-anchored, so default SwiftUI
    /// avoidance can't lift this floating overlay — in landscape the composer
    /// ended up behind the keyboard. We track the keyboard height ourselves
    /// (see `.ignoresSafeArea(.keyboard)` + the notification observers below)
    /// and lift/shrink the card to keep the input visible. Always 0 on macOS.
    @State private var keyboardHeight: CGFloat = 0

    private let iconSize: CGFloat = 56
    /// Pure sizing math (also unit-tested via `ChatCardSizingTests`).
    private let sizing = ChatCardSizing()
    private var edgePadding: CGFloat { sizing.edgePadding }

    var body: some View {
        GeometryReader { geo in
            // Portion of the keyboard overlapping the card's content area (the
            // home-indicator inset is already excluded from `geo.size`).
            let overlap = max(0, keyboardHeight - geo.safeAreaInsets.bottom)
            // Space the card may occupy once the keyboard is up.
            let available = CGSize(
                width: geo.size.width,
                height: max(0, geo.size.height - overlap)
            )
            ZStack(alignment: .bottomTrailing) {
                if isExpanded {
                    card(in: available)
                        .transition(
                            .scale(scale: 0.6, anchor: .bottomTrailing)
                            .combined(with: .opacity)
                        )
                } else {
                    iconButton
                        .transition(
                            .scale(scale: 0.6, anchor: .bottomTrailing)
                            .combined(with: .opacity)
                        )
                }
            }
            .padding(isFullscreen ? 0 : edgePadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            // Lift the bottom-anchored card above the keyboard.
            .padding(.bottom, overlap)
        }
        // Guided tour: mirror its chat intent so each step deterministically
        // expands (chat / slash steps) or collapses (navigate steps) the
        // overlay — that keeps a bottom-placed coach card from colliding with
        // an open chat. `wantChatOpen` only changes during the tour, so this
        // never fights normal use.
        .onChange(of: tour.wantChatOpen) { _, want in
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                isExpanded = want
                if !want { isFullscreen = false }
            }
        }
        #if os(iOS)
        // Keep the GeometryReader at full height (don't let the system shrink
        // it for the keyboard) so we can do the avoidance ourselves above.
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .onReceive(NotificationCenter.default.publisher(
            for: UIResponder.keyboardWillChangeFrameNotification
        )) { note in updateKeyboard(from: note, hidden: false) }
        .onReceive(NotificationCenter.default.publisher(
            for: UIResponder.keyboardWillHideNotification
        )) { note in updateKeyboard(from: note, hidden: true) }
        #endif
    }

    #if os(iOS)
    /// Mirror the keyboard's height into `keyboardHeight`, animated with the
    /// system's own curve/duration so the card glides up and down with it.
    private func updateKeyboard(from note: Notification, hidden: Bool) {
        let info = note.userInfo
        let duration = (info?[UIResponder.keyboardAnimationDurationUserInfoKey]
            as? Double) ?? 0.25
        let endHeight = (info?[UIResponder.keyboardFrameEndUserInfoKey]
            as? NSValue)?.cgRectValue.height ?? 0
        withAnimation(.easeOut(duration: duration)) {
            keyboardHeight = hidden ? 0 : endHeight
        }
    }
    #endif

    private var iconButton: some View {
        Button {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                isExpanded = true
            }
        } label: {
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
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
            .frame(width: iconSize, height: iconSize)
            .shadow(color: .black.opacity(0.25), radius: 8, x: 0, y: 3)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open chat")
    }

    private func card(in containerSize: CGSize) -> some View {
        let size: CGSize = isFullscreen
            ? containerSize
            : sizing.resolvedSize(user: userSize, in: containerSize)

        return ZStack(alignment: .topLeading) {
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    Spacer()
                    Button {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                            isFullscreen.toggle()
                        }
                    } label: {
                        Image(systemName: isFullscreen
                              ? "arrow.down.right.and.arrow.up.left"
                              : "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.secondary)
                            .padding(7)
                            .background(Color.secondary.opacity(0.15), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(isFullscreen ? "Restore chat size" : "Expand chat to full screen")
                    .padding(.trailing, 4)
                    Button(action: collapse) {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .bold))
                            .padding(7)
                            .background(Color.secondary.opacity(0.15), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close chat")
                }
                .padding(.horizontal, 8)
                .padding(.top, 8)
                ConversationPager(
                    scope: scope,
                    coordinator: coordinator,
                    store: store,
                    agents: agents,
                    onSwitchAgent: onSwitchAgent
                )
            }
            if !isFullscreen {
                resizeGrip(in: containerSize)
            }
        }
        .frame(width: size.width, height: size.height)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: isFullscreen ? 0 : 14, style: .continuous))
        .shadow(color: .black.opacity(0.25), radius: 18, x: 0, y: 8)
    }

    private func resizeGrip(in containerSize: CGSize) -> some View {
        Image(systemName: "square.resize")
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(.secondary)
            .padding(6)
            .background(Color.secondary.opacity(0.15), in: Circle())
            .padding(8)
            .contentShape(Rectangle())
            #if os(macOS)
            .onHover { hovering in
                if hovering {
                    NSCursor.crosshair.push()
                } else {
                    NSCursor.pop()
                }
            }
            #endif
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if dragStartSize == nil {
                            dragStartSize = sizing.resolvedSize(user: userSize, in: containerSize)
                        }
                        let start = dragStartSize ?? sizing.resolvedSize(user: userSize, in: containerSize)
                        let proposed = CGSize(
                            width: start.width - value.translation.width,
                            height: start.height - value.translation.height
                        )
                        userSize = sizing.clamp(proposed, in: containerSize)
                    }
                    .onEnded { _ in
                        dragStartSize = nil
                    }
            )
            .accessibilityLabel("Resize chat panel")
    }

    private func collapse() {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            isExpanded = false
            isFullscreen = false
        }
    }
}
