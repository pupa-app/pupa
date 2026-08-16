import SwiftUI

/// Jira-style kanban rendering of `TrackerData`. One vertical lane per
/// option of the field named `data.columnField` (a `.select` field), plus
/// an implicit "(Unset)" lane for items missing that field. Items are
/// re-grouped each render; cards reclassify by dragging between lanes
/// (drop onto "(Unset)" clears the column-field value).
public struct KanbanView: View {
    @Bindable var store: MyAppStore
    let data: TrackerData
    let myAppId: UUID
    let componentId: String?
    @State private var sheet: SheetTarget?
    /// See `TrackerView.queryByComponent` — same structural-`@State` caveat.
    @State private var queryByComponent: [String: String] = [:]
    /// Filter-panel disclosure, collapsed by default.
    @State private var filtersShownByComponent: [String: Bool] = [:]

    public init(store: MyAppStore, data: TrackerData, myAppId: UUID, componentId: String? = nil) {
        self.store = store
        self.data = data
        self.myAppId = myAppId
        self.componentId = componentId
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            CanvasTitleBar(
                store: store,
                data: data,
                componentId: componentId,
                filtersExpanded: hasAnyFilters ? filtersShownBinding : nil,
                activeFilterCount: activeFilterCount
            )

            if let column = resolvedColumnField {
                if !data.items.isEmpty {
                    TrackerSearchField(initialText: query, onQueryChange: setQuery)
                        .id(componentId)
                }
                // Kanban honours `data.filter` too, so the chips must be
                // reachable from here — otherwise an agent- or grid-set filter
                // hides cards with no visible cause and no way to clear it.
                if hasAnyFilters, filtersShown {
                    FiltersBar(store: store, fields: data.visibleFields, filter: data.filter, componentId: componentId)
                }
                GroupByBar(store: store, fields: data.visibleFields, currentColumn: column, componentId: componentId)
                LanesScroller(
                    entries: filtered,
                    density: CardDensity.resolve(viewMode: .kanban, shrink: data.shrinkCards),
                    isNarrowed: !query.isEmpty || data.filter.contains { !$0.value.isEmpty },
                    visibleFields: data.visibleFields,
                    column: column,
                    onAdd: { prefilled in sheet = .add(prefilled: prefilled) },
                    onEdit: { itemId in sheet = .edit(itemId: itemId) },
                    onMove: { itemId, newValue in
                        guard let item = data.items.first(where: { $0.id == itemId }) else { return }
                        let current = item.values[column.name] ?? ""
                        guard current != newValue else { return }
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                            _ = store.patchItem(id: itemId, with: [column.name: newValue], myAppId: myAppId, componentId: componentId)
                        }
                    }
                )
            } else {
                EmptyKanbanHint(store: store, componentId: componentId)
            }
        }
        .sheet(item: $sheet) { target in
            ItemSheet(
                target: target,
                store: store,
                fields: data.visibleFields,
                initialItem: initialItem(for: target),
                myAppId: myAppId,
                componentId: componentId,
                initialLinkedItems: initialLinkedItems(for: target),
                onClose: { sheet = nil }
            )
        }
    }

    /// Same as TrackerView's helper — sourced row's `linkedItems` for the
    /// editor sheet so the kanban edit experience matches the grid one.
    private func initialLinkedItems(for target: SheetTarget) -> [ComponentItemRef] {
        switch target {
        case .add: return []
        case .edit(let itemId):
            return data.items.first(where: { $0.id == itemId })?.linkedItems ?? []
        }
    }

    private var query: String { queryByComponent[componentId ?? ""] ?? "" }

    private func setQuery(_ new: String) {
        guard new != query else { return }
        queryByComponent[componentId ?? ""] = new
    }

    private var hasAnyFilters: Bool {
        data.visibleFields.contains { $0.type == .select && !($0.options ?? []).isEmpty }
    }

    private var filtersShown: Bool { filtersShownByComponent[componentId ?? ""] ?? false }

    private var filtersShownBinding: Binding<Bool> {
        Binding(
            get: { filtersShown },
            set: { filtersShownByComponent[componentId ?? ""] = $0 }
        )
    }

    private var activeFilterCount: Int {
        data.filter.reduce(into: 0) { n, entry in if !entry.value.isEmpty { n += 1 } }
    }

    /// Selected once here and passed down, so bucketing never re-runs the
    /// filter per lane.
    private var filtered: [TrackerFiltering.Entry] {
        TrackerFiltering.visibleEntries(
            items: data.items,
            fields: data.visibleFields,
            filter: data.filter,
            query: query
        )
    }

    /// Resolve the column field from `data.columnField`. Returns nil when
    /// the named field is missing, hidden, or no longer a usable select —
    /// any of those surface the empty-state hint instead of grouping by a
    /// field the user can't see. A hidden column field is treated as
    /// "no usable column" so unhide cleanly restores the kanban grouping.
    private var resolvedColumnField: FieldDef? {
        guard let name = data.columnField,
              let field = data.fields.first(where: { $0.name == name }),
              field.type == .select,
              !(field.options ?? []).isEmpty,
              !(field.hidden ?? false) else { return nil }
        return field
    }

    private func initialItem(for target: SheetTarget) -> [String: String] {
        switch target {
        case .add(let prefilled):
            return prefilled
        case .edit(let itemId):
            return data.items.first(where: { $0.id == itemId })?.values ?? [:]
        }
    }
}

// MARK: - Group-by picker

/// Lets the user pick which select field drives the kanban columns. Only
/// shown when at least one usable select field exists (otherwise the
/// `EmptyKanbanHint` is rendered instead). Selecting an option re-enters
/// `setTrackerViewMode(.kanban, columnField:)` so the choice persists and
/// the agent sees the change via `getCanvasState`.
private struct GroupByBar: View {
    @Bindable var store: MyAppStore
    let fields: [FieldDef]
    let currentColumn: FieldDef
    var componentId: String? = nil

    var body: some View {
        HStack(spacing: 8) {
            Text("Group by")
                .font(.caption)
                .foregroundStyle(.secondary)
            Menu {
                ForEach(eligibleFields) { field in
                    Button {
                        select(field.name)
                    } label: {
                        if field.name == currentColumn.name {
                            Label(field.label ?? field.name, systemImage: "checkmark")
                        } else {
                            Text(field.label ?? field.name)
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(currentColumn.label ?? currentColumn.name)
                        .font(.caption.weight(.semibold))
                    Image(systemName: "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.accentColor.opacity(0.15))
                .clipShape(Capsule())
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(eligibleFields.count <= 1)
            Spacer()
        }
    }

    private var eligibleFields: [FieldDef] {
        fields.filter { $0.type == .select && !($0.options ?? []).isEmpty && !($0.hidden ?? false) }
    }

    private func select(_ name: String) {
        guard name != currentColumn.name else { return }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            _ = store.setTrackerViewMode(.kanban, columnField: name, componentId: componentId)
        }
    }
}

// MARK: - Lanes

private struct LanesScroller: View {
    /// Already filtered and searched by `KanbanView`. Bucketing never sees
    /// the raw item list, which is what stopped kanban ignoring `data.filter`.
    let entries: [TrackerFiltering.Entry]
    let density: CardDensity
    /// A filter or query is active — switches empty lanes to "No matches".
    let isNarrowed: Bool
    let visibleFields: [FieldDef]
    let column: FieldDef
    let onAdd: ([String: String]) -> Void
    let onEdit: (UUID) -> Void
    let onMove: (UUID, String) -> Void

    private static let laneWidth: CGFloat = 260

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 14) {
                ForEach(lanes, id: \.id) { lane in
                    Lane(
                        title: lane.title,
                        count: lane.entries.count,
                        items: lane.entries,
                        layout: cardLayout,
                        density: density,
                        isNarrowed: isNarrowed,
                        accentTint: tint(for: lane),
                        laneValue: lane.laneValue,
                        onAdd: { onAdd(prefill(for: lane)) },
                        onEdit: onEdit,
                        onMove: onMove
                    )
                    .frame(width: Self.laneWidth)
                }
            }
            .padding(.bottom, 4)
        }
    }

    private var cardLayout: CardLayout {
        CardLayout.from(fields: visibleFields, excluding: column.name)
    }

    /// Every option lane plus "(Unset)" — always, even when a lane is empty,
    /// so searching narrows cards without reflowing the board.
    private var lanes: [TrackerFiltering.LaneBucket] {
        TrackerFiltering.lanes(entries: entries, column: column)
    }

    private func prefill(for lane: TrackerFiltering.LaneBucket) -> [String: String] {
        lane.laneValue.isEmpty ? [:] : [column.name: lane.laneValue]
    }

    /// Stable per-option tint so lanes are visually distinguishable.
    private func tint(for lane: TrackerFiltering.LaneBucket) -> Color {
        guard !lane.laneValue.isEmpty else { return Color.gray }
        let seed = abs(lane.laneValue.hashValue)
        let hue = Double(seed % 360) / 360.0
        return Color(hue: hue, saturation: 0.55, brightness: 0.65)
    }

}

private struct Lane: View {
    let title: String
    let count: Int
    let items: [TrackerFiltering.Entry]
    let layout: CardLayout
    let density: CardDensity
    let isNarrowed: Bool
    let accentTint: Color
    /// Value written to the column field when an item is dropped here.
    /// Empty string for the "(Unset)" lane.
    let laneValue: String
    let onAdd: () -> Void
    let onEdit: (UUID) -> Void
    let onMove: (UUID, String) -> Void

    @State private var dropTargeted: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle()
                    .fill(accentTint)
                    .frame(width: 8, height: 8)
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text("\(count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(action: onAdd) {
                    Image(systemName: "plus")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.borderless)
                .help("Add item to \(title)")
            }
            .padding(.horizontal, 4)

            if items.isEmpty {
                // Same frame either way: lane geometry must never depend on
                // whether rows currently match.
                Text(isNarrowed ? "No matches" : "Drop or add an item")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, minHeight: 60, alignment: .center)
                    .background(Color.gray.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(
                                Color.gray.opacity(0.25),
                                style: StrokeStyle(lineWidth: 1, dash: [4, 3])
                            )
                    )
            } else {
                // Plain VStack, deliberately not Lazy. This lane sits inside a
                // horizontal ScrollView inside the canvas's vertical one, so it
                // is laid out against an unbounded height proposal — a lazy
                // stack has no viewport to virtualize against there, builds
                // every row anyway, and its placement/estimation pass is one
                // half of the layout loop that froze the board (pupa#120).
                VStack(spacing: density == .minimal ? 4 : 8) {
                    ForEach(items) { entry in
                        TrackerItemCard(
                            item: entry.item,
                            layout: layout,
                            positionIndex: entry.positionIndex,
                            density: density,
                            onTap: { onEdit(entry.item.id) }
                        )
                        .draggable(entry.item.id.uuidString)
                    }
                }
            }
        }
        .padding(12)
        // No `maxHeight: .infinity`: the height proposal here is unbounded
        // (vertical ScrollView → horizontal ScrollView → lane), so stretching
        // to fill it makes lane height and content height define each other.
        // Lanes now size to their content and end ragged, which is the honest
        // rendering of "this lane holds fewer cards".
        .background(Color.cardBackground.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(dropTargeted ? accentTint : Color.cardBorder,
                        lineWidth: dropTargeted ? 2 : 1)
        )
        .dropDestination(for: String.self) { strings, _ in
            guard let raw = strings.first, let id = UUID(uuidString: raw) else { return false }
            onMove(id, laneValue)
            return true
        } isTargeted: { dropTargeted = $0 }
    }
}

// MARK: - Empty-state hint

private struct EmptyKanbanHint: View {
    @Bindable var store: MyAppStore
    var componentId: String? = nil

    var body: some View {
        SectionCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("Kanban needs a select field")
                    .font(.headline)
                Text("Add a `select`-type field with at least one option (e.g. status: todo / doing / done) to group items into columns. Or switch back to grid view.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                        _ = store.setTrackerViewMode(.grid, componentId: componentId)
                    }
                } label: {
                    Label("Back to grid", systemImage: "square.grid.2x2")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
    }
}
