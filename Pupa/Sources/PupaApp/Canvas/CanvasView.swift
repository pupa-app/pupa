import SwiftUI

public struct CanvasView: View {
    @Bindable var store: MyAppStore
    let selection: SidebarSelection
    let coordinator: ChatSessionCoordinator

    public init(
        store: MyAppStore,
        selection: SidebarSelection,
        coordinator: ChatSessionCoordinator
    ) {
        self.store = store
        self.selection = selection
        self.coordinator = coordinator
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if let component = resolvedComponent {
                    if component.kindString != "empty" {
                        // Lock toggle sits on top of the component; when locked,
                        // the body is disabled (controls inert) but still scrolls.
                        LockToggle(
                            store: store,
                            myAppId: resolvedMyAppId,
                            componentId: component.id,
                            isLocked: component.isLocked
                        )
                    }
                    componentContent(component)
                        .disabled(component.isLocked)
                } else {
                    EmptyComponentHint(kind: "empty")
                }
            }
            .padding(24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.canvasBackground)
        .linkedItemPopupHost(store: store, myAppId: resolvedMyAppId)
    }

    @ViewBuilder
    private func componentContent(_ component: Component) -> some View {
        // Every canvas kind renders through its `ComponentModule` (issue #162).
        // Only `.empty` (and any future kind before its module lands —
        // `ComponentRegistry.assertComplete` traps that at bootstrap) has no
        // module; it falls through to the empty-state placeholder.
        if let module = ComponentRegistry.shared.module(forKind: component.kindString) {
            module.makeView(
                component: component,
                store: store,
                myAppId: resolvedMyAppId,
                coordinator: coordinator
            )
        } else {
            EmptyComponentHint(kind: component.kindString)
        }
    }

    /// Component the canvas should render. Resolution prefers an explicit
    /// `.myAppComponent` selection; falling back to the active component of
    /// the MyApp (which a `.myApp` parent selection or stale `componentId`
    /// both end up at).
    private var resolvedComponent: Component? {
        switch selection {
        case .myAppComponent(let myAppId, let componentId):
            guard let m = store.myApps.first(where: { $0.id == myAppId }) else { return nil }
            return m.component(withId: componentId) ?? m.activeComponent
        case .myApp(let myAppId):
            return store.myApps.first(where: { $0.id == myAppId })?.activeComponent
        default:
            return store.activeMyApp.activeComponent
        }
    }

    /// MyApp id the resolved component belongs to. Passed into the
    /// calendar view so linked-event resolution can find sibling tracker
    /// components in the same MyApp.
    private var resolvedMyAppId: UUID {
        switch selection {
        case .myAppComponent(let id, _), .myApp(let id):
            return id
        default:
            return store.activeMyAppId
        }
    }
}

/// Lock icon on top of a canvas component. Toggles `Component.isLocked`;
/// a locked component refuses every mutating tool (agent) and disables its
/// in-canvas edit controls (user), while reads/scroll still work.
private struct LockToggle: View {
    @Bindable var store: MyAppStore
    let myAppId: UUID
    let componentId: String
    let isLocked: Bool

    var body: some View {
        HStack {
            Spacer()
            Button {
                store.setComponentLocked(componentId: componentId, locked: !isLocked, myAppId: myAppId)
            } label: {
                Image(systemName: isLocked ? "lock.fill" : "lock.open")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(isLocked ? Color.orange : Color.secondary)
                    .padding(7)
                    .background(.thinMaterial, in: Circle())
                    .overlay(Circle().strokeBorder(Color.primary.opacity(0.08)))
            }
            .buttonStyle(.plain)
            .help(isLocked ? "Unlock component — allow edits" : "Lock component — block edits")
            .accessibilityLabel(isLocked ? "Unlock component" : "Lock component")
        }
    }
}

private struct EmptyComponentHint: View {
    let kind: String

    var body: some View {
        VStack(spacing: 6) {
            Text(headline).font(.headline).foregroundStyle(.primary)
            Text(subline)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
        }
        .padding(32)
        .frame(maxWidth: .infinity)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.gray.opacity(0.3), style: StrokeStyle(lineWidth: 1, dash: [6, 4]))
        )
    }

    // In practice `kind` is always `"empty"` (moduled kinds render their own
    // view via `ComponentModule.makeView` and never reach here); the module
    // lookup stays as a defensive path for any future non-module kind.
    private var headline: String {
        ComponentRegistry.shared.module(forKind: kind)?.emptyHint().headline
            ?? "Your canvas is empty"
    }

    private var subline: String {
        ComponentRegistry.shared.module(forKind: kind)?.emptyHint().subline
            ?? "Tell the chat what you want to build. Try \"Build me a wardrobe tracker\" or \"Add a calendar of my appointments\"."
    }
}
