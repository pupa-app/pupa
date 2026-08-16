import SwiftUI

// Shared chrome and item-rendering primitives used by both `TrackerView`
// (grid mode) and `KanbanView` (kanban mode). Both views render the same
// `TrackerData` — only the layout around items differs — so the card body,
// add/edit sheet, and section card live here to avoid drift.

// MARK: - Canvas title bar

/// Title + shrink toggle + view-mode toggle. The view-mode toggle flips
/// `TrackerData.viewMode` between `.grid` and `.kanban` via
/// `MyAppStore.setTrackerViewMode`. Disabled in grid mode when no select
/// field has options — kanban needs a column field to group by.
struct CanvasTitleBar: View {
    @Bindable var store: MyAppStore
    let data: TrackerData
    /// Component being rendered. Threaded into the view-mode toggle so the
    /// mutation lands on THIS tracker, not the first tracker in the myApp
    /// (the kind-routed fallback ignores which component is on screen).
    var componentId: String? = nil
    /// Disclosure state for the filter chips. Nil when the tracker has no
    /// filterable select field — the button then doesn't render at all.
    var filtersExpanded: Binding<Bool>? = nil
    /// Non-empty entries in `data.filter`. Surfaced as a badge so a filter
    /// set by the agent, or left behind from a previous session, is visible
    /// while the panel is collapsed.
    var activeFilterCount: Int = 0

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(data.title).font(.title).bold()
            Spacer()
            if let filtersExpanded {
                filterButton(filtersExpanded)
            }
            shrinkButton
            toggleButton
        }
    }

    private func filterButton(_ expanded: Binding<Bool>) -> some View {
        Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                expanded.wrappedValue.toggle()
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: activeFilterCount > 0
                      ? "line.3.horizontal.decrease.circle.fill"
                      : "line.3.horizontal.decrease.circle")
                if activeFilterCount > 0 {
                    Text("\(activeFilterCount)")
                }
            }
            .font(.caption.weight(.semibold))
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .tint(activeFilterCount > 0 ? Color.accentColor : nil)
        .help(expanded.wrappedValue ? "Hide filters" : "Show filters")
    }

    private var shrinkButton: some View {
        Button(action: toggleShrink) {
            Image(systemName: data.shrinkCards
                  ? "rectangle.expand.vertical"
                  : "rectangle.compress.vertical")
                .font(.caption.weight(.semibold))
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .help(data.shrinkCards ? "Show full cards" : "Shrink cards to one line")
    }

    private func toggleShrink() {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            _ = store.setTrackerCardsShrunk(!data.shrinkCards, componentId: componentId)
        }
    }

    @ViewBuilder
    private var toggleButton: some View {
        switch data.viewMode {
        case .grid:
            Button(action: switchToKanban) {
                Label("Kanban", systemImage: "rectangle.split.3x1")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!hasUsableSelectField)
            .help(hasUsableSelectField
                  ? "Show as kanban board"
                  : "Add a select field with options to use kanban view")
        case .kanban:
            Button(action: switchToGrid) {
                Label("Grid", systemImage: "square.grid.2x2")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Show as card grid")
        }
    }

    private var hasUsableSelectField: Bool {
        data.visibleFields.contains { $0.type == .select && !($0.options ?? []).isEmpty }
    }

    private func switchToKanban() {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            _ = store.setTrackerViewMode(.kanban, componentId: componentId)
        }
    }

    private func switchToGrid() {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            _ = store.setTrackerViewMode(.grid, componentId: componentId)
        }
    }
}

// MARK: - Section card chrome

struct SectionCard<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            content
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.cardBorder, lineWidth: 1)
        )
    }
}

// MARK: - Search

/// Free-text row search, shared by grid and kanban.
///
/// Owns the typed text itself and hands the parent only a debounced query.
/// That split is load-bearing, not tidiness: the parent re-runs
/// `TrackerFiltering` and rebuilds every card whenever its own state changes,
/// and the kanban lane stack is deliberately non-lazy, so a `@State` on the
/// parent would rebuild the whole board on every keystroke — the debounce
/// alone would not help. Here a keystroke invalidates this one `HStack`.
///
/// Never persisted: `MyAppStore.persist()` is a synchronous whole-app encode
/// plus disk write, so a stored query would mean one of those per character.
struct TrackerSearchField: View {
    let initialText: String
    var placeholder: String = "Search items"
    let onQueryChange: (String) -> Void

    @State private var text: String

    init(initialText: String, placeholder: String = "Search items", onQueryChange: @escaping (String) -> Void) {
        self.initialText = initialText
        self.placeholder = placeholder
        self.onQueryChange = onQueryChange
        _text = State(initialValue: initialText)
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.caption)
                .foregroundStyle(.secondary)
            field
            if !text.isEmpty {
                Button {
                    text = ""
                    // Clearing restores the whole board — never make that wait
                    // out the debounce.
                    onQueryChange("")
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Clear search")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.gray.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        // `.task(id:)` cancels the pending task on every new keystroke, so the
        // query only lands once typing pauses. No Task handle to leak.
        .task(id: text) {
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled else { return }
            onQueryChange(text)
        }
    }

    private var field: some View {
        let base = TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(.subheadline)
            .autocorrectionDisabled(true)
        #if os(iOS)
        return base
            .textInputAutocapitalization(.never)
            .submitLabel(.search)
        #else
        return base
        #endif
    }
}

// MARK: - Filters

/// Select-field filter chips. Shared by both views: kanban honours
/// `TrackerData.filter` too, so it needs the same way to see and clear one
/// that the agent (`setTrackerFilter`) or grid mode may have set.
///
/// Collapsed by default behind the title bar's filter button — chips are
/// occasional, and on a narrow board they cost a whole row of the canvas.
/// The button carries a count badge so a live filter is never invisible.
struct FiltersBar: View {
    @Bindable var store: MyAppStore
    let fields: [FieldDef]
    let filter: [String: String]
    var componentId: String? = nil

    var body: some View {
        SectionCard {
            HStack(alignment: .top) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(filterableFields) { field in
                            FilterChip(
                                field: field,
                                value: filter[field.name] ?? "",
                                onSelect: { value in
                                    store.setFilter(field: field.name, value: value, componentId: componentId)
                                }
                            )
                        }
                    }
                }
                if activeCount > 0 {
                    Button("Clear") {
                        for field in filterableFields where !(filter[field.name] ?? "").isEmpty {
                            store.setFilter(field: field.name, value: "", componentId: componentId)
                        }
                    }
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.borderless)
                }
            }
        }
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    private var activeCount: Int {
        filterableFields.reduce(into: 0) { n, f in
            if !(filter[f.name] ?? "").isEmpty { n += 1 }
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

// MARK: - Add / Edit sheet

/// Discriminator for the unified add/edit modal. Used by both grid and
/// kanban views. `add(prefilled:)` lets kanban lanes prefill the column
/// field (e.g. "status = doing") so a new item lands in the right lane.
/// `edit` carries the item's stable UUID — row identity must survive field
/// reorders / hide-shows / item removals that would shift array indices.
enum SheetTarget: Identifiable {
    case add(prefilled: [String: String] = [:])
    case edit(itemId: UUID)

    var id: String {
        switch self {
        case .add(let prefilled):
            if prefilled.isEmpty { return "add" }
            return "add-" + prefilled.sorted(by: { $0.key < $1.key })
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: ",")
        case .edit(let itemId): return "edit-\(itemId.uuidString)"
        }
    }
}

struct ItemSheet: View {
    let target: SheetTarget
    @Bindable var store: MyAppStore
    let fields: [FieldDef]
    let initialItem: [String: String]
    /// MyApp the tracker lives in. Used by the "Linked items" picker to
    /// resolve cross-component targets and by the save path to call
    /// store mutators with an explicit `myAppId:` (rather than relying
    /// on `activeMyAppId`, which would race in multi-myapp scenarios).
    let myAppId: UUID
    /// Tracker component id the edited row belongs to. Used by the
    /// picker's `excludeRef` to hide the row from itself and by the
    /// link-pill resolver to scope display names. Optional because
    /// `.add` doesn't know its target component until the row lands.
    let componentId: String?
    /// Initial linked-items list, applied on first render. Edits live
    /// in `linkedDraft` until Save persists them via
    /// `setTrackerItemLinkedItems`.
    let initialLinkedItems: [ComponentItemRef]
    let onClose: () -> Void

    @State private var draft: [String: String]
    @State private var linkedDraft: [ComponentItemRef]
    @State private var pickerPresented: Bool = false

    init(
        target: SheetTarget,
        store: MyAppStore,
        fields: [FieldDef],
        initialItem: [String: String],
        myAppId: UUID,
        componentId: String? = nil,
        initialLinkedItems: [ComponentItemRef] = [],
        onClose: @escaping () -> Void
    ) {
        self.target = target
        self.store = store
        self.fields = fields
        self.initialItem = initialItem
        self.myAppId = myAppId
        self.componentId = componentId
        self.initialLinkedItems = initialLinkedItems
        self.onClose = onClose
        self._draft = State(initialValue: initialItem)
        self._linkedDraft = State(initialValue: initialLinkedItems)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(fields) { field in
                        sheetField(for: field)
                    }
                }
                if case .edit(let itemId) = target {
                    linkedItemsSection(for: itemId)
                    Section {
                        Button(role: .destructive) {
                            _ = store.removeItem(id: itemId, myAppId: myAppId, componentId: componentId)
                            onClose()
                        } label: {
                            Label("Delete item", systemImage: "trash")
                        }
                    }
                }
            }
            .navigationTitle(navTitle)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onClose)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(confirmLabel, action: commit)
                        .disabled(!canConfirm)
                }
            }
            #if os(macOS)
            .frame(minWidth: 360, idealWidth: 420, minHeight: 360, idealHeight: 520)
            #endif
            .sheet(isPresented: $pickerPresented) {
                ComponentItemPickerSheet(
                    store: store,
                    myAppId: myAppId,
                    excludeRef: editingItemRef,
                    alreadyLinked: Set(linkedDraft),
                    onPick: { newRefs in
                        var seen = Set(linkedDraft)
                        for ref in newRefs where seen.insert(ref).inserted {
                            linkedDraft.append(ref)
                        }
                        pickerPresented = false
                    },
                    onClose: { pickerPresented = false }
                )
            }
        }
        .linkedItemPopupHost(store: store, myAppId: myAppId)
        #if os(iOS)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        #endif
    }

    @ViewBuilder
    private func linkedItemsSection(for itemId: UUID) -> some View {
        Section {
            if linkedDraft.isEmpty {
                Text("Nothing linked yet")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(linkedDraft, id: \.self) { ref in
                    linkedRefRow(ref)
                }
                .onDelete { offsets in
                    linkedDraft.remove(atOffsets: offsets)
                }
            }
            Button {
                pickerPresented = true
            } label: {
                Label("Add link…", systemImage: "plus")
            }
        } header: {
            Text("Linked items")
        } footer: {
            Text("Attach any tracker row, calendar event, or checklist row in this MyApp. Each pill shows the live name; edits in the target update it automatically.")
                .font(.caption)
        }
    }

    @ViewBuilder
    private func linkedRefRow(_ ref: ComponentItemRef) -> some View {
        let resolved = store.displayNameForRefTarget(
            componentId: ref.componentId,
            itemId: ref.itemId,
            myAppId: myAppId
        )
        let comp = store.componentName(ref.componentId, myAppId: myAppId) ?? ref.componentId
        LinkedRefEditorRow(
            ref: ref,
            resolvedName: resolved,
            componentName: comp,
            onRemove: { linkedDraft.removeAll { $0 == ref } }
        )
    }

    private var editingItemRef: ComponentItemRef? {
        guard let componentId, case .edit(let itemId) = target else { return nil }
        return ComponentItemRef(componentId: componentId, itemId: itemId)
    }

    private var navTitle: String {
        switch target {
        case .add: return "Add item"
        case .edit: return "Edit item"
        }
    }

    private var confirmLabel: String {
        switch target {
        case .add: return "Add"
        case .edit: return "Save"
        }
    }

    private var canConfirm: Bool {
        switch target {
        case .add:
            return draft.values.contains { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        case .edit:
            return draft != initialItem || linkedDraft != initialLinkedItems
        }
    }

    private func commit() {
        let trimmed = draft.mapValues { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        switch target {
        case .add:
            _ = store.addItem(trimmed, myAppId: myAppId, componentId: componentId)
        case .edit(let itemId):
            if draft != initialItem {
                _ = store.patchItem(id: itemId, with: trimmed, myAppId: myAppId, componentId: componentId)
            }
            if linkedDraft != initialLinkedItems {
                _ = store.setTrackerItemLinkedItems(id: itemId, refs: linkedDraft, myAppId: myAppId, componentId: componentId)
            }
        }
        onClose()
    }

    /// Each row reads as key → value: the field name is a persistent leading
    /// label (`LabeledContent` / a caption header) so the row stays legible
    /// once filled — a bare placeholder vanishes the moment a value lands.
    @ViewBuilder
    private func sheetField(for field: FieldDef) -> some View {
        let binding = Binding<String>(
            get: { draft[field.name] ?? "" },
            set: { draft[field.name] = $0 }
        )
        let key = field.label ?? field.name
        switch field.type {
        case .select:
            if let options = field.options {
                Picker(key, selection: binding) {
                    Text("—").tag("")
                    ForEach(options, id: \.self) { Text($0).tag($0) }
                }
            }
        case .number:
            LabeledContent(key) {
                TextField("", text: binding)
                    .multilineTextAlignment(.trailing)
                    #if os(iOS)
                    .keyboardType(.decimalPad)
                    #endif
            }
        case .text:
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(key)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    NavigationLink {
                        TextDetailEditor(title: key, text: binding)
                    } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help("Open larger editor")
                }
                TextField(key, text: binding, axis: .vertical)
                    .lineLimit(1...)
            }
        case .image:
            LabeledContent(key) {
                TextField("", text: binding, prompt: Text("URL or emoji"))
                    .multilineTextAlignment(.trailing)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    #endif
            }
        case .link:
            LabeledContent(key) {
                TextField("", text: binding, prompt: Text("https://…"))
                    .multilineTextAlignment(.trailing)
                    #if os(iOS)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    #endif
            }
        }
    }
}

/// Full-pane editor for a single `.text` field. Pushed inside the
/// `ItemSheet`'s `NavigationStack` so the binding writes straight through
/// to the sheet's `draft` and the regular Save button commits.
private struct TextDetailEditor: View {
    let title: String
    @Binding var text: String

    var body: some View {
        TextEditor(text: $text)
            .padding()
            .navigationTitle(title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
    }
}

// MARK: - Card density

/// How much of an item a card shows. Derived from the view mode and the
/// persisted `shrinkCards` flag — shrink collapses both modes onto one
/// rendering rather than doubling the layouts, since a one-liner is a
/// one-liner whether it sits in a lane or a grid cell.
enum CardDensity {
    case comfortable   // grid: hero, meta rows, 3 chips, 3 links
    case compact       // kanban lane: no hero, tighter type, 1 chip, 2 links
    case minimal       // shrunk: title only, one line

    static func resolve(viewMode: TrackerViewMode, shrink: Bool) -> CardDensity {
        if shrink { return .minimal }
        return viewMode == .kanban ? .compact : .comfortable
    }
}

/// Per-density caps, split out so they are testable without building a view.
enum CardDensityMetrics {
    static func chipCap(_ density: CardDensity) -> Int {
        switch density {
        case .comfortable: 3
        case .compact: 1
        case .minimal: 0
        }
    }

    static func linkCap(_ density: CardDensity) -> Int {
        switch density {
        case .comfortable: 3
        case .compact: 2
        case .minimal: 0
        }
    }

    /// Link pills per row once the "+k more" chip has expanded them. A
    /// constant, never a measurement: pill widths are unknown until layout,
    /// and reading them back to decide the wrap would rebuild the
    /// measurement→state→size cycle `TextOverflowEstimate` exists to avoid.
    /// `LinkPill` already truncates, so a fixed chunk cannot overflow.
    static func linksPerRow(_ density: CardDensity) -> Int {
        density == .comfortable ? 2 : 1
    }
}

// MARK: - Card layout

struct CardLayout {
    let imageField: FieldDef?       // first .image field (optional hero)
    let titleField: FieldDef?
    let metaFields: [FieldDef]      // up to 2
    let chipFields: [FieldDef]      // all select fields, capped per-card at 3
    let linkFields: [FieldDef]      // all .link fields; the card caps per density

    /// Build a layout from a tracker's fields. `excluding` lets kanban hide
    /// the column field's value from each card (the lane header already
    /// shows it) so chips don't get redundant.
    static func from(fields: [FieldDef], excluding excluded: String? = nil) -> CardLayout {
        var image: FieldDef?
        var title: FieldDef?
        var meta: [FieldDef] = []
        var chips: [FieldDef] = []
        var links: [FieldDef] = []

        for field in fields where field.name != excluded {
            switch field.type {
            case .image:
                if image == nil { image = field }
            case .select:
                chips.append(field)
            case .link:
                links.append(field)
            case .text, .number:
                if title == nil { title = field } else { meta.append(field) }
            }
        }

        if title == nil {
            title = fields.first(where: {
                $0.type != .image && $0.type != .link && $0.name != excluded
            }) ?? fields.first
        }

        return CardLayout(
            imageField: image,
            titleField: title,
            metaFields: Array(meta.prefix(2)),
            chipFields: chips,
            linkFields: links
        )
    }
}

// MARK: - Expandable caption

/// Predicts whether a string needs more than `lineLimit` lines, from the
/// string alone.
///
/// Deliberately never measures geometry. `ExpandableText` used to compare a
/// hidden unconstrained copy of the text against the line-limited one through
/// two `GeometryReader`s and write both heights into `@State`. Inside a
/// `LazyVStack` that never terminates: the measurement decides whether the
/// "Show more" button exists, the button changes the height being measured,
/// the changed height re-places the lazy stack, and placement re-fires the
/// measurement's `onAppear`. That is the pupa#120 hang — main thread pinned at
/// 100%, force-quit to recover.
enum TextOverflowEstimate {
    /// Characters that fit on one `.caption` line in a 260pt kanban lane.
    static let laneCharsPerLine = 34
    /// Same, for the wider grid card.
    static let gridCharsPerLine = 52

    /// Deliberately eager: offering the toggle on a string that happens to fit
    /// costs one tap that changes nothing, while withholding it brings back
    /// the bare ellipsis this view exists to avoid.
    static func mayOverflow(_ text: String, lineLimit: Int, charsPerLine: Int) -> Bool {
        guard lineLimit > 0 else { return false }
        let hardLines = text.split(separator: "\n", omittingEmptySubsequences: false)
        if hardLines.count > lineLimit { return true }
        return text.count > lineLimit * charsPerLine
    }
}

/// Caption-styled text that truncates to `lineLimit` lines and surfaces a
/// "Show more" / "Show less" toggle when the value is long enough to need one.
/// Used on `TrackerItemCard` so long `.text` values no longer collapse to a
/// single ellipsis. See `TextOverflowEstimate` for why the toggle is predicted
/// rather than measured.
private struct ExpandableText: View {
    let text: String
    let lineLimit: Int
    let charsPerLine: Int

    @State private var isExpanded: Bool = false

    private var canExpand: Bool {
        TextOverflowEstimate.mayOverflow(text, lineLimit: lineLimit, charsPerLine: charsPerLine)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(isExpanded ? nil : lineLimit)
                .fixedSize(horizontal: false, vertical: true)

            if canExpand {
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) { isExpanded.toggle() }
                } label: {
                    Text(isExpanded ? "Show less" : "Show more")
                        .font(.caption2.weight(.semibold))
                }
                .buttonStyle(.borderless)
            }
        }
    }
}

// MARK: - Item card

/// Renders one tracker row. Used by both views at three densities — grid
/// (`.comfortable`: hero image, meta rows), kanban lane (`.compact`), and
/// shrunk (`.minimal`: a one-line title, for scanning a whole board). The
/// card reads values from the item's sparse `values` dict — missing keys for
/// a given field render as empty, which keeps the card valid through any
/// schema mutation (add field, hide field, …).
struct TrackerItemCard: View {
    let item: TrackerItem
    let layout: CardLayout
    let positionIndex: Int
    let density: CardDensity
    let onTap: () -> Void
    /// Optional resolver invoked once per ref in `item.linkedItems` to
    /// produce the chain-link pill text. Caller is typically `TrackerView`
    /// closing over the store + myAppId. Nil → linked-items row hidden
    /// (kanban passes nil to keep lane cards tight).
    let resolveLinkName: ((ComponentItemRef) -> String?)?

    /// Set by the "+k more" chip. Written only by a tap — nothing here reads
    /// geometry, so growing the card cannot feed back into a measurement.
    @State private var linksExpanded = false

    init(
        item: TrackerItem,
        layout: CardLayout,
        positionIndex: Int,
        density: CardDensity = .comfortable,
        onTap: @escaping () -> Void,
        resolveLinkName: ((ComponentItemRef) -> String?)? = nil
    ) {
        self.item = item
        self.layout = layout
        self.positionIndex = positionIndex
        self.density = density
        self.onTap = onTap
        self.resolveLinkName = resolveLinkName
    }

    private var values: [String: String] { item.values }

    private static let heroHeight: CGFloat = 120

    private var compact: Bool { density == .compact }

    var body: some View {
        Group {
            if density == .minimal { minimalCard } else { fullCard }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius)
                .stroke(Color.cardBorder, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
    }

    private var cornerRadius: CGFloat {
        switch density {
        case .comfortable: 12
        case .compact: 10
        case .minimal: 8
        }
    }

    /// One line, nothing else. Skips `ExpandableText` (and its per-card state
    /// and overflow estimate), the hero `AsyncImage`, meta rows, chips and
    /// pills — which is also why a shrunk board is far cheaper to rebuild.
    private var minimalCard: some View {
        HStack(spacing: 6) {
            if let tint = minimalTint {
                Circle().fill(tint).frame(width: 6, height: 6)
            }
            Text(titleText)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(titleIsFallback ? .secondary : .primary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    /// Keeps the first chip's colour semantics visible even with no chips
    /// rendered, so lanes stay scannable when shrunk.
    private var minimalTint: Color? {
        guard let first = allItemChips.first?.1 else { return nil }
        let hue = Double(abs(first.hashValue) % 360) / 360.0
        return Color(hue: hue, saturation: 0.55, brightness: 0.65)
    }

    private var fullCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !compact, layout.imageField != nil {
                hero
            }

            VStack(alignment: .leading, spacing: compact ? 6 : 8) {
                Text(titleText)
                    .font(compact ? .subheadline.weight(.semibold) : .headline)
                    .lineLimit(compact ? 2 : 1)
                    .foregroundStyle(titleIsFallback ? .secondary : .primary)

                ForEach(metaEntries, id: \.field) { entry in
                    if entry.isText {
                        ExpandableText(
                            text: entry.value,
                            lineLimit: compact ? 2 : 3,
                            charsPerLine: compact
                                ? TextOverflowEstimate.laneCharsPerLine
                                : TextOverflowEstimate.gridCharsPerLine
                        )
                    } else {
                        Text(entry.value)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                if !visibleChips.isEmpty || chipOverflow > 0 {
                    HStack(spacing: 6) {
                        ForEach(visibleChips, id: \.0) { chip in
                            Text(chip.1)
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Color.accentColor.opacity(0.18))
                                .clipShape(Capsule())
                        }
                        if chipOverflow > 0 {
                            Text("+\(chipOverflow)")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Color.gray.opacity(0.12))
                                .clipShape(Capsule())
                        }
                    }
                }

                if !visibleLinkEntries.isEmpty {
                    linksRow
                }

                if let resolveLinkName, !item.linkedItems.isEmpty {
                    linkedRefsRow(resolveLinkName)
                }
            }
            .padding(compact ? 10 : 14)
        }
    }

    /// Collapsed: one row of pills plus a "+k" chip. Expanded: fixed-width
    /// chunks so a link-heavy item stays inside a 260pt lane.
    @ViewBuilder
    private var linksRow: some View {
        let rows = chunkedLinks
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(rows.enumerated()), id: \.offset) { row in
                HStack(spacing: 6) {
                    ForEach(row.element, id: \.field) { entry in
                        LinkPill(field: entry.field, value: entry.value, url: entry.url)
                    }
                    if row.offset == rows.count - 1, linkOverflow > 0 || linksExpanded {
                        linkOverflowChip
                    }
                }
            }
        }
    }

    private var linkOverflowChip: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.18)) { linksExpanded.toggle() }
        } label: {
            Text(linksExpanded ? "Show less" : "+\(linkOverflow)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.gray.opacity(0.12))
                .clipShape(Capsule())
        }
        .buttonStyle(.borderless)
    }

    private var chunkedLinks: [[LinkEntry]] {
        let entries = visibleLinkEntries
        let perRow = CardDensityMetrics.linksPerRow(density)
        guard linksExpanded, perRow > 0 else { return [entries] }
        return stride(from: 0, to: entries.count, by: perRow).map {
            Array(entries[$0..<min($0 + perRow, entries.count)])
        }
    }

    @ViewBuilder
    private var hero: some View {
        let value = heroValue
        if let url = heroURL(value) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill()
                case .failure:
                    initialBadge
                case .empty:
                    ZStack { Color.gray.opacity(0.08); ProgressView() }
                @unknown default:
                    initialBadge
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: Self.heroHeight)
            .clipped()
        } else if !value.isEmpty {
            ZStack {
                heroBackdropTint
                Text(value)
                    .font(.system(size: 56))
                    .lineLimit(1)
                    .minimumScaleFactor(0.4)
                    .padding(.horizontal, 8)
            }
            .frame(maxWidth: .infinity)
            .frame(height: Self.heroHeight)
        } else {
            initialBadge
                .frame(maxWidth: .infinity)
                .frame(height: Self.heroHeight)
        }
    }

    private var heroValue: String {
        guard let f = layout.imageField else { return "" }
        return (values[f.name] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func heroURL(_ value: String) -> URL? {
        let lower = value.lowercased()
        guard lower.hasPrefix("http://") || lower.hasPrefix("https://") else { return nil }
        return URL(string: value)
    }

    private var initialBadge: some View {
        let initial = String(titleText.prefix(1)).uppercased()
        return ZStack {
            heroBackdropTint
            Text(initial)
                .font(.system(size: 44, weight: .bold))
                .foregroundStyle(.white.opacity(0.9))
        }
    }

    private var heroBackdropTint: Color {
        let seed = abs(titleText.hashValue)
        let hue = Double(seed % 360) / 360.0
        return Color(hue: hue, saturation: 0.45, brightness: 0.65)
    }

    private var titleText: String {
        if let f = layout.titleField, let v = values[f.name], !v.trimmingCharacters(in: .whitespaces).isEmpty {
            return v
        }
        return "Untitled #\(positionIndex + 1)"
    }

    private var titleIsFallback: Bool {
        guard let f = layout.titleField, let v = values[f.name] else { return true }
        return v.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private struct MetaEntry: Hashable {
        let field: String
        let value: String
        let isText: Bool
    }

    /// One row per visible meta field. `.text` rows expand inline via
    /// `ExpandableText`; `.number` rows render as a single secondary line.
    /// Empty values are dropped so a sparse `values` dict produces a tidy
    /// card.
    private var metaEntries: [MetaEntry] {
        layout.metaFields.compactMap { f -> MetaEntry? in
            let v = (values[f.name] ?? "").trimmingCharacters(in: .whitespaces)
            guard !v.isEmpty else { return nil }
            return MetaEntry(field: f.name, value: v, isText: f.type == .text)
        }
    }

    private var allItemChips: [(String, String)] {
        layout.chipFields.compactMap { f in
            let v = (values[f.name] ?? "").trimmingCharacters(in: .whitespaces)
            return v.isEmpty ? nil : (f.name, v)
        }
    }

    private var chipCap: Int { CardDensityMetrics.chipCap(density) }

    private var visibleChips: [(String, String)] {
        Array(allItemChips.prefix(chipCap))
    }

    private var chipOverflow: Int {
        max(0, allItemChips.count - chipCap)
    }

    private struct LinkEntry {
        let field: String
        let value: String
        let url: URL?
    }

    /// Every non-empty `.link` field. `CardLayout` no longer truncates —
    /// how many fit is a per-density presentation call, made here.
    private var allLinkEntries: [LinkEntry] {
        layout.linkFields.compactMap { f -> LinkEntry? in
            let v = (values[f.name] ?? "").trimmingCharacters(in: .whitespaces)
            guard !v.isEmpty else { return nil }
            return LinkEntry(field: f.name, value: v, url: parseURL(v))
        }
    }

    private var visibleLinkEntries: [LinkEntry] {
        let all = allLinkEntries
        guard !linksExpanded else { return all }
        return Array(all.prefix(CardDensityMetrics.linkCap(density)))
    }

    private var linkOverflow: Int {
        guard !linksExpanded else { return 0 }
        return max(0, allLinkEntries.count - CardDensityMetrics.linkCap(density))
    }

    private func parseURL(_ value: String) -> URL? {
        // Accept bare https://… / http://… as-is; prepend https:// for
        // domain-only inputs (e.g. "github.com/foo") so the agent can write
        // shorthand URLs and have them open cleanly.
        if let url = URL(string: value), url.scheme != nil { return url }
        if value.contains(".") && !value.contains(" ") {
            return URL(string: "https://\(value)")
        }
        return nil
    }

    /// Inline pills row for `item.linkedItems` — chain-link icon + live
    /// target display name. Capped at 3 visible (with a "+N" overflow
    /// chip) to match the chip + link-field caps already used elsewhere
    /// on the card, since long lists on a card grid get unreadable fast.
    /// `resolve` is fully resolved into an array of (ref, name) pairs
    /// up-front so the SwiftUI `ForEach` closure doesn't have to capture
    /// a non-escaping parameter.
    @ViewBuilder
    private func linkedRefsRow(_ resolve: (ComponentItemRef) -> String?) -> some View {
        let visible: [(ref: ComponentItemRef, resolved: String?)] = item.linkedItems
            .prefix(3)
            .map { ref in (ref, resolve(ref)) }
        let overflow = max(0, item.linkedItems.count - 3)
        HStack(spacing: 6) {
            ForEach(visible, id: \.ref) { entry in
                LinkedRefPill(ref: entry.ref, resolvedName: entry.resolved)
            }
            if overflow > 0 {
                Text("+\(overflow)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.gray.opacity(0.12))
                    .clipShape(Capsule())
            }
        }
    }
}

// MARK: - Link pill

/// Clickable URL pill rendered on cards for `.link` fields. Tap opens the
/// URL in the default browser via SwiftUI's `Link`. Falls back to a
/// non-clickable, secondary-styled pill when the value doesn't parse as a
/// URL — keeps malformed input visible without breaking the layout.
private struct LinkPill: View {
    let field: String
    let value: String
    let url: URL?

    private var displayText: String {
        guard let url = url else { return value }
        // In-app `pupa://` links label by note / component name — their host
        // is the link *kind* ("memory"), so hosts alone read identically.
        if let label = ChatLink.displayLabel(for: url) { return label }
        if let host = url.host {
            return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        }
        return value
    }

    var body: some View {
        if let url = url {
            Link(destination: url) {
                pill(text: displayText, enabled: true)
            }
            .buttonStyle(.plain)
        } else {
            pill(text: displayText, enabled: false)
        }
    }

    private func pill(text: String, enabled: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "link")
                .font(.caption2)
            Text(text)
                .font(.caption.weight(.medium))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .foregroundStyle(enabled ? Color.accentColor : Color.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(enabled ? Color.accentColor.opacity(0.10) : Color.gray.opacity(0.10))
        .clipShape(Capsule())
        // `.onTapGesture` propagates to the card's tap-to-edit handler when
        // wrapped by `Link`'s buttonStyle(.plain) — adding contentShape
        // here would steal the gesture. Default Link hit-testing is fine.
    }
}
