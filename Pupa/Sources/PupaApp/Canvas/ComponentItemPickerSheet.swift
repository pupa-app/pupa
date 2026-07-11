import SwiftUI

/// Generic multi-select picker over every link-bearing item in a MyApp.
/// Replaces the per-kind picker sheets that lived inside `CalendarView`
/// and `ChecklistView` before project `0.0.41`. Each link-bearing
/// component (tracker, calendar, checklist) shows up as its own
/// `Section`; tapping items toggles them in / out of the in-flight
/// selection and "Done" hands the picked refs back to the caller.
///
/// Caller responsibilities:
///
/// - Pass `excludeRef` to hide the source item itself from the list —
///   the true self-reference `(source == target)` is the only link the
///   store rejects, and the picker enforces it upfront so the row never
///   appears as a selectable target.
/// - Pass `alreadyLinked` to grey out refs the source already holds; the
///   user can still see them, just can't double-pick.
/// - On "Done", `onPick` receives the **newly picked** refs only (no
///   re-affirmation of the already-linked set); merge them into the
///   source's `linkedItems` and persist via the appropriate store
///   mutator (`setTrackerItemLinkedItems`, `patchCalendarEvent` /
///   `patchChecklistItem` with a wholesale `linkedItems` patch).
struct ComponentItemPickerSheet: View {
    @Bindable var store: MyAppStore
    let myAppId: UUID
    /// Source ref hidden from the picker (a row cannot link to itself).
    /// Pass `nil` when the picker is opened for a brand-new item that
    /// doesn't have a stable id yet.
    let excludeRef: ComponentItemRef?
    let alreadyLinked: Set<ComponentItemRef>
    let onPick: ([ComponentItemRef]) -> Void
    let onClose: () -> Void

    @State private var selected: Set<ComponentItemRef> = []

    var body: some View {
        NavigationStack {
            List {
                ForEach(linkableComponents, id: \.id) { comp in
                    Section(sectionHeader(for: comp)) {
                        let entries = items(in: comp)
                        if entries.isEmpty {
                            Text(emptyHint(for: comp))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(entries, id: \.0) { (itemId, displayName) in
                                let ref = ComponentItemRef(componentId: comp.id, itemId: itemId)
                                if ref != excludeRef {
                                    row(for: ref, displayName: displayName)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Link items")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onClose)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { onPick(Array(selected)) }
                        .disabled(selected.isEmpty)
                }
            }
            #if os(macOS)
            .frame(minWidth: 380, idealWidth: 460, minHeight: 360, idealHeight: 520)
            #endif
        }
    }

    @ViewBuilder
    private func row(for ref: ComponentItemRef, displayName: String) -> some View {
        let isLinked = alreadyLinked.contains(ref)
        let isPicked = selected.contains(ref)
        Button {
            guard !isLinked else { return }
            if isPicked { selected.remove(ref) } else { selected.insert(ref) }
        } label: {
            HStack {
                Image(systemName: isLinked
                      ? "checkmark.circle.fill"
                      : (isPicked ? "checkmark.circle.fill" : "circle"))
                    .foregroundStyle(isLinked || isPicked ? Color.accentColor : Color.secondary)
                Text(displayName)
                    .foregroundStyle(isLinked ? .secondary : .primary)
                Spacer()
                if isLinked {
                    Text("Already linked")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(isLinked)
    }

    /// Every link-bearing component in the MyApp. Empty components are
    /// excluded (they hold nothing to link to). Order matches the
    /// sidebar so the picker reads predictably.
    private var linkableComponents: [Component] {
        guard let myApp = store.myApps.first(where: { $0.id == myAppId }) else { return [] }
        return myApp.components.filter {
            ComponentRegistry.shared.module(forKind: $0.kindString)?.isLinkable ?? false
        }
    }

    private func sectionHeader(for comp: Component) -> String {
        "\(comp.name) (\(comp.kindString))"
    }

    private func emptyHint(for comp: Component) -> String {
        ComponentRegistry.shared.module(forKind: comp.kindString)?.linkPickerEmptyHint
            ?? "Nothing to link here yet"
    }

    private func items(in comp: Component) -> [(UUID, String)] {
        guard let module = ComponentRegistry.shared.module(forKind: comp.kindString) else { return [] }
        return module.linkableItems(in: comp, store: store, myAppId: myAppId)
            .map { ($0.id, $0.displayName) }
    }
}
