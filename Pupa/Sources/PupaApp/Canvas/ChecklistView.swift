import SwiftUI

/// Checklist component view. A bullet list of `{id, text, done,
/// linkedItems}` rows the user can tick off, edit inline, link to other
/// components' items, or delete. All mutations route through `MyAppStore`
/// so the agent and the UI see the same source of truth. Linked refs
/// render as inline pills under each row and resolve live via
/// `MyAppStore.displayNameForRefTarget` — edits to the target component
/// propagate without re-render plumbing.
public struct ChecklistView: View {
    @Bindable var store: MyAppStore
    let data: ChecklistData
    let myAppId: UUID
    /// Component being rendered. Threaded into every mutation (add / toggle
    /// / remove / edit) so writes land on THIS checklist, not the first
    /// checklist in the myApp (the kind-routed fallback ignores which
    /// component is on screen).
    let componentId: String?

    @State private var draft: String = ""
    @State private var editorTarget: ChecklistItem?

    public init(store: MyAppStore, data: ChecklistData, myAppId: UUID, componentId: String? = nil) {
        self.store = store
        self.data = data
        self.myAppId = myAppId
        self.componentId = componentId
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ChecklistTitleBar(data: data)

            if data.items.isEmpty {
                ChecklistEmptyHint()
            } else {
                VStack(spacing: 0) {
                    ForEach(data.items) { item in
                        ChecklistRow(
                            store: store,
                            myAppId: myAppId,
                            componentId: componentId,
                            item: item,
                            onEdit: { editorTarget = item }
                        )
                        if item.id != data.items.last?.id {
                            Divider()
                        }
                    }
                }
                .background(Color.gray.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }

            addRow
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .sheet(item: $editorTarget) { item in
            ChecklistItemEditorSheet(
                store: store,
                myAppId: myAppId,
                item: item,
                componentId: componentId,
                onClose: { editorTarget = nil }
            )
        }
    }

    private var addRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "plus.circle")
                .font(.body)
                .foregroundStyle(.secondary)
            TextField("Add item", text: $draft)
                .textFieldStyle(.plain)
                .onSubmit(commitDraft)
            Button("Add", action: commitDraft)
                .buttonStyle(.borderless)
                .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.gray.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func commitDraft() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        _ = store.addChecklistItem(text: trimmed, myAppId: myAppId, componentId: componentId)
        draft = ""
    }
}

// MARK: - Title bar

private struct ChecklistTitleBar: View {
    let data: ChecklistData

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "checklist")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text(data.title.isEmpty ? "Checklist" : data.title)
                .font(.title2)
                .fontWeight(.semibold)
            Spacer()
            Text(progressLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var progressLabel: String {
        let done = data.items.filter(\.done).count
        let total = data.items.count
        if total == 0 { return "No items" }
        return "\(done)/\(total) done"
    }
}

// MARK: - Row

private struct ChecklistRow: View {
    @Bindable var store: MyAppStore
    let myAppId: UUID
    var componentId: String? = nil
    let item: ChecklistItem
    let onEdit: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button {
                _ = store.setChecklistItemDone(id: item.id, done: !item.done, myAppId: myAppId, componentId: componentId)
            } label: {
                Image(systemName: item.done ? "checkmark.square.fill" : "square")
                    .font(.title3)
                    .foregroundStyle(item.done ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)
            .help(item.done ? "Mark as not done" : "Mark as done")

            VStack(alignment: .leading, spacing: 4) {
                Text(item.text.isEmpty ? "(empty item)" : item.text)
                    .font(.body)
                    .strikethrough(item.done)
                    .foregroundStyle(item.done ? .secondary : .primary)
                if !item.linkedItems.isEmpty {
                    LinkedRefsRow(refs: item.linkedItems, store: store, myAppId: myAppId)
                }
            }
            Spacer(minLength: 0)
            Button(action: onEdit) {
                Image(systemName: "pencil")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Edit item")
            Button(role: .destructive) {
                _ = store.removeChecklistItem(id: item.id, myAppId: myAppId, componentId: componentId)
            } label: {
                Image(systemName: "trash")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Delete item")
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .contentShape(Rectangle())
    }
}

/// Inline pills row — one pill per linked ref. Reuses the same look as
/// the calendar's linked-items row (chain-link icon + live display name).
/// Target display names resolve via `displayNameForRefTarget`, which
/// dispatches between tracker / calendar / checklist resolvers based on
/// the target component's kind.
private struct LinkedRefsRow: View {
    let refs: [ComponentItemRef]
    @Bindable var store: MyAppStore
    let myAppId: UUID

    var body: some View {
        ChecklistFlowLayout(spacing: 4) {
            ForEach(refs, id: \.self) { ref in
                pill(ref)
            }
        }
    }

    @ViewBuilder
    private func pill(_ ref: ComponentItemRef) -> some View {
        let resolved = store.displayNameForRefTarget(
            componentId: ref.componentId,
            itemId: ref.itemId,
            myAppId: myAppId
        )
        LinkedRefPill(ref: ref, resolvedName: resolved)
    }
}

/// Minimal flow layout — wraps children to the next row when they
/// overflow the available width. Lives next to `CalendarView`'s
/// `FlowLayout` for now; PR 2's reusable picker work hoists both into
/// one place.
private struct ChecklistFlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0
        var maxRowWidth: CGFloat = 0
        for sv in subviews {
            let size = sv.sizeThatFits(.unspecified)
            if rowWidth + size.width > maxWidth, rowWidth > 0 {
                totalHeight += rowHeight + spacing
                maxRowWidth = max(maxRowWidth, rowWidth - spacing)
                rowWidth = 0
                rowHeight = 0
            }
            rowWidth += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        totalHeight += rowHeight
        maxRowWidth = max(maxRowWidth, rowWidth - spacing)
        return CGSize(width: maxRowWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x: CGFloat = bounds.minX
        var y: CGFloat = bounds.minY
        var rowHeight: CGFloat = 0
        for sv in subviews {
            let size = sv.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            sv.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

// MARK: - Empty hint

private struct ChecklistEmptyHint: View {
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "checklist")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("No items yet")
                .font(.headline)
            Text("Type below to add one, or ask the chat: \"Make a packing list for a weekend trip\".")
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
}

// MARK: - Edit sheet

struct ChecklistItemEditorSheet: View {
    @Bindable var store: MyAppStore
    let myAppId: UUID
    let item: ChecklistItem
    /// Checklist component the edited item belongs to. Set by the linked-
    /// item popup dispatcher so mutations target the right component even
    /// when it's not the active one; nil from in-place edits in the owning
    /// ChecklistView.
    var componentId: String? = nil
    let onClose: () -> Void

    @State private var text: String = ""
    @State private var done: Bool = false
    @State private var linkedItems: [ComponentItemRef] = []
    @State private var pickerPresented: Bool = false

    /// Source ref of the row being edited. Passed into the picker so it
    /// hides this row from the "Link items" list — a row cannot link
    /// to itself.
    private var editingItemRef: ComponentItemRef? {
        if let componentId {
            return ComponentItemRef(componentId: componentId, itemId: item.id)
        }
        guard let comp = store.myApps.first(where: { $0.id == myAppId })?
            .components.first(where: {
                if case .checklist = $0.body { return true }
                return false
            })?.id else { return nil }
        return ComponentItemRef(componentId: comp, itemId: item.id)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Text") {
                    TextField("Item text", text: $text, axis: .vertical)
                        .lineLimit(2...6)
                }
                Section {
                    Toggle("Done", isOn: $done)
                }
                Section {
                    if linkedItems.isEmpty {
                        Text("Nothing linked yet")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(linkedItems, id: \.self) { ref in
                            linkedRefRow(ref)
                        }
                        .onDelete { offsets in
                            linkedItems.remove(atOffsets: offsets)
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
                    Text("Attach any tracker row or calendar event in this MyApp. Each pill shows the live name; edits in the target update it automatically.")
                        .font(.caption)
                }
            }
            .navigationTitle("Edit item")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onClose)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: commit)
                        .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                ToolbarItem(placement: .destructiveAction) {
                    Button(role: .destructive, action: deleteItem) {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
            #if os(macOS)
            .frame(minWidth: 380, idealWidth: 460, minHeight: 360, idealHeight: 520)
            #endif
            .sheet(isPresented: $pickerPresented) {
                ComponentItemPickerSheet(
                    store: store,
                    myAppId: myAppId,
                    excludeRef: editingItemRef,
                    alreadyLinked: Set(linkedItems),
                    onPick: { newRefs in
                        var seen = Set(linkedItems)
                        for ref in newRefs where seen.insert(ref).inserted {
                            linkedItems.append(ref)
                        }
                        pickerPresented = false
                    },
                    onClose: { pickerPresented = false }
                )
            }
        }
        .linkedItemPopupHost(store: store, myAppId: myAppId)
        .onAppear(perform: loadInitial)
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
            onRemove: { linkedItems.removeAll { $0 == ref } }
        )
    }

    private func loadInitial() {
        text = item.text
        done = item.done
        linkedItems = item.linkedItems
    }

    private func commit() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var patch = MyAppStore.ChecklistItemPatch()
        patch.text = trimmed
        patch.done = done
        patch.linkedItems = linkedItems
        _ = store.patchChecklistItem(id: item.id, patch: patch, myAppId: myAppId, componentId: componentId)
        onClose()
    }

    private func deleteItem() {
        _ = store.removeChecklistItem(id: item.id, myAppId: myAppId, componentId: componentId)
        onClose()
    }
}

