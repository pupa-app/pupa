import Foundation

/// The notification composer's "when" controls as a value, with the two-way
/// mapping to a `NotificationRequest.Trigger`.
///
/// Lives outside the view so the round-trip can be tested: a lossy one
/// silently retimes somebody's reminder when they open it to fix a typo.
struct NotificationTriggerDraft: Equatable {
    enum Kind: String, CaseIterable, Identifiable {
        case now = "Now"
        case after = "In..."
        case atDate = "At..."
        case daily = "Daily"
        case weekly = "Weekly"
        case everyNHours = "Every..."
        var id: String { rawValue }
    }

    static let delayMinutesRange = 1...60

    /// Display name for a `Calendar`-indexed weekday (1 = Sunday).
    static func weekdayName(_ weekday: Int) -> String {
        Calendar.current.weekdaySymbols[weekday - 1]
    }

    var kind: Kind = .now
    var delayMinutes = 5
    var atDate: Date
    var timeOfDay: Date
    var weekday = 2
    var everyHours = 4

    init(now: Date = Date()) {
        atDate = now.addingTimeInterval(3_600)
        timeOfDay = now
    }

    /// Seed from an existing trigger. `.after` becomes the absolute instant it
    /// resolved to: the delay is already running, and the minutes stepper
    /// can't express one longer than an hour without truncating it.
    init(trigger: NotificationRequest.Trigger, deliveryAt: Date?, now: Date = Date()) {
        self.init(now: now)
        switch trigger {
        case .now:
            kind = .now
        case .after:
            kind = .atDate
            atDate = max(deliveryAt ?? atDate, now)
        case .atDate(let date):
            kind = .atDate
            atDate = max(date, now)
        case .daily(let hour, let minute):
            kind = .daily
            timeOfDay = Self.time(hour: hour, minute: minute, on: now)
        case .weekly(let day, let hour, let minute):
            kind = .weekly
            weekday = day
            timeOfDay = Self.time(hour: hour, minute: minute, on: now)
        case .everyNHours(let hours):
            kind = .everyNHours
            everyHours = hours
        }
    }

    var trigger: NotificationRequest.Trigger {
        let clock = Calendar.current.dateComponents([.hour, .minute], from: timeOfDay)
        let hour = clock.hour ?? 9
        let minute = clock.minute ?? 0
        switch kind {
        case .now: return .now
        case .after: return .after(seconds: delayMinutes * 60)
        case .atDate: return .atDate(atDate)
        case .daily: return .daily(hour: hour, minute: minute)
        case .weekly: return .weekly(weekday: weekday, hour: hour, minute: minute)
        case .everyNHours: return .everyNHours(everyHours)
        }
    }

    private static func time(hour: Int, minute: Int, on day: Date) -> Date {
        Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: day) ?? day
    }
}
