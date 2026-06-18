import SwiftUI

/// Bottom dock for quick-switching between a myApp's homepage and its
/// component pages — the familiar "tab bar" pattern, scoped to one app.
/// Icon-only buttons (Home + one per component) tinted in the app's color;
/// the current page is highlighted.
///
/// Reveal is by *approaching the bottom*:
///   - macOS: a transparent strip along the bottom edge tracks the pointer;
///     nearing it slides the dock up, leaving hides it.
///   - iOS (no hover): a slim handle peeks at the bottom; tapping it expands
///     the dock, and selecting a page tucks it away again.
///
/// Hosted once in `AppView`'s detail `ZStack` (below `ChatOverlay`, so an
/// expanded chat covers it). The transparent filler region is non-hittable,
/// so the canvas underneath stays interactive.
public struct MyAppDock: View {
    /// Which page the dock should mark as active.
    public enum Page: Equatable {
        case home
        case component(String)
        case memory(String)
    }

    /// A myApp memory note shown as a dock shortcut. `path` is the note's
    /// path in the global memory tree — it drives both selection and the
    /// active-page highlight.
    public struct MemoryItem: Identifiable, Equatable {
        public let path: String
        public let name: String
        public init(path: String, name: String) {
            self.path = path
            self.name = name
        }
        public var id: String { path }
    }

    let store: MyAppStore
    let myAppId: UUID
    let currentPage: Page
    let appColor: Color
    /// The myApp's top-level memory notes, shown after the component icons.
    let memoryFiles: [MemoryItem]
    /// iOS: a counter the host bumps when the page behind is scrolled. Each
    /// change tucks the dock away — scrolling dismisses it. Unused on macOS.
    let dismissSignal: Int
    let onSelect: (SidebarSelection) -> Void

    public init(
        store: MyAppStore,
        myAppId: UUID,
        currentPage: Page,
        appColor: Color,
        memoryFiles: [MemoryItem] = [],
        dismissSignal: Int = 0,
        onSelect: @escaping (SidebarSelection) -> Void
    ) {
        self.store = store
        self.myAppId = myAppId
        self.currentPage = currentPage
        self.appColor = appColor
        self.memoryFiles = memoryFiles
        self.dismissSignal = dismissSignal
        self.onSelect = onSelect
    }

    /// Revealed = dock fully shown. macOS toggles it on hover; iOS on tap.
    @State private var revealed = false
    /// iOS inactivity timer token. Bumped on every reveal / page-switch / hide;
    /// a pending fade only fires if its token still matches (i.e. nothing has
    /// re-armed or cancelled it since). Avoids capturing non-Sendable `self` in
    /// a `Task`.
    @State private var hideToken = 0

    private var app: MyApp? { store.myApps.first { $0.id == myAppId } }

    public var body: some View {
        #if os(macOS)
        macBody
        #else
        iosBody
        #endif
    }

    #if os(macOS)
    /// Hover-to-reveal: a transparent strip along the bottom edge tracks the
    /// pointer; nearing it slides the dock up, leaving hides it. The filler
    /// `Spacer` is non-hittable, so the canvas stays interactive.
    private var macBody: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            ZStack(alignment: .bottom) {
                Color.clear
                    .frame(height: 28)
                    .contentShape(Rectangle())
                    .onHover { revealed = $0 }
                dockCapsule
                    .onHover { if $0 { revealed = true } }
                    .offset(y: revealed ? 0 : 96)
                    .opacity(revealed ? 1 : 0)
                    .padding(.bottom, 12)
            }
            .animation(.spring(duration: 0.25), value: revealed)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }
    #else
    /// iOS reveal: a classy up-chevron handle sits at the very bottom; tapping
    /// it expands the dock. The dock never covers the page — only the floating
    /// capsule and handle are hittable, so the page behind stays scrollable.
    /// Scrolling dismisses the dock (via `dismissSignal` bumped by the host),
    /// and an inactivity timer fades it after 5s. The dock persists across page
    /// switches (it doesn't auto-close on a jump), so you can hop several pages
    /// before it tucks away.
    private var iosBody: some View {
        ZStack(alignment: .bottom) {
            if revealed {
                dockCapsule
                    .padding(.bottom, 10)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            } else {
                handle
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .animation(.spring(duration: 0.25), value: revealed)
        .onChange(of: dismissSignal) { hide() }
        .onDisappear { hideToken += 1 }
    }

    /// Small up-chevron pill pinned to the bottom edge. Tap expands the dock.
    private var handle: some View {
        Button { reveal() } label: {
            Image(systemName: "chevron.up")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(appColor)
                .frame(width: 46, height: 22)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(appColor.opacity(0.25)))
        }
        .buttonStyle(.plain)
        .padding(.bottom, 4)
    }

    private func reveal() {
        revealed = true
        scheduleAutoHide()
    }

    private func hide() {
        hideToken += 1
        revealed = false
    }

    /// (Re)arm the 5-second inactivity fade. The deferred close only fires if
    /// its token is still current, so any newer reveal/hide cancels it.
    private func scheduleAutoHide() {
        hideToken += 1
        let token = hideToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            if token == hideToken { revealed = false }
        }
    }
    #endif

    /// Pill row: Home + one icon per component. Hugs its content when the icons
    /// fit; once they'd overflow the width it scrolls horizontally instead of
    /// running off the screen edges.
    private var dockCapsule: some View {
        ViewThatFits(in: .horizontal) {
            iconRow
            ScrollView(.horizontal) { iconRow }
                .scrollIndicators(.hidden)
        }
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08)))
        .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
        .padding(.horizontal, 16)
    }

    private var iconRow: some View {
        HStack(spacing: 4) {
            iconButton(
                system: "house",
                active: currentPage == .home,
                help: "Home"
            ) { select(.myAppHome(myAppId)) }

            ForEach(app?.components ?? []) { component in
                iconButton(
                    system: component.iconSystemName,
                    active: currentPage == .component(component.id),
                    help: component.name
                ) { select(.myAppComponent(myAppId, component.id)) }
            }

            // The app's notes, after a hairline so they read as a distinct
            // group from the component pages. All share the `note.text` glyph
            // — the tooltip / accessibility label carries the note name.
            if !memoryFiles.isEmpty {
                Divider()
                    .frame(height: 22)
                    .padding(.horizontal, 2)
                ForEach(memoryFiles) { item in
                    iconButton(
                        system: "note.text",
                        active: currentPage == .memory(item.path),
                        help: item.name
                    ) { select(.myAppMemoryFile(myAppId, item.path)) }
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    private func iconButton(
        system: String,
        active: Bool,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(active ? appColor : appColor.opacity(0.55))
                .frame(width: 38, height: 38)
                .background {
                    if active { Circle().fill(appColor.opacity(0.18)) }
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }

    private func select(_ selection: SidebarSelection) {
        onSelect(selection)
        #if os(iOS)
        // Stay open across the page switch; just re-arm the inactivity fade so
        // it tucks away 5s after the last hop (or sooner if the page is tapped).
        scheduleAutoHide()
        #endif
    }
}
