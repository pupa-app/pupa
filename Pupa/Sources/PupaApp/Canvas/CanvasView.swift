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
        switch component.body {
        case .empty:
            EmptyComponentHint(kind: component.kindString)
        case .tracker(let data):
            switch data.viewMode {
            case .grid:
                TrackerView(store: store, data: data, myAppId: resolvedMyAppId, componentId: component.id)
            case .kanban:
                KanbanView(store: store, data: data, myAppId: resolvedMyAppId, componentId: component.id)
            }
        case .calendar(let data):
            CalendarView(store: store, data: data, myAppId: resolvedMyAppId, componentId: component.id)
        case .checklist(let data):
            ChecklistView(store: store, data: data, myAppId: resolvedMyAppId, componentId: component.id)
        case .slack(let data):
            SlackView(store: store, data: data, myAppId: resolvedMyAppId,
                      componentId: component.id, coordinator: coordinator)
        case .calculator(let data):
            CalculatorView(store: store, data: data, myAppId: resolvedMyAppId, componentId: component.id)
        case .chart(let data):
            ChartContainerView(store: store, data: data, myAppId: resolvedMyAppId)
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

    private var headline: String {
        switch kind {
        case "calendar": return "This calendar is empty"
        case "tracker": return "This tracker is empty"
        case "checklist": return "This checklist is empty"
        case "calculator": return "This calculator is empty"
        case "chart": return "This chart is empty"
        default: return "Your canvas is empty"
        }
    }

    private var subline: String {
        switch kind {
        case "calendar":
            return "Tell the chat what events to add. Try \"Add a dentist appointment Tuesday at 10am\"."
        case "tracker":
            return "Tell the chat what to track. Try \"Build me a wardrobe tracker\" or \"I want to log books I've read\"."
        case "checklist":
            return "Tell the chat what to list. Try \"Make a packing list for a weekend trip\" or \"Things to do today\"."
        case "calculator":
            return "Tell the chat what to compute. Try \"Estimate my monthly mortgage payment\" or \"Total my expenses by category\"."
        case "chart":
            return "Tell the chat what to plot. Try \"Pie chart of spend by cuisine\" or \"Bar chart of monthly totals\"."
        default:
            return "Tell the chat what you want to build. Try \"Build me a wardrobe tracker\" or \"Add a calendar of my appointments\"."
        }
    }
}
