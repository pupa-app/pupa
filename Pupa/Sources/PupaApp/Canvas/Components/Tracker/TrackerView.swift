import SwiftUI

public struct TrackerView: View {
    @Bindable var store: MyAppStore
    let data: TrackerData
    /// MyApp the tracker lives in. Threaded down so link-pill rendering
    /// can resolve cross-component targets and the editor sheet can
    /// scope its mutations.
    let myAppId: UUID
    /// Stable id of the tracker component currently being rendered.
    /// Used by the link picker to hide self-refs and by the link-pill
    /// resolver to namespace ref scoping. Optional only for legacy
    /// init paths; CanvasView always supplies it.
    let componentId: String?
    @State private var sheet: SheetTarget?
    /// Debounced search text, keyed by component id. `CanvasView` builds
    /// component views without `.id(component.id)`, so `@State` is keyed by
    /// structural position — a bare `String` here would leak one tracker's
    /// query onto the next. Same fix `SlackView.channelScrollAnchor` uses.
    @State private var queryByComponent: [String: String] = [:]

    public init(store: MyAppStore, data: TrackerData, myAppId: UUID, componentId: String? = nil) {
        self.store = store
        self.data = data
        self.myAppId = myAppId
        self.componentId = componentId
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            CanvasTitleBar(store: store, data: data, componentId: componentId)

            if !data.items.isEmpty {
                TrackerSearchField(initialText: query, onQueryChange: setQuery)
                    .id(componentId)
            }

            if hasAnyFilters {
                FiltersBar(store: store, fields: data.visibleFields, filter: data.filter, componentId: componentId)
            }

            CardsSection(
                data: data,
                query: query,
                resolveLinkName: { ref in
                    store.displayNameForRefTarget(
                        componentId: ref.componentId,
                        itemId: ref.itemId,
                        myAppId: myAppId
                    )
                },
                filtered: filtered,
                onAdd: { sheet = .add() },
                onEdit: { itemId in sheet = .edit(itemId: itemId) }
            )
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

    /// Lookup an edited row's current `linkedItems` so the editor sheet
    /// loads in sync with the canvas. `.add` always starts empty.
    private func initialLinkedItems(for target: SheetTarget) -> [ComponentItemRef] {
        switch target {
        case .add: return []
        case .edit(let itemId):
            return data.items.first(where: { $0.id == itemId })?.linkedItems ?? []
        }
    }

    private var hasAnyFilters: Bool {
        data.visibleFields.contains { $0.type == .select && !($0.options ?? []).isEmpty }
    }

    private var query: String { queryByComponent[componentId ?? ""] ?? "" }

    private func setQuery(_ new: String) {
        guard new != query else { return }
        queryByComponent[componentId ?? ""] = new
    }

    private var filtered: [TrackerFiltering.Entry] {
        TrackerFiltering.visibleEntries(
            items: data.items,
            fields: data.visibleFields,
            filter: data.filter,
            query: query
        )
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

// MARK: - Cards section

private struct CardsSection: View {
    let data: TrackerData
    let query: String
    /// Resolver passed to each `TrackerItemCard` so it can render
    /// chain-link pills for its `linkedItems`. Closes over the store +
    /// myAppId from `TrackerView`.
    let resolveLinkName: (ComponentItemRef) -> String?
    let filtered: [TrackerFiltering.Entry]
    let onAdd: () -> Void
    let onEdit: (UUID) -> Void

    /// Shrunk cards are one line tall, so they want narrower columns —
    /// otherwise a shrunk board wastes most of its width on padding.
    private func gridColumns(_ density: CardDensity) -> [GridItem] {
        [GridItem(.adaptive(minimum: density == .minimal ? 180 : 220), spacing: 12, alignment: .top)]
    }

    private var emptyMessage: String {
        if data.items.isEmpty {
            return "No items yet — tap Add to create one, or type in the chat."
        }
        return query.isEmpty
            ? "No items match the current filter."
            : "No items match “\(query)”."
    }

    var body: some View {
        SectionCard {
            HStack {
                Text("Items").font(.headline)
                Spacer()
                Text("\(filtered.count) of \(data.items.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button(action: onAdd) {
                    Label("Add", systemImage: "plus")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }

            if filtered.isEmpty {
                Text(emptyMessage)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                let layout = CardLayout.from(fields: data.visibleFields)
                let density = CardDensity.resolve(viewMode: .grid, shrink: data.shrinkCards)
                LazyVGrid(columns: gridColumns(density), alignment: .leading, spacing: 12) {
                    ForEach(filtered) { entry in
                        TrackerItemCard(
                            item: entry.item,
                            layout: layout,
                            positionIndex: entry.positionIndex,
                            density: density,
                            onTap: { onEdit(entry.item.id) },
                            resolveLinkName: density == .minimal ? nil : resolveLinkName
                        )
                    }
                }
            }
        }
    }
}
