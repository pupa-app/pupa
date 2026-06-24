import SwiftUI

/// Change-history page — a newest-first list of `ItemEvent`s for a given
/// MyApp, grouped by calendar day, with an Undo button per reversible row.
/// Pushed onto the detail `NavigationStack` from the bottom bar's History
/// button (the parent stack supplies the nav bar + back button).
public struct ChangeHistoryView: View {
    @Bindable var store: MyAppStore
    let myAppId: UUID

    private let cal = Calendar.autoupdatingCurrent
    private let relFmt: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    private var app: MyApp? { store.myApps.first { $0.id == myAppId } }
    private var appColor: Color { .color(atIndex: store.colorIndex(for: myAppId)) }

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
        // Pinned page header so it's always clear this is a MyApp's History —
        // matches the eyebrow + name header on the other MyApp pages.
        .safeAreaInset(edge: .top, spacing: 0) {
            MyAppPageHeader(
                page: "History",
                name: app?.name ?? "History",
                icon: "clock",
                color: appColor
            )
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.bar)
            .overlay(alignment: .bottom) { Divider() }
        }
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
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
