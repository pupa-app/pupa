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
    /// Debounced search text, keyed by board. `CanvasView` builds component
    /// views without `.id(component.id)`, so `@State` is keyed by structural
    /// position — a bare `String` here would leak one tracker's query onto the
    /// next. The key must be the board, not the component id: ids repeat
    /// across MyApps (`MyAppStore.addComponent`).
    @State private var queryByComponentKey: [CanvasComponentKey: String] = [:]
    /// Filter-panel disclosure, collapsed by default. Board-keyed for the
    /// same reason as the query.
    @State private var filtersShownByComponentKey: [CanvasComponentKey: Bool] = [:]
    /// Cards peeked open despite `data.shrinkCards`. Ephemeral on purpose: a
    /// peek is chrome, and `persist()` is a whole-app encode + iCloud write —
    /// the same reason the search query above is not persisted. Keyed by board
    /// like the rest — see `CanvasComponentKey`.
    @State private var peeks = TrackerPeekState()

    public init(store: MyAppStore, data: TrackerData, myAppId: UUID, componentId: String? = nil) {
        self.store = store
        self.data = data
        self.myAppId = myAppId
        self.componentId = componentId
    }

    /// Identity every piece of this view's per-component `@State` keys on.
    /// See `CanvasComponentKey` — never key on `componentId` alone.
    private var componentKey: CanvasComponentKey {
        CanvasComponentKey(myAppId: myAppId, componentId: componentId)
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

            if !data.items.isEmpty {
                TrackerSearchField(initialText: query, onQueryChange: setQuery)
                    .id(componentKey)
            }

            if hasAnyFilters, filtersShown {
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
                expandedIds: expandedIds,
                onToggleExpand: toggleExpanded,
                onAdd: { sheet = .add() },
                onEdit: { itemId in sheet = .edit(itemId: itemId) }
            )
        }
        // The global shrink button overwrites this board's peeks. Keyed off the
        // state rather than the button so a `shrinkCards` change from any source
        // clears them — the button, an agent's `setTrackerCardsShrunk`, or a
        // History restore. The key carries the whole board because this `@State`
        // outlives the component: without it, the canvas swapping in another
        // tracker whose flag differs reads as a button press and closes cards
        // nobody touched. A flag flipped while the user is on a different board
        // is not cleared here; that board reads its own bucket when it returns.
        .onChange(of: TrackerShrinkKey(component: componentKey, shrink: data.shrinkCards)) { old, new in
            guard TrackerShrinkKey.isShrinkToggle(from: old, to: new) else { return }
            peeks.clear(for: componentKey)
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

    private var filtersShown: Bool { filtersShownByComponentKey[componentKey] ?? false }

    private var filtersShownBinding: Binding<Bool> {
        Binding(
            get: { filtersShown },
            set: { filtersShownByComponentKey[componentKey] = $0 }
        )
    }

    private var activeFilterCount: Int {
        data.filter.reduce(into: 0) { n, entry in if !entry.value.isEmpty { n += 1 } }
    }

    private var query: String { queryByComponentKey[componentKey] ?? "" }

    private var expandedIds: Set<UUID> { peeks.ids(for: componentKey) }

    private func toggleExpanded(_ itemId: UUID) { peeks.toggle(itemId, for: componentKey) }

    private func setQuery(_ new: String) {
        guard new != query else { return }
        queryByComponentKey[componentKey] = new
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
    /// Cards peeked open on a shrunk board. Non-empty only while this board is
    /// shrunk, or until the next same-board flag flip clears it — a flag moved
    /// while the user is elsewhere leaves the bucket standing.
    let expandedIds: Set<UUID>
    let onToggleExpand: (UUID) -> Void
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
                // Column width follows the board, never a single peek: one tap
                // must not reflow every other card.
                let boardDensity = CardDensity.resolve(viewMode: .grid, shrink: data.shrinkCards)
                LazyVGrid(columns: gridColumns(boardDensity), alignment: .leading, spacing: 12) {
                    ForEach(filtered) { entry in
                        TrackerItemCard(
                            item: entry.item,
                            layout: layout,
                            positionIndex: entry.positionIndex,
                            density: CardDensity.resolve(
                                viewMode: .grid,
                                shrink: data.shrinkCards,
                                expanded: expandedIds.contains(entry.item.id)
                            ),
                            onTap: { onEdit(entry.item.id) },
                            // Passed unconditionally now: `.minimal` renders
                            // `minimalCard`, which has neither the pills row
                            // nor the linked-refs row, so the resolver is
                            // inert there and needs no gate of its own.
                            resolveLinkName: resolveLinkName,
                            expansion: data.shrinkCards
                                ? (isExpanded: expandedIds.contains(entry.item.id),
                                   toggle: { onToggleExpand(entry.item.id) })
                                : nil
                        )
                    }
                }
            }
        }
    }
}
