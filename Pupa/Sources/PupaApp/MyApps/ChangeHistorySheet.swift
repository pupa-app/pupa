import SwiftUI

/// Routes for the Change History sheet presented from the sidebar's
/// per-MyApp "History" row.
public enum ChangeHistorySheetDestination: Identifiable, Hashable {
    case forMyApp(myAppId: UUID)

    public var id: UUID {
        switch self { case .forMyApp(let id): return id }
    }
}

/// Sheet body — shows a newest-first list of `ItemEvent`s for a given
/// MyApp, grouped by calendar day, with an Undo button per reversible row.
public struct ChangeHistorySheet: View {
    @Bindable var store: MyAppStore
    let myAppId: UUID
    var onClose: () -> Void

    private let cal = Calendar.autoupdatingCurrent
    private let relFmt: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    private var events: [ItemEvent] {
        store.itemEventLog.events(forMyApp: myAppId).reversed()
    }

    private var groupedByDay: [(label: String, events: [ItemEvent])] {
        var result: [(label: String, events: [ItemEvent])] = []
        var current: (label: String, events: [ItemEvent])? = nil
        for event in events {
            let label = dayLabel(for: event.timestamp)
            if current?.label == label {
                current!.events.append(event)
            } else {
                if let c = current { result.append(c) }
                current = (label, [event])
            }
        }
        if let c = current { result.append(c) }
        return result
    }

    public var body: some View {
        NavigationStack {
            Group {
                if events.isEmpty {
                    ContentUnavailableView(
                        "No changes yet",
                        systemImage: "clock",
                        description: Text("Changes made through the app or agent will appear here.")
                    )
                } else {
                    List {
                        ForEach(groupedByDay, id: \.label) { group in
                            Section(group.label) {
                                ForEach(group.events) { event in
                                    ChangeHistoryRow(
                                        event: event,
                                        summary: store.changeSummary(for: event),
                                        relFmt: relFmt
                                    ) {
                                        _ = store.undo(eventId: event.id)
                                    }
                                }
                            }
                        }
                    }
                    #if os(iOS)
                    .listStyle(.insetGrouped)
                    #endif
                }
            }
            .navigationTitle("History")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { onClose() }
                }
            }
        }
    }

    private func dayLabel(for date: Date) -> String {
        if cal.isDateInToday(date) { return "Today" }
        if cal.isDateInYesterday(date) { return "Yesterday" }
        let fmt = DateFormatter()
        fmt.dateStyle = .medium
        fmt.timeStyle = .none
        return fmt.string(from: date)
    }
}

private struct ChangeHistoryRow: View {
    let event: ItemEvent
    let summary: String
    let relFmt: RelativeDateTimeFormatter
    var onUndo: () -> Void

    private var isReversible: Bool {
        event.inverse() != nil && !event.undone && !event.isUndo
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            actorGlyph
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(summary)
                    .font(.subheadline)
                    .foregroundStyle(event.undone ? .secondary : .primary)
                    .strikethrough(event.undone)
                HStack(spacing: 4) {
                    Text(relFmt.localizedString(for: event.timestamp, relativeTo: Date()))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    if event.undone {
                        Text("· undone")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    } else if event.isUndo {
                        Text("· undo")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer()

            if isReversible {
                Button("Undo") { onUndo() }
                    .font(.caption)
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var actorGlyph: some View {
        switch event.actor {
        case .user:
            Image(systemName: "person.fill")
                .foregroundStyle(.secondary)
        case .agent:
            Image(systemName: "sparkles")
                .foregroundStyle(Color.orchestratorColor)
        }
    }
}
