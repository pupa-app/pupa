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
