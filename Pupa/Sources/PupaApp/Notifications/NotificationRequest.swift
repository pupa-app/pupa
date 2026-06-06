import Foundation
import AGUIKit

/// Value-type description of a notification the agent wants to schedule.
/// Built from the `sendNotification` tool args by `init(fromToolArgs:)` and
/// consumed by `NotificationCenterCoordinator.schedule(_:)`.
public struct NotificationRequest: Sendable, Hashable {
    public enum Trigger: Sendable, Hashable {
        /// Fire as soon as the OS will allow. Maps to a `UNTimeIntervalNotificationTrigger`
        /// with a tiny epsilon (iOS rejects `timeInterval == 0`).
        case now
        /// Fire `seconds` seconds from when the system accepts the request.
        case after(seconds: Int)
        /// Fire at the given absolute wall-clock instant.
        case atDate(Date)
    }

    public enum ParseError: Error, CustomStringConvertible {
        case missingField(String)
        case invalidTrigger(String)
        case titleTooLong(Int)
        case bodyTooLong(Int)
        case secondsOutOfRange(Int)
        case unparseableDate(String)
        case pastDate(String)

        public var description: String {
            switch self {
            case .missingField(let f): return "missing '\(f)'"
            case .invalidTrigger(let m): return "invalid trigger: \(m)"
            case .titleTooLong(let n): return "title too long (\(n) > 64 chars)"
            case .bodyTooLong(let n): return "body too long (\(n) > 256 chars)"
            case .secondsOutOfRange(let s): return "seconds=\(s) out of range (1..31536000)"
            case .unparseableDate(let s): return "could not parse '\(s)' as ISO-8601"
            case .pastDate(let s): return "atDate '\(s)' is in the past"
            }
        }
    }

    /// Optional deep-link target. When present, tapping the notification banner
    /// navigates the app to the specified myApp (and optionally component).
    public struct Target: Sendable, Hashable {
        public let myAppId: UUID
        /// Component to focus, e.g. `"tracker-1"`. Nil opens the myApp home.
        public let componentId: String?

        public init(myAppId: UUID, componentId: String? = nil) {
            self.myAppId = myAppId
            self.componentId = componentId
        }
    }

    public static let titleMaxLength = 64
    public static let bodyMaxLength = 256
    public static let secondsRange = 1...31_536_000

    public let title: String
    public let body: String
    public let trigger: Trigger
    /// Where to navigate when the user taps the notification banner.
    /// Nil means tapping just foregrounds the app with no extra routing.
    public let target: Target?

    public init(title: String, body: String, trigger: Trigger, target: Target? = nil) {
        self.title = title
        self.body = body
        self.trigger = trigger
        self.target = target
    }

    /// Build from the raw `AnyJSON` the tool registry hands us, or throw a
    /// `ParseError` describing what's wrong. Callers map the error
    /// description into the tool's `{ok: false, error: ...}` echo.
    public init(fromToolArgs args: AnyJSON, now: Date = Date()) throws {
        guard let title = args["title"]?.stringValue, !title.isEmpty else {
            throw ParseError.missingField("title")
        }
        if title.count > Self.titleMaxLength { throw ParseError.titleTooLong(title.count) }

        guard let body = args["body"]?.stringValue, !body.isEmpty else {
            throw ParseError.missingField("body")
        }
        if body.count > Self.bodyMaxLength { throw ParseError.bodyTooLong(body.count) }

        guard let trigger = args["trigger"], case .object = trigger else {
            throw ParseError.missingField("trigger")
        }
        guard let kind = trigger["kind"]?.stringValue else {
            throw ParseError.invalidTrigger("missing 'kind'")
        }

        let parsedTrigger: Trigger
        switch kind {
        case "now":
            parsedTrigger = .now
        case "after":
            guard let seconds = trigger["seconds"]?.intValue else {
                throw ParseError.invalidTrigger("'after' requires integer 'seconds'")
            }
            if !Self.secondsRange.contains(seconds) {
                throw ParseError.secondsOutOfRange(seconds)
            }
            parsedTrigger = .after(seconds: seconds)
        case "atDate":
            guard let iso = trigger["iso8601"]?.stringValue else {
                throw ParseError.invalidTrigger("'atDate' requires 'iso8601'")
            }
            guard let date = Self.parseISO8601(iso) else {
                throw ParseError.unparseableDate(iso)
            }
            if date <= now {
                throw ParseError.pastDate(iso)
            }
            parsedTrigger = .atDate(date)
        default:
            throw ParseError.invalidTrigger("unknown kind '\(kind)' (expected now / after / atDate)")
        }

        var target: Target? = nil
        if let targetArg = args["target"], case .object = targetArg,
           let idStr = targetArg["myAppId"]?.stringValue,
           let uuid = UUID(uuidString: idStr) {
            let componentId = targetArg["componentId"]?.stringValue
            target = Target(myAppId: uuid, componentId: componentId)
        }

        self.init(title: title, body: body, trigger: parsedTrigger, target: target)
    }

    /// Compute the delivery instant the user will see in the echo payload.
    /// `.now` resolves to ~100 ms after `referenceDate` (matches the
    /// coordinator's epsilon) so the agent's `deliveryAt` matches reality.
    public func deliveryAt(referenceDate: Date = Date()) -> Date {
        switch trigger {
        case .now: return referenceDate.addingTimeInterval(0.1)
        case .after(let seconds): return referenceDate.addingTimeInterval(TimeInterval(seconds))
        case .atDate(let date): return date
        }
    }

    /// Mirror of the parsed trigger as a JSON object for the tool echo.
    public func triggerEcho() -> AnyJSON {
        switch trigger {
        case .now:
            return .object(["kind": .string("now")])
        case .after(let seconds):
            return .object(["kind": .string("after"), "seconds": .int(seconds)])
        case .atDate(let date):
            return .object([
                "kind": .string("atDate"),
                "iso8601": .string(Self.formatISO8601(date)),
            ])
        }
    }

    // MARK: - ISO-8601 helpers

    /// Parse an ISO-8601 string, accepting both fractional and second-precision.
    /// `ISO8601DateFormatter` is non-`Sendable`, so we allocate per call rather
    /// than caching — the cost is negligible compared to the agent round-trip.
    public static func parseISO8601(_ s: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = fractional.date(from: s) { return d }
        let seconds = ISO8601DateFormatter()
        seconds.formatOptions = [.withInternetDateTime]
        return seconds.date(from: s)
    }

    public static func formatISO8601(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }
}
