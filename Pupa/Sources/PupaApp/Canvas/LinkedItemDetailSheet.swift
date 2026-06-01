import SwiftUI

/// Environment key whose value opens a `ComponentItemRef` as a pop-up
/// editor at the nearest enclosing `linkedItemPopupHost(...)`. Pill rows
/// invoke this on tap; the host wires it to local state that drives a
/// `.sheet(item:)` carrying `LinkedItemDetailSheet`.
///
/// Hosts are installed at every level that contains tappable pills —
/// `CanvasView` (for pills on cards) and inside each existing editor sheet
/// (`ItemSheet`, `CalendarEventEditorSheet`, `ChecklistItemEditorSheet`)
/// so cross-component navigation chains stack instead of competing for the
/// same modal slot.
private struct OpenLinkedItemKey: @preconcurrency EnvironmentKey {
    @MainActor
    static let defaultValue: (ComponentItemRef) -> Void = { _ in }
}

extension EnvironmentValues {
    var openLinkedItem: (ComponentItemRef) -> Void {
        get { self[OpenLinkedItemKey.self] }
        set { self[OpenLinkedItemKey.self] = newValue }
    }
}

/// Wraps a `ComponentItemRef` with a stable identity so it can drive
/// `.sheet(item:)`. The underlying ref is `Hashable` but not `Identifiable`
/// in its public API; this keeps the conformance scoped to the popup
/// machinery.
private struct LinkedRefTarget: Identifiable {
    let ref: ComponentItemRef
    var id: String { "\(ref.componentId):\(ref.itemId.uuidString)" }
}

/// Sheet body that resolves a `ComponentItemRef` to the target's kind and
/// renders the matching existing editor in `.edit` mode. The dispatch
/// reuses `ItemSheet` / `CalendarEventEditorSheet` /
/// `ChecklistItemEditorSheet` unchanged — the only addition is passing the
/// explicit `componentId:` so the editor's save / delete paths target the
/// right component even when it isn't the active one.
struct LinkedItemDetailSheet: View {
    @Bindable var store: MyAppStore
    let ref: ComponentItemRef
    let myAppId: UUID
    let onClose: () -> Void

    var body: some View {
        switch store.componentKind(ref.componentId, myAppId: myAppId) {
        case "tracker":
            trackerEditor
        case "calendar":
            calendarEditor
        case "checklist":
            checklistEditor
        default:
            fallback
        }
    }

    @ViewBuilder
    private var trackerEditor: some View {
        if let item = trackerItem, let fields = trackerFields {
            ItemSheet(
                target: .edit(itemId: ref.itemId),
                store: store,
                fields: fields,
                initialItem: item.values,
                myAppId: myAppId,
                componentId: ref.componentId,
                initialLinkedItems: item.linkedItems,
                onClose: onClose
            )
        } else {
            fallback
        }
    }

    @ViewBuilder
    private var calendarEditor: some View {
        if let event = calendarEvent {
            CalendarEventEditorSheet(
                store: store,
                myAppId: myAppId,
                target: .edit(event),
                componentId: ref.componentId,
                onClose: onClose
            )
        } else {
            fallback
        }
    }

    @ViewBuilder
    private var checklistEditor: some View {
        if let item = checklistItem {
            ChecklistItemEditorSheet(
                store: store,
                myAppId: myAppId,
                item: item,
                componentId: ref.componentId,
                onClose: onClose
            )
        } else {
            fallback
        }
    }

    private var trackerItem: TrackerItem? {
        guard case .tracker(let t) = component()?.body else { return nil }
        return t.items.first(where: { $0.id == ref.itemId })
    }

    private var trackerFields: [FieldDef]? {
        guard case .tracker(let t) = component()?.body else { return nil }
        return t.visibleFields
    }

    private var calendarEvent: CalendarEvent? {
        guard case .calendar(let c) = component()?.body else { return nil }
        return c.events.first(where: { $0.id == ref.itemId })
    }

    private var checklistItem: ChecklistItem? {
        guard case .checklist(let cl) = component()?.body else { return nil }
        return cl.items.first(where: { $0.id == ref.itemId })
    }

    private func component() -> Component? {
        store.myApps.first(where: { $0.id == myAppId })?
            .components.first(where: { $0.id == ref.componentId })
    }

    @ViewBuilder
    private var fallback: some View {
        NavigationStack {
            VStack(spacing: 8) {
                Image(systemName: "link.slash")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Text("This linked item no longer exists.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(32)
            .frame(maxWidth: .infinity)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", action: onClose)
                }
            }
            #if os(macOS)
            .frame(minWidth: 320, idealWidth: 360, minHeight: 200, idealHeight: 220)
            #endif
        }
    }
}

/// View modifier that hosts the linked-item popup at the current
/// presentation layer. Apply at every layer that contains tappable pills:
/// `CanvasView` (cards) and inside each editor sheet's `NavigationStack`
/// body (so a stacked sheet appears above the open editor instead of being
/// swallowed by the already-presented modal).
struct LinkedItemPopupHostModifier: ViewModifier {
    @Bindable var store: MyAppStore
    let myAppId: UUID
    @State private var target: LinkedRefTarget?

    func body(content: Content) -> some View {
        content
            .environment(\.openLinkedItem, { ref in
                target = LinkedRefTarget(ref: ref)
            })
            .sheet(item: $target) { wrapped in
                LinkedItemDetailSheet(
                    store: store,
                    ref: wrapped.ref,
                    myAppId: myAppId,
                    onClose: { target = nil }
                )
            }
    }
}

extension View {
    func linkedItemPopupHost(store: MyAppStore, myAppId: UUID) -> some View {
        modifier(LinkedItemPopupHostModifier(store: store, myAppId: myAppId))
    }
}

/// Reusable pill rendering for the `link` chips that appear on tracker
/// cards, calendar event rows, and checklist rows. Tappable when
/// `resolvedName` is non-nil — invokes `\.openLinkedItem` so the nearest
/// enclosing `linkedItemPopupHost` brings up the target's editor.
/// Renders dimmed and non-interactive for deleted refs (resolvedName ==
/// nil), keeping the previous "(deleted)" placeholder visible.
struct LinkedRefPill: View {
    let ref: ComponentItemRef
    let resolvedName: String?
    @Environment(\.openLinkedItem) private var openLinkedItem

    var body: some View {
        if let name = resolvedName {
            Button {
                openLinkedItem(ref)
            } label: {
                pillLabel(text: name, deleted: false)
            }
            .buttonStyle(.plain)
        } else {
            pillLabel(text: "(deleted)", deleted: true)
        }
    }

    private func pillLabel(text: String, deleted: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "link").font(.caption2)
            Text(text).font(.caption).lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background((deleted ? Color.gray : Color.accentColor).opacity(0.15))
        .foregroundStyle(deleted ? Color.secondary : Color.accentColor)
        .clipShape(Capsule())
    }
}

/// Row used inside an editor sheet's "Linked items" section. Icon + name +
/// sub-label opens the target via `\.openLinkedItem`; the trailing minus
/// button removes the link from the local draft. Deleted refs render the
/// "(deleted)" placeholder and are non-tappable, mirroring the card pill
/// behavior.
struct LinkedRefEditorRow: View {
    let ref: ComponentItemRef
    let resolvedName: String?
    let componentName: String
    let onRemove: () -> Void
    @Environment(\.openLinkedItem) private var openLinkedItem

    var body: some View {
        HStack(spacing: 8) {
            if let name = resolvedName {
                Button {
                    openLinkedItem(ref)
                } label: {
                    rowLabel(name: name, deleted: false)
                }
                .buttonStyle(.plain)
            } else {
                rowLabel(name: "(deleted)", deleted: true)
            }
            Spacer()
            Button(action: onRemove) {
                Image(systemName: "minus.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private func rowLabel(name: String, deleted: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "link")
                .font(.caption)
                .foregroundStyle(deleted ? Color.secondary : Color.accentColor)
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(.body)
                Text(componentName).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
        .opacity(deleted ? 0.6 : 1)
    }
}
