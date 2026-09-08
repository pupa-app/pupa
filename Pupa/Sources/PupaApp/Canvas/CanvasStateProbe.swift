#if DEBUG
import Foundation

/// Test-only record of what a canvas component view resolved on its last
/// render. Backs the swap harness, which drives a real `CanvasView` through a
/// component change and asserts state did not carry over.
///
/// A probe rather than an assertion on `@State` directly: SwiftUI exposes no
/// supported way to read a hosted view's private state. Same shape as
/// `TrackerFiltering.normalizeCountForTesting`; unsynchronised, relying on the
/// suite being `--no-parallel`.
enum CanvasStateProbe {
    /// Component key each render resolved, oldest first.
    nonisolated(unsafe) static var keys: [CanvasComponentKey] = []
    /// Month each `CalendarMonthBody` render displayed, oldest first.
    nonisolated(unsafe) static var calendarMonths: [Date] = []

    static func reset() {
        keys = []
        calendarMonths = []
    }

    static func record(key: CanvasComponentKey, month: Date? = nil) {
        keys.append(key)
        if let month { calendarMonths.append(month) }
    }
}
#endif
