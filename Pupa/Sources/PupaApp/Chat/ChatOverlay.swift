import SwiftUI

/// Floating chat overlay. Collapsed by default as a circular pupa
/// button bottom-trailing of the detail pane; tapping expands it into a
/// floating card (defaulting to roughly half the available space) that hosts
/// a `ConversationPager` — a horizontal swipeable list of conversations for
/// the active scope. The card is user-resizable via a grip on its top-leading
/// corner. The chosen size survives expand/collapse within a session but
/// resets each launch.
struct ChatOverlay: View {
    let scope: ChatScope
    let coordinator: ChatSessionCoordinator
    let store: MyAppStore
    let agents: [AgentPickerEntry]
    let onSwitchAgent: (ChatScope) -> Void

    @State private var isExpanded: Bool = false
    @State private var userSize: CGSize? = nil
    @State private var dragStartSize: CGSize? = nil

    private let edgePadding: CGFloat = 16
    private let iconSize: CGFloat = 56
    private let minCardSize = CGSize(width: 320, height: 360)
    private let defaultWidthFraction: CGFloat = 0.5
    private let defaultHeightFraction: CGFloat = 0.6

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottomTrailing) {
                if isExpanded {
                    card(in: geo.size)
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
            .padding(edgePadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        }
    }

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
        let size = resolvedSize(in: containerSize)

        return ZStack(alignment: .topLeading) {
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    Spacer()
                    Button(action: collapse) {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .bold))
                            .padding(6)
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
            resizeGrip(in: containerSize)
        }
        .frame(width: size.width, height: size.height)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: .black.opacity(0.25), radius: 18, x: 0, y: 8)
    }

    private func resizeGrip(in containerSize: CGSize) -> some View {
        Image(systemName: "arrow.up.left.and.down.right")
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
                            dragStartSize = resolvedSize(in: containerSize)
                        }
                        let start = dragStartSize ?? resolvedSize(in: containerSize)
                        let proposed = CGSize(
                            width: start.width - value.translation.width,
                            height: start.height - value.translation.height
                        )
                        userSize = clamp(proposed, in: containerSize)
                    }
                    .onEnded { _ in
                        dragStartSize = nil
                    }
            )
            .accessibilityLabel("Resize chat panel")
    }

    private func defaultSize(in containerSize: CGSize) -> CGSize {
        let maxW = max(minCardSize.width, containerSize.width - edgePadding * 2)
        let maxH = max(minCardSize.height, containerSize.height - edgePadding * 2)
        let w = max(minCardSize.width, min(maxW, containerSize.width * defaultWidthFraction))
        let h = max(minCardSize.height, min(maxH, containerSize.height * defaultHeightFraction))
        return CGSize(width: w, height: h)
    }

    private func resolvedSize(in containerSize: CGSize) -> CGSize {
        clamp(userSize ?? defaultSize(in: containerSize), in: containerSize)
    }

    private func clamp(_ size: CGSize, in containerSize: CGSize) -> CGSize {
        let maxW = max(minCardSize.width, containerSize.width - edgePadding * 2)
        let maxH = max(minCardSize.height, containerSize.height - edgePadding * 2)
        return CGSize(
            width: max(minCardSize.width, min(maxW, size.width)),
            height: max(minCardSize.height, min(maxH, size.height))
        )
    }

    private func collapse() {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            isExpanded = false
        }
    }
}
