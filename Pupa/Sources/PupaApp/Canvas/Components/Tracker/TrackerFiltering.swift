import Foundation

/// Row selection shared by both tracker views: the persisted select-field
/// `filter` plus the ephemeral free-text search query, and the kanban lane
/// bucketing that consumes the result.
///
/// Pure and SwiftUI-free on purpose — both `TrackerView` and `KanbanView`
/// must select rows identically (kanban used to bucket `data.items` raw and
/// silently ignore `filter`), and the "Untitled #n" numbering contract is
/// easier to pin in a test that needs no store.
enum TrackerFiltering {

    #if DEBUG
    /// Test-only tally of the once-per-call normalisations: the search needle
    /// plus each active filter value. Backs the perf invariant that these are
    /// hoisted out of the row loop — the count must not move with item count.
    /// Unsafe by declaration, safe in practice: Pupa's suite is `--no-parallel`.
    nonisolated(unsafe) static var normalizeCountForTesting = 0
    /// Test-only tally of per-row value lowercasings. This is the term that
    /// scales with the board, so what matters is how *few* rows and fields it
    /// touches: an idle board must not pay for search at all.
    nonisolated(unsafe) static var valueScanCountForTesting = 0

    static func resetCountersForTesting() {
        normalizeCountForTesting = 0
        valueScanCountForTesting = 0
    }
    #endif

    struct Entry: Identifiable, Hashable {
        let item: TrackerItem
        /// Index in the UNFILTERED items array. Drives the card's
        /// "Untitled #n" fallback, which must not renumber as rows drop out
        /// while the user types.
        let positionIndex: Int
        var id: UUID { item.id }
    }

    /// Rows passing both the select filter (AND across non-empty entries,
    /// case-insensitive exact match) and the search query (case-insensitive
    /// substring across every non-image field value).
    ///
    /// Pass `data.visibleFields` — hidden fields then drop out of search for
    /// free. `.image` values are excluded because they are URLs, and a
    /// hero-image column would make "https" match every row.
    static func visibleEntries(
        items: [TrackerItem],
        fields: [FieldDef],
        filter: [String: String],
        query: String
    ) -> [Entry] {
        let activeFilter = filter.filter { !$0.value.isEmpty }
            .mapValues { value -> String in
                #if DEBUG
                normalizeCountForTesting += 1
                #endif
                return value.lowercased()
            }
        #if DEBUG
        normalizeCountForTesting += 1
        #endif
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let searchable = fields.filter { $0.type != .image }.map(\.name)

        var out: [Entry] = []
        out.reserveCapacity(items.count)
        for (idx, item) in items.enumerated() {
            guard matchesFilter(item, activeFilter) else { continue }
            guard needle.isEmpty || matchesQuery(item, needle, in: searchable) else { continue }
            out.append(Entry(item: item, positionIndex: idx))
        }
        return out
    }

    private static func matchesFilter(_ item: TrackerItem, _ filter: [String: String]) -> Bool {
        for (field, wanted) in filter {
            #if DEBUG
            valueScanCountForTesting += 1
            #endif
            if (item.values[field] ?? "").lowercased() != wanted { return false }
        }
        return true
    }

    private static func matchesQuery(
        _ item: TrackerItem,
        _ needle: String,
        in fields: [String]
    ) -> Bool {
        fields.contains { name in
            guard let value = item.values[name], !value.isEmpty else { return false }
            #if DEBUG
            valueScanCountForTesting += 1
            #endif
            return value.lowercased().contains(needle)
        }
    }

    // MARK: - Kanban lanes

    /// Id of the implicit lane holding items whose column value is empty or
    /// not one of the field's options.
    static let unsetLaneId = "__unset__"

    struct LaneBucket {
        let id: String
        /// Value written to the column field when a card is dropped on this
        /// lane. Empty string for "(Unset)".
        let laneValue: String
        let title: String
        let entries: [Entry]
    }

    /// One bucket per column option in declaration order, plus a trailing
    /// "(Unset)" bucket. Every lane is returned even when empty: the lane set
    /// must depend only on the field schema, never on which rows currently
    /// match, so filtering or searching never reflows the board.
    static func lanes(entries: [Entry], column: FieldDef) -> [LaneBucket] {
        let options = column.options ?? []
        var buckets: [String: [Entry]] = [:]
        var unset: [Entry] = []

        for entry in entries {
            let value = (entry.item.values[column.name] ?? "")
                .trimmingCharacters(in: .whitespaces)
            if value.isEmpty || !options.contains(value) {
                unset.append(entry)
            } else {
                buckets[value, default: []].append(entry)
            }
        }

        var lanes = options.map { opt in
            LaneBucket(id: opt, laneValue: opt, title: opt, entries: buckets[opt] ?? [])
        }
        lanes.append(LaneBucket(
            id: unsetLaneId,
            laneValue: "",
            title: "(Unset)",
            entries: unset
        ))
        return lanes
    }
}
