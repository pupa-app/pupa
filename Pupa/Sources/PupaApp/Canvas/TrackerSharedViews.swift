import SwiftUI

// Shared chrome and item-rendering primitives used by both `TrackerView`
// (grid mode) and `KanbanView` (kanban mode). Both views render the same
// `TrackerData` — only the layout around items differs — so the card body,
// add/edit sheet, and section card live here to avoid drift.

// MARK: - Canvas title bar

/// Title + view-mode toggle. The toggle flips `TrackerData.viewMode` between
/// `.grid` and `.kanban` via `MyAppStore.setTrackerViewMode`. Disabled in
/// grid mode when no select field has options — kanban needs a column field
/// to group by.
struct CanvasTitleBar: View {
    @Bindable var store: MyAppStore
    let data: TrackerData

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(data.title).font(.title).bold()
            Spacer()
            toggleButton
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
            _ = store.setTrackerViewMode(.kanban)
        }
    }

    private func switchToGrid() {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            _ = store.setTrackerViewMode(.grid)
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
            _ = store.addItem(trimmed, myAppId: myAppId)
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

    @ViewBuilder
    private func sheetField(for field: FieldDef) -> some View {
        let binding = Binding<String>(
            get: { draft[field.name] ?? "" },
            set: { draft[field.name] = $0 }
        )
        switch field.type {
        case .select:
            if let options = field.options {
                Picker(field.label ?? field.name, selection: binding) {
                    Text("—").tag("")
                    ForEach(options, id: \.self) { Text($0).tag($0) }
                }
            }
        case .number:
            TextField(field.label ?? field.name, text: binding)
                #if os(iOS)
                .keyboardType(.decimalPad)
                #endif
        case .text:
            HStack(alignment: .top, spacing: 6) {
                TextField(field.label ?? field.name, text: binding, axis: .vertical)
                    .lineLimit(1...)
                NavigationLink {
                    TextDetailEditor(title: field.label ?? field.name, text: binding)
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Open larger editor")
            }
        case .image:
            TextField(field.label ?? field.name, text: binding, prompt: Text("URL or emoji"))
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
                #endif
        case .link:
            TextField(field.label ?? field.name, text: binding, prompt: Text("https://…"))
                #if os(iOS)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
                #endif
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

// MARK: - Card layout

struct CardLayout {
    let imageField: FieldDef?       // first .image field (optional hero)
    let titleField: FieldDef?
    let metaFields: [FieldDef]      // up to 2
    let chipFields: [FieldDef]      // all select fields, capped per-card at 3
    let linkFields: [FieldDef]      // all .link fields, capped per-card at 2

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
            linkFields: Array(links.prefix(2))
        )
    }
}

// MARK: - Expandable caption

/// Caption-styled text that truncates to `lineLimit` lines and surfaces a
/// "Show more" / "Show less" toggle when the value would actually overflow
/// at the current width. Used on `TrackerItemCard` so long `.text` values
/// no longer collapse to a single ellipsis. Truncation is detected by
/// rendering an unconstrained-height copy of the same string into a hidden
/// background and comparing its measured height against the visible
/// (line-limited) one — both are remeasured via `.onChange` so the toggle
/// stays correct across width changes / dynamic-type updates.
private struct ExpandableText: View {
    let text: String
    let lineLimit: Int

    @State private var isExpanded: Bool = false
    @State private var fullHeight: CGFloat = 0
    @State private var truncatedHeight: CGFloat = 0

    private var canExpand: Bool { fullHeight > truncatedHeight + 0.5 }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(isExpanded ? nil : lineLimit)
                .fixedSize(horizontal: false, vertical: true)
                .background(
                    GeometryReader { geo in
                        Color.clear
                            .onAppear { truncatedHeight = geo.size.height }
                            .onChange(of: geo.size.height) { _, h in truncatedHeight = h }
                    }
                )
                .background(
                    Text(text)
                        .font(.caption)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                        .hidden()
                        .background(
                            GeometryReader { geo in
                                Color.clear
                                    .onAppear { fullHeight = geo.size.height }
                                    .onChange(of: geo.size.height) { _, h in fullHeight = h }
                            }
                        )
                )

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

/// Renders one tracker row. Used in both the grid (full layout, hero image)
/// and kanban (compact layout, no hero, single chip) views. The card reads
/// values from the item's sparse `values` dict — missing keys for a given
/// field render as empty, which keeps the card valid through any schema
/// mutation (add field, hide field, …).
struct TrackerItemCard: View {
    let item: TrackerItem
    let layout: CardLayout
    let positionIndex: Int
    let compact: Bool
    let onTap: () -> Void
    /// Optional resolver invoked once per ref in `item.linkedItems` to
    /// produce the chain-link pill text. Caller is typically `TrackerView`
    /// closing over the store + myAppId. Nil → linked-items row hidden
    /// (kanban-compact mode passes nil to keep lane cards tight).
    let resolveLinkName: ((ComponentItemRef) -> String?)?

    init(
        item: TrackerItem,
        layout: CardLayout,
        positionIndex: Int,
        compact: Bool = false,
        onTap: @escaping () -> Void,
        resolveLinkName: ((ComponentItemRef) -> String?)? = nil
    ) {
        self.item = item
        self.layout = layout
        self.positionIndex = positionIndex
        self.compact = compact
        self.onTap = onTap
        self.resolveLinkName = resolveLinkName
    }

    private var values: [String: String] { item.values }

    private static let heroHeight: CGFloat = 120

    var body: some View {
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
                        ExpandableText(text: entry.value, lineLimit: compact ? 2 : 3)
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

                if !linkEntries.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(linkEntries, id: \.field) { entry in
                            LinkPill(field: entry.field, value: entry.value, url: entry.url)
                        }
                    }
                }

                if let resolveLinkName, !item.linkedItems.isEmpty {
                    linkedRefsRow(resolveLinkName)
                }
            }
            .padding(compact ? 10 : 14)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: compact ? 10 : 12))
        .overlay(
            RoundedRectangle(cornerRadius: compact ? 10 : 12)
                .stroke(Color.cardBorder, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
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

    private var chipCap: Int { compact ? 1 : 3 }

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

    private var linkEntries: [LinkEntry] {
        let cap = compact ? 1 : 2
        return layout.linkFields.compactMap { f -> LinkEntry? in
            let v = (values[f.name] ?? "").trimmingCharacters(in: .whitespaces)
            guard !v.isEmpty else { return nil }
            return LinkEntry(field: f.name, value: v, url: parseURL(v))
        }
        .prefix(cap)
        .map { $0 }
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
        if let url = url, let host = url.host {
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
