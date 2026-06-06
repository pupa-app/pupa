import Foundation

/// Pure, store-free reduce over a tracker's items. Pulls one numeric field
/// off every item that passes a case-insensitive AND equality filter, then
/// folds the parsed values to a single scalar. No SwiftUI, no store, no
/// MainActor — `CalculatorResolver` calls it for `aggregate` rows, and
/// Phase 2 (#22) reuses it for chart series.
public enum TrackerAggregator {

    /// Outcome of a reduce. `value` is the scalar the caller surfaces;
    /// `matchedItems` / `numericValues` let the caller distinguish "no
    /// matching rows" from "matching rows but nothing parsed as a number"
    /// (the latter is a `nonNumeric` situation for sum/avg/min/max).
    public struct Outcome: Equatable, Sendable {
        public var value: Double
        public var matchedItems: Int
        public var numericValues: Int

        public init(value: Double, matchedItems: Int, numericValues: Int) {
            self.value = value
            self.matchedItems = matchedItems
            self.numericValues = numericValues
        }
    }

    /// Reduce `field` over `items` after applying `filter`.
    ///
    /// - `count` returns the number of items passing the filter (it never
    ///   needs the field to parse as a number, so `value == matchedItems`).
    /// - `sum` / `avg` / `min` / `max` parse the field of each matched item
    ///   via `parseNumber`, skipping empty / unparseable values. `sum` of
    ///   nothing is `0`; `avg` / `min` / `max` of nothing is `0` with
    ///   `numericValues == 0` so the caller can flag it.
    public static func reduce(
        _ reduce: CalcReduce,
        field: String,
        items: [TrackerItem],
        filter: [String: String] = [:]
    ) -> Outcome {
        let matched = items.filter { matches($0, filter: filter) }

        if reduce == .count {
            return Outcome(value: Double(matched.count), matchedItems: matched.count, numericValues: matched.count)
        }

        let numbers = matched.compactMap { parseNumber($0.values[field]) }
        let count = numbers.count
        let value: Double
        switch reduce {
        case .sum:
            value = numbers.reduce(0, +)
        case .avg:
            value = count > 0 ? numbers.reduce(0, +) / Double(count) : 0
        case .min:
            value = numbers.min() ?? 0
        case .max:
            value = numbers.max() ?? 0
        case .count:
            value = Double(count)  // unreachable — handled above
        }
        return Outcome(value: value, matchedItems: matched.count, numericValues: count)
    }

    /// Convenience over `reduce(_:field:items:filter:)` for callers holding
    /// a `TrackerData` + `AggregateSpec`.
    public static func reduce(_ spec: AggregateSpec, over tracker: TrackerData) -> Outcome {
        reduce(spec.reduce, field: spec.fieldName, items: tracker.items, filter: spec.filter)
    }

    /// Group `items` (after `filter`) by their `groupBy` value, reduce
    /// `valueField` within each group, and emit one `ChartPoint` per group.
    /// Phase 2 (#22) calls this for `tracker`-sourced charts.
    ///
    /// - `label` is the group value; `y` the per-group reduced scalar.
    /// - When `xIsNumericOrDate` is true the group value is parsed to a
    ///   continuous `x` (a number, or an ISO-8601 / `yyyy-MM-dd` date as a
    ///   Unix timestamp) and the points are sorted ascending by `x` — the
    ///   "unidirectional x axis" for line / bar over a date or numeric field.
    ///   Groups whose value doesn't parse sort to the front (`x == nil`
    ///   treated as `-inf`). When false, points keep first-seen group order
    ///   and `x` stays nil (categorical axis / pie sectors).
    public static func series(
        valueField: String,
        groupBy: String,
        reduce reduceOp: CalcReduce,
        items: [TrackerItem],
        filter: [String: String] = [:],
        xIsNumericOrDate: Bool = false
    ) -> [ChartPoint] {
        let matched = items.filter { matches($0, filter: filter) }

        // Group preserving first-seen order so a categorical axis stays stable.
        var groups: [String: [TrackerItem]] = [:]
        var order: [String] = []
        for item in matched {
            let key = item.values[groupBy]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(item)
        }

        var points: [ChartPoint] = order.map { label in
            let outcome = reduce(reduceOp, field: valueField, items: groups[label] ?? [])
            let x: Double? = xIsNumericOrDate ? parseXAxis(label) : nil
            return ChartPoint(label: label, x: x, y: outcome.value)
        }

        if xIsNumericOrDate {
            points.sort { ($0.x ?? -.infinity) < ($1.x ?? -.infinity) }
        }
        return points
    }

    /// Parse a group-by value into a continuous x position: a plain number
    /// (via `parseNumber`), or a date (ISO-8601 instant, or `yyyy-MM-dd`) as a
    /// Unix timestamp. Returns nil when neither parses, so the caller can sort
    /// unparseable buckets to the front rather than crashing.
    static func parseXAxis(_ raw: String) -> Double? {
        if let n = parseNumber(raw) { return n }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Formatters built locally — `ISO8601DateFormatter` / `DateFormatter`
        // aren't `Sendable`, so a shared static would be a data race. Chart
        // series are small, so the per-call cost is negligible.
        if let date = ISO8601DateFormatter().date(from: trimmed) { return date.timeIntervalSince1970 }
        let day = DateFormatter()
        day.calendar = Calendar(identifier: .gregorian)
        day.locale = Locale(identifier: "en_US_POSIX")
        day.timeZone = TimeZone(identifier: "UTC")
        day.dateFormat = "yyyy-MM-dd"
        if let date = day.date(from: trimmed) { return date.timeIntervalSince1970 }
        return nil
    }

    /// Case-insensitive AND equality match: every `(key, value)` in `filter`
    /// must equal the item's value for `key` (both trimmed, compared
    /// case-insensitively). A missing key on the item fails the match.
    /// An empty filter matches every item.
    static func matches(_ item: TrackerItem, filter: [String: String]) -> Bool {
        for (key, wanted) in filter {
            let have = item.values[key]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if have.caseInsensitiveCompare(wanted.trimmingCharacters(in: .whitespacesAndNewlines)) != .orderedSame {
                return false
            }
        }
        return true
    }

    /// Parse a tracker field string into a Double. Tolerates surrounding
    /// whitespace, thousands separators (`1,234.50`), a leading currency
    /// symbol (`$`, `€`, `£`, `¥`), and a trailing percent sign (`12%` →
    /// `12`). Returns nil for empty / non-numeric values so they're skipped
    /// rather than counted as zero.
    static func parseNumber(_ raw: String?) -> Double? {
        guard var s = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        if let v = Double(s) { return v }
        // Strip common decorations and retry.
        s.removeAll { $0 == "," || $0 == "$" || $0 == "€" || $0 == "£" || $0 == "¥" || $0 == " " }
        if s.hasSuffix("%") { s.removeLast() }
        return Double(s)
    }
}
