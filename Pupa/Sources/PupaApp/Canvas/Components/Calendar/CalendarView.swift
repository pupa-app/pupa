import SwiftUI

/// Calendar component view. Switches between a list and month-grid view
/// mode (toggled in the header or by the `setCalendarViewMode` tool); tap
/// an event in either mode to open the edit sheet. All mutations route
/// through `MyAppStore.patchCalendarEvent` / `addCalendarEvent` /
/// `removeCalendarEvent`, so the agent and the UI see the same source of
/// truth.
public struct CalendarView: View {
    @Bindable var store: MyAppStore
    let data: CalendarData
    /// MyApp the calendar lives in. Threaded down so linked-event
    /// resolution can find sibling tracker components in the same MyApp.
    let myAppId: UUID
    /// Component being rendered. Threaded into the view-mode toggle and the
    /// event editor so mutations land on THIS calendar, not the first
    /// calendar in the myApp (the kind-routed fallback ignores which
    /// component is on screen).
    let componentId: String?

    @State private var editorTarget: EditorTarget?

    public init(store: MyAppStore, data: CalendarData, myAppId: UUID, componentId: String? = nil) {
        self.store = store
        self.data = data
        self.myAppId = myAppId
        self.componentId = componentId
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            CalendarTitleBar(
                store: store,
                data: data,
                componentId: componentId,
                onAddEvent: { editorTarget = .new }
            )

            switch data.viewMode {
            case .list:
                CalendarListBody(
                    store: store,
                    data: data,
                    myAppId: myAppId,
                    onPickEvent: { event in editorTarget = .edit(event) }
                )
            case .month:
                CalendarMonthBody(
                    store: store,
                    data: data,
                    myAppId: myAppId,
                    onPickEvent: { event in editorTarget = .edit(event) }
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .sheet(item: $editorTarget) { target in
            CalendarEventEditorSheet(
                store: store,
                myAppId: myAppId,
                target: target,
                componentId: componentId,
                onClose: { editorTarget = nil }
            )
        }
    }
}

/// Sheet input: either editing an existing event or composing a new one.
/// Conforms to `Identifiable` so `.sheet(item:)` can drive presentation.
enum EditorTarget: Identifiable {
    case new
    case edit(CalendarEvent)

    var id: String {
        switch self {
        case .new: return "new"
        case .edit(let e): return "edit-\(e.id.uuidString)"
        }
    }
}

// MARK: - Title bar with view toggle

private struct CalendarTitleBar: View {
    @Bindable var store: MyAppStore
    let data: CalendarData
    var componentId: String? = nil
    let onAddEvent: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "calendar")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text(data.title)
                .font(.title2)
                .fontWeight(.semibold)
            Spacer()
            Text("\(data.events.count) event\(data.events.count == 1 ? "" : "s")")
                .font(.caption)
                .foregroundStyle(.secondary)
            // View-mode picker mirrors the tracker's grid/kanban toggle —
            // a Picker with a SegmentedStyle reads quickly and the mutation
            // routes through the same `setCalendarViewMode` path the agent
            // uses.
            Picker("View", selection: Binding(
                get: { data.viewMode },
                set: { store.setCalendarViewMode($0, componentId: componentId) }
            )) {
                Image(systemName: "list.bullet").tag(CalendarViewMode.list)
                Image(systemName: "square.grid.3x3").tag(CalendarViewMode.month)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 90)
            Button(action: onAddEvent) {
                Label("Add event", systemImage: "plus")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .help("Add event")
        }
    }
}

// MARK: - List body

private struct CalendarListBody: View {
    @Bindable var store: MyAppStore
    let data: CalendarData
    let myAppId: UUID
    let onPickEvent: (CalendarEvent) -> Void

    var body: some View {
        if data.events.isEmpty {
            CalendarEmptyHint()
        } else {
            VStack(alignment: .leading, spacing: 16) {
                ForEach(groupedDays(events: data.sortedEvents), id: \.dayKey) { group in
                    daySection(group)
                }
            }
        }
    }

    @ViewBuilder
    private func daySection(_ group: DayGroup) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(group.headerText)
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
            VStack(spacing: 0) {
                ForEach(group.events) { event in
                    Button(action: { onPickEvent(event) }) {
                        EventRow(event: event, store: store, myAppId: myAppId)
                    }
                    .buttonStyle(.plain)
                    if event.id != group.events.last?.id {
                        Divider()
                    }
                }
            }
            .background(Color.gray.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }
}

// MARK: - Month body

private struct CalendarMonthBody: View {
    @Bindable var store: MyAppStore
    let data: CalendarData
    let myAppId: UUID
    let onPickEvent: (CalendarEvent) -> Void

    @State private var displayedMonth: Date
    @State private var selectedDay: Date

    /// Anchor the initial month + selected day on the **first event** when
    /// the calendar has any — otherwise on today. If we always defaulted to
    /// today the user would see an empty grid when their events sit in a
    /// different month (e.g. seeded last year), which reads as "broken".
    init(
        store: MyAppStore,
        data: CalendarData,
        myAppId: UUID,
        onPickEvent: @escaping (CalendarEvent) -> Void
    ) {
        self.store = store
        self.data = data
        self.myAppId = myAppId
        self.onPickEvent = onPickEvent
        let anchor: Date = {
            let starts = data.events.compactMap { parseEventStart($0.start) }.sorted()
            return starts.first ?? Date()
        }()
        self._displayedMonth = State(initialValue: monthStart(for: anchor))
        self._selectedDay = State(initialValue: Calendar.current.startOfDay(for: anchor))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            monthHeader
            weekdayRow
            monthGrid
            selectedDayEvents
        }
    }

    private var monthHeader: some View {
        HStack {
            Button {
                if let next = Calendar.current.date(byAdding: .month, value: -1, to: displayedMonth) {
                    displayedMonth = monthStart(for: next)
                }
            } label: { Image(systemName: "chevron.left") }
            .buttonStyle(.borderless)

            Text(monthLabel(displayedMonth))
                .font(.headline)
                .frame(maxWidth: .infinity)

            Button("Today") {
                let today = Date()
                displayedMonth = monthStart(for: today)
                selectedDay = Calendar.current.startOfDay(for: today)
            }
            .buttonStyle(.borderless)
            .font(.caption)

            Button {
                if let next = Calendar.current.date(byAdding: .month, value: 1, to: displayedMonth) {
                    displayedMonth = monthStart(for: next)
                }
            } label: { Image(systemName: "chevron.right") }
            .buttonStyle(.borderless)
        }
    }

    private var weekdayRow: some View {
        HStack(spacing: 0) {
            ForEach(weekdaySymbols(), id: \.self) { sym in
                Text(sym)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private var monthGrid: some View {
        let cells = monthCells(for: displayedMonth)
        let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 7)
        return LazyVGrid(columns: columns, spacing: 4) {
            ForEach(cells, id: \.self) { date in
                dayCell(date)
            }
        }
    }

    @ViewBuilder
    private func dayCell(_ date: Date) -> some View {
        let cal = Calendar.current
        let inMonth = cal.isDate(date, equalTo: displayedMonth, toGranularity: .month)
        let isSelected = cal.isDate(date, inSameDayAs: selectedDay)
        let isToday = cal.isDateInToday(date)
        let count = eventCount(on: date)
        Button {
            selectedDay = cal.startOfDay(for: date)
        } label: {
            VStack(spacing: 2) {
                Text("\(cal.component(.day, from: date))")
                    .font(.callout.monospacedDigit())
                    .fontWeight(isToday ? .bold : .regular)
                    .foregroundStyle(inMonth ? Color.primary : Color.secondary.opacity(0.5))
                HStack(spacing: 2) {
                    ForEach(0..<min(count, 3), id: \.self) { _ in
                        Circle()
                            .fill(isSelected ? Color.white : Color.accentColor)
                            .frame(width: 4, height: 4)
                    }
                    if count > 3 {
                        Text("+")
                            .font(.caption2)
                            .foregroundStyle(isSelected ? Color.white : Color.accentColor)
                    }
                    if count == 0 {
                        Color.clear.frame(width: 4, height: 4)
                    }
                }
            }
            .frame(maxWidth: .infinity, minHeight: 36)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isSelected ? Color.accentColor : (isToday ? Color.accentColor.opacity(0.15) : Color.clear))
            )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var selectedDayEvents: some View {
        let events = eventsOn(date: selectedDay)
        VStack(alignment: .leading, spacing: 8) {
            Text(longDayLabel(for: selectedDay))
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
            if events.isEmpty {
                Text("No events on this day")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 12)
            } else {
                VStack(spacing: 0) {
                    ForEach(events) { event in
                        Button(action: { onPickEvent(event) }) {
                            EventRow(event: event, store: store, myAppId: myAppId)
                        }
                        .buttonStyle(.plain)
                        if event.id != events.last?.id { Divider() }
                    }
                }
                .background(Color.gray.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
    }

    // MARK: - Date helpers

    private func eventsOn(date: Date) -> [CalendarEvent] {
        let cal = Calendar.current
        return data.sortedEvents.filter { event in
            guard let d = parseEventStart(event.start) else { return false }
            return cal.isDate(d, inSameDayAs: date)
        }
    }

    private func eventCount(on date: Date) -> Int {
        eventsOn(date: date).count
    }
}

// MARK: - Shared row + helpers

private struct EventRow: View {
    let event: CalendarEvent
    @Bindable var store: MyAppStore
    let myAppId: UUID

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(timeText(for: event))
                .font(.callout.monospacedDigit())
                .fontWeight(.medium)
                .foregroundStyle(.primary)
                .frame(width: 110, alignment: .leading)

            VStack(alignment: .leading, spacing: 4) {
                Text(event.title)
                    .font(.body)
                    .fontWeight(.medium)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if !event.linkedItems.isEmpty {
                    LinkedItemsRow(refs: event.linkedItems, store: store, myAppId: myAppId)
                }
                if let location = event.location, !location.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "mappin.and.ellipse").font(.caption)
                        Text(location).font(.caption)
                    }
                    .foregroundStyle(.secondary)
                }
                if let notes = event.notes, !notes.isEmpty {
                    Text(notes)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.secondary.opacity(0.4))
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .contentShape(Rectangle())
    }
}

/// Horizontal list of linked-item pills shown under an event title.
/// Each pill: chain-link icon + target's live display name (pulled
/// from the target component at render time, so edits propagate).
/// Targets may be any kind — `displayNameForRefTarget` dispatches per
/// kind. Wraps to multiple lines on small widths via `FlowLayout`.
private struct LinkedItemsRow: View {
    let refs: [ComponentItemRef]
    @Bindable var store: MyAppStore
    let myAppId: UUID

    var body: some View {
        FlowLayout(spacing: 4) {
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
            .frame(maxWidth: 220, alignment: .leading)
    }
}

/// Minimal flow layout — wraps children to the next row when they
/// overflow the available width. SwiftUI's built-in `Layout` makes this
/// a few lines; avoids pulling in a dependency for one place.
private struct FlowLayout: Layout {
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
        // Never report a width wider than the container: a single very long
        // pill must not push the row (and the whole canvas) beyond page fit.
        if maxWidth.isFinite { maxRowWidth = min(maxRowWidth, maxWidth) }
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

private struct CalendarEmptyHint: View {
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "calendar")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("No events yet")
                .font(.headline)
            Text("Tap + to add one, or ask the chat: \"Add a coffee meeting Friday at 2pm\".")
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

// MARK: - Event editor sheet

struct CalendarEventEditorSheet: View {
    @Bindable var store: MyAppStore
    let myAppId: UUID
    let target: EditorTarget
    /// Calendar component the edited event belongs to. Set by the linked-
    /// item popup dispatcher so mutations target the right component even
    /// when it's not the active one; nil from in-place edits in the owning
    /// CalendarView (which always edits its own active calendar).
    var componentId: String? = nil
    let onClose: () -> Void

    @State private var title: String = ""
    @State private var start: Date = Date()
    @State private var hasEnd: Bool = false
    @State private var end: Date = Date().addingTimeInterval(3600)
    @State private var location: String = ""
    @State private var notes: String = ""
    /// In-flight linked-items list — committed to the event on Save.
    @State private var linkedItems: [ComponentItemRef] = []
    @State private var pickerPresented: Bool = false

    private var isNew: Bool {
        if case .new = target { return true }
        return false
    }

    /// Source ref of the event being edited, or nil for a new event.
    /// Passed into the picker so the picker hides this event from the
    /// "Link items" list — an event cannot link to itself.
    private var editingEventRef: ComponentItemRef? {
        if case .edit(let event) = target {
            if let componentId {
                return ComponentItemRef(componentId: componentId, itemId: event.id)
            }
            guard let calComp = store.myApps.first(where: { $0.id == myAppId })?
                .components.first(where: {
                    if case .calendar = $0.body { return true }
                    return false
                })?.id else { return nil }
            return ComponentItemRef(componentId: calComp, itemId: event.id)
        }
        return nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Title") {
                    TextField("Event title", text: $title)
                }
                Section("When") {
                    DatePicker("Starts", selection: $start, displayedComponents: [.date, .hourAndMinute])
                    Toggle("Has end time", isOn: $hasEnd)
                    if hasEnd {
                        DatePicker("Ends", selection: $end, displayedComponents: [.date, .hourAndMinute])
                    }
                }
                Section("Location") {
                    TextField("Optional", text: $location)
                }
                Section("Notes") {
                    TextField("Optional", text: $notes, axis: .vertical)
                        .lineLimit(3...8)
                }
                Section {
                    if linkedItems.isEmpty {
                        Text("Nothing linked yet")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(linkedItems, id: \.self) { ref in
                            linkedItemRow(ref)
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
                    Text("Attach any tracker row, calendar event, or checklist row in this MyApp. Each pill shows the live name; edits in the target update it automatically.")
                        .font(.caption)
                }
            }
            .navigationTitle(isNew ? "New event" : "Edit event")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onClose)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isNew ? "Add" : "Save", action: commit)
                        .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if !isNew {
                    ToolbarItem(placement: .destructiveAction) {
                        Button(role: .destructive, action: deleteEvent) {
                            Label("Delete", systemImage: "trash")
                        }
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
                    // Hide the event being edited from the picker so it
                    // can never link to itself. .new has no id yet, so
                    // there's nothing to exclude.
                    excludeRef: editingEventRef,
                    alreadyLinked: Set(linkedItems),
                    onPick: { newRefs in
                        // Append new picks, preserving order and de-dup.
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
    private func linkedItemRow(_ ref: ComponentItemRef) -> some View {
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
        if case .edit(let event) = target {
            title = event.title
            start = parseEventStart(event.start) ?? Date()
            if let endStr = event.end, let d = parseEventStart(endStr) {
                hasEnd = true
                end = d
            } else {
                hasEnd = false
                end = start.addingTimeInterval(3600)
            }
            location = event.location ?? ""
            notes = event.notes ?? ""
            linkedItems = event.linkedItems
        }
    }

    private func commit() {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else { return }
        let f = makeISOFormatter()
        let trimmedLoc = location.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalisedLoc: String? = trimmedLoc.isEmpty ? nil : trimmedLoc
        let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalisedNotes: String? = trimmedNotes.isEmpty ? nil : trimmedNotes
        switch target {
        case .new:
            let event = CalendarEvent(
                title: trimmedTitle,
                start: f.string(from: start),
                end: hasEnd ? f.string(from: end) : nil,
                location: normalisedLoc,
                notes: normalisedNotes,
                linkedItems: linkedItems
            )
            _ = store.addCalendarEvent(event, myAppId: myAppId, componentId: componentId)
        case .edit(let original):
            var patch = MyAppStore.CalendarEventPatch()
            patch.title = trimmedTitle
            patch.start = f.string(from: start)
            patch.end = .some(hasEnd ? f.string(from: end) : nil)
            patch.location = .some(normalisedLoc)
            patch.notes = .some(normalisedNotes)
            patch.linkedItems = linkedItems
            _ = store.patchCalendarEvent(id: original.id, patch: patch, myAppId: myAppId, componentId: componentId)
        }
        onClose()
    }

    private func deleteEvent() {
        if case .edit(let event) = target {
            _ = store.removeCalendarEvent(id: event.id, myAppId: myAppId, componentId: componentId)
        }
        onClose()
    }
}

// MARK: - Date / formatting helpers (file-scope)

/// Build a fresh ISO-8601 formatter on demand. `ISO8601DateFormatter` is
/// not `Sendable` so we can't cache it as a top-level `let`; cost is
/// negligible relative to the rest of a calendar render.
fileprivate func makeISOFormatter() -> ISO8601DateFormatter {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f
}

/// Parse an event's `start`/`end` ISO-8601 string into a Date. Permissive:
/// handles full ISO-8601 with timezone, ISO-8601 without timezone, and
/// pure date strings (YYYY-MM-DD) — the last interprets as midnight local
/// time. Returns nil if nothing parses.
fileprivate func parseEventStart(_ iso: String) -> Date? {
    if let d = makeISOFormatter().date(from: iso) { return d }
    let plain = DateFormatter()
    plain.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
    plain.timeZone = TimeZone.current
    if let d = plain.date(from: iso) { return d }
    let dateOnly = DateFormatter()
    dateOnly.dateFormat = "yyyy-MM-dd"
    return dateOnly.date(from: iso)
}

fileprivate func formatTime(_ iso: String, fallback: String? = "—") -> String? {
    if let date = parseEventStart(iso) {
        // Pure-date strings are "all day"
        if iso.count == 10 { return "All day" }
        let f = DateFormatter()
        f.timeStyle = .short
        return f.string(from: date)
    }
    return fallback
}

fileprivate func monthStart(for date: Date) -> Date {
    let cal = Calendar.current
    let comps = cal.dateComponents([.year, .month], from: date)
    return cal.date(from: comps) ?? date
}

fileprivate func monthLabel(_ date: Date) -> String {
    let f = DateFormatter()
    f.dateFormat = "MMMM yyyy"
    return f.string(from: date)
}

fileprivate func weekdaySymbols() -> [String] {
    var f = DateFormatter().shortWeekdaySymbols ?? ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
    // Rotate so Monday is first — matches macOS Calendar default in most locales.
    let firstWeekday = Calendar.current.firstWeekday
    f = Array(f[(firstWeekday - 1)...] + f[..<(firstWeekday - 1)])
    return f
}

/// Build the 6-week (42-cell) grid for `displayedMonth`, padding leading
/// and trailing cells with adjacent-month dates so the grid is always
/// rectangular. The view dims out-of-month cells visually.
fileprivate func monthCells(for displayedMonth: Date) -> [Date] {
    let cal = Calendar.current
    let firstOfMonth = monthStart(for: displayedMonth)
    let weekdayOfFirst = cal.component(.weekday, from: firstOfMonth)
    // Map cal.firstWeekday (1...7) onto "days before" the first-of-month.
    let firstWeekday = cal.firstWeekday
    let lead = (weekdayOfFirst - firstWeekday + 7) % 7
    guard let gridStart = cal.date(byAdding: .day, value: -lead, to: firstOfMonth) else {
        return []
    }
    return (0..<42).compactMap { offset in
        cal.date(byAdding: .day, value: offset, to: gridStart)
    }
}

fileprivate func longDayLabel(for date: Date) -> String {
    let cal = Calendar.current
    let f = DateFormatter()
    f.dateFormat = "EEE d MMM yyyy"
    let base = f.string(from: date)
    if cal.isDateInToday(date) { return "Today · \(base)" }
    if cal.isDateInTomorrow(date) { return "Tomorrow · \(base)" }
    if cal.isDateInYesterday(date) { return "Yesterday · \(base)" }
    return base
}

/// One day's worth of events grouped under a header label, used by the
/// list view (the month view groups per-day inline via `eventsOn`).
fileprivate struct DayGroup: Hashable {
    static func == (lhs: DayGroup, rhs: DayGroup) -> Bool { lhs.dayKey == rhs.dayKey }
    func hash(into hasher: inout Hasher) { hasher.combine(dayKey) }

    let dayKey: String
    let headerText: String
    let events: [CalendarEvent]
}

fileprivate func groupedDays(events: [CalendarEvent]) -> [DayGroup] {
    var keyOrder: [String] = []
    var buckets: [String: (label: String, events: [CalendarEvent])] = [:]
    for event in events {
        let key = String(event.start.prefix(10))
        if buckets[key] == nil {
            keyOrder.append(key)
            buckets[key] = (label: dayLabel(forKey: key), events: [])
        }
        buckets[key]?.events.append(event)
    }
    return keyOrder.compactMap { key in
        guard let bucket = buckets[key] else { return nil }
        return DayGroup(dayKey: key, headerText: bucket.label, events: bucket.events)
    }
}

fileprivate func timeText(for event: CalendarEvent) -> String {
    let start = formatTime(event.start)
    guard let end = event.end, let endText = formatTime(end, fallback: nil) else {
        return start ?? "—"
    }
    return "\(start ?? "—")–\(endText)"
}

fileprivate func dayLabel(forKey key: String) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd"
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    guard let date = formatter.date(from: key) else { return "Unknown date" }
    return longDayLabel(for: date)
}
