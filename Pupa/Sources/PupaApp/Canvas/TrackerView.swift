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

    public init(store: MyAppStore, data: TrackerData, myAppId: UUID, componentId: String? = nil) {
        self.store = store
        self.data = data
        self.myAppId = myAppId
        self.componentId = componentId
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            CanvasTitleBar(store: store, data: data)

            if hasAnyFilters {
                FiltersBar(store: store, fields: data.visibleFields, filter: data.filter)
            }

            CardsSection(
                data: data,
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

    private var filtered: [(item: TrackerItem, positionIndex: Int)] {
        data.items.enumerated()
            .map { (item: $1, positionIndex: $0) }
            .filter { entry in
                for (field, val) in data.filter where !val.isEmpty {
                    if (entry.item.values[field] ?? "").lowercased() != val.lowercased() {
                        return false
                    }
                }
                return true
            }
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

// MARK: - Filters

private struct FiltersBar: View {
    @Bindable var store: MyAppStore
    let fields: [FieldDef]
    let filter: [String: String]

    var body: some View {
        SectionCard {
            HStack(alignment: .top) {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .foregroundStyle(.secondary)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(filterableFields) { field in
                            FilterChip(
                                field: field,
                                value: filter[field.name] ?? "",
                                onSelect: { value in
                                    store.setFilter(field: field.name, value: value)
                                }
                            )
                        }
                    }
                }
            }
        }
    }

    private var filterableFields: [FieldDef] {
        fields.filter { $0.type == .select && !($0.options ?? []).isEmpty }
    }
}

private struct FilterChip: View {
    let field: FieldDef
    let value: String
    let onSelect: (String) -> Void

    var body: some View {
        Menu {
            Button("All") { onSelect("") }
            ForEach(field.options ?? [], id: \.self) { opt in
                Button(opt) { onSelect(opt) }
            }
        } label: {
            HStack(spacing: 6) {
                Text(field.label ?? field.name)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value.isEmpty ? "All" : value)
                    .font(.caption.weight(.semibold))
                Image(systemName: "chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(value.isEmpty ? Color.gray.opacity(0.12) : Color.accentColor.opacity(0.18))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Cards section

private struct CardsSection: View {
    let data: TrackerData
    /// Resolver passed to each `TrackerItemCard` so it can render
    /// chain-link pills for its `linkedItems`. Closes over the store +
    /// myAppId from `TrackerView`.
    let resolveLinkName: (ComponentItemRef) -> String?
    let filtered: [(item: TrackerItem, positionIndex: Int)]
    let onAdd: () -> Void
    let onEdit: (UUID) -> Void

    private let columns: [GridItem] = [
        GridItem(.adaptive(minimum: 220), spacing: 12, alignment: .top)
    ]

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
                Text(data.items.isEmpty
                     ? "No items yet — tap Add to create one, or type in the chat."
                     : "No items match the current filter.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                let layout = CardLayout.from(fields: data.visibleFields)
                LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                    ForEach(filtered, id: \.item.id) { entry in
                        TrackerItemCard(
                            item: entry.item,
                            layout: layout,
                            positionIndex: entry.positionIndex,
                            onTap: { onEdit(entry.item.id) },
                            resolveLinkName: resolveLinkName
                        )
                    }
                }
            }
        }
    }
}
