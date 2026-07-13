import Foundation
import Testing
import AGUIKit
@testable import PupaApp

/// Pins the `sendNotification` tool's arg-parsing surface — the only piece
/// of the notification path that does not depend on `UNUserNotificationCenter`
/// and is therefore safe to exercise in this non-app test process.
@Suite("NotificationRequest parsing")
struct NotificationRequestTests {

    private func args(_ obj: [String: AnyJSON]) -> AnyJSON { .object(obj) }

    @Test("kind=now parses with title + body")
    func parsesNow() throws {
        let req = try NotificationRequest(fromToolArgs: args([
            "title": .string("Hi"),
            "body": .string("There"),
            "trigger": .object(["kind": .string("now")]),
        ]))
        #expect(req.title == "Hi")
        #expect(req.body == "There")
        if case .now = req.trigger {} else { Issue.record("expected .now"); return }
    }

    @Test("kind=after carries seconds through")
    func parsesAfter() throws {
        let req = try NotificationRequest(fromToolArgs: args([
            "title": .string("Kettle"),
            "body": .string("Off"),
            "trigger": .object(["kind": .string("after"), "seconds": .int(300)]),
        ]))
        guard case .after(let seconds) = req.trigger else { Issue.record("expected .after"); return }
        #expect(seconds == 300)
    }

    @Test("kind=after rejects out-of-range seconds")
    func rejectsAfterOutOfRange() {
        #expect(throws: NotificationRequest.ParseError.self) {
            _ = try NotificationRequest(fromToolArgs: args([
                "title": .string("x"),
                "body": .string("y"),
                "trigger": .object(["kind": .string("after"), "seconds": .int(0)]),
            ]))
        }
        #expect(throws: NotificationRequest.ParseError.self) {
            _ = try NotificationRequest(fromToolArgs: args([
                "title": .string("x"),
                "body": .string("y"),
                "trigger": .object(["kind": .string("after"), "seconds": .int(99_999_999)]),
            ]))
        }
    }

    @Test("kind=atDate accepts ISO-8601 in the future")
    func parsesAtDateFuture() throws {
        let future = Date().addingTimeInterval(3_600)
        let iso = NotificationRequest.formatISO8601(future)
        let req = try NotificationRequest(fromToolArgs: args([
            "title": .string("Call mom"),
            "body": .string("Now"),
            "trigger": .object(["kind": .string("atDate"), "iso8601": .string(iso)]),
        ]))
        guard case .atDate(let d) = req.trigger else { Issue.record("expected .atDate"); return }
        // ISO-8601 second-precision round-trip may shave fractions; allow a tiny tolerance.
        #expect(abs(d.timeIntervalSince(future)) < 1.0)
    }

    @Test("kind=atDate in the past throws")
    func rejectsAtDatePast() {
        let past = Date().addingTimeInterval(-3_600)
        let iso = NotificationRequest.formatISO8601(past)
        #expect(throws: NotificationRequest.ParseError.self) {
            _ = try NotificationRequest(fromToolArgs: args([
                "title": .string("x"),
                "body": .string("y"),
                "trigger": .object(["kind": .string("atDate"), "iso8601": .string(iso)]),
            ]))
        }
    }

    @Test("kind=atDate with unparseable ISO throws")
    func rejectsUnparseableISO() {
        #expect(throws: NotificationRequest.ParseError.self) {
            _ = try NotificationRequest(fromToolArgs: args([
                "title": .string("x"),
                "body": .string("y"),
                "trigger": .object(["kind": .string("atDate"), "iso8601": .string("not-a-date")]),
            ]))
        }
    }

    @Test("missing title or body throws")
    func rejectsMissingFields() {
        #expect(throws: NotificationRequest.ParseError.self) {
            _ = try NotificationRequest(fromToolArgs: args([
                "body": .string("y"),
                "trigger": .object(["kind": .string("now")]),
            ]))
        }
        #expect(throws: NotificationRequest.ParseError.self) {
            _ = try NotificationRequest(fromToolArgs: args([
                "title": .string("x"),
                "trigger": .object(["kind": .string("now")]),
            ]))
        }
    }

    @Test("unknown trigger kind throws")
    func rejectsUnknownKind() {
        #expect(throws: NotificationRequest.ParseError.self) {
            _ = try NotificationRequest(fromToolArgs: args([
                "title": .string("x"),
                "body": .string("y"),
                "trigger": .object(["kind": .string("everyMonday")]),
            ]))
        }
    }

    @Test("title / body length caps enforced")
    func rejectsOverlongStrings() {
        let longTitle = String(repeating: "a", count: NotificationRequest.titleMaxLength + 1)
        let longBody = String(repeating: "b", count: NotificationRequest.bodyMaxLength + 1)
        #expect(throws: NotificationRequest.ParseError.self) {
            _ = try NotificationRequest(fromToolArgs: args([
                "title": .string(longTitle),
                "body": .string("ok"),
                "trigger": .object(["kind": .string("now")]),
            ]))
        }
        #expect(throws: NotificationRequest.ParseError.self) {
            _ = try NotificationRequest(fromToolArgs: args([
                "title": .string("ok"),
                "body": .string(longBody),
                "trigger": .object(["kind": .string("now")]),
            ]))
        }
    }

    @Test("triggerEcho mirrors the parsed trigger")
    func triggerEchoShape() throws {
        let req = try NotificationRequest(fromToolArgs: args([
            "title": .string("Hi"),
            "body": .string("There"),
            "trigger": .object(["kind": .string("after"), "seconds": .int(42)]),
        ]))
        guard case .object(let obj) = req.triggerEcho() else { Issue.record("expected object"); return }
        #expect(obj["kind"] == .string("after"))
        #expect(obj["seconds"] == .int(42))
    }

    @Test("target with myAppId only is parsed")
    func parsesTargetAppOnly() throws {
        let id = UUID()
        let req = try NotificationRequest(fromToolArgs: args([
            "title": .string("Done"),
            "body": .string("Check it out"),
            "trigger": .object(["kind": .string("now")]),
            "target": .object(["myAppId": .string(id.uuidString)]),
        ]))
        #expect(req.target?.myAppId == id)
        #expect(req.target?.componentId == nil)
    }

    @Test("target with myAppId + componentId is parsed")
    func parsesTargetWithComponent() throws {
        let id = UUID()
        let req = try NotificationRequest(fromToolArgs: args([
            "title": .string("Done"),
            "body": .string("Check it out"),
            "trigger": .object(["kind": .string("now")]),
            "target": .object([
                "myAppId": .string(id.uuidString),
                "componentId": .string("tracker-1"),
            ]),
        ]))
        #expect(req.target?.myAppId == id)
        #expect(req.target?.componentId == "tracker-1")
    }

    @Test("target is nil when omitted")
    func targetNilWhenOmitted() throws {
        let req = try NotificationRequest(fromToolArgs: args([
            "title": .string("Hi"),
            "body": .string("There"),
            "trigger": .object(["kind": .string("now")]),
        ]))
        #expect(req.target == nil)
    }

    @Test("target with invalid UUID is silently ignored")
    func targetIgnoresInvalidUUID() throws {
        let req = try NotificationRequest(fromToolArgs: args([
            "title": .string("Hi"),
            "body": .string("There"),
            "trigger": .object(["kind": .string("now")]),
            "target": .object(["myAppId": .string("not-a-uuid")]),
        ]))
        #expect(req.target == nil)
    }

    // MARK: - Recurring presets

    private func recurring(_ trigger: [String: AnyJSON]) throws -> NotificationRequest {
        try NotificationRequest(fromToolArgs: args([
            "title": .string("Remind"),
            "body": .string("Ping"),
            "trigger": .object(trigger),
        ]))
    }

    @Test("kind=daily parses hour + minute and echoes")
    func parsesDaily() throws {
        let req = try recurring(["kind": .string("daily"), "hour": .int(22), "minute": .int(0)])
        guard case .daily(let h, let m) = req.trigger else { Issue.record("expected .daily"); return }
        #expect(h == 22)
        #expect(m == 0)
        #expect(req.trigger.repeats)
        guard case .object(let obj) = req.triggerEcho() else { Issue.record("expected object"); return }
        #expect(obj["kind"] == .string("daily"))
        #expect(obj["hour"] == .int(22))
        #expect(obj["minute"] == .int(0))
    }

    @Test("kind=daily rejects out-of-range hour / minute")
    func rejectsDailyOutOfRange() {
        for bad in [["hour": AnyJSON.int(24), "minute": .int(0)],
                    ["hour": .int(-1), "minute": .int(0)],
                    ["hour": .int(9), "minute": .int(60)]] {
            #expect(throws: NotificationRequest.ParseError.self) {
                _ = try self.recurring(bad.merging(["kind": .string("daily")]) { a, _ in a })
            }
        }
    }

    @Test("kind=daily missing minute throws")
    func rejectsDailyMissingField() {
        #expect(throws: NotificationRequest.ParseError.self) {
            _ = try self.recurring(["kind": .string("daily"), "hour": .int(9)])
        }
    }

    @Test("kind=weekly uses Calendar weekday indexing (Sunday=1)")
    func parsesWeeklySundayIndexed() throws {
        let req = try recurring([
            "kind": .string("weekly"), "weekday": .int(1), "hour": .int(9), "minute": .int(30),
        ])
        guard case .weekly(let wd, let h, let m) = req.trigger else { Issue.record("expected .weekly"); return }
        #expect(wd == 1)  // Sunday, not offset
        #expect(h == 9)
        #expect(m == 30)
        #expect(req.trigger.repeats)
        // weekday 0 and 8 are out of the 1...7 range.
        for badWeekday in [0, 8] {
            #expect(throws: NotificationRequest.ParseError.self) {
                _ = try self.recurring([
                    "kind": .string("weekly"), "weekday": .int(badWeekday),
                    "hour": .int(9), "minute": .int(0),
                ])
            }
        }
    }

    @Test("kind=everyNHours parses hours and rejects out-of-range")
    func parsesEveryNHours() throws {
        let req = try recurring(["kind": .string("everyNHours"), "hours": .int(6)])
        guard case .everyNHours(let hours) = req.trigger else { Issue.record("expected .everyNHours"); return }
        #expect(hours == 6)
        #expect(req.trigger.repeats)
        guard case .object(let obj) = req.triggerEcho() else { Issue.record("expected object"); return }
        #expect(obj["kind"] == .string("everyNHours"))
        #expect(obj["hours"] == .int(6))
        for bad in [0, 25] {
            #expect(throws: NotificationRequest.ParseError.self) {
                _ = try self.recurring(["kind": .string("everyNHours"), "hours": .int(bad)])
            }
        }
    }

    @Test("Trigger.repeats is false for one-shot triggers")
    func oneShotDoesNotRepeat() throws {
        let now = try recurring(["kind": .string("now")])
        #expect(!now.trigger.repeats)
        let after = try recurring(["kind": .string("after"), "seconds": .int(60)])
        #expect(!after.trigger.repeats)
    }

    @Test("deliveryAt: everyNHours advances by hours*3600 from the reference")
    func deliveryAtEveryNHours() throws {
        let ref = Date(timeIntervalSince1970: 1_700_000_000)
        let req = try NotificationRequest(fromToolArgs: args([
            "title": .string("x"), "body": .string("y"),
            "trigger": .object(["kind": .string("everyNHours"), "hours": .int(2)]),
        ]), now: ref)
        #expect(req.deliveryAt(referenceDate: ref) == ref.addingTimeInterval(7200))
    }

    @Test("deliveryAt: daily lands on the requested hour/minute in the future")
    func deliveryAtDaily() throws {
        let ref = Date(timeIntervalSince1970: 1_700_000_000)
        let req = try recurring(["kind": .string("daily"), "hour": .int(22), "minute": .int(0)])
        let next = req.deliveryAt(referenceDate: ref)
        #expect(next > ref)
        let comps = Calendar.current.dateComponents([.hour, .minute], from: next)
        #expect(comps.hour == 22)
        #expect(comps.minute == 0)
    }

    // MARK: - Tap actions

    private func withTap(_ tap: [String: AnyJSON]?) throws -> NotificationRequest {
        var obj: [String: AnyJSON] = [
            "title": .string("Hi"),
            "body": .string("There"),
            "trigger": .object(["kind": .string("now")]),
        ]
        if let tap { obj["tapAction"] = .object(tap) }
        return try NotificationRequest(fromToolArgs: args(obj))
    }

    @Test("tapAction absent defaults to foreground")
    func tapActionDefaultsForeground() throws {
        let req = try withTap(nil)
        #expect(req.tapAction == .foreground)
    }

    @Test("tapAction=foreground ignores any prompt")
    func tapActionForegroundIgnoresPrompt() throws {
        let req = try withTap(["kind": .string("foreground"), "prompt": .string("ignored")])
        #expect(req.tapAction == .foreground)
    }

    @Test("tapAction=populateChat carries prompt and echoes")
    func tapActionPopulateChat() throws {
        let req = try withTap(["kind": .string("populateChat"), "prompt": .string("Log my mood")])
        #expect(req.tapAction == .populateChat(prompt: "Log my mood"))
        guard case .object(let obj) = req.tapActionEcho() else { Issue.record("expected object"); return }
        #expect(obj["kind"] == .string("populateChat"))
        #expect(obj["prompt"] == .string("Log my mood"))
    }

    @Test("tapAction=runAgent carries prompt")
    func tapActionRunAgent() throws {
        let req = try withTap(["kind": .string("runAgent"), "prompt": .string("Summarize trackers")])
        #expect(req.tapAction == .runAgent(prompt: "Summarize trackers"))
    }

    @Test("tapAction populateChat/runAgent require a non-empty prompt")
    func tapActionRequiresPrompt() {
        for kind in ["populateChat", "runAgent"] {
            #expect(throws: NotificationRequest.ParseError.self) {
                _ = try self.withTap(["kind": .string(kind)])
            }
            #expect(throws: NotificationRequest.ParseError.self) {
                _ = try self.withTap(["kind": .string(kind), "prompt": .string("")])
            }
        }
    }

    @Test("tapAction rejects over-length prompt")
    func tapActionRejectsOverlongPrompt() {
        let long = String(repeating: "z", count: NotificationRequest.tapPromptMaxLength + 1)
        #expect(throws: NotificationRequest.ParseError.self) {
            _ = try self.withTap(["kind": .string("runAgent"), "prompt": .string(long)])
        }
    }

    @Test("unknown tapAction kind throws")
    func tapActionUnknownKind() {
        #expect(throws: NotificationRequest.ParseError.self) {
            _ = try self.withTap(["kind": .string("openBrowser"), "prompt": .string("x")])
        }
    }

    @Test("weekly + runAgent + target round-trip together")
    func combinedRecurringTapTarget() throws {
        let id = UUID()
        let req = try NotificationRequest(fromToolArgs: args([
            "title": .string("Morning brief"),
            "body": .string("Ready"),
            "trigger": .object([
                "kind": .string("weekly"), "weekday": .int(2), "hour": .int(8), "minute": .int(0),
            ]),
            "target": .object(["myAppId": .string(id.uuidString), "componentId": .string("tracker-1")]),
            "tapAction": .object(["kind": .string("runAgent"), "prompt": .string("Summarize")]),
        ]))
        guard case .weekly(let wd, _, _) = req.trigger else { Issue.record("expected .weekly"); return }
        #expect(wd == 2)
        #expect(req.target?.myAppId == id)
        #expect(req.target?.componentId == "tracker-1")
        #expect(req.tapAction == .runAgent(prompt: "Summarize"))
    }
}
