import Foundation
import Testing
@testable import PupaApp

/// The composer's trigger mapping. A lossy round-trip here silently retimes
/// somebody's reminder when they open it to fix a typo — which is exactly what
/// the old minutes-clamped `.after` case did to anything over an hour.
@Suite("NotificationTriggerDraft")
struct NotificationTriggerDraftTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func roundTrip(
        _ trigger: NotificationRequest.Trigger,
        deliveryAt: Date? = nil
    ) -> NotificationRequest.Trigger {
        NotificationTriggerDraft(trigger: trigger, deliveryAt: deliveryAt, now: now).trigger
    }

    @Test("recurring presets survive a round-trip unchanged")
    func recurringRoundTrips() {
        #expect(roundTrip(.daily(hour: 7, minute: 30)) == .daily(hour: 7, minute: 30))
        #expect(
            roundTrip(.weekly(weekday: 5, hour: 18, minute: 45))
                == .weekly(weekday: 5, hour: 18, minute: 45)
        )
        #expect(roundTrip(.everyNHours(6)) == .everyNHours(6))
        #expect(roundTrip(.now) == .now)
    }

    @Test("a future atDate survives unchanged")
    func atDateRoundTrips() {
        let when = now.addingTimeInterval(86_400)
        #expect(roundTrip(.atDate(when)) == .atDate(when))
    }

    @Test("an after-delay becomes the instant it resolved to, however long")
    func longDelayKeepsItsInstant() {
        // Six hours: the minutes stepper caps at 60, so mapping back to
        // `.after` would truncate this to one hour on save.
        let due = now.addingTimeInterval(6 * 3_600)
        #expect(roundTrip(.after(seconds: 6 * 3_600), deliveryAt: due) == .atDate(due))
    }

    @Test("a delivery instant already past is pulled up to now, never scheduled backwards")
    func pastInstantClampsToNow() {
        let overdue = now.addingTimeInterval(-3_600)
        #expect(roundTrip(.atDate(overdue)) == .atDate(now))
        #expect(roundTrip(.after(seconds: 60), deliveryAt: overdue) == .atDate(now))
    }

    @Test("a fresh draft schedules for now")
    func freshDraftIsNow() {
        #expect(NotificationTriggerDraft(now: now).trigger == .now)
    }
}
