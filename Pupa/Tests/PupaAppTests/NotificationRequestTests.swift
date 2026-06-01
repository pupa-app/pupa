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
}
